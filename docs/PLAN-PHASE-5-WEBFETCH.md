# Plan PHASE-5: WebFetch 工具

## 状态: 计划中

## 问题

当前 z-agent-core 无法获取 web 内容。LLM 经常需要查阅在线文档、API 参考、GitHub issues 等资源。缺少 `webfetch` 工具限制了 agent 的信息获取能力。

## 概览

- **参考**：opencode 的 `webfetch.ts` 实现（37 行 TypeScript），确认了最小化设计——HTTP GET → HTML→Markdown 转换。
- **改动范围**：1 个新文件 + 1 行注册 + 1 个 HTML→Markdown 转换器
- **设计方案**：复用现有的 curl 子进程模式（与 provider.zig 一致），HTML→Markdown 用简单的正则/字符替换实现（不引入外部依赖，参考 opencode 的轻量方案）

## 工具规格

```
name:        "webfetch"
description: "Fetch content from a URL and convert HTML to Markdown.
              Returns the page content in markdown format.
              Use this to read online documentation, API references, or any web resource."
params:      { "url": string, "format": "text"|"markdown"|"html" (optional, default "markdown") }
```

### 执行流程

```
1. 验证 URL 格式（必须有 scheme: http/https）
2. 调用 curl -sL --max-time 30 "$url"
3. 获取 HTTP body
4. 根据 format 参数:
   - "html": 直接返回原始 HTML
   - "markdown": HTML → Markdown 转换后返回
   - "text": 去除所有 HTML 标签后返回
5. 返回 ToolResult，session_content 包含处理后的内容
```

---

## 实施

### 步骤 1: 创建 `src/tool/webfetch.zig`

**文件**: `src/tool/webfetch.zig`（新建）

```zig
const std = @import("std");
const types = @import("../types.zig");

pub const tool_name = "webfetch";
pub const tool_description = "Fetch content from a URL. Returns the content in the specified format (markdown by default).";
pub const tool_params =
    \\{"type":"object","properties":{
    \\"url":{"type":"string","description":"The URL to fetch content from"},
    \\"format":{"type":"string","enum":["text","markdown","html"],"description":"Output format (default: markdown)"}},
    \\"required":["url"]}
;

const MAX_CONTENT: usize = 1 * 1024 * 1024; // 1MB limit
const MAX_TIMEOUT_SECS: u16 = 30;

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

    // Validate URL scheme
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
        const content = try std.fmt.allocPrint(ctx.allocator, "Error: URL must start with http:// or https://", .{});
        return types.ToolResult{ .session_content = content };
    }

    const format: enum { text, markdown, html } = blk: {
        if (args.object.get("format")) |f| {
            if (f == .string) {
                if (std.mem.eql(u8, f.string, "text")) break :blk .text;
                if (std.mem.eql(u8, f.string, "html")) break :blk .html;
            }
        }
        break :blk .markdown;
    };

    // Fetch via curl subprocess (same pattern as provider.zig)
    var argv = std.ArrayListAligned([]const u8, null).empty;
    try argv.append(ctx.allocator, if (@import("builtin").os.tag == .windows) "curl.exe" else "curl");

    const url_owned = try ctx.allocator.dupe(u8, url);
    errdefer ctx.allocator.free(url_owned);

    var timeout_buf: [8]u8 = undefined;
    const timeout_str = try std.fmt.bufPrint(&timeout_buf, "{d}", .{MAX_TIMEOUT_SECS});
    try argv.appendSlice(ctx.allocator, &[_][]const u8{
        "-sL", "--max-time", timeout_str,
        "--compressed",
        "-H", "User-Agent: z-agent-core/1.0",
        url_owned,
    });

    const result = std.process.run(ctx.allocator, ctx.io, .{
        .argv = argv.items,
        .stdout_limit = @enumFromInt(MAX_CONTENT),
        .stderr_limit = @enumFromInt(10240),
    }) catch |err| {
        const content = try std.fmt.allocPrint(ctx.allocator, "Error: fetch failed: {s}", .{@errorName(err)});
        return types.ToolResult{
            .session_content = content,
            .err_msg = try ctx.allocator.dupe(u8, @errorName(err)),
        };
    };
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        const content = try std.fmt.allocPrint(ctx.allocator,
            "Error: HTTP request failed (exit code {d})\n{s}",
            .{ @as(i32, if (result.term == .exited) @intCast(result.term.exited) else -1), result.stderr });
        return types.ToolResult{ .session_content = content };
    }

    var output: []const u8 = undefined;
    switch (format) {
        .html => {
            output = try truncatedCopy(ctx.allocator, result.stdout);
        },
        .markdown => {
            const md = htmlToMarkdown(ctx.allocator, result.stdout) catch |md_err| {
                // Fallback: return as text if conversion fails
                return types.ToolResult{ .session_content = try truncatedCopy(ctx.allocator, result.stdout) };
                _ = md_err;
            };
            output = md;
        },
        .text => {
            output = try stripHtml(ctx.allocator, result.stdout);
        },
    }

    return types.ToolResult{
        .session_content = output,
        .meta = .{ .webfetch = .{
            .url = url_owned,
            .byte_count = result.stdout.len,
            .format = @tagName(format),
        } },
    };
}
```

