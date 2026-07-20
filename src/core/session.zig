const std = @import("std");
const types = @import("../types.zig");
const Io = std.Io;

/// Linear session storing messages in a JSONL file. All data owned by internal arena.
pub const Session = struct {
    _arena: std.heap.ArenaAllocator,
    io: Io,
    path: ?[]const u8,
    name: []const u8,
    _messages: std.ArrayListAligned(types.Message, null),
    modified: bool,
    model: []const u8,

    /// Create a new empty session. Name defaults to "New Session".
    pub fn init(allocator: std.mem.Allocator, io: Io, model: []const u8) !Session {
        var self = Session{
            ._arena = std.heap.ArenaAllocator.init(allocator),
            .io = io,
            .path = null,
            .name = &.{},
            ._messages = std.ArrayListAligned(types.Message, null).empty,
            .modified = false,
            .model = &.{},
        };
        errdefer self._arena.deinit();
        const arena = self._arena.allocator();
        self.name = try arena.dupe(u8, "New Session");
        self.model = try arena.dupe(u8, model);
        return self;
    }

    /// Load a session from a JSONL file. Returns error.InvalidSession if no header found.
    pub fn load(allocator: std.mem.Allocator, io: Io, path: []const u8) !Session {
        const file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
        defer file.close(io);
        const size = @as(usize, @intCast((try file.stat(io)).size));
        var raw_content = try allocator.alloc(u8, size);
        defer allocator.free(raw_content);
        const n = try file.readPositionalAll(io, raw_content, 0);
        const content_src = raw_content[0..n];

        var self = Session{
            ._arena = std.heap.ArenaAllocator.init(allocator),
            .io = io,
            .path = null,
            .name = &.{},
            ._messages = std.ArrayListAligned(types.Message, null).empty,
            .modified = false,
            .model = &.{},
        };
        errdefer self._arena.deinit();
        const arena = self._arena.allocator();
        const content = try arena.dupe(u8, content_src);

        self.path = try arena.dupe(u8, path);
        self.name = try arena.dupe(u8, "New Session");
        self.model = try arena.dupe(u8, "unknown");

        var lines = std.mem.splitScalar(u8, content, '\n');
        var header_seen = false;

        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, "\r");
            if (line.len == 0) continue;

            var parsed = std.json.parseFromSlice(std.json.Value, arena, line, .{}) catch continue;
            defer parsed.deinit();

            const obj = parsed.value.object;

            if (obj.get("type")) |tv| {
                if (tv == .string and std.mem.eql(u8, tv.string, "header")) {
                    if (obj.get("model")) |mv| if (mv == .string) {
                        arena.free(self.model);
                        self.model = try arena.dupe(u8, mv.string);
                    };
                    if (obj.get("name")) |nv| if (nv == .string) {
                        arena.free(self.name);
                        self.name = try arena.dupe(u8, nv.string);
                    };
                    header_seen = true;
                    continue;
                }
            }

            const role_str = obj.get("role") orelse continue;
            if (role_str != .string) continue;
            const role = roleFromString(role_str.string) orelse continue;

            const content_val = if (obj.get("content")) |v| if (v == .string) v.string else "" else "";

            const reasoning_content: ?[]const u8 = if (obj.get("reasoning_content")) |v| if (v == .string) try arena.dupe(u8, v.string) else null else null;

            var tool_calls: ?[]types.ToolCall = null;
            if (obj.get("tool_calls")) |tcs_val| {
                if (tcs_val == .array) {
                    const tcs = try arena.alloc(types.ToolCall, tcs_val.array.items.len);
                    for (tcs_val.array.items, 0..) |tc_val, j| {
                        const tc_obj = tc_val.object;
                        const id = if (tc_obj.get("id")) |v| if (v == .string) v.string else "" else "";
                        const name = if (tc_obj.get("name")) |v| if (v == .string) v.string else "" else "";
                        const arguments = if (tc_obj.get("arguments")) |v| if (v == .string) v.string else "" else "";
                        tcs[j] = .{
                            .id = try arena.dupe(u8, id),
                            .name = try arena.dupe(u8, name),
                            .arguments = try arena.dupe(u8, arguments),
                        };
                    }
                    tool_calls = tcs;
                }
            }

            const tool_call_id: ?[]const u8 = if (obj.get("tool_call_id")) |v| if (v == .string) try arena.dupe(u8, v.string) else null else null;
            const ts = if (obj.get("timestamp")) |v| if (v == .integer) @as(i64, @intCast(v.integer)) else @as(i64, 0) else @as(i64, 0);
            const msg_model: ?[]const u8 = if (obj.get("model")) |v| if (v == .string) try arena.dupe(u8, v.string) else null else null;
            const usage: ?types.TokenUsage = if (obj.get("usage")) |u_val| blk: {
                if (u_val == .object) {
                    const u = u_val.object;
                    if (u.get("input")) |in_val| {
                        if (u.get("output")) |out_val| {
                            if (u.get("total")) |tot_val| {
                                if (in_val != .null and out_val != .null and tot_val != .null) {
                                    const cache_hit: ?u32 = if (u.get("cache_hit")) |ch|
                                        if (ch != .null) @as(?u32, @intCast(ch.integer)) else null
                                    else null;
                                    const cache_miss: ?u32 = if (u.get("cache_miss")) |cm|
                                        if (cm != .null) @as(?u32, @intCast(cm.integer)) else null
                                    else null;
                                    break :blk .{
                                        .input = @intCast(in_val.integer),
                                        .output = @intCast(out_val.integer),
                                        .total = @intCast(tot_val.integer),
                                        .cache_hit = cache_hit,
                                        .cache_miss = cache_miss,
                                    };
                                }
                            }
                        }
                    }
                }
                break :blk null;
            } else null;

            try self._messages.append(arena, .{
                .role = role,
                .content = try arena.dupe(u8, content_val),
                .reasoning_content = reasoning_content,
                .tool_calls = tool_calls,
                .tool_call_id = tool_call_id,
                .timestamp = ts,
                .model = msg_model,
                .usage = usage,
            });
        }

        if (!header_seen) return error.InvalidSession;
        return self;
    }

    /// Append a message with deep copy into session arena. Auto-fills timestamp and model.
    pub fn append(self: *Session, msg: types.Message) !void {
        const arena = self._arena.allocator();
        var duped = msg;

        if (duped.timestamp == 0) {
            const clock_ts = Io.Clock.Timestamp.now(self.io, .real);
            duped.timestamp = Io.Timestamp.toSeconds(clock_ts.raw);
        }
        if (duped.role == .assistant and duped.model == null) {
            duped.model = self.model;
        }

        duped.content = try arena.dupe(u8, msg.content);
        if (msg.reasoning_content) |rc| duped.reasoning_content = try arena.dupe(u8, rc);
        if (msg.model) |m| duped.model = try arena.dupe(u8, m);
        if (msg.tool_call_id) |tci| duped.tool_call_id = try arena.dupe(u8, tci);
        if (msg.tool_calls) |tcs| {
            const duped_tcs = try arena.alloc(types.ToolCall, tcs.len);
            for (tcs, duped_tcs) |src, *dst| {
                dst.* = .{
                    .id = try arena.dupe(u8, src.id),
                    .name = try arena.dupe(u8, src.name),
                    .arguments = try arena.dupe(u8, src.arguments),
                };
            }
            duped.tool_calls = duped_tcs;
        }

        try self._messages.append(arena, duped);
        self.modified = true;
    }

    /// Return all messages. Slice borrowed from session arena; invalidated on append.
    pub fn messages(self: *const Session) []const types.Message {
        return self._messages.items;
    }

    /// Remove and return the last message. Keeps at least 1 message (system prompt guard).
    /// Used for rollback on failed runTurn (api_error/interrupted).
    /// Truncate message list to at most `keep` items. Scope: error rollback only.
    /// App records pre_count before appending user message, calls truncateTo(pre_count)
    /// on runTurn error to remove user + any partial assistant/tool messages from agent.
    /// Always followed by session.flush() at the call site; not for general-purpose truncation.
    pub fn truncateTo(self: *Session, keep: usize) void {
        if (keep < self._messages.items.len) {
            self._messages.shrinkRetainingCapacity(keep);
            self.modified = true;
        }
    }

    /// Replace the first system message or prepend one. Used for per-turn system prompt refresh.
    pub fn updateFirstSystem(self: *Session, content: []const u8) !void {
        const arena = self._arena.allocator();
        const duped = try arena.dupe(u8, content);
        if (self._messages.items.len > 0 and self._messages.items[0].role == .system) {
            self._messages.items[0].content = duped;
        } else {
            try self._messages.insert(arena, 0, .{ .role = .system, .content = duped });
        }
        self.modified = true;
    }

    /// Write all messages to JSONL file. Creates .zagent/sessions/ if needed.
    pub fn flush(self: *Session) !void {
        const arena = self._arena.allocator();
        const cwd = Io.Dir.cwd();

        if (self.path == null) {
            const file_name = sanitizeFileName(arena, self.name) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
            };
            const final_name = if (std.mem.eql(u8, file_name, "New_Session")) blk: {
                const ts = Io.Clock.Timestamp.now(self.io, .real);
                const now_ms = Io.Timestamp.toMilliseconds(ts.raw);
                break :blk try std.fmt.allocPrint(arena, "{d}", .{now_ms});
            } else file_name;
            const filename = try std.fmt.allocPrint(arena, "{s}.jsonl", .{final_name});
            cwd.createDirPath(self.io, ".zagent/sessions") catch {};
            self.path = try std.fs.path.join(arena, &.{ ".zagent/sessions", filename });
        }

        const tmp_path = try std.fmt.allocPrint(arena, "{s}.tmp", .{self.path.?});
        defer {
            if (!std.mem.eql(u8, self.path.?, tmp_path)) {
                cwd.deleteFile(self.io, tmp_path) catch {};
            }
        }

        {
            const file = try cwd.createFile(self.io, tmp_path, .{});
            defer file.close(self.io);

            try writeHeader(arena, self.io, file, self.name, self.model);
            for (self._messages.items) |msg| {
                var buf = std.array_list.Managed(u8).init(arena);
                defer buf.deinit();
                try serializeMessage(&buf, msg);
                try file.writeStreamingAll(self.io, buf.items);
            }
        }

        try Io.Dir.rename(cwd, tmp_path, cwd, self.path.?, self.io);
        self.modified = false;

        if (self._messages.items.len > 50) {
            var msg_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "session: {d} messages, context may overflow\n", .{self._messages.items.len}) catch return;
            var dbuf: [256]u8 = undefined;
            var dw: Io.File.Writer = .init(.stderr(), self.io, &dbuf);
            _ = dw.interface.writeAll(msg) catch {};
            _ = dw.interface.flush() catch {};
        }
    }

    /// Write current session messages to a JSONL file. Does not change internal path.
    /// Uses temp-then-rename for atomicity.
    pub fn writeTo(self: *Session, file_path: []const u8, io: Io) !void {
        const arena = self._arena.allocator();
        const cwd = Io.Dir.cwd();

        const tmp_path = try std.fmt.allocPrint(arena, "{s}.tmp", .{file_path});
        defer cwd.deleteFile(io, tmp_path) catch {};

        {
            const file = try cwd.createFile(io, tmp_path, .{});
            defer file.close(io);

            try writeHeader(arena, io, file, self.name, self.model);
            for (self._messages.items) |msg| {
                var buf = std.array_list.Managed(u8).init(arena);
                defer buf.deinit();
                try serializeMessage(&buf, msg);
                try file.writeStreamingAll(io, buf.items);
            }
        }

        try Io.Dir.rename(cwd, tmp_path, cwd, file_path, io);
    }

    /// Rename session and corresponding JSONL file. Creates new file, keeps old.
    pub fn rename(self: *Session, new_name: []const u8) !void {
        const arena = self._arena.allocator();

        const file_name = sanitizeFileName(arena, new_name) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };

        if (self.path != null) {
            const cwd = Io.Dir.cwd();
            const dir_path = std.fs.path.dirname(self.path.?) orelse ".";
            var candidate = try std.fmt.allocPrint(arena, "{s}.jsonl", .{file_name});
            var target = try std.fs.path.join(arena, &.{ dir_path, candidate });

            var counter: usize = 1;
            while (true) {
                const exists = Io.Dir.cwd().openFile(self.io, target, .{ .mode = .read_only }) catch null;
                if (exists == null) break;
                exists.?.close(self.io);
                candidate = try std.fmt.allocPrint(arena, "{s}-{d}.jsonl", .{ file_name, counter });
                target = try std.fs.path.join(arena, &.{ dir_path, candidate });
                counter += 1;
            }

            try Io.Dir.rename(cwd, self.path.?, cwd, target, self.io);
            self.path = target;
        }

        self.name = try arena.dupe(u8, new_name);
    }

    /// Free all session memory including arena.
    pub fn deinit(self: *Session) void {
        self._arena.deinit();
    }
};

