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
    flushFn: *const fn (*anyopaque) anyerror!void,

    pub fn writeAll(self: SseWriter, bytes: []const u8) !void {
        return self.writeAllFn(self.ctx, bytes);
    }

    pub fn flush(self: SseWriter) !void {
        return self.flushFn(self.ctx);
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
        .flushFn = struct {
            fn flush(p: *anyopaque) anyerror!void {
                const w: *Child = @ptrCast(@alignCast(p));
                try w.flush();
            }
        }.flush,
    };
}

pub const SseState = struct {
    w: SseWriter,
    io: std.Io,
    agent: ?*agent_mod.AgentLoop = null,
    thinking_start_ms: i64 = 0,
    current_phase: PhaseType = .none,
    tool_id_counter: u32 = 0,

    pub fn writeFrame(self: *SseState, event: []const u8, data: []const u8) !void {
        var buf: [4096]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "event: {s}\ndata: {s}\n\n", .{ event, data });
        try self.w.writeAll(msg);
        try self.w.flush();
    }

    fn writeTextDelta(self: *SseState, event: []const u8, text: []const u8) !void {
        var buf: [8192]u8 = undefined;
        const pos = try std.fmt.bufPrint(&buf, "event: {s}\ndata: {{\"text\":\"", .{event});
        var pos2 = pos.len;
        pos2 += (try jsonEscapeBuf(buf[pos2..], text)).len;
        const end = try std.fmt.bufPrint(buf[pos2..], "\"}}\n\n", .{});
        try self.w.writeAll(buf[0 .. pos2 + end.len]);
        try self.w.flush();
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
            s.writeFrame("thinking_start", "{}") catch {
                if (s.agent) |ag| ag.abort();
            };
        },
        .content => {
            s.writeFrame("content_start", "{}") catch {
                if (s.agent) |ag| ag.abort();
            };
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
    s.writeTextDelta(event, bytes) catch {
        if (s.agent) |ag| ag.abort();
    };
}

fn writeRendered(ctx: ?*anyopaque, line: []const u8) void {
    const s: *SseState = @ptrCast(@alignCast(ctx.?));
    s.writeTextDelta("content_delta", line) catch {
        if (s.agent) |ag| ag.abort();
    };
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
            s.writeFrame("thinking_end", payload) catch {
                if (s.agent) |ag| ag.abort();
            };
        },
        .content => {
            s.writeFrame("content_end", "{}") catch {
                if (s.agent) |ag| ag.abort();
            };
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
    s.writeFrame("tool_start", payload) catch {
        if (s.agent) |ag| ag.abort();
    };
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

    if (had_error) {
        const err = err_msg orelse "unknown error";
        var buf: [512]u8 = undefined;
        const payload = std.fmt.bufPrint(&buf, "{{\"id\":\"call_{d}\",\"name\":\"{s}\",\"error\":\"{s}\"}}", .{ s.tool_id_counter, tool_name, err }) catch "{}";
        s.writeFrame("tool_error", payload) catch {
            if (s.agent) |ag| ag.abort();
        };
    } else {
        var header_buf: [512]u8 = undefined;
        const header = if (tool_args.len > 0 and !std.mem.eql(u8, tool_args, "{}"))
            std.fmt.bufPrint(&header_buf, "```input\n{s}\n```\n\n", .{tool_args}) catch "```input\n...\n```\n\n"
        else
            "";

        if (header.len > 0) {
            s.writeTextDelta("tool_delta", header) catch {
                if (s.agent) |ag| ag.abort();
                return;
            };
        }

        const output = user_output orelse "";
        var pos: usize = 0;
        while (pos < output.len) {
            const end = @min(pos + 7000, output.len);
            s.writeTextDelta("tool_delta", output[pos..end]) catch {
                if (s.agent) |ag| ag.abort();
                break;
            };
            pos = end;
        }

        // serialize ToolMeta as tool_meta event
        var meta_buf: [512]u8 = undefined;
        const meta_json = serializeMeta(&meta_buf, meta) catch "";
        if (meta_json.len > 0) {
            s.writeFrame("tool_meta", meta_json) catch {};
        }
    }
}

fn serializeMeta(buf: []u8, meta: types.ToolMeta) ![]const u8 {
    switch (meta) {
        .bash => |m| return try std.fmt.bufPrint(buf, "{{\"name\":\"bash\",\"exit_code\":{d},\"byte_count\":{d},\"truncated\":{}}}", .{ m.exit_code, m.byte_count, m.truncated }),
        .read => |m| return try std.fmt.bufPrint(buf, "{{\"name\":\"read\",\"total_lines\":{d},\"byte_count\":{d},\"truncated\":{}}}", .{ m.total_lines, m.byte_count, m.truncated }),
        .grep => |m| return try std.fmt.bufPrint(buf, "{{\"name\":\"grep\",\"match_count\":{d},\"files_scanned\":{d},\"truncated\":{}}}", .{ m.match_count, m.files_scanned, m.truncated }),
        .glob => |m| return try std.fmt.bufPrint(buf, "{{\"name\":\"glob\",\"file_count\":{d},\"truncated\":{}}}", .{ m.file_count, m.truncated }),
        .edit => |m| return try std.fmt.bufPrint(buf, "{{\"name\":\"edit\",\"replacements\":{d}}}", .{m.replacements}),
        .write => |m| return try std.fmt.bufPrint(buf, "{{\"name\":\"write\",\"byte_count\":{d},\"existed\":{}}}", .{ m.byte_count, m.existed }),
        .skill => |m| return try std.fmt.bufPrint(buf, "{{\"name\":\"skill\",\"file_count\":{d}}}", .{m.file_count}),
        .webfetch => |m| return try std.fmt.bufPrint(buf, "{{\"name\":\"webfetch\",\"byte_count\":{d},\"format\":\"{s}\",\"mime\":\"{s}\"}}", .{ m.byte_count, m.format, m.mime }),
        .none => return &.{},
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
