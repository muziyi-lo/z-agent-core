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
    /// Writer for tool confirmation messages (stderr).
    display_writer: *std.Io.Writer,
};

/// Registered tool descriptor exposed to LLM via OpenAI tools API.
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    params: []const u8,
    /// Execute the tool. Returns allocator-owned slice, caller must free.
    execute: *const fn (ctx: ToolContext, args: []const u8) anyerror![]const u8,
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
    reasoning: bool,
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