fn roleFromString(s: []const u8) ?types.Role {
    if (std.mem.eql(u8, s, "system")) return .system;
    if (std.mem.eql(u8, s, "user")) return .user;
    if (std.mem.eql(u8, s, "assistant")) return .assistant;
    if (std.mem.eql(u8, s, "tool")) return .tool;
    return null;
}

fn sanitizeFileName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var buf: std.ArrayListAligned(u8, null) = .empty;
    errdefer buf.deinit(allocator);
    for (name) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.') {
            try buf.append(allocator, c);
        } else {
            try buf.append(allocator, '_');
        }
    }
    if (buf.items.len == 0) return allocator.dupe(u8, "session");
    return buf.toOwnedSlice(allocator);
}

fn appendEscapedJsonString(buf: *std.array_list.Managed(u8), s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c < 0x80) {
            switch (c) {
                '"' => try buf.appendSlice("\\\""),
                '\\' => try buf.appendSlice("\\\\"),
                '\n' => try buf.appendSlice("\\n"),
                '\r' => try buf.appendSlice("\\r"),
                '\t' => try buf.appendSlice("\\t"),
                0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                    var hex_buf: [6]u8 = undefined;
                    const hex = try std.fmt.bufPrint(&hex_buf, "\\u00{x:0>2}", .{@as(u8, c)});
                    try buf.appendSlice(hex);
                },
                else => try buf.append(c),
            }
            i += 1;
        } else if (c >= 0xC0 and c <= 0xDF) {
            if (i + 1 < s.len) {
                try buf.appendSlice(s[i..i + 2]);
                i += 2;
            } else {
                try buf.appendSlice("\\ufffd");
                i += 1;
            }
        } else if (c >= 0xE0 and c <= 0xEF) {
            if (i + 2 < s.len) {
                try buf.appendSlice(s[i..i + 3]);
                i += 3;
            } else {
                try buf.appendSlice("\\ufffd");
                i += 1;
            }
        } else if (c >= 0xF0 and c <= 0xF4) {
            if (i + 3 < s.len) {
                try buf.appendSlice(s[i..i + 4]);
                i += 4;
            } else {
                try buf.appendSlice("\\ufffd");
                i += 1;
            }
        } else {
            try buf.appendSlice("\\ufffd");
            i += 1;
        }
    }
}