### 步骤 2: HTML → Markdown 转换器

**文件**: `src/tool/webfetch.zig`（内联辅助函数）

```zig
/// Minimal HTML to Markdown converter. Handles common tags; unsupported tags
/// pass through as text. No external deps — custom implementation matching
/// opencode's lightweight approach.
fn htmlToMarkdown(allocator: std.mem.Allocator, html: []const u8) ![]const u8 {
    var buf = std.ArrayListAligned(u8, null).empty;
    errdefer buf.deinit(allocator);

    var i: usize = 0;
    var in_tag = false;
    var tag_buf: [64]u8 = undefined;
    var tag_len: usize = 0;
    var list_depth: usize = 0;

    while (i < html.len) {
        if (!in_tag) {
            if (html[i] == '<') {
                in_tag = true;
                tag_len = 0;
            } else {
                try buf.append(allocator, html[i]);
            }
        } else {
            if (html[i] == '>') {
                in_tag = false;
                const tag = tag_buf[0..tag_len];
                const tag_lower = toLower(tag); // inline lowercase

                // Block-level tags → newlines
                if (isBlockTag(tag_lower)) {
                    try buf.append(allocator, '\n');
                }
                // Headings
                if (std.mem.startsWith(u8, tag_lower, "h1")) try buf.appendSlice(allocator, "\n# ");
                if (std.mem.startsWith(u8, tag_lower, "h2")) try buf.appendSlice(allocator, "\n## ");
                if (std.mem.startsWith(u8, tag_lower, "h3")) try buf.appendSlice(allocator, "\n### ");
                if (std.mem.startsWith(u8, tag_lower, "/h1") or
                    std.mem.startsWith(u8, tag_lower, "/h2") or
                    std.mem.startsWith(u8, tag_lower, "/h3")) try buf.append(allocator, '\n');
                // List items
                if (std.mem.eql(u8, tag_lower, "li")) try buf.appendSlice(allocator, "- ");
                // Links: <a href="...">text</a> → [text](href)
                // (simplified: just output link text)
                if (std.mem.startsWith(u8, tag_lower, "/a")) try buf.appendSlice(allocator, "");
                // Code blocks
                if (std.mem.startsWith(u8, tag_lower, "code")) try buf.append(allocator, '`');
            } else if (tag_len < tag_buf.len) {
                tag_buf[tag_len] = html[i];
                tag_len += 1;
            }
        }
        i += 1;
    }

    return buf.toOwnedSlice(allocator);
}

fn isBlockTag(tag_lower: []const u8) bool {
    const blocks = [_][]const u8{
        "p", "/p", "div", "/div", "br", "hr",
        "h1", "h2", "h3", "h4", "h5", "h6",
        "/h1", "/h2", "/h3", "/h4", "/h5", "/h6",
        "ul", "/ul", "ol", "/ol", "li", "/li",
        "table", "/table", "tr", "/tr",
    };
    for (blocks) |b| {
        if (std.mem.eql(u8, tag_lower, b)) return true;
    }
    return false;
}

fn stripHtml(allocator: std.mem.Allocator, html: []const u8) ![]const u8 {
    var buf = std.ArrayListAligned(u8, null).empty;
    var in_tag = false;
    for (html) |c| {
        if (c == '<') { in_tag = true; continue; }
        if (c == '>') { in_tag = false; continue; }
        if (!in_tag) try buf.append(allocator, c);
    }
    // Collapse whitespace
    var result = std.ArrayListAligned(u8, null).empty;
    var last_was_space = false;
    for (buf.items) |c| {
        const is_space = c == ' ' or c == '\n' or c == '\r' or c == '\t';
        if (is_space) {
            if (!last_was_space) {
                try result.append(allocator, ' ');
                last_was_space = true;
            }
        } else {
            try result.append(allocator, c);
            last_was_space = false;
        }
    }
    buf.deinit(allocator);
    return result.toOwnedSlice(allocator);
}

