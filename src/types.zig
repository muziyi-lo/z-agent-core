const std = @import("std");

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

pub const ToolResult = struct {
    session_content: []const u8,
    err_msg: ?[]const u8 = null,
    /// Zero-copy view into session_content — NOT freed by deinit.
    user_output: ?[]const u8 = null,
    meta: ToolMeta = .none,

    pub fn deinit(self: *ToolResult, allocator: std.mem.Allocator) void {
        allocator.free(self.session_content);
        if (self.err_msg) |e| allocator.free(e);
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