fn epochToISO8601(allocator: std.mem.Allocator, epoch_s: i64) ![]const u8 {
    const z = @divFloor(epoch_s, 86400) + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = @as(u64, @intCast(z - era * 146097));
    const yoe = @as(u64, @intCast((doe - doe / 1460 + doe / 36524 - doe / 146096) / 365));
    const y = @as(i64, @intCast(yoe)) + @as(i64, @intCast(era * 400));
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp = (5 * doy + 2) / 153;
    const d = doy - (153 * mp + 2) / 5 + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const year = if (m <= 2) y + 1 else y;
    const tod = @mod(epoch_s, 86400);
    const h = @divFloor(tod, 3600);
    const min = @mod(@divFloor(tod, 60), 60);
    const sec = @mod(tod, 60);
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ year, m, d, h, min, sec });
}

fn writeHeader(allocator: std.mem.Allocator, io: Io, file: Io.File, name: []const u8, model: []const u8) !void {
    const clock_ts = Io.Clock.Timestamp.now(io, .real);
    const now = Io.Timestamp.toSeconds(clock_ts.raw);
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try buf.appendSlice("{\"type\":\"header\",\"timestamp\":\"");
    const ts_iso = epochToISO8601(allocator, now) catch unreachable;
    defer allocator.free(ts_iso);
    try buf.appendSlice(ts_iso);
    try buf.appendSlice("\",\"model\":\"");
    try appendEscapedJsonString(&buf, model);
    try buf.appendSlice("\",\"name\":\"");
    try appendEscapedJsonString(&buf, name);
    try buf.appendSlice("\"}\n");

    try file.writeStreamingAll(io, buf.items);
}

