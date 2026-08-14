const std = @import("std");
const provider_mod = @import("../../io/provider.zig");
const agent_mod = @import("../../core/agent.zig");
const types = @import("../../types.zig");
const jsonw = @import("../../util/jsonw.zig");

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
        try self.sendTextFrame(event, text);
    }

    /// Fixed-first + alloc-fallback single-frame send. Hot path (short deltas)
    /// is zero-alloc via the 8192 stack buffer; rare oversized deltas fall back
    /// to one heap allocation instead of dropping the stream.
    fn sendTextFrame(self: *SseState, event: []const u8, text: []const u8) !void {
        var stack_buf: [8192]u8 = undefined;
        var jw = jsonw.JsonWriter.initFixed(&stack_buf);
        writeTextPayload(&jw, text) catch |err| {
            if (err != error.WriteFailed) return err;
            var ajw = jsonw.JsonWriter.init(std.heap.page_allocator);
            errdefer ajw.deinit();
            try writeTextPayload(&ajw, text);
            var out = try ajw.result();
            defer out.deinit();
            var head_buf: [128]u8 = undefined;
            const head = try std.fmt.bufPrint(&head_buf, "event: {s}\ndata: ", .{event});
            try self.w.writeAll(head);
            try self.w.writeAll(out.bytes);
            try self.w.writeAll("\n\n");
            try self.w.flush();
            return;
        };
        var head_buf: [128]u8 = undefined;
        const head = try std.fmt.bufPrint(&head_buf, "event: {s}\ndata: ", .{event});
        try self.w.writeAll(head);
        var out = try jw.result(); // fixed mode: borrowed view
        defer out.deinit();        // no-op for fixed
        try self.w.writeAll(out.bytes);
        try self.w.writeAll("\n\n");
        try self.w.flush();
    }
};

/// Write the JSON payload `{"text":"<escaped>"}` into a JsonWriter.
fn writeTextPayload(jw: *jsonw.JsonWriter, text: []const u8) !void {
    try jw.beginObject(null);
    try jw.stringField("text", text);
    try jw.endValue();
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
        var jw = jsonw.JsonWriter.init(std.heap.page_allocator);
        defer jw.deinit();
        serializeMeta(&jw, meta) catch return;
        var meta_json = try jw.result();
        defer meta_json.deinit();
        if (meta_json.bytes.len > 0) {
            s.writeFrame("tool_meta", meta_json.bytes) catch {};
        }
    }
}

/// Numeric-only ToolMeta summary for streaming display (no path/command etc).
fn serializeMeta(jw: *jsonw.JsonWriter, meta: types.ToolMeta) !void {
    switch (meta) {
        .bash => |m| {
            try jw.beginObject(null);
            try jw.stringField("name", "bash");
            try jw.intField("exit_code", m.exit_code);
            try jw.intField("byte_count", m.byte_count);
            try jw.boolField("truncated", m.truncated);
            try jw.endValue();
        },
        .read => |m| {
            try jw.beginObject(null);
            try jw.stringField("name", "read");
            try jw.intField("total_lines", m.total_lines);
            try jw.intField("byte_count", m.byte_count);
            try jw.boolField("truncated", m.truncated);
            try jw.endValue();
        },
        .grep => |m| {
            try jw.beginObject(null);
            try jw.stringField("name", "grep");
            try jw.intField("match_count", m.match_count);
            try jw.intField("files_scanned", m.files_scanned);
            try jw.boolField("truncated", m.truncated);
            try jw.endValue();
        },
        .glob => |m| {
            try jw.beginObject(null);
            try jw.stringField("name", "glob");
            try jw.intField("file_count", m.file_count);
            try jw.boolField("truncated", m.truncated);
            try jw.endValue();
        },
        .edit => |m| {
            try jw.beginObject(null);
            try jw.stringField("name", "edit");
            try jw.intField("replacements", m.replacements);
            try jw.endValue();
        },
        .write => |m| {
            try jw.beginObject(null);
            try jw.stringField("name", "write");
            try jw.intField("byte_count", m.byte_count);
            try jw.boolField("existed", m.existed);
            try jw.endValue();
        },
        .skill => |m| {
            try jw.beginObject(null);
            try jw.stringField("name", "skill");
            try jw.intField("file_count", m.file_count);
            try jw.endValue();
        },
        .webfetch => |m| {
            try jw.beginObject(null);
            try jw.stringField("name", "webfetch");
            try jw.intField("byte_count", m.byte_count);
            try jw.stringField("format", m.format);
            try jw.stringField("mime", m.mime);
            try jw.endValue();
        },
        .none => {},
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
