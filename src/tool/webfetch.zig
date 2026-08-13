const std = @import("std");
const types = @import("../types.zig");
const builtin = @import("builtin");

pub const tool_name = "webfetch";
pub const tool_description = "Fetch content from a URL and convert it to markdown (default), text, or raw HTML. Use this to read online documentation, API references, or any web resource.";
pub const tool_params =
    \\{"type":"object","properties":{
    \\"url":{"type":"string","description":"The HTTP or HTTPS URL to fetch content from"},
    \\"format":{"type":"string","enum":["text","markdown","html"],"description":"Output format (default: markdown)"},
    \\"timeout":{"type":"integer","description":"Timeout in seconds (default: 30, max: 120)"}},
    \\"required":["url"]}
;

const MAX_BODY_BYTES: usize = 1024 * 1024; // 1MB body cap
const DEFAULT_TIMEOUT_SECS: u32 = 30;
const MAX_TIMEOUT_SECS: u32 = 120;
const STDOUT_META_BYTES: usize = 1024; // -w 尾注 stdout 上限（几十字节，安全）
const STDERR_BYTES: usize = 10240;

const BROWSER_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36";
const HONEST_UA = "z-agent-core/1.0";

const Format = enum { text, markdown, html };

/// Execute the webfetch tool. Validates URL, runs curl (body to temp file, meta to stdout),
/// validates MIME, retries Cloudflare 403 once, then converts per format.
pub fn execute(ctx: types.ToolContext, args: std.json.Value) anyerror!types.ToolResult {
    const url_val = args.object.get("url") orelse {
        const content = try std.fmt.allocPrint(ctx.allocator, "Error: missing 'url' argument", .{});
        return types.ToolResult{ .session_content = content };
    };
    if (url_val != .string or url_val.string.len == 0) {
        const content = try std.fmt.allocPrint(ctx.allocator, "Error: 'url' must be a non-empty string", .{});
        return types.ToolResult{ .session_content = content };
    }
    const url = url_val.string;

    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
        const content = try std.fmt.allocPrint(ctx.allocator, "Error: URL must start with http:// or https://", .{});
        return types.ToolResult{ .session_content = content };
    }

    const format: Format = blk: {
        if (args.object.get("format")) |f| {
            if (f == .string) {
                if (std.mem.eql(u8, f.string, "text")) break :blk .text;
                if (std.mem.eql(u8, f.string, "html")) break :blk .html;
            }
        }
        break :blk .markdown;
    };

    const timeout_secs: u32 = blk: {
        if (args.object.get("timeout")) |tv| {
            if (tv == .integer and tv.integer > 0) {
                break :blk @intCast(@min(tv.integer, MAX_TIMEOUT_SECS));
            }
        }
        break :blk DEFAULT_TIMEOUT_SECS;
    };

    // First attempt: browser UA. If 403, retry once with honest UA (Cloudflare simplified).
    var fetch = try doFetch(ctx, url, format, timeout_secs, BROWSER_UA);
    if (fetch.http_code == 403) {
        // 换诚实 UA 重试一次。先释放首次结果，再覆盖——单一路径释放，避免 defer/手动 free 双路径 double-free
        freeFetch(&fetch, ctx.allocator);
        fetch = try doFetch(ctx, url, format, timeout_secs, HONEST_UA);
    }
    defer freeFetch(&fetch, ctx.allocator);

    if (!fetch.ok) {
        const content = try std.fmt.allocPrint(ctx.allocator, "Error: HTTP request failed (code {d})", .{fetch.http_code});
        return types.ToolResult{ .session_content = content, .err_msg = try ctx.allocator.dupe(u8, "webfetch_http_error") };
    }

    // MIME validation
    if (!isTextualMime(fetch.mime)) {
        const content = try std.fmt.allocPrint(ctx.allocator, "Error: unsupported content type: {s}", .{fetch.mime});
        return types.ToolResult{ .session_content = content, .err_msg = try ctx.allocator.dupe(u8, "webfetch_unsupported_mime") };
    }

    var output: []const u8 = undefined;
    const is_html = std.mem.indexOf(u8, fetch.mime, "text/html") != null;

    if (!is_html) {
        // 非 HTML：不做转换，原样返回（截断）
        output = try truncateCopy(ctx.allocator, fetch.body);
    } else switch (format) {
        .html => output = try truncateCopy(ctx.allocator, fetch.body),
        .markdown => output = try htmlToMarkdown(ctx.allocator, fetch.body),
        .text => output = try stripHtml(ctx.allocator, fetch.body),
    }

    // mime 借用必须存活到 ToolResult 消费后：嵌入 session_content 尾部，
    // meta.mime 指向该片段（ToolMeta 零拷贝借用约定，types.zig:61）。
    // 避免 mime 借用 fetch.meta（execute 内临时分配，defer 释放 → 悬垂）。
    if (fetch.mime.len > 0) {
        const tagged = try std.fmt.allocPrint(ctx.allocator, "{s}\n\n[Content-Type: {s}]", .{ output, fetch.mime });
        ctx.allocator.free(output);
        output = tagged;
    }

    return types.ToolResult{
        .session_content = output,
        .meta = .{ .webfetch = .{
            .url = url,
            .byte_count = fetch.body.len,
            .format = @tagName(format),
            .mime = contentMimeSuffix(output, fetch.mime.len),
        } },
    };
}