fn serializeMessage(buf: *std.array_list.Managed(u8), msg: types.Message) !void {
    try buf.appendSlice("{\"role\":\"");
    try buf.appendSlice(@tagName(msg.role));
    try buf.appendSlice("\"");

    try buf.appendSlice(",\"content\":\"");
    try appendEscapedJsonString(buf, msg.content);
    try buf.appendSlice("\"");

    if (msg.reasoning_content) |rc| {
        try buf.appendSlice(",\"reasoning_content\":\"");
        try appendEscapedJsonString(buf, rc);
        try buf.appendSlice("\"");
    }

    if (msg.tool_calls) |tcs| {
        try buf.appendSlice(",\"tool_calls\":[");
        for (tcs, 0..) |tc, j| {
            if (j > 0) try buf.appendSlice(",");
            try buf.appendSlice("{\"id\":\"");
            try appendEscapedJsonString(buf, tc.id);
            try buf.appendSlice("\",\"name\":\"");
            try appendEscapedJsonString(buf, tc.name);
            try buf.appendSlice("\",\"arguments\":\"");
            try appendEscapedJsonString(buf, tc.arguments);
            try buf.appendSlice("\"}");
        }
        try buf.appendSlice("]");
    }

    if (msg.tool_call_id) |tci| {
        try buf.appendSlice(",\"tool_call_id\":\"");
        try appendEscapedJsonString(buf, tci);
        try buf.appendSlice("\"");
    }

    if (msg.model) |m| {
        try buf.appendSlice(",\"model\":\"");
        try appendEscapedJsonString(buf, m);
        try buf.appendSlice("\"");
    }

    if (msg.timestamp != 0) {
        var ts_buf: [32]u8 = undefined;
        const ts_str = try std.fmt.bufPrint(&ts_buf, ",\"timestamp\":{d}", .{msg.timestamp});
        try buf.appendSlice(ts_str);
    }

    if (msg.usage) |u| {
        try buf.appendSlice(",\"usage\":{\"input\":");
        var in_buf: [16]u8 = undefined;
        const in_s = try std.fmt.bufPrint(&in_buf, "{d}", .{u.input});
        try buf.appendSlice(in_s);
        try buf.appendSlice(",\"output\":");
        var out_buf: [16]u8 = undefined;
        const out_s = try std.fmt.bufPrint(&out_buf, "{d}", .{u.output});
        try buf.appendSlice(out_s);
        try buf.appendSlice(",\"total\":");
        var tot_buf: [16]u8 = undefined;
        const tot_s = try std.fmt.bufPrint(&tot_buf, "{d}", .{u.total});
        try buf.appendSlice(tot_s);
        if (u.cache_hit) |ch| {
            try buf.appendSlice(",\"cache_hit\":");
            var ch_buf: [16]u8 = undefined;
            const ch_s = try std.fmt.bufPrint(&ch_buf, "{d}", .{ch});
            try buf.appendSlice(ch_s);
        }
        if (u.cache_miss) |cm| {
            try buf.appendSlice(",\"cache_miss\":");
            var cm_buf: [16]u8 = undefined;
            const cm_s = try std.fmt.bufPrint(&cm_buf, "{d}", .{cm});
            try buf.appendSlice(cm_s);
        }
        try buf.appendSlice("}");
    }

    try buf.appendSlice("}\n");
}

