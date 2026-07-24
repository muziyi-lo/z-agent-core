const std = @import("std");
const provider_mod = @import("../../io/provider.zig");
const agent_mod = @import("../../core/agent.zig");
const types = @import("../../types.zig");

const Io = std.Io;
const PhaseWriterCb = provider_mod.PhaseWriterCb;
const ToolDisplayCb = agent_mod.ToolDisplayCb;
const PhaseType = provider_mod.PhaseType;

pub const SseWriter = struct {
    ctx: *anyopaque,
    writeAllFn: *const fn (*anyopaque, []const u8) anyerror!void,
    printFn: *const fn (*anyopaque, []const u8) anyerror!void,

    pub fn writeAll(self: SseWriter, bytes: []const u8) !void {
        return self.writeAllFn(self.ctx, bytes);
    }
};

pub fn sseWriterFrom(ptr: anytype) SseWriter {
    const T = @TypeOf(ptr);
    const info = @typeInfo(T);
    const Child = info.pointer.child;
    return .{
        .ctx = @ptrCast(@alignCast(ptr)),
        .writeAllFn = struct {
            fn writeAll(p: *anyopaque, bytes: []const u8) anyerror!void {
                const w: *Child = @ptrCast(@alignCast(p));
                try w.writeAll(bytes);
            }
        }.writeAll,
        .printFn = struct {
            fn print(p: *anyopaque, bytes: []const u8) anyerror!void {
                _ = p;
                _ = bytes;
            }
        }.print,
    };
}

pub const SseState = struct {
    w: SseWriter,
    io: std.Io,
    thinking_start_ms: i64 = 0,
    current_phase: PhaseType = .none,
    tool_id_counter: u32 = 0,

    pub fn writeFrame(self: *SseState, event: []const u8, data: []const u8) !void {
        var buf: [512]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "event: {s}\ndata: {s}\n\n", .{ event, data });
        try self.w.writeAll(msg);
    }

    fn writeTextDelta(self: *SseState, event: []const u8, text: []const u8) !void {
        var buf: [2048]u8 = undefined;
        const pos = try std.fmt.bufPrint(&buf, "event: {s}\ndata: {{\"text\":\"", .{event});
        var pos2 = pos.len;
        pos2 += (try jsonEscapeBuf(buf[pos2..], text)).len;
        const end = try std.fmt.bufPrint(buf[pos2..], "\"}}\n\n", .{});
        try self.w.writeAll(buf[0 .. pos2 + end.len]);
    }
};

fn jsonEscapeBuf(buf: []u8, s: []const u8) ![]u8 {
    var pos: usize = 0;
    for (s) |c| {
        if (pos + 2 >= buf.len) return error.BufferTooSmall;
        switch (c) {
            '"' => { buf[pos] = '\\'; pos += 1; buf[pos] = '"'; pos += 1; },
            '\\' => { buf[pos] = '\\'; pos += 1; buf[pos] = '\\'; pos += 1; },
            '\n' => { buf[pos] = '\\'; pos += 1; buf[pos] = 'n'; pos += 1; },
            '\r' => { buf[pos] = '\\'; pos += 1; buf[pos] = 'r'; pos += 1; },
            '\t' => { buf[pos] = '\\'; pos += 1; buf[pos] = 't'; pos += 1; },
            else => { buf[pos] = c; pos += 1; },
        }
    }
    return buf[0..pos];
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

pub fn createToolDisplay(state: *SseState) ToolDisplayCb {
    return .{
        .context = state,
        .begin_tool = beginTool,
        .render = renderTool,
    };
}

fn beginPhase(ctx: ?*anyopaque, mtype: PhaseType) void {
    const s: *SseState = @ptrCast(@alignCast(ctx.?));
    s.current_phase = mtype;
    switch (mtype) {
        .thinking => {
            s.thinking_start_ms = Io.Timestamp.toMilliseconds(Io.Clock.Timestamp.now(s.io, .real).raw);
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

test "sse: writeFrame format" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    var state = SseState{ .w = sseWriterFrom(&aw.writer), .io = std.testing.io };

    try state.writeFrame("thinking_start", "{}");

    var list = aw.toArrayList();
    defer list.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("event: thinking_start\ndata: {}\n\n", list.items);
}

test "sse: PhaseWriterCb begin_phase thinking emits thinking_start" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    var state = SseState{ .w = sseWriterFrom(&aw.writer), .io = std.testing.io };

    const cb = createPhaseWriter(&state);
    cb.begin_phase(cb.context, .thinking);

    var list = aw.toArrayList();
    defer list.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.startsWith(u8, list.items, "event: thinking_start\ndata: "));
}