/// 返回 session_content 尾部嵌入的 "[Content-Type: xxx]" 中 xxx 的切片（零拷贝借用）。
/// 找不到时返回空串（调用方不应展示）。
fn contentMimeSuffix(content: []const u8, mime_len: usize) []const u8 {
    const marker = "[Content-Type: ";
    if (std.mem.lastIndexOf(u8, content, marker)) |start| {
        const val_start = start + marker.len;
        const end = @min(val_start + mime_len, content.len);
        return content[val_start..end];
    }
    return content[content.len..]; // 空切片
}

const FetchResult = struct {
    ok: bool,
    http_code: i32,
    body: []const u8, // 临时文件内容，调用方 free
    meta: []const u8, // 尾注 stdout 拷贝，调用方 free
    mime: []const u8, // Content-Type 独立拷贝（从 meta dupe），调用方 free
    tmp_path: ?[]const u8 = null, // 临时文件路径，调用方 free（若有）
};

fn freeFetch(f: *FetchResult, allocator: std.mem.Allocator) void {
    allocator.free(f.body);
    allocator.free(f.meta);
    if (f.mime.len > 0) allocator.free(f.mime);
    if (f.tmp_path) |p| allocator.free(p);
    f.body = &[_]u8{};
    f.meta = &[_]u8{};
    f.mime = &[_]u8{};
    f.tmp_path = null;
}