fn truncatedCopy(allocator: std.mem.Allocator, src: []const u8) ![]const u8 {
    const max_len = @min(src.len, MAX_CONTENT);
    const result = try allocator.alloc(u8, max_len);
    @memcpy(result, src[0..max_len]);
    if (src.len > MAX_CONTENT) {
        const suffix = try std.fmt.allocPrint(allocator, "\n\n[Content truncated: {d} bytes → {d} bytes]", .{ src.len, MAX_CONTENT });
        defer allocator.free(suffix);
        // ... append truncation notice ...
    }
    return result;
}
```

### 步骤 3: 注册工具

**文件**: `src/tool/registry.zig`

```zig
const webfetch_tool = @import("webfetch.zig");  // NEW import

pub fn buildRegistry() Registry {
    return .{
        .handlers = &.{
            // ... existing 8 handlers ...
            .{ .name = webfetch_tool.tool_name, .description = webfetch_tool.tool_description, .params = webfetch_tool.tool_params, .execute = webfetch_tool.execute },  // NEW
        },
    };
}
```

### 步骤 4: ToolMeta 扩展

**文件**: `src/types.zig`

```zig
pub const ToolMeta = union(enum) {
    none: void,
    // ... existing variants ...
    webfetch: struct {  // NEW
        url: []const u8,
        byte_count: usize,
        format: []const u8,
    },
};
```

---

## 验证

```powershell
zig build
zig test src/tool/webfetch.zig --cache-dir .zig-cache
```

| 测试场景 | 预期结果 |
|----------|----------|
| `webfetch { url: "https://example.com" }` | 返回 Markdown 格式的页面内容 |
| `webfetch { url: "https://example.com", format: "text" }` | 返回纯文本（去除 HTML） |
| `webfetch { url: "https://example.com", format: "html" }` | 返回原始 HTML |
| `webfetch { url: "invalid-url" }` | 返回错误信息 |
| `webfetch { url: "" }` | 错误: url must be non-empty |
| `webfetch { url: "ftp://example.com" }` | 错误: URL must start with http:// or https:// |

### 测试用例 (webfetch.zig)

1. `test "webfetch: missing url"`:
   ```zig
   var result = try execute(ctx, .{ .object = empty_object });
   defer result.deinit(testing.allocator);
   try testing.expect(std.mem.indexOf(u8, result.session_content, "missing") != null);
   ```

2. `test "webfetch: invalid url scheme"`:
   ```zig
   var result = try execute(ctx, parseJson(\\{"url":"ftp://example.com"}));
   defer result.deinit(testing.allocator);
   try testing.expect(std.mem.indexOf(u8, result.session_content, "http://") != null);
   ```

3. `test "webfetch: fetch real URL"` (requires network):
   ```zig
   var result = try execute(ctx, parseJson(\\{"url":"https://httpbin.org/robots.txt"}));
   defer result.deinit(testing.allocator);
   try testing.expect(result.session_content.len > 0);
   try testing.expect(!result.is_error orelse false);
   ```

4. `test "webfetch: html to markdown basic"`:
   ```zig
   const html = "<h1>Title</h1><p>Hello <b>world</b></p>";
   const md = try htmlToMarkdown(testing.allocator, html);
   defer testing.allocator.free(md);
   try testing.expect(std.mem.indexOf(u8, md, "Title") != null);
   try testing.expect(std.mem.indexOf(u8, md, "Hello") != null);
   ```

5. `test "webfetch: stripHtml"`:
   ```zig
   const html = "<div>hello</div><p>world</p>";
   const text = try stripHtml(testing.allocator, html);
   defer testing.allocator.free(text);
   try testing.expect(std.mem.eql(u8, "hello world", std.mem.trim(u8, text, " ")));
   ```

---

## 设计决策

| 决策 | 理由 |
|------|------|
| curl 子进程 vs Zig HTTP client | 与现有 provider.zig 保持一致；Zig 0.16 无内置 HTTP client |
| 自实现 HTML→MD vs 引入库 | 零外部依赖原则；opencode 的 TypeScript 实现仅 37 行 |
| 1MB 限制 | 防止超大页面占用内存；与 bash 工具的 512KB 输出限制类似 |
| 30s 超时 | 与 provider 的 `connect_timeout_secs` 一致 |
| 不处理 JavaScript 渲染页面 | 这是 curl 的限制；动态页面需未来用 headless browser |

## 波及

| 文件 | 改动 | 破坏性 |
|------|------|--------|
| `src/tool/webfetch.zig` | 新建，~200 行 | 否 |
| `src/tool/registry.zig` | 新增 1 行 import + 1 行注册 | 否 |
| `src/types.zig` | ToolMeta 新增 `webfetch` 变体 | 否 |
| `src/test.zig` | 无需修改（测试在 webfetch.zig 内部） | 否 |
