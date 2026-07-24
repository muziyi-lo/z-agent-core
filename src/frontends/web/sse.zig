const std = @import("std");
const provider_mod = @import("../../io/provider.zig");
const agent_mod = @import("../../core/agent.zig");
const types = @import("../../types.zig");

const Io = std.Io;
const PhaseWriterCb = provider_mod.PhaseWriterCb;
const ToolDisplayCb = agent_mod.ToolDisplayCb;
const PhaseType = provider_mod.PhaseType;

pub const SseState = struct {
    writer: *Io.Writer,
    io: std.Io,
    thinking_start_ms: i64 = 0,
    current_phase: PhaseType = .none,
    tool_id_counter: u32 = 0,

    pub fn writeFrame(self: *SseState, event: []const u8, data: []const u8) !void {
        try self.writer.print("event: {s}\ndata: {s}\n\n", .{ event, data });
    }

    fn writeTextDelta(self: *SseState, event: []const u8, text: []const u8) !void {
        try self.writer.print("event: {s}\ndata: {{\"text\":\"", .{event});
        try writeJsonEscaped(self.writer, text);
        try self.writer.writeAll("\"}\n\n");
    }
};

fn writeJsonEscaped(writer: *Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => try writer.print("\\u{d:0>4}", .{@as(u16, c)}),
            else => try writer.writeByte(c),
        }
    }
}

pub fn createPhaseWriter(state: *SseState) PhaseWriterCb {
    return .{
        .context = state,
        .begin_phase = beginPhase,
        .write_raw = writeRaw,
        .write_rendered = writeRendered,
        .end_phase = endPhase,
    };
}

pub fn webPhaseWriterCb() PhaseWriterCb {
    return .{
        .context = null,
        .begin_phase = beginPhase,
        .write_raw = writeRaw,
        .write_rendered = writeRendered,
        .end_phase = endPhase,
    };
}

pub fn webToolDisplayCb() ToolDisplayCb {
    return .{
        .context = null,
        .begin_tool = beginTool,
        .render = renderTool,
    };
}

fn beginPhase(ctx: ?*anyopaque, mtype: PhaseType) void {
    const s: *SseState = @ptrCast(@alignCast(ctx.?));
    s.current_phase = mtype;
    switch (mtype) {
        .thinking => {
            const now_ts = Io.Clock.Timestamp.now(s.io, .real);
            s.thinking_start_ms = Io.Timestamp.toMilliseconds(now_ts.raw);
            s.writeFrame("thinking_start", "{}") catch {};
        },
        .content => {
            s.writeFrame("content_start", "{}") catch {};
        },
        .none => {},
    }
}

fn writeRaw(ctx: ?*anyopaque, bytes: []const u8) void {
    const s: *SseState = @ptrCast(@alignCast(ctx.?));
    const event: []const u8 = switch (s.current_phase) {
        .thinking => "thinking_delta",
        .content => "content_delta",
        .none => return,
    };
    s.writeTextDelta(event, bytes) catch {};
}

fn writeRendered(ctx: ?*anyopaque, line: []const u8) void {
    const s: *SseState = @ptrCast(@alignCast(ctx.?));
    s.writeTextDelta("content_delta", line) catch {};
}

fn endPhase(ctx: ?*anyopaque) void {
    const s: *SseState = @ptrCast(@alignCast(ctx.?));
    switch (s.current_phase) {
        .thinking => {
            const end_ts = Io.Clock.Timestamp.now(s.io, .real);
            const end_ms = Io.Timestamp.toMilliseconds(end_ts.raw);
            const duration_ms = if (end_ms > s.thinking_start_ms) end_ms - s.thinking_start_ms else 0;
            var buf: [48]u8 = undefined;
            const payload = std.fmt.bufPrint(&buf, "{{\"duration_ms\":{d}}}", .{duration_ms}) catch "{}";
            s.writeFrame("thinking_end", payload) catch {};
        },
        .content => {
            s.writeFrame("content_end", "{}") catch {};
        },
        .none => {},
    }
    s.current_phase = .none;
}

pub fn createToolDisplay(state: *SseState) ToolDisplayCb {
    return .{
        .context = state,
        .begin_tool = beginTool,
        .render = renderTool,
    };
}

fn beginTool(ctx: ?*anyopaque, tool_name: []const u8) void {
    const s: *SseState = @ptrCast(@alignCast(ctx.?));
    s.tool_id_counter += 1;
    var buf: [256]u8 = undefined;
    const payload = std.fmt.bufPrint(&buf, "{{\"id\":\"call_{d}\",\"name\":\"{s}\"}}", .{ s.tool_id_counter, tool_name }) catch "{}";
    s.writeFrame("tool_start", payload) catch {};
}

