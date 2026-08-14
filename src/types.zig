const std = @import("std");
const jsonw = @import("util/jsonw.zig");

pub const VERSION = @import("build_options").version;

/// Chat message in the session history. All slices owned by session arena.
/// `id` is a monotonic stable message identifier assigned by the session
/// (see Session._next_id). Position-ordered for legacy files: ids follow
/// append order except the system prompt (prepended, may have the highest id).
pub const Message = struct {
    id: u64 = 0,
    role: Role,
    content: []const u8,
    reasoning_content: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
    tool_call_id: ?[]const u8 = null,
    /// Per-tool structured metadata, persisted only on role=tool messages
    /// (source: ToolResult.meta at agent.zig append site; matched to the
    /// preceding assistant's tool_calls by tool_call_id on reload).
    /// Arena-duped on append/load — never a borrow from ToolResult.
    meta: ?ToolMeta = null,
    timestamp: i64 = 0,
    model: ?[]const u8 = null,
    usage: ?TokenUsage = null,
};

/// Token usage captured from SSE [DONE] frame. Null for user/tool messages.
pub const TokenUsage = struct {
    input: u32,
    output: u32,
    total: u32,
    cache_hit: ?u32 = null,
    cache_miss: ?u32 = null,
};

/// Data-only API endpoint info passed to tools that need LLM access (e.g. compact).
pub const ApiEndpoint = struct {
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
};

pub const Role = enum { system, user, assistant, tool };

/// LLM function call request with id, name, and JSON arguments string.
pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

/// Execution context passed to tool handlers.
pub const ToolContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    api_endpoint: ?ApiEndpoint = null,
    abort_target: ?*bool = null,
    messages: ?[]const Message = null,
    session_ref: ?*anyopaque = null,
    provider_ref: ?*anyopaque = null,
    /// Skill root directory relative to project_root (from Config.skills_dir).
    skills_dir: []const u8 = ".zagent/skills",
};

/// Per-tool structured metadata for frontend display.
/// All slices are zero-copy borrows (into session_content or tool args).
pub const ToolMeta = union(enum) {
    none: void,
    write: struct {
        path: []const u8,
        existed: bool,
        old_lines: ?usize,
        new_lines: usize,
        byte_count: usize,
    },
    read: struct {
        path: []const u8,
        is_directory: bool,
        total_lines: usize,
        byte_count: usize,
        truncated: bool,
        next_offset: ?u32,
    },
    grep: struct {
        pattern: []const u8,
        path: ?[]const u8,
        match_count: usize,
        files_scanned: usize,
        truncated: bool,
    },
    bash: struct {
        command: []const u8,
        exit_code: i32,
        byte_count: usize,
        truncated: bool,
        timed_out: bool,
    },
    glob: struct {
        pattern: []const u8,
        path: ?[]const u8,
        file_count: usize,
        truncated: bool,
    },
    skill: struct {
        name: []const u8,
        file_count: usize,
    },
    edit: struct {
        path: []const u8,
        replacements: usize,
        old_lines: usize,
        new_lines: usize,
    },
    webfetch: struct {
        url: []const u8,
        byte_count: usize,
        format: []const u8,
        mime: []const u8,
    },
};