pub const SessionInfo = types.SessionInfo;

/// List all sessions in session_dir. Caller owns returned slice; free with freeSessionInfoList.
pub fn list(allocator: std.mem.Allocator, io: Io, session_dir: []const u8) ![]SessionInfo {
    var dir = Io.Dir.cwd().openDir(io, session_dir, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);

    var results: std.ArrayListAligned(SessionInfo, null) = .empty;
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;

        const file_path = try std.fs.path.join(allocator, &.{ session_dir, entry.name });
        defer allocator.free(file_path);

        const file = Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only }) catch continue;
        defer file.close(io);

        const size = @as(usize, @intCast((file.stat(io) catch continue).size));

        var content = allocator.alloc(u8, size) catch continue;
        defer allocator.free(content);
        const n = file.readPositionalAll(io, content, 0) catch continue;

        var lines = std.mem.splitScalar(u8, content[0..n], '\n');
        var header: struct {
            timestamp: i64 = 0,
            name: []const u8 = "",
            model: []const u8 = "",
        } = .{};
        var found = false;

        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, "\r");
            if (line.len == 0) continue;

            var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
            defer parsed.deinit();

            if (parsed.value.object.get("type")) |tv| {
                if (tv == .string and std.mem.eql(u8, tv.string, "header")) {
                    if (parsed.value.object.get("timestamp")) |tsv| {
                        if (tsv == .string) {
                            header.timestamp = parseISO8601Epoch(tsv.string);
                        }
                    }
                    if (parsed.value.object.get("name")) |nv| {
                        if (nv == .string) header.name = try allocator.dupe(u8, nv.string);
                    }
                    if (parsed.value.object.get("model")) |mv| {
                        if (mv == .string) header.model = try allocator.dupe(u8, mv.string);
                    }
                    found = true;
                    break;
                }
            }
            break;
        }

        if (!found) continue;

        const stem = if (std.mem.endsWith(u8, entry.name, ".jsonl"))
            entry.name[0 .. entry.name.len - 6]
        else
            entry.name;

        const msg_count_est = @max(size / 150, 1);

        try results.append(allocator, .{
            .id = try allocator.dupe(u8, stem),
            .name = header.name,
            .file_path = try allocator.dupe(u8, file_path),
            .timestamp = header.timestamp,
            .model = header.model,
            .msg_count = msg_count_est,
        });
    }

    const sorted = try results.toOwnedSlice(allocator);
    std.mem.sort(SessionInfo, sorted, {}, struct {
        fn lt(_: void, a: SessionInfo, b: SessionInfo) bool {
            return a.timestamp > b.timestamp;
        }
    }.lt);
    return sorted;
}