fn renderTool(
    ctx: ?*anyopaque,
    tool_name: []const u8,
    tool_args: []const u8,
    had_error: bool,
    err_msg: ?[]const u8,
    user_output: ?[]const u8,
    meta: types.ToolMeta,
) anyerror!void {
    const s: *SseState = @ptrCast(@alignCast(ctx.?));
    _ = tool_name;
    _ = tool_args;
    _ = meta;

    if (had_error) {
        const err = err_msg orelse "unknown error";
        var buf: [512]u8 = undefined;
        const payload = std.fmt.bufPrint(&buf, "{{\"id\":\"call_{d}\",\"error\":\"{s}\"}}", .{ s.tool_id_counter, err }) catch "{}";
        try s.writeFrame("tool_error", payload);
    } else {
        const output = user_output orelse "";
        try s.writeTextDelta("tool_delta", output);
    }
}

test "writeJsonEscaped special chars" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    const state = SseState{ .writer = &aw.writer, .io = std.testing.io };

    try writeJsonEscaped(state.writer, "hello\n\"world\"");
    var list = aw.toArrayList();
    defer list.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello\\n\\\"world\\\"", list.items);
}

test "sse: writeFrame format" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    var state = SseState{ .writer = &aw.writer, .io = std.testing.io };

    try state.writeFrame("thinking_start", "{}");

    var list = aw.toArrayList();
    defer list.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("event: thinking_start\ndata: {}\n\n", list.items);
}

test "sse: writeTextDelta escapes text" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    var state = SseState{ .writer = &aw.writer, .io = std.testing.io };

    try state.writeTextDelta("thinking_delta", "hello");

    var list = aw.toArrayList();
    defer list.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("event: thinking_delta\ndata: {\"text\":\"hello\"}\n\n", list.items);
}

test "sse: PhaseWriterCb begin_phase thinking emits thinking_start" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    var state = SseState{ .writer = &aw.writer, .io = std.testing.io };

    const cb = createPhaseWriter(&state);
    cb.begin_phase(cb.context, .thinking);

    var list = aw.toArrayList();
    defer list.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("event: thinking_start\ndata: {}\n\n", list.items);
}
test "sse: PhaseWriterCb write_raw in thinking phase emits thinking_delta" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    var state = SseState{ .writer = &aw.writer, .io = std.testing.io };

    const cb = createPhaseWriter(&state);
    state.current_phase = .thinking;
    cb.write_raw(cb.context, "some text");

    var list = aw.toArrayList();
    defer list.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("event: thinking_delta\ndata: {\"text\":\"some text\"}\n\n", list.items);
}

test "sse: ToolDisplayCb begin_tool emits tool_start with incrementing id" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    var state = SseState{ .writer = &aw.writer, .io = std.testing.io };

    const cb = createToolDisplay(&state);
    cb.begin_tool.?(cb.context, "read");

    var list = aw.toArrayList();
    defer list.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("event: tool_start\ndata: {\"id\":\"call_1\",\"name\":\"read\"}\n\n", list.items);
}

test "sse: ToolDisplayCb begin_tool increments id across calls" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    var state = SseState{ .writer = &aw.writer, .io = std.testing.io };
    state.tool_id_counter = 1;

    const cb = createToolDisplay(&state);
    cb.begin_tool.?(cb.context, "bash");

    var list = aw.toArrayList();
    defer list.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("event: tool_start\ndata: {\"id\":\"call_2\",\"name\":\"bash\"}\n\n", list.items);
}

test "sse: ToolDisplayCb render error emits tool_error" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    var state = SseState{ .writer = &aw.writer, .io = std.testing.io };
    state.tool_id_counter = 1;

    const cb = createToolDisplay(&state);
    try cb.render(cb.context, "read", "{}", true, "file not found", null, .none);

    var list = aw.toArrayList();
    defer list.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("event: tool_error\ndata: {\"id\":\"call_1\",\"error\":\"file not found\"}\n\n", list.items);
}

test "sse: PhaseWriterCb end_phase thinking emits thinking_end with duration" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    var state = SseState{ .writer = &aw.writer, .io = std.testing.io };
    state.current_phase = .thinking;
    const start_ts = Io.Clock.Timestamp.now(std.testing.io, .real);
    state.thinking_start_ms = Io.Timestamp.toMilliseconds(start_ts.raw);

    const cb = createPhaseWriter(&state);
    cb.end_phase(cb.context);

    var list = aw.toArrayList();
    defer list.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.startsWith(u8, list.items, "event: thinking_end\ndata: {\"duration_ms\":"));
}