/// Serialize ToolMeta as a flat object (same shape session.zig persisted).
/// Full field set — single source of truth shared by session/handler. The
/// legacy session.zig appendToolMetaJson was removed (F7); sse.zig keeps
/// a numeric-only subset for streaming. Invariant: cover every variant here +
/// parseToolMeta (session.zig) + sse serializeMeta.
pub fn writeJson(self: ToolMeta, w: *jsonw.JsonWriter) !void {
    switch (self) {
        .none => {
            try w.beginObject(null);
            try w.stringField("name", "none");
            try w.endValue();
        },
        .write => |m| {
            try w.beginObject(null);
            try w.stringField("name", "write");
            try w.stringField("path", m.path);
            try w.boolField("existed", m.existed);
            if (m.old_lines) |ol| try w.intField("old_lines", ol);
            try w.intField("new_lines", m.new_lines);
            try w.intField("byte_count", m.byte_count);
            try w.endValue();
        },
        .read => |m| {
            try w.beginObject(null);
            try w.stringField("name", "read");
            try w.stringField("path", m.path);
            try w.boolField("is_directory", m.is_directory);
            try w.intField("total_lines", m.total_lines);
            try w.intField("byte_count", m.byte_count);
            try w.boolField("truncated", m.truncated);
            if (m.next_offset) |no| try w.intField("next_offset", no);
            try w.endValue();
        },
        .grep => |m| {
            try w.beginObject(null);
            try w.stringField("name", "grep");
            try w.stringField("pattern", m.pattern);
            if (m.path) |p| try w.stringField("path", p);
            try w.intField("match_count", m.match_count);
            try w.intField("files_scanned", m.files_scanned);
            try w.boolField("truncated", m.truncated);
            try w.endValue();
        },
        .bash => |m| {
            try w.beginObject(null);
            try w.stringField("name", "bash");
            try w.stringField("command", m.command);
            try w.intField("exit_code", m.exit_code);
            try w.intField("byte_count", m.byte_count);
            try w.boolField("truncated", m.truncated);
            try w.boolField("timed_out", m.timed_out);
            try w.endValue();
        },
        .glob => |m| {
            try w.beginObject(null);
            try w.stringField("name", "glob");
            try w.stringField("pattern", m.pattern);
            if (m.path) |p| try w.stringField("path", p);
            try w.intField("file_count", m.file_count);
            try w.boolField("truncated", m.truncated);
            try w.endValue();
        },
        .skill => |m| {
            try w.beginObject(null);
            try w.stringField("name", "skill");
            // skill 变体的 name 字段与顶层标签键 "name" 冲突——用 "skill" 键（与 session.zig 一致）
            try w.stringField("skill", m.name);
            try w.intField("file_count", m.file_count);
            try w.endValue();
        },
        .edit => |m| {
            try w.beginObject(null);
            try w.stringField("name", "edit");
            try w.stringField("path", m.path);
            try w.intField("replacements", m.replacements);
            try w.intField("old_lines", m.old_lines);
            try w.intField("new_lines", m.new_lines);
            try w.endValue();
        },
        .webfetch => |m| {
            try w.beginObject(null);
            try w.stringField("name", "webfetch");
            try w.stringField("url", m.url);
            try w.intField("byte_count", m.byte_count);
            try w.stringField("format", m.format);
            try w.stringField("mime", m.mime);
            try w.endValue();
        },
    }
}

pub const ToolResult = struct {
    session_content: []const u8,
    err_msg: ?[]const u8 = null,
    /// Zero-copy view into session_content — NOT freed by deinit.
    user_output: ?[]const u8 = null,
    meta: ToolMeta = .none,
    /// Owned parsed args JSON tree; keeps zero-copy meta borrows alive
    /// until deinit (N14 fix: transferred via finishExec — single point).
    /// CONTRACT: ToolResult must NOT be shallow-copied — args_owned carries a
    /// pointer to a shared arena; a copy would double-deinit. Pass by pointer
    /// or move; deep-copy (re-parse) if caching is ever needed.
    args_owned: ?std.json.Parsed(std.json.Value) = null,

    pub fn deinit(self: *ToolResult, allocator: std.mem.Allocator) void {
        allocator.free(self.session_content);
        if (self.err_msg) |e| allocator.free(e);
        if (self.args_owned) |*p| p.deinit();
    }

    /// Single ownership-transfer point: keeps `parsed` alive inside the result
    /// so zero-copy meta borrows stay valid until deinit. All callers
    /// (registry.execute, every tool's testExec) must delegate here — never
    /// assign args_owned by hand.
    pub fn finishExec(
        exec: anytype,
        ctx: ToolContext,
        parsed: std.json.Value,
        owned: std.json.Parsed(std.json.Value),
    ) !ToolResult {
        var result = try exec(ctx, parsed);
        result.args_owned = owned;
        return result;
    }
};

/// Registered tool descriptor exposed to LLM via OpenAI tools API.
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    params: []const u8,
    execute: *const fn (ctx: ToolContext, args: std.json.Value) anyerror!ToolResult,
};

pub const InputModality = enum { text, image };

pub const Api = enum { openai_compat };