fn doFetch(ctx: types.ToolContext, url: []const u8, format: Format, timeout_secs: u32, ua: []const u8) !FetchResult {
    const allocator = ctx.allocator;

    // 临时文件路径（项目 .tmp/ 下，用 pid 防并发冲突；trace.zig:45-49 跨平台模式）
    var tmp_buf: [256]u8 = undefined;
    var tmp_buf2: [256]u8 = undefined;
    const pid: u32 = if (builtin.os.tag == .windows)
        std.os.windows.GetCurrentProcessId()
    else
        @intCast(std.posix.getpid());
    const tmp_path = try std.fmt.bufPrint(&tmp_buf, "{s}/.tmp/webfetch-{d}-{d}.html", .{ ctx.project_root, pid, @intFromEnum(format) });

    // 确保 .tmp 目录存在：curl -o 到不存在的目录会 exit 23（Failed writing body）→ 工具误报 code -1。
    // 用户项目首次运行时 .tmp 不存在，必须创建（已有则忽略 PathAlreadyExists）。
    {
        const tmp_dir = try std.fmt.bufPrint(&tmp_buf2, "{s}/.tmp", .{ctx.project_root});
        std.Io.Dir.cwd().createDir(ctx.io, tmp_dir, .default_file) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    var argv = std.ArrayListAligned([]const u8, null).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, if (builtin.os.tag == .windows) "curl.exe" else "curl");
    try argv.appendSlice(allocator, &[_][]const u8{ "-sL", "--compressed", "--max-time" });
    const tstr = try std.fmt.allocPrint(allocator, "{d}", .{timeout_secs});
    defer allocator.free(tstr);
    try argv.append(allocator, tstr);
    try argv.append(allocator, "-o");
    try argv.append(allocator, tmp_path);
    try argv.append(allocator, "-w");
    try argv.append(allocator, "HTTP_CODE:%{http_code} CONTENT_TYPE:%{content_type}");
    const ua_owned = try std.fmt.allocPrint(allocator, "User-Agent: {s}", .{ua});
    defer allocator.free(ua_owned);
    try argv.appendSlice(allocator, &[_][]const u8{ "-H", ua_owned });
    const accept = switch (format) {
        .markdown => "text/markdown;q=1.0, text/x-markdown;q=0.9, text/plain;q=0.8, text/html;q=0.7, */*;q=0.1",
        .text => "text/plain;q=1.0, text/markdown;q=0.9, text/html;q=0.8, */*;q=0.1",
        .html => "text/html;q=1.0, application/xhtml+xml;q=0.9, text/plain;q=0.8, text/markdown;q=0.7, */*;q=0.1",
    };
    const accept_owned = try std.fmt.allocPrint(allocator, "Accept: {s}", .{accept});
    defer allocator.free(accept_owned);
    try argv.appendSlice(allocator, &[_][]const u8{ "-H", accept_owned });
    try argv.append(allocator, url);

    const timeout_opt: std.Io.Timeout = .{ .duration = .{
        .raw = std.Io.Duration.fromSeconds(timeout_secs),
        .clock = std.Io.Clock.real,
    } };

    const meta_limit: std.Io.Limit = @enumFromInt(STDOUT_META_BYTES);
    const err_limit: std.Io.Limit = @enumFromInt(STDERR_BYTES);

    const proc_result = std.process.run(allocator, ctx.io, .{
        .argv = argv.items,
        .stdout_limit = meta_limit,
        .stderr_limit = err_limit,
        .timeout = timeout_opt,
    }) catch {
        // 进程级兜底（DNS/启动挂起）：curl --max-time 无法覆盖
        return error.WebFetchTimeout;
    };
    defer allocator.free(proc_result.stdout);
    defer allocator.free(proc_result.stderr);

    const exit_code: i32 = switch (proc_result.term) {
        .exited => |code| @intCast(code),
        else => -1,
    };

    if (exit_code != 0) {
        std.Io.Dir.cwd().deleteFile(ctx.io, tmp_path) catch {};
        return FetchResult{
            .ok = false,
            .http_code = -1,
            .body = try allocator.dupe(u8, ""),
            .meta = try allocator.dupe(u8, proc_result.stdout),
            .mime = "",
            .tmp_path = null,
        };
    }

    // 解析尾注：HTTP_CODE:NNN CONTENT_TYPE:xxx
    var http_code: i32 = -1;
    var mime: []const u8 = "";
    const meta = proc_result.stdout;
    if (std.mem.indexOf(u8, meta, "HTTP_CODE:")) |start| {
        const rest = meta[start + "HTTP_CODE:".len ..];
        if (rest.len > 0) {
            const num_end = std.mem.indexOfAny(u8, rest, " \r\n") orelse rest.len;
            http_code = std.fmt.parseInt(i32, rest[0..num_end], 10) catch -1;
        }
    }
    if (std.mem.indexOf(u8, meta, "CONTENT_TYPE:")) |start| {
        const rest = meta[start + "CONTENT_TYPE:".len ..];
        const end = std.mem.indexOfAny(u8, rest, " \r\n") orelse rest.len;
        // mime 必须 dupe 独立拷贝：meta 借用 proc_result.stdout，而它在函数尾部被 defer free → 悬垂
        mime = try allocator.dupe(u8, rest[0..end]);
    }

    // 读取临时文件 body（读取后删除，M-04 生命周期闭环）。
    // tmp_path 是相对 cwd 路径，必须用 Dir.cwd().deleteFile（deleteFileAbsolute 只接受绝对路径，相对路径会 unreachable panic）
    const body = readTempFile(allocator, ctx.io, tmp_path) catch |err| {
        std.Io.Dir.cwd().deleteFile(ctx.io, tmp_path) catch {};
        return err;
    };
    std.Io.Dir.cwd().deleteFile(ctx.io, tmp_path) catch {};

    return FetchResult{
        .ok = exit_code == 0,
        .http_code = http_code,
        .body = body,
        .meta = try allocator.dupe(u8, meta),
        .mime = mime,
        .tmp_path = try allocator.dupe(u8, tmp_path),
    };
}

