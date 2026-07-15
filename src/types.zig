const std = @import("std");

pub const VERSION = @import("build_options").version;

/// Chat message in the session history. All slices owned by session arena.
pub const Message = struct {
    role: Role,
    content: []const u8,
    tool_calls: ?[]const ToolCall = null,
    tool_call_id: ?[]const u8 = null,
    timestamp: i64 = 0,
    model: ?[]const u8 = null,
    usage: ?TokenUsage = null,
};

/// Token usage captured from SSE [DONE] frame. Null for user/tool messages.
pub const TokenUsage = struct {
    input: u32,
    output: u32,
    total: u32,
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
};