/// LLM model descriptor from TOML config.
pub const Model = struct {
    id: []const u8,
    name: []const u8,
    provider: []const u8 = "",
    context_window: u32,
    max_tokens: u32,
    params_json: ?[]const u8 = null,
    input: []const InputModality,
    compat: ?ModelCompatOverride = null,
};

/// Per-model protocol quirks. Populated by detectCompat(); TOML overrides via ModelCompatOverride.
pub const ModelCompat = struct {
    thinking_format: ThinkingFormat = .none,
    thinking_level: ThinkingLevel = .high,
    max_tokens_field: MaxTokensField = .max_tokens,
    supports_stream_options: bool = false,
    supports_usage_in_streaming: bool = false,
    require_reasoning_on_tool_calls: bool = false,
};

/// TOML override — all optional. Null fields keep detectCompat() value.
pub const ModelCompatOverride = struct {
    thinking_format: ?ThinkingFormat = null,
    thinking_level: ?ThinkingLevel = null,
    max_tokens_field: ?MaxTokensField = null,
    supports_stream_options: ?bool = null,
    supports_usage_in_streaming: ?bool = null,
    require_reasoning_on_tool_calls: ?bool = null,
};

pub const ThinkingFormat = enum {
    none,
    thinking_object,
    reasoning_effort,
    enable_thinking_bool,
    thinking_parameters,
    thinking_with_budget,
    thinking_config_object,
};

pub const ThinkingLevel = enum {
    none,
    minimal,
    low,
    medium,
    high,
    xhigh,
    max,

    pub fn fromString(s: []const u8) ?ThinkingLevel {
        inline for (@typeInfo(ThinkingLevel).@"enum".fields) |field| {
            if (std.mem.eql(u8, s, field.name)) return @field(ThinkingLevel, field.name);
        }
        return null;
    }
};

pub const MaxTokensField = enum {
    max_tokens,
    max_tokens_to_sample,
    max_output_tokens,
};

/// Provider configuration entry from TOML config.
pub const ProviderEntry = struct {
    name: []const u8,
    api: Api,
    base_url: []const u8,
    models: []const Model,
    api_key_env: []const u8,
};

/// Streaming LLM response. content and tool_calls own their data (arena-backed).
pub const ProviderResponse = struct {
    content: ?[]const u8,
    reasoning_content: ?[]const u8 = null,
    tool_calls: ?[]ToolCall,
    finish_reason: FinishReason,
    usage: ?TokenUsage = null,
};

/// Per-request LLM finish reason. Distinct from agent-level TurnFinish.
pub const FinishReason = enum {
    stop,
    tool_calls,
    length,
    content_filter,
    unknown,
};

/// Session metadata returned by session.list(). Caller owns all slices.
pub const SessionInfo = struct {
    id: []const u8,
    name: []const u8,
    file_path: []const u8,
    timestamp: i64,
    model: []const u8,
    msg_count: usize,
    /// Source session id for fork/branch children (null for top-level sessions).
    parent_id: ?[]const u8 = null,
};