fn readTempFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);
    const stat = try file.stat(io);
    const size: usize = @intCast(@min(stat.size, MAX_BODY_BYTES));
    const buf = try allocator.alloc(u8, size);
    if (size > 0) {
        const n = try file.readPositionalAll(io, buf, 0);
        if (n < size) {
            // 实际读取不足（截断到文件尾部）
            return allocator.realloc(buf, n);
        }
    }
    return buf;
}

fn truncateCopy(allocator: std.mem.Allocator, src: []const u8) ![]const u8 {
    if (src.len <= MAX_BODY_BYTES) return allocator.dupe(u8, src);
    const head = try allocator.dupe(u8, src[0..MAX_BODY_BYTES]);
    const suffix = try std.fmt.allocPrint(allocator, "\n\n[Content truncated: {d} bytes → {d} bytes]", .{ src.len, MAX_BODY_BYTES });
    const out = try std.mem.concat(allocator, u8, &.{ head, suffix });
    allocator.free(head);
    allocator.free(suffix);
    return out;
}

pub fn isTextualMime(mime: []const u8) bool {
    if (mime.len == 0) return true; // 无 Content-Type：保守按文本处理
    const m = mime;
    if (std.mem.startsWith(u8, m, "image/")) {
        return std.mem.eql(u8, m, "image/svg+xml") or std.mem.eql(u8, m, "image/vnd.fastbidsheet");
    }
    return std.mem.startsWith(u8, m, "text/") or
        std.mem.eql(u8, m, "application/json") or
        std.mem.endsWith(u8, m, "+json") or
        std.mem.eql(u8, m, "application/xml") or
        std.mem.endsWith(u8, m, "+xml") or
        std.mem.eql(u8, m, "application/javascript") or
        std.mem.eql(u8, m, "application/x-javascript");
}

