const std = @import("std");
const types = @import("../types.zig");
const provider_mod = @import("../io/provider.zig");
const session_mod = @import("../core/session.zig");

pub const tool_name = "compact";
pub const tool_description = "Compress conversation history by summarizing old messages. Use when approaching context window limits.";
pub const tool_params =
    \\{"type":"object","properties":{"keep_count":{"type":"integer","description":"Number of recent messages to keep uncompressed (default: 6)"}},"required":[]}
;

pub fn execute(ctx: types.ToolContext, args: std.json.Value) anyerror!types.ToolResult {
    _ = args;
    const keep_count: usize = 6;

    const provider: *provider_mod.Provider = if (ctx.provider_ref) |p|
        @ptrCast(@alignCast(p))
    else {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: compact tool requires provider access", .{});
        return types.ToolResult{ .session_content = msg };
    };

    const session: *session_mod.Session = if (ctx.session_ref) |s|
        @ptrCast(@alignCast(s))
    else {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: compact tool requires session access", .{});
        return types.ToolResult{ .session_content = msg };
    };

    const api_endpoint = ctx.api_endpoint;
    _ = api_endpoint;

    const all_msgs = session.messages();
    if (all_msgs.len <= keep_count + 2) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Not enough messages to compact ({d} total, need > {d})", .{ all_msgs.len, keep_count + 2 });
        return types.ToolResult{ .session_content = msg };
    }

    const compact_from: usize = 1; // skip system prompt
    const compact_end: usize = all_msgs.len - keep_count;
    const to_summarize = all_msgs[compact_from..compact_end];

    const summary = generateSummary(ctx.allocator, ctx.io, to_summarize, provider) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error generating summary: {s}", .{@errorName(err)});
        return types.ToolResult{ .session_content = msg };
    };
    defer ctx.allocator.free(summary);

    // Build new message list: [system prompt] + [summary] + [last keep_count messages]
    const rest = all_msgs[compact_end..];
    const new_len = 1 + 1 + rest.len;
    var new_msgs = try std.ArrayListAligned(types.Message, null).initCapacity(ctx.allocator, new_len);
    defer new_msgs.deinit(ctx.allocator);

    try new_msgs.append(ctx.allocator, all_msgs[0]); // system prompt
    try new_msgs.append(ctx.allocator, .{
        .role = .system,
        .content = summary,
    });

    for (rest) |m| {
        try new_msgs.append(ctx.allocator, m);
    }

    // Replace session messages via truncate + re-insert
    session.truncateTo(0);
    for (new_msgs.items) |m| {
        try session.append(m);
    }

    const result = try std.fmt.allocPrint(ctx.allocator, "Compacted conversation: kept system prompt + {d} recent messages. Summary: {s}", .{ rest.len, summary });
    return types.ToolResult{
        .session_content = result,
        .meta = .none,
    };
}

fn generateSummary(
    allocator: std.mem.Allocator,
    io: std.Io,
    messages: []const types.Message,
    provider: *provider_mod.Provider,
) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var summary_msgs = std.ArrayListAligned(types.Message, null).empty;
    try summary_msgs.append(arena_alloc, .{
        .role = .system,
        .content = "Summarize the following conversation concisely. Keep key decisions, actions taken, and unresolved items. Output ONLY the summary, no preamble.",
    });

    for (messages) |m| {
        if (m.role == .system) continue;
        try summary_msgs.append(arena_alloc, m);
    }

    var temp_provider = provider_mod.Provider{
        .config = provider.config,
    };

    const resp = try temp_provider.chatCompletionStreaming(&arena, io, summary_msgs.items, null, null);
    if (resp.content) |c| {
        return allocator.dupe(u8, c);
    }
    return allocator.dupe(u8, "(summary unavailable)");
}