/// Infer protocol compat from provider base_url. Path keywords (case-insensitive,
/// stack buffer ≤256 bytes) take priority; domain heuristic is fallback.
pub fn detectCompat(base_url: []const u8) ModelCompat {
    var c = ModelCompat{};

    if (base_url.len <= 256) {
        var lower: [256]u8 = undefined;
        for (base_url, 0..) |ch, i| lower[i] = std.ascii.toLower(ch);
        const url_lower = lower[0..base_url.len];

        if (std.mem.indexOf(u8, url_lower, "/openai/") != null) {
            c.thinking_format = .reasoning_effort;
            c.supports_stream_options = true;
            c.supports_usage_in_streaming = true;
        }
        if (std.mem.indexOf(u8, url_lower, "/deepseek/") != null) {
            c.thinking_format = .thinking_object;
            c.require_reasoning_on_tool_calls = true;
        }
        if (std.mem.indexOf(u8, url_lower, "/aliyun/") != null or
            std.mem.indexOf(u8, url_lower, "/qwen/") != null)
        {
            c.thinking_format = .enable_thinking_bool;
        }
        if (std.mem.indexOf(u8, url_lower, "/anthropic/") != null or
            std.mem.indexOf(u8, url_lower, "/claude/") != null)
        {
            c.thinking_format = .thinking_with_budget;
            c.max_tokens_field = .max_tokens_to_sample;
        }
        if (std.mem.indexOf(u8, url_lower, "/gemini/") != null) {
            c.thinking_format = .thinking_config_object;
            c.max_tokens_field = .max_output_tokens;
        }
    }

    var url = base_url;
    if (std.mem.startsWith(u8, url, "https://")) url = url["https://".len..];
    if (std.mem.startsWith(u8, url, "http://")) url = url["http://".len..];
    const hostname = if (std.mem.indexOfAny(u8, url, "/:")) |pos| url[0..pos] else url;

    if (std.mem.endsWith(u8, hostname, ".deepseek.com") or
        std.mem.eql(u8, hostname, "api.deepseek.com"))
    {
        if (c.thinking_format == .none) c.thinking_format = .thinking_object;
        c.require_reasoning_on_tool_calls = true;
    }
    if (std.mem.eql(u8, hostname, "api.openai.com") or
        std.mem.endsWith(u8, hostname, ".openai.com"))
    {
        if (c.thinking_format == .none) c.thinking_format = .reasoning_effort;
        c.supports_stream_options = true;
        c.supports_usage_in_streaming = true;
    }
    if (std.mem.startsWith(u8, hostname, "dashscope.") or
        std.mem.endsWith(u8, hostname, ".aliyuncs.com"))
    {
        if (c.thinking_format == .none) c.thinking_format = .enable_thinking_bool;
    }

    return c;
}

test "ThinkingLevel fromString all values" {
    try @import("std").testing.expectEqual(ThinkingLevel.none, ThinkingLevel.fromString("none").?);
    try @import("std").testing.expectEqual(ThinkingLevel.minimal, ThinkingLevel.fromString("minimal").?);
    try @import("std").testing.expectEqual(ThinkingLevel.low, ThinkingLevel.fromString("low").?);
    try @import("std").testing.expectEqual(ThinkingLevel.medium, ThinkingLevel.fromString("medium").?);
    try @import("std").testing.expectEqual(ThinkingLevel.high, ThinkingLevel.fromString("high").?);
    try @import("std").testing.expectEqual(ThinkingLevel.xhigh, ThinkingLevel.fromString("xhigh").?);
    try @import("std").testing.expectEqual(ThinkingLevel.max, ThinkingLevel.fromString("max").?);
    try @import("std").testing.expectEqual(@as(?ThinkingLevel, null), ThinkingLevel.fromString("invalid"));
}

test "detectCompat deepseek" {
    const c = detectCompat("https://api.deepseek.com");
    try @import("std").testing.expectEqual(ThinkingFormat.thinking_object, c.thinking_format);
    try @import("std").testing.expect(c.require_reasoning_on_tool_calls);
}

test "detectCompat openai" {
    const c = detectCompat("https://api.openai.com/v1");
    try @import("std").testing.expectEqual(ThinkingFormat.reasoning_effort, c.thinking_format);
    try @import("std").testing.expect(c.supports_stream_options);
    try @import("std").testing.expect(c.supports_usage_in_streaming);
}

test "detectCompat aliyun" {
    const c = detectCompat("https://dashscope.aliyuncs.com/compatible-mode/v1");
    try @import("std").testing.expectEqual(ThinkingFormat.enable_thinking_bool, c.thinking_format);
}

test "detectCompat gateway path override" {
    const c = detectCompat("https://my-gateway.example.com/deepseek/v1");
    try @import("std").testing.expectEqual(ThinkingFormat.thinking_object, c.thinking_format);
}

test "detectCompat unknown defaults" {
    const c = detectCompat("https://custom-llm.example.com/v1");
    try @import("std").testing.expectEqual(ThinkingFormat.none, c.thinking_format);
    try @import("std").testing.expect(!c.supports_stream_options);
}

test "Message default no reasoning_content" {
    const msg = Message{ .role = .user, .content = "hello" };
    try @import("std").testing.expect(msg.reasoning_content == null);
}