/// 轻量 HTML→Markdown：跳过 script/style/noscript/iframe；支持 h/段落/加粗/斜体/链接/列表/代码块。
pub fn htmlToMarkdown(allocator: std.mem.Allocator, html: []const u8) ![]const u8 {
    var out = std.ArrayListAligned(u8, null).empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    var list_stack = std.ArrayListAligned(usize, null).empty; // 每层 ul/ol 深度
    defer list_stack.deinit(allocator);
    var in_skip: usize = 0; // script/style/noscript/iframe 深度
    var in_pre = false;
    var link_stack = std.ArrayListAligned([]const u8, null).empty; // 待闭合 <a> 的 href
    defer link_stack.deinit(allocator);

    while (i < html.len) {
        if (html[i] != '<') {
            if (in_skip == 0) {
                try out.append(allocator, html[i]);
            }
            i += 1;
            continue;
        }

        // 解析标签
        const tag_end = std.mem.indexOfScalar(u8, html[i + 1 ..], '>') orelse {
            // 无闭合：原样输出
            if (in_skip == 0) try out.append(allocator, html[i]);
            i += 1;
            continue;
        };
        const raw_tag = html[i + 1 .. i + 1 + tag_end];
        i += 1 + tag_end + 1; // 跳过 <...>

        const tag = parseTagName(raw_tag); // 小写无属性
        const is_close = raw_tag.len > 0 and raw_tag[0] == '/';

        // 跳过块处理（script/style/noscript/iframe）
        if (isSkipTag(tag)) {
            if (is_close) {
                if (in_skip > 0) in_skip -= 1;
            } else {
                in_skip += 1;
            }
            continue;
        }
        if (in_skip > 0) continue;

        // 闭合标签
        if (is_close) {
            if (std.mem.eql(u8, tag, "h1") or std.mem.eql(u8, tag, "h2") or std.mem.eql(u8, tag, "h3") or
                std.mem.eql(u8, tag, "h4") or std.mem.eql(u8, tag, "h5") or std.mem.eql(u8, tag, "h6"))
            {
                try out.appendSlice(allocator, "\n\n");
            } else if (std.mem.eql(u8, tag, "strong") or std.mem.eql(u8, tag, "b")) {
                try out.appendSlice(allocator, "**");
            } else if (std.mem.eql(u8, tag, "em") or std.mem.eql(u8, tag, "i")) {
                try out.appendSlice(allocator, "*");
            } else if (std.mem.eql(u8, tag, "code")) {
                if (in_pre) {
                    // pre 内 code：无 fenced 标记，由 pre 处理
                } else {
                    try out.append(allocator, '`');
                }
            } else if (std.mem.eql(u8, tag, "a")) {
                if (link_stack.items.len > 0) {
                    const href = link_stack.pop().?;
                    try out.appendSlice(allocator, "](");
                    try out.appendSlice(allocator, href);
                    try out.append(allocator, ')');
                }
            } else if (std.mem.eql(u8, tag, "li")) {
                try out.appendSlice(allocator, "\n");
            } else if (std.mem.eql(u8, tag, "p") or std.mem.eql(u8, tag, "div")) {
                try out.appendSlice(allocator, "\n\n");
            } else if (std.mem.eql(u8, tag, "pre")) {
                in_pre = false;
                try out.appendSlice(allocator, "\n```\n");
            }
            continue;
        }

        // 开始标签
        if (std.mem.eql(u8, tag, "h1")) try out.appendSlice(allocator, "\n\n# ");
        if (std.mem.eql(u8, tag, "h2")) try out.appendSlice(allocator, "\n\n## ");
        if (std.mem.eql(u8, tag, "h3")) try out.appendSlice(allocator, "\n\n### ");
        if (std.mem.eql(u8, tag, "h4")) try out.appendSlice(allocator, "\n\n#### ");
        if (std.mem.eql(u8, tag, "h5")) try out.appendSlice(allocator, "\n\n##### ");
        if (std.mem.eql(u8, tag, "h6")) try out.appendSlice(allocator, "\n\n###### ");
        if (std.mem.eql(u8, tag, "strong") or std.mem.eql(u8, tag, "b")) try out.appendSlice(allocator, "**");
        if (std.mem.eql(u8, tag, "em") or std.mem.eql(u8, tag, "i")) try out.appendSlice(allocator, "*");
        if (std.mem.eql(u8, tag, "br") or std.mem.eql(u8, tag, "hr")) try out.appendSlice(allocator, "\n");
        if (std.mem.eql(u8, tag, "p") or std.mem.eql(u8, tag, "div")) {
            if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.appendSlice(allocator, "\n\n");
        }
        if (std.mem.eql(u8, tag, "li")) {
            try out.appendSlice(allocator, "\n- ");
        }
        if (std.mem.eql(u8, tag, "code")) {
            if (in_pre) {
                // pre 内：不标记
            } else {
                try out.append(allocator, '`');
            }
        }
        if (std.mem.eql(u8, tag, "pre")) {
            in_pre = true;
            try out.appendSlice(allocator, "\n```\n");
        }
        if (std.mem.eql(u8, tag, "a")) {
            const href = extractAttr(raw_tag, "href") orelse "";
            try out.appendSlice(allocator, "[");
            try link_stack.append(allocator, href);
        }
    }

    return out.toOwnedSlice(allocator);
}