fn parseISO8601Epoch(ts: []const u8) i64 {
    if (ts.len < 19) return 0;
    const year = std.fmt.parseInt(i32, ts[0..4], 10) catch return 0;
    const month = std.fmt.parseInt(u32, ts[5..7], 10) catch return 0;
    const day = std.fmt.parseInt(u32, ts[8..10], 10) catch return 0;
    const hour = std.fmt.parseInt(u32, ts[11..13], 10) catch return 0;
    const minute = std.fmt.parseInt(u32, ts[14..16], 10) catch return 0;
    const second = std.fmt.parseInt(u32, ts[17..19], 10) catch return 0;

    const y = @as(i32, year) - @as(i32, @intFromBool(month <= 2));
    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe = @as(u32, @intCast(y - era * 400));
    const doy = (153 * (if (month > 2) month - 3 else month + 9) + 2) / 5 + day - 1;
    const doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    const days = era * 146097 + @as(i32, @intCast(doe)) - 719468;
    return @as(i64, days) * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + second;
}

/// Free all memory allocated by list().
pub fn freeSessionInfoList(allocator: std.mem.Allocator, list_slice: []SessionInfo) void {
    for (list_slice) |info| {
        allocator.free(info.id);
        allocator.free(info.name);
        allocator.free(info.file_path);
        allocator.free(info.model);
    }
    allocator.free(list_slice);
}

test "session: init creates empty" {
    const io = std.testing.io;
    var sess = try Session.init(std.testing.allocator, io, "deepseek/deepseek-v4-pro");
    defer sess.deinit();

    try std.testing.expectEqualStrings("New Session", sess.name);
    try std.testing.expectEqualStrings("deepseek/deepseek-v4-pro", sess.model);
    try std.testing.expectEqual(@as(usize, 0), sess.messages().len);
    try std.testing.expect(!sess.modified);
}

test "session: append and retrieve" {
    const io = std.testing.io;
    var sess = try Session.init(std.testing.allocator, io, "deepseek/deepseek-v4-pro");
    defer sess.deinit();

    try sess.append(.{ .role = .user, .content = "hello", .timestamp = 100 });
    try sess.append(.{ .role = .assistant, .content = "hi there" });

    const msgs = sess.messages();
    try std.testing.expectEqual(@as(usize, 2), msgs.len);
    try std.testing.expectEqual(types.Role.user, msgs[0].role);
    try std.testing.expectEqualStrings("hello", msgs[0].content);
    try std.testing.expectEqual(@as(i64, 100), msgs[0].timestamp);
    try std.testing.expectEqual(types.Role.assistant, msgs[1].role);
    try std.testing.expectEqualStrings("deepseek/deepseek-v4-pro", msgs[1].model orelse "");
    try std.testing.expect(msgs[1].timestamp > 0);
    try std.testing.expect(sess.modified);
}

test "session: append auto-fills timestamp" {
    const io = std.testing.io;
    var sess = try Session.init(std.testing.allocator, io, "deepseek/model");
    defer sess.deinit();

    try sess.append(.{ .role = .user, .content = "hi" });
    const msgs = sess.messages();
    try std.testing.expect(msgs[0].timestamp > 0);
}

test "session: append auto-fills model for assistant" {
    const io = std.testing.io;
    var sess = try Session.init(std.testing.allocator, io, "deepseek/model");
    defer sess.deinit();

    try sess.append(.{ .role = .assistant, .content = "hello" });
    const msgs = sess.messages();
    try std.testing.expectEqualStrings("deepseek/model", msgs[0].model orelse "");
}

test "session: message pairs by adjacency" {
    const io = std.testing.io;
    var sess = try Session.init(std.testing.allocator, io, "deepseek/model");
    defer sess.deinit();

    try sess.append(.{ .role = .user, .content = "read file" });
    try sess.append(.{ .role = .assistant, .content = "", .tool_calls = &.{
        .{ .id = "c1", .name = "read", .arguments = "{}" },
    } });
    try sess.append(.{ .role = .tool, .content = "file contents", .tool_call_id = "c1" });
    try sess.append(.{ .role = .assistant, .content = "done" });

    const msgs = sess.messages();
    try std.testing.expectEqual(@as(usize, 4), msgs.len);
    try std.testing.expectEqual(types.Role.user, msgs[0].role);
    try std.testing.expectEqual(types.Role.assistant, msgs[1].role);
    try std.testing.expect(msgs[1].tool_calls != null);
    try std.testing.expectEqualStrings("c1", msgs[1].tool_calls.?[0].id);
    try std.testing.expectEqual(types.Role.tool, msgs[2].role);
    try std.testing.expectEqualStrings("c1", msgs[2].tool_call_id orelse "");
    try std.testing.expectEqual(types.Role.assistant, msgs[3].role);
}