test "Message with reasoning_content" {
    const msg = Message{
        .role = .assistant,
        .content = "I'll read that file.",
        .reasoning_content = "The user wants me to read a file.",
        .tool_calls = &.{.{ .id = "c1", .name = "read", .arguments = "{}" }},
    };
    try @import("std").testing.expect(msg.reasoning_content != null);
    try @import("std").testing.expectEqualStrings("I'll read that file.", msg.content);
}

test "ToolMeta writeJson emits session-matching bytes for all variants" {
    const variants = [_]ToolMeta{
        .{ .none = {} },
        .{ .write = .{ .path = "a.txt", .existed = true, .old_lines = 2, .new_lines = 3, .byte_count = 7 } },
        .{ .read = .{ .path = "b.zig", .is_directory = false, .total_lines = 99, .byte_count = 100, .truncated = true, .next_offset = 50 } },
        .{ .grep = .{ .pattern = "fn.*foo", .path = "src", .match_count = 4, .files_scanned = 5, .truncated = false } },
        .{ .bash = .{ .command = "ls", .exit_code = 0, .byte_count = 3, .truncated = false, .timed_out = false } },
        .{ .glob = .{ .pattern = "*.zig", .path = null, .file_count = 8, .truncated = false } },
        .{ .skill = .{ .name = "memory", .file_count = 2 } },
        .{ .edit = .{ .path = "c.zig", .replacements = 1, .old_lines = 2, .new_lines = 2 } },
        .{ .webfetch = .{ .url = "https://e.com", .byte_count = 100, .format = "markdown", .mime = "text/html" } },
    };
    const expected = [_][]const u8{
        "{\"name\":\"none\"}",
        "{\"name\":\"write\",\"path\":\"a.txt\",\"existed\":true,\"old_lines\":2,\"new_lines\":3,\"byte_count\":7}",
        "{\"name\":\"read\",\"path\":\"b.zig\",\"is_directory\":false,\"total_lines\":99,\"byte_count\":100,\"truncated\":true,\"next_offset\":50}",
        "{\"name\":\"grep\",\"pattern\":\"fn.*foo\",\"path\":\"src\",\"match_count\":4,\"files_scanned\":5,\"truncated\":false}",
        "{\"name\":\"bash\",\"command\":\"ls\",\"exit_code\":0,\"byte_count\":3,\"truncated\":false,\"timed_out\":false}",
        "{\"name\":\"glob\",\"pattern\":\"*.zig\",\"file_count\":8,\"truncated\":false}",
        "{\"name\":\"skill\",\"skill\":\"memory\",\"file_count\":2}",
        "{\"name\":\"edit\",\"path\":\"c.zig\",\"replacements\":1,\"old_lines\":2,\"new_lines\":2}",
        "{\"name\":\"webfetch\",\"url\":\"https://e.com\",\"byte_count\":100,\"format\":\"markdown\",\"mime\":\"text/html\"}",
    };
    for (variants, 0..) |meta, i| {
        var jw = jsonw.JsonWriter.init(std.testing.allocator);
        defer jw.deinit();
        try writeJson(meta, &jw);
        var out = try jw.result();
        defer out.deinit();
        try @import("std").testing.expectEqualStrings(expected[i], out.bytes);
    }
}

test "ToolMeta writeJson roundtrip parse serialize parse" {
    const variants = [_]ToolMeta{
        .{ .write = .{ .path = "a.txt", .existed = false, .old_lines = null, .new_lines = 3, .byte_count = 7 } },
        .{ .read = .{ .path = "b.zig", .is_directory = true, .total_lines = 99, .byte_count = 100, .truncated = true, .next_offset = null } },
        .{ .grep = .{ .pattern = "fn", .path = null, .match_count = 2, .files_scanned = 3, .truncated = false } },
        .{ .bash = .{ .command = "echo hi", .exit_code = 0, .byte_count = 3, .truncated = false, .timed_out = true } },
        .{ .glob = .{ .pattern = "*.zig", .path = "src", .file_count = 4, .truncated = false } },
        .{ .skill = .{ .name = "mem", .file_count = 5 } },
        .{ .edit = .{ .path = "a.zig", .replacements = 1, .old_lines = 2, .new_lines = 2 } },
        .{ .webfetch = .{ .url = "https://example.com", .byte_count = 100, .format = "markdown", .mime = "text/html" } },
    };
    for (variants) |meta| {
        var jw = jsonw.JsonWriter.init(std.testing.allocator);
        defer jw.deinit();
        try writeJson(meta, &jw);
        var out = try jw.result();
        defer out.deinit();

        // parse -> serialize -> parse: first parse proves valid JSON
        var parsed = std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.bytes, .{}) catch |err| {
            std.debug.print("invalid JSON for {s}: [{s}] err={s}\n", .{ @tagName(meta), out.bytes, @errorName(err) });
            return err;
        };
        defer parsed.deinit();
        const name = parsed.value.object.get("name").?.string;
        try std.testing.expectEqualStrings(@tagName(meta), name);

        // second serialize from the parsed value must equal the first output
        var jw2 = jsonw.JsonWriter.init(std.testing.allocator);
        defer jw2.deinit();
        const parsed_meta = parseToolMetaValue(parsed.value);
        if (parsed_meta) |pm| {
            try writeJson(pm, &jw2);
            var out2 = try jw2.result();
            defer out2.deinit();
            try std.testing.expectEqualStrings(out.bytes, out2.bytes);
        }
    }
}