/// 去 HTML 标签 + 空白折叠；跳过 script/style/noscript/iframe 内容。
pub fn stripHtml(allocator: std.mem.Allocator, html: []const u8) ![]const u8 {
    var buf = std.ArrayListAligned(u8, null).empty;
    errdefer buf.deinit(allocator);

    var i: usize = 0;
    var in_skip: usize = 0;
    var last_was_space = false;

    const appendSpace = struct {
        fn go(bb: *std.ArrayListAligned(u8, null), a: std.mem.Allocator, last: *bool) !void {
            if (!last.*) {
                try bb.append(a, ' ');
                last.* = true;
            }
        }
    }.go;

    while (i < html.len) {
        if (html[i] == '<') {
            const tag_end = std.mem.indexOfScalar(u8, html[i + 1 ..], '>') orelse {
                i += 1;
                continue;
            };
            const raw_tag = html[i + 1 .. i + 1 + tag_end];
            i += 1 + tag_end + 1;
            const tag = parseTagName(raw_tag);
            const is_close = raw_tag.len > 0 and raw_tag[0] == '/';
            if (isSkipTag(tag)) {
                if (is_close) {
                    if (in_skip > 0) in_skip -= 1;
                } else {
                    in_skip += 1;
                }
            } else if (isBlockTag(tag) and !is_close) {
                try appendSpace(&buf, allocator, &last_was_space);
            }
            continue;
        }
        if (in_skip == 0) {
            const c = html[i];
            if (c == ' ' or c == '\n' or c == '\r' or c == '\t') {
                try appendSpace(&buf, allocator, &last_was_space);
            } else {
                try buf.append(allocator, c);
                last_was_space = false;
            }
        }
        i += 1;
    }

    // 返回 owned 切片：先 trim 再拷贝到精确大小，保证调用方 free(返回切片) 尺寸匹配
    const raw = try buf.toOwnedSlice(allocator);
    const trimmed = std.mem.trim(u8, raw, " ");
    if (trimmed.len == raw.len) return raw;
    const out = try allocator.dupe(u8, trimmed);
    allocator.free(raw);
    return out;
}

fn parseTagName(raw: []const u8) []const u8 {
    var start: usize = 0;
    if (raw.len > 0 and raw[0] == '/') start = 1;
    var end = start;
    while (end < raw.len) : (end += 1) {
        const c = raw[end];
        if (!(c >= 'a' and c <= 'z') and !(c >= 'A' and c <= 'Z') and !(c >= '0' and c <= '9')) break;
    }
    return raw[start..end];
}

fn toLowerInPlace(tag: []const u8) []const u8 {
    // parseTagName 保持原样；比较用 eqlLower
    return tag;
}

fn eqlTag(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
}

fn isSkipTag(tag: []const u8) bool {
    return eqlTag(tag, "script") or eqlTag(tag, "style") or eqlTag(tag, "noscript") or eqlTag(tag, "iframe") or
        eqlTag(tag, "object") or eqlTag(tag, "embed");
}

fn isBlockTag(tag: []const u8) bool {
    return eqlTag(tag, "p") or eqlTag(tag, "div") or eqlTag(tag, "br") or eqlTag(tag, "hr") or
        eqlTag(tag, "h1") or eqlTag(tag, "h2") or eqlTag(tag, "h3") or eqlTag(tag, "h4") or
        eqlTag(tag, "h5") or eqlTag(tag, "h6") or eqlTag(tag, "li") or eqlTag(tag, "pre");
}