test "session: flush writes JSONL" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-session-flush";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {};
    try Io.Dir.cwd().createDirPath(io, test_root);
    try Io.Dir.cwd().createDirPath(io, test_root ++ "/.zagent/sessions");

    var orig_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const orig_len = Io.Dir.cwd().realPath(io, &orig_cwd_buf) catch unreachable;

    try std.process.setCurrentPath(io, test_root);

    var sess = try Session.init(allocator, io, "deepseek/model");
    defer sess.deinit();
    try sess.append(.{ .role = .user, .content = "hello", .timestamp = 1752062401 });

    try sess.flush();
    try std.testing.expect(!sess.modified);

    const real_dir = try Io.Dir.cwd().openDir(io, ".zagent/sessions", .{ .iterate = true });
    defer real_dir.close(io);
    var iter2 = real_dir.iterate();
    var found_file = false;
    while (iter2.next(io) catch null) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".jsonl")) {
            found_file = true;
            break;
        }
    }
    try std.testing.expect(found_file);

    try std.process.setCurrentPath(io, orig_cwd_buf[0..orig_len]);
}

test "session: load reads JSONL" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-session-load";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {};
    try Io.Dir.cwd().createDirPath(io, test_root);
    const sessions_dir = try std.fs.path.join(allocator, &.{ test_root, ".zagent", "sessions" });
    defer allocator.free(sessions_dir);
    try Io.Dir.cwd().createDirPath(io, sessions_dir);

    const content =
        \\{"type":"header","timestamp":"2026-07-09T12:00:00Z","model":"deepseek/model","name":"Test Session"}
        \\{"role":"user","content":"hello","timestamp":1752062401}
        \\{"role":"assistant","content":"Hi!","model":"deepseek/model","timestamp":1752062402}
        \\
    ;

    const file_path = try std.fs.path.join(allocator, &.{ test_root, ".zagent", "sessions", "test.jsonl" });
    defer allocator.free(file_path);
    {
        const file = try Io.Dir.cwd().createFile(io, file_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, content);
    }

    var loaded_sess = try Session.load(allocator, io, file_path);
    defer loaded_sess.deinit();

    try std.testing.expectEqualStrings("Test Session", loaded_sess.name);
    try std.testing.expectEqualStrings("deepseek/model", loaded_sess.model);
    const msgs = loaded_sess.messages();
    try std.testing.expectEqual(@as(usize, 2), msgs.len);
    try std.testing.expectEqual(types.Role.user, msgs[0].role);
    try std.testing.expectEqualStrings("hello", msgs[0].content);
    try std.testing.expectEqual(types.Role.assistant, msgs[1].role);
    try std.testing.expectEqualStrings("Hi!", msgs[1].content);
}

test "session: flush then load roundtrip" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-session-roundtrip";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {};
    try Io.Dir.cwd().createDirPath(io, test_root);
    try Io.Dir.cwd().createDirPath(io, test_root ++ "/.zagent/sessions");

    var orig_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const orig_len = Io.Dir.cwd().realPath(io, &orig_cwd_buf) catch unreachable;

    try std.process.setCurrentPath(io, test_root);

    var sess = try Session.init(allocator, io, "deepseek/model");
    defer sess.deinit();
    try sess.append(.{ .role = .user, .content = "hello", .timestamp = 1752062401 });
    try sess.append(.{ .role = .assistant, .content = "world", .timestamp = 1752062402 });
    try sess.flush();
    const saved_path = sess.path.?;

    var loaded = try Session.load(allocator, io, saved_path);
    defer loaded.deinit();

    try std.testing.expectEqualStrings("New Session", loaded.name);
    try std.testing.expectEqual(@as(usize, 2), loaded.messages().len);
    try std.testing.expectEqualStrings("hello", loaded.messages()[0].content);
    try std.testing.expectEqualStrings("world", loaded.messages()[1].content);

    try std.process.setCurrentPath(io, orig_cwd_buf[0..orig_len]);
}

test "session: rename file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-session-rename";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {};
    try Io.Dir.cwd().createDirPath(io, test_root);
    const sessions_dir = try std.fs.path.join(allocator, &.{ test_root, ".zagent", "sessions" });
    defer allocator.free(sessions_dir);
    try Io.Dir.cwd().createDirPath(io, sessions_dir);

    const file_path = try std.fs.path.join(allocator, &.{ test_root, ".zagent", "sessions", "test.jsonl" });
    defer allocator.free(file_path);
    {
        const file = try Io.Dir.cwd().createFile(io, file_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io,
            \\{"type":"header","timestamp":"2026-07-09T12:00:00Z","model":"deepseek/model","name":"Old Name"}
            \\
        );
    }

    var sess = try Session.load(allocator, io, file_path);
    defer sess.deinit();

    try sess.rename("My Session");
    try std.testing.expectEqualStrings("My Session", sess.name);
    try std.testing.expect(!std.mem.eql(u8, file_path, sess.path orelse ""));

    {
        const f = Io.Dir.cwd().openFile(io, sess.path.?, .{ .mode = .read_only }) catch null;
        try std.testing.expect(f != null);
        if (f) |ff| ff.close(io);
    }
}