/// Roundtrip helper: reconstruct ToolMeta from a parsed JSON value (mirrors
/// session.zig parseToolMeta field mapping).
fn parseToolMetaValue(v: std.json.Value) ?ToolMeta {
    const obj = v.object;
    const name = obj.get("name").?.string;
    const t: ToolMeta = blk: {
        if (std.mem.eql(u8, name, "none")) break :blk .none;
        if (std.mem.eql(u8, name, "write")) break :blk .{ .write = .{ .path = obj.get("path").?.string, .existed = obj.get("existed").?.bool, .old_lines = if (obj.get("old_lines")) |x| @intCast(x.integer) else null, .new_lines = @intCast(obj.get("new_lines").?.integer), .byte_count = @intCast(obj.get("byte_count").?.integer) } };
        if (std.mem.eql(u8, name, "read")) break :blk .{ .read = .{ .path = obj.get("path").?.string, .is_directory = obj.get("is_directory").?.bool, .total_lines = @intCast(obj.get("total_lines").?.integer), .byte_count = @intCast(obj.get("byte_count").?.integer), .truncated = obj.get("truncated").?.bool, .next_offset = if (obj.get("next_offset")) |x| @intCast(x.integer) else null } };
        if (std.mem.eql(u8, name, "grep")) break :blk .{ .grep = .{ .pattern = obj.get("pattern").?.string, .path = if (obj.get("path")) |x| x.string else null, .match_count = @intCast(obj.get("match_count").?.integer), .files_scanned = @intCast(obj.get("files_scanned").?.integer), .truncated = obj.get("truncated").?.bool } };
        if (std.mem.eql(u8, name, "bash")) break :blk .{ .bash = .{ .command = obj.get("command").?.string, .exit_code = @intCast(obj.get("exit_code").?.integer), .byte_count = @intCast(obj.get("byte_count").?.integer), .truncated = obj.get("truncated").?.bool, .timed_out = obj.get("timed_out").?.bool } };
        if (std.mem.eql(u8, name, "glob")) break :blk .{ .glob = .{ .pattern = obj.get("pattern").?.string, .path = if (obj.get("path")) |x| x.string else null, .file_count = @intCast(obj.get("file_count").?.integer), .truncated = obj.get("truncated").?.bool } };
        if (std.mem.eql(u8, name, "skill")) break :blk .{ .skill = .{ .name = obj.get("skill").?.string, .file_count = @intCast(obj.get("file_count").?.integer) } };
        if (std.mem.eql(u8, name, "edit")) break :blk .{ .edit = .{ .path = obj.get("path").?.string, .replacements = @intCast(obj.get("replacements").?.integer), .old_lines = @intCast(obj.get("old_lines").?.integer), .new_lines = @intCast(obj.get("new_lines").?.integer) } };
        if (std.mem.eql(u8, name, "webfetch")) break :blk .{ .webfetch = .{ .url = obj.get("url").?.string, .byte_count = @intCast(obj.get("byte_count").?.integer), .format = obj.get("format").?.string, .mime = obj.get("mime").?.string } };
        return null;
    };
    return t;
}