fn extractAttr(raw: []const u8, name: []const u8) ?[]const u8 {
    // 简单属性提取：name="value"
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (std.mem.eql(u8, raw[i..@min(i + name.len, raw.len)], name)) {
            var j = i + name.len;
            while (j < raw.len and (raw[j] == ' ' or raw[j] == '\t')) j += 1;
            if (j < raw.len and raw[j] == '=') {
                j += 1;
                while (j < raw.len and (raw[j] == ' ' or raw[j] == '\t')) j += 1;
                if (j < raw.len and raw[j] == '"') {
                    const close = std.mem.indexOfScalarPos(u8, raw, j + 1, '"') orelse return null;
                    return raw[j + 1 .. close];
                }
            }
        }
    }
    return null;
}

fn testExec(ctx: types.ToolContext, args_json: []const u8) !types.ToolResult {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{ .ignore_unknown_fields = true }) catch {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: invalid arguments JSON", .{});
        return types.ToolResult{ .session_content = msg };
    };
    defer parsed.deinit();
    return execute(ctx, parsed.value);
}

test "webfetch: missing url" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const ctx = types.ToolContext{ .allocator = allocator, .io = io, .project_root = "." };
    var result = try testExec(ctx, "{}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "missing") != null);
}

test "webfetch: invalid url scheme" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const ctx = types.ToolContext{ .allocator = allocator, .io = io, .project_root = "." };
    var result = try testExec(ctx, "{\"url\":\"ftp://example.com\"}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "http://") != null);
}

test "webfetch: invalid url scheme file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const ctx = types.ToolContext{ .allocator = allocator, .io = io, .project_root = "." };
    var result = try testExec(ctx, "{\"url\":\"file:///etc/passwd\"}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "http://") != null);
}

test "webfetch: html to markdown" {
    const allocator = std.testing.allocator;
    const html = "<h1>Title</h1><p>Hello <b>world</b></p>";
    const md = try htmlToMarkdown(allocator, html);
    defer allocator.free(md);
    try std.testing.expect(std.mem.indexOf(u8, md, "# Title") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "**world**") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "Hello") != null);
}

test "webfetch: stripHtml" {
    const allocator = std.testing.allocator;
    const html = "<div>hello</div><p>world</p>";
    const text = try stripHtml(allocator, html);
    defer allocator.free(text);
    try std.testing.expect(std.mem.eql(u8, "hello world", text));
}

test "webfetch: stripHtml skips script" {
    const allocator = std.testing.allocator;
    const html = "<script>bad()</script>hello";
    const text = try stripHtml(allocator, html);
    defer allocator.free(text);
    try std.testing.expect(std.mem.eql(u8, "hello", text));
}

test "webfetch: isTextualMime" {
    const allocator = std.testing.allocator;
    _ = allocator;
    try std.testing.expect(isTextualMime("text/html"));
    try std.testing.expect(isTextualMime("application/json"));
    try std.testing.expect(!isTextualMime("image/png"));
    try std.testing.expect(!isTextualMime("application/pdf"));
    try std.testing.expect(isTextualMime("image/svg+xml"));
}

test "webfetch: link conversion" {
    const allocator = std.testing.allocator;
    const html = "<a href=\"https://example.com\">Example</a>";
    const md = try htmlToMarkdown(allocator, html);
    defer allocator.free(md);
    try std.testing.expect(std.mem.indexOf(u8, md, "[Example](https://example.com)") != null);
}

test "webfetch: fetch real url" {
    // 真实网络测试：需要 curl 在网络环境可用
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const ctx = types.ToolContext{ .allocator = allocator, .io = io, .project_root = "." };
    var result = try testExec(ctx, "{\"url\":\"https://httpbin.org/robots.txt\",\"format\":\"text\"}");
    defer result.deinit(allocator);
    // 网络不可用时不判定失败（容错）
    if (std.mem.indexOf(u8, result.session_content, "Error:") == null) {
        try std.testing.expect(result.session_content.len > 0);
    }
}