test "session: sanitize file name" {
    const allocator = std.testing.allocator;
    const result = try sanitizeFileName(allocator, "Hello World! 2026");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello_World__2026", result);

    const result2 = try sanitizeFileName(allocator, "!@#$%");
    defer allocator.free(result2);
    try std.testing.expectEqualStrings("_____", result2);

    const result3 = try sanitizeFileName(allocator, "!!!");
    defer allocator.free(result3);
    try std.testing.expectEqualStrings("___", result3);

    const result4 = try sanitizeFileName(allocator, "");
    defer allocator.free(result4);
    try std.testing.expectEqualStrings("session", result4);
}

test "session: list sessions" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-session-list";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {};
    try Io.Dir.cwd().createDirPath(io, test_root);
    const sessions_dir = try std.fs.path.join(allocator, &.{ test_root, ".zagent", "sessions" });
    defer allocator.free(sessions_dir);
    try Io.Dir.cwd().createDirPath(io, sessions_dir);

    {
        const file_a = try std.fs.path.join(allocator, &.{ sessions_dir, "a.jsonl" });
        defer allocator.free(file_a);
        const file = try Io.Dir.cwd().createFile(io, file_a, .{});
        defer file.close(io);
        try file.writeStreamingAll(io,
            \\{"type":"header","timestamp":"2026-07-09T12:00:00Z","model":"m1","name":"Session A"}
            \\
        );
    }
    {
        const file_b = try std.fs.path.join(allocator, &.{ sessions_dir, "b.jsonl" });
        defer allocator.free(file_b);
        const file = try Io.Dir.cwd().createFile(io, file_b, .{});
        defer file.close(io);
        try file.writeStreamingAll(io,
            \\{"type":"header","timestamp":"2026-07-09T13:00:00Z","model":"m2","name":"Session B"}
            \\
        );
    }

    const sessions = try list(allocator, io, sessions_dir);
    defer freeSessionInfoList(allocator, sessions);

    try std.testing.expect(sessions.len >= 2);
}

test "session: empty list" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const result = list(allocator, io, ".zig-test-nonexistent-sessions") catch &.{};
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "session: load invalid file returns error" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-session-invalid";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {};
    try Io.Dir.cwd().createDirPath(io, test_root);

    const file_path = try std.fs.path.join(allocator, &.{ test_root, "bad.jsonl" });
    defer allocator.free(file_path);
    {
        const file = try Io.Dir.cwd().createFile(io, file_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "not a valid session header\n");
    }

    const result = Session.load(allocator, io, file_path);
    try std.testing.expectError(error.InvalidSession, result);
}

test "session: load skips invalid message lines" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-session-skip";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {};
    try Io.Dir.cwd().createDirPath(io, test_root);

    const content =
        \\{"type":"header","timestamp":"2026-07-09T12:00:00Z","model":"deepseek/model","name":"Test"}
        \\{"role":"user","content":"valid","timestamp":1}
        \\this is not json
        \\{"role":"assistant","content":"also valid","timestamp":2}
        \\
    ;

    const file_path = try std.fs.path.join(allocator, &.{ test_root, "skip.jsonl" });
    defer allocator.free(file_path);
    {
        const file = try Io.Dir.cwd().createFile(io, file_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, content);
    }

    var loaded2 = try Session.load(allocator, io, file_path);
    defer loaded2.deinit();

    try std.testing.expectEqual(@as(usize, 2), loaded2.messages().len);
}

test "session: truncateTo shrinks" {
    const io = std.testing.io;
    var sess = try Session.init(std.testing.allocator, io, "test");
    defer sess.deinit();

    try sess.append(.{ .role = .system, .content = "sys" });
    try sess.append(.{ .role = .user, .content = "u1" });
    try sess.append(.{ .role = .assistant, .content = "a1" });
    try sess.append(.{ .role = .tool, .content = "t1" });

    sess.truncateTo(2);
    try std.testing.expectEqual(@as(usize, 2), sess.messages().len);
    try std.testing.expectEqualStrings("sys", sess.messages()[0].content);
    try std.testing.expectEqualStrings("u1", sess.messages()[1].content);
    try std.testing.expect(sess.modified);
}

test "session: truncateTo keep >= len is no-op" {
    const io = std.testing.io;
    var sess = try Session.init(std.testing.allocator, io, "test");
    defer sess.deinit();

    try sess.append(.{ .role = .system, .content = "sys" });
    sess.modified = false;
    sess.truncateTo(5);
    try std.testing.expectEqual(@as(usize, 1), sess.messages().len);
    try std.testing.expect(!sess.modified);
}
