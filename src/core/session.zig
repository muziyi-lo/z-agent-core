const std = @import("std");
const types = @import("../types.zig");
const Io = std.Io;

pub const DEFAULT_SESSION_NAME = "New Session";
pub const DEFAULT_SESSION_FILENAME = "New_Session";
/// Single source of truth for the sessions directory (relative to project root).
/// Referenced by Session.flush and both frontends (init.zig, server.zig).
pub const sessions_subdir = ".zagent/sessions";

/// Process-level lock serializing all session file writes (flush / writeTo /
/// writePrefixTo / removeMessage / renameTitle). Session.flush does a whole-file
/// tmp+rename with a FIXED tmp name (`{path}.tmp`), so two threads writing the
/// same session concurrently would clobber each other's tmp file. Locking must
/// cover the full read-modify-write transaction, single-layer held (public
/// entry locks, internal `XxxLocked` is lock-free) — see renameTitle.
var session_write_mutex: std.Io.Mutex = .init;

/// Linear session storing messages in a JSONL file. All data owned by internal arena.
pub const Session = struct {
    _arena: std.heap.ArenaAllocator,
    io: Io,
    path: ?[]const u8,
    name: []const u8,
    _messages: std.ArrayListAligned(types.Message, null),
    modified: bool,
    model: []const u8,
    /// Source session id for fork/branch children (null for top-level sessions).
    parent_id: ?[]const u8 = null,
    /// Next message id to assign. Monotonic across appends; loaded ids bump it.
    _next_id: u64,
    /// Id of the latest `[Compaction]` system message written by compactSession.
    /// Null when never compacted in-process. Not persisted (non-backward-compat
    /// policy): stale-usage guard only needs a non-null bound once compacted.
    last_compact_id: ?u64 = null,

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
            .parent_id = null,
            ._next_id = 1,
            .last_compact_id = null,
        };
        errdefer self._arena.deinit();
        const arena = self._arena.allocator();
        self.name = try arena.dupe(u8, DEFAULT_SESSION_NAME);
        self.model = try arena.dupe(u8, model);
        return self;
    }

    /// Delete a session JSONL file by path. Mirrors load() parameter convention.
    pub fn deleteFile(io: Io, path: []const u8) !void {
        try Io.Dir.cwd().deleteFile(io, path);
    }

    /// Reject session IDs containing path traversal characters.
    /// Accepts alphanumeric, `-` (UUID v4), `_`.
    pub fn isValidId(id: []const u8) bool {
        if (id.len == 0) return false;
        for (id) |c| {
            if (c == '.' or c == '/' or c == '\\') return false;
        }
        return true;
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
            .parent_id = null,
            ._next_id = 1,
            .last_compact_id = null,
        };
        errdefer self._arena.deinit();
        const arena = self._arena.allocator();
        const content = try arena.dupe(u8, content_src);

        self.path = try arena.dupe(u8, path);
        self.name = try arena.dupe(u8, DEFAULT_SESSION_NAME);
        self.model = try arena.dupe(u8, "unknown");

        var lines = std.mem.splitScalar(u8, content, '\n');
        var header_seen = false;
        var migrated = false;

        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, "\r");
            if (line.len == 0) continue;

            var parsed = std.json.parseFromSlice(std.json.Value, arena, line, .{}) catch {
                var dbuf: [256]u8 = undefined;
                var dw: Io.File.Writer = .init(.stderr(), io, &dbuf);
                _ = dw.interface.writeAll("z-agent-core: warning: skipping unparseable line in session file\n") catch {};
                _ = dw.interface.flush() catch {};
                continue;
            };
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
                    if (obj.get("parent_id")) |pv| if (pv == .string and pv.string.len > 0) {
                        self.parent_id = try arena.dupe(u8, pv.string);
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

            // Message id: preserve persisted id; assign a fresh monotonic id for
            // legacy lines without one (one-time migration, flushed below).
            var assigned_id: u64 = undefined;
            if (obj.get("id")) |v| {
                if (v == .integer) {
                    assigned_id = @intCast(v.integer);
                    if (self._next_id <= assigned_id) self._next_id = assigned_id + 1;
                } else {
                    assigned_id = self._next_id;
                    self._next_id += 1;
                    migrated = true;
                }
            } else {
                assigned_id = self._next_id;
                self._next_id += 1;
                migrated = true;
            }

            try self._messages.append(arena, .{
                .id = assigned_id,
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

        // Legacy session without ids: write back once so ids become stable.
        // Best-effort — a read-only file must not prevent loading (ids stay
        // assigned in memory for this load; the next flush retries persistence).
        if (migrated) {
            self.modified = true;
            self.flush() catch |err| {
                var dbuf: [256]u8 = undefined;
                var dw: Io.File.Writer = .init(.stderr(), io, &dbuf);
                _ = dw.interface.writeAll("z-agent-core: warning: failed to persist migrated message ids: ") catch {};
                _ = dw.interface.writeAll(@errorName(err)) catch {};
                _ = dw.interface.flush() catch {};
            };
        }

        return self;
    }

    /// Append a message with deep copy into session arena. Auto-fills timestamp,
    /// model and a fresh monotonic id.
    pub fn append(self: *Session, msg: types.Message) !void {
        const arena = self._arena.allocator();
        var duped = msg;

        duped.id = self._next_id;
        self._next_id += 1;

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
    /// Prepend assigns a fresh id (system message may carry a high id — truncate/branch
    /// locate boundaries by id then operate on position, so system is always kept).
    pub fn updateFirstSystem(self: *Session, content: []const u8) !void {
        const arena = self._arena.allocator();
        const duped = try arena.dupe(u8, content);
        if (self._messages.items.len > 0 and self._messages.items[0].role == .system) {
            self._messages.items[0].content = duped;
        } else {
            const new_id = self._next_id;
            self._next_id += 1;
            try self._messages.insert(arena, 0, .{ .id = new_id, .role = .system, .content = duped });
        }
        self.modified = true;
    }

    /// Find the array index of a message by id. Null when not found.
    pub fn indexOfId(self: *const Session, id: u64) ?usize {
        for (self._messages.items, 0..) |msg, i| {
            if (msg.id == id) return i;
        }
        return null;
    }

    /// Allocate a fresh monotonic message id (e.g. for a compaction summary).
    pub fn allocateMessageId(self: *Session) u64 {
        const id = self._next_id;
        self._next_id += 1;
        return id;
    }

    /// Insert a message at an array position preserving its id (undo of delete /
    /// truncate). Strings deep-copied into the session arena. Caller flushes.
    pub fn insertMessageAt(self: *Session, index: usize, msg: types.Message) !void {
        const arena = self._arena.allocator();
        var duped = msg;
        duped.content = try arena.dupe(u8, msg.content);
        if (msg.reasoning_content) |rc| duped.reasoning_content = try arena.dupe(u8, rc);
        if (msg.model) |m| duped.model = try arena.dupe(u8, m);
        if (msg.tool_call_id) |tci| duped.tool_call_id = try arena.dupe(u8, tci);
        if (msg.tool_calls) |tcs| {
            const duped_tcs = try arena.alloc(types.ToolCall, tcs.len);
            for (tcs, duped_tcs) |s, *dst| {
                dst.* = .{
                    .id = try arena.dupe(u8, s.id),
                    .name = try arena.dupe(u8, s.name),
                    .arguments = try arena.dupe(u8, s.arguments),
                };
            }
            duped.tool_calls = duped_tcs;
        }
        try self._messages.insert(arena, @min(index, self._messages.items.len), duped);
        self.modified = true;
    }

    /// Replace all messages with a new list (compaction). Preserves each message's
    /// id (frontend caches ids across reloads); strings are deep-copied into the
    /// session arena. Caller must flush to persist.
    pub fn replaceMessages(self: *Session, new_list: []const types.Message) !void {
        const arena = self._arena.allocator();
        var next: std.ArrayListAligned(types.Message, null) = .empty;
        errdefer next.deinit(arena);
        for (new_list) |src| {
            var duped = src;
            duped.content = try arena.dupe(u8, src.content);
            if (src.reasoning_content) |rc| duped.reasoning_content = try arena.dupe(u8, rc);
            if (src.model) |m| duped.model = try arena.dupe(u8, m);
            if (src.tool_call_id) |tci| duped.tool_call_id = try arena.dupe(u8, tci);
            if (src.tool_calls) |tcs| {
                const duped_tcs = try arena.alloc(types.ToolCall, tcs.len);
                for (tcs, duped_tcs) |s, *dst| {
                    dst.* = .{
                        .id = try arena.dupe(u8, s.id),
                        .name = try arena.dupe(u8, s.name),
                        .arguments = try arena.dupe(u8, s.arguments),
                    };
                }
                duped.tool_calls = duped_tcs;
            }
            try next.append(arena, duped);
        }
        self._messages = next;
        self.modified = true;
    }

    /// Write all messages to JSONL file. Creates .zagent/sessions/ if needed.
    /// Public entry — acquires the process-level session_write_mutex, then calls
    /// the lock-free flushLocked. Do NOT call from inside a held lock.
    pub fn flush(self: *Session) !void {
        session_write_mutex.lock(self.io) catch return error.MutexLockFailed;
        defer session_write_mutex.unlock(self.io);
        try self.flushLocked();
    }

    /// Lock-free internal flush (no mutex). Callers must hold session_write_mutex.
    fn flushLocked(self: *Session) !void {
        const arena = self._arena.allocator();
        const cwd = Io.Dir.cwd();

        if (self.path == null) {
            const file_name = sanitizeFileName(arena, self.name) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
            };
            const final_name = if (std.mem.eql(u8, file_name, DEFAULT_SESSION_FILENAME)) blk: {
                const ts = Io.Clock.Timestamp.now(self.io, .real);
                const now_ms = Io.Timestamp.toMilliseconds(ts.raw);
                break :blk try std.fmt.allocPrint(arena, "{d}", .{now_ms});
            } else file_name;
            const filename = try std.fmt.allocPrint(arena, "{s}.jsonl", .{final_name});
            cwd.createDirPath(self.io, sessions_subdir) catch {};
            self.path = try std.fs.path.join(arena, &.{ sessions_subdir, filename });
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

            try writeHeader(arena, self.io, file, self.name, self.model, self.parent_id, self._messages.items.len);
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
            const msg = std.fmt.bufPrint(&msg_buf, "session: {d} messages, context may overflow\n", .{self._messages.items.len}) catch {
                var dbuf: [256]u8 = undefined;
                var dw: Io.File.Writer = .init(.stderr(), self.io, &dbuf);
                _ = dw.interface.writeAll("session: context overflow warning\n") catch {};
                _ = dw.interface.flush() catch {};
                return;
            };
            var dbuf: [256]u8 = undefined;
            var dw: Io.File.Writer = .init(.stderr(), self.io, &dbuf);
            _ = dw.interface.writeAll(msg) catch {};
            _ = dw.interface.flush() catch {};
        }
    }

    /// Write current session messages to a JSONL file. Does not change internal path.
    /// Uses temp-then-rename for atomicity.
    pub fn writeTo(self: *Session, file_path: []const u8, io: Io) !void {
        try writeMessagesTo(self, file_path, io, self._messages.items.len, self.name, self.model, self.parent_id);
    }

    /// Write the first `count` messages to a JSONL file under `name` and `parent_id`
    /// (branch-at-message fork). Uses temp-then-rename for atomicity.
    pub fn writePrefixTo(self: *Session, file_path: []const u8, io: Io, count: usize, name: []const u8, parent_id: ?[]const u8) !void {
        try writeMessagesTo(self, file_path, io, @min(count, self._messages.items.len), name, self.model, parent_id);
    }

    fn writeMessagesTo(self: *Session, file_path: []const u8, io: Io, count: usize, name: []const u8, model: []const u8, parent_id: ?[]const u8) !void {
        const arena = self._arena.allocator();
        const cwd = Io.Dir.cwd();

        const tmp_path = try std.fmt.allocPrint(arena, "{s}.tmp", .{file_path});
        defer cwd.deleteFile(io, tmp_path) catch {};

        {
            const file = try cwd.createFile(io, tmp_path, .{});
            defer file.close(io);

            try writeHeader(arena, io, file, name, model, parent_id, count);
            for (self._messages.items[0..count]) |msg| {
                var buf = std.array_list.Managed(u8).init(arena);
                defer buf.deinit();
                try serializeMessage(&buf, msg);
                try file.writeStreamingAll(io, buf.items);
            }
        }

        try Io.Dir.rename(cwd, tmp_path, cwd, file_path, io);
    }

    /// Rename session. The display name lives in the JSONL header; the file name
    /// (session id) is stable and never changes — renaming must not break id
    /// references (LRN-20260806-002). Caller flushes to persist the new header.
    pub fn rename(self: *Session, new_name: []const u8) !void {
        const arena = self._arena.allocator();
        self.name = try arena.dupe(u8, new_name);
        self.modified = true;
    }

    /// Remove a message at the given index. Uses temp-then-rename for atomicity.
    /// Index 0 is typically the system message; callers should ensure they don't remove it
    /// unless they know what they're doing.
    /// Public entry — acquires session_write_mutex, then delegates to removeMessageLocked.
    pub fn removeMessage(self: *Session, index: usize) !void {
        session_write_mutex.lock(self.io) catch return error.MutexLockFailed;
        defer session_write_mutex.unlock(self.io);
        try self.removeMessageLocked(index);
    }

    /// Lock-free internal remove (no mutex). Callers must hold session_write_mutex.
    fn removeMessageLocked(self: *Session, index: usize) !void {
        const arena = self._arena.allocator();
        const cwd = Io.Dir.cwd();

        if (index >= self._messages.items.len) return error.IndexOutOfBounds;
        if (self.path == null) return error.NoPath;

        _ = self._messages.orderedRemove(index);

        const tmp_path = try std.fmt.allocPrint(arena, "{s}.tmp", .{self.path.?});
        defer {
            if (!std.mem.eql(u8, self.path.?, tmp_path)) {
                cwd.deleteFile(self.io, tmp_path) catch {};
            }
        }

        {
            const file = try cwd.createFile(self.io, tmp_path, .{});
            defer file.close(self.io);

            try writeHeader(arena, self.io, file, self.name, self.model, self.parent_id, self._messages.items.len);
            for (self._messages.items) |msg| {
                var buf = std.array_list.Managed(u8).init(arena);
                defer buf.deinit();
                try serializeMessage(&buf, msg);
                try file.writeStreamingAll(self.io, buf.items);
            }
        }

        try Io.Dir.rename(cwd, tmp_path, cwd, self.path.?, self.io);
        self.modified = false;
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

/// Atomically rename a session's display title: single-layer lock covering the
/// full read-modify-write transaction — lock → load the LATEST file (so we never
/// clobber messages another thread appended) → in-memory rename → lock-free
/// flush write-back. Do NOT call flush() (public, re-locks → deadlock).
/// `path` is the full session file path (session.path).
pub fn renameTitle(allocator: std.mem.Allocator, io: Io, path: ?[]const u8, new_name: []const u8) !void {
    const p = path orelse return error.NoPath;
    session_write_mutex.lock(io) catch return error.MutexLockFailed;
    defer session_write_mutex.unlock(io);

    var sess = try Session.load(allocator, io, p);
    defer sess.deinit();
    try sess.rename(new_name);
    try sess.flushLocked();
}

fn sanitizeFileName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {    var buf: std.ArrayListAligned(u8, null) = .empty;
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
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ @as(u32, @intCast(year)), m, d, @as(u32, @intCast(h)), @as(u32, @intCast(min)), @as(u32, @intCast(sec)) });
}

fn writeHeader(allocator: std.mem.Allocator, io: Io, file: Io.File, name: []const u8, model: []const u8, parent_id: ?[]const u8, msg_count: usize) !void {
    const clock_ts = Io.Clock.Timestamp.now(io, .real);
    const now = Io.Timestamp.toSeconds(clock_ts.raw);
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try buf.appendSlice("{\"type\":\"header\",\"timestamp\":\"");
    const ts_iso = try epochToISO8601(allocator, now);
    defer allocator.free(ts_iso);
    try buf.appendSlice(ts_iso);
    try buf.appendSlice("\",\"model\":\"");
    try appendEscapedJsonString(&buf, model);
    try buf.appendSlice("\",\"name\":\"");
    try appendEscapedJsonString(&buf, name);
    if (parent_id) |pid| {
        try buf.appendSlice("\",\"parent_id\":\"");
        try appendEscapedJsonString(&buf, pid);
    }
    var cnt_buf: [24]u8 = undefined;
    const cnt_str = try std.fmt.bufPrint(&cnt_buf, "\",\"msg_count\":{d}", .{msg_count});
    try buf.appendSlice(cnt_str);
    try buf.appendSlice("}\n");

    try file.writeStreamingAll(io, buf.items);
}

fn serializeMessage(buf: *std.array_list.Managed(u8), msg: types.Message) !void {
    var id_buf: [24]u8 = undefined;
    const id_str = try std.fmt.bufPrint(&id_buf, "{{\"id\":{d},\"role\":\"", .{msg.id});
    try buf.appendSlice(id_str);
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
    var dir = Io.Dir.cwd().openDir(io, session_dir, .{ .iterate = true }) catch |err| {
        if (err != error.FileNotFound and err != error.NotDir) {
            var dbuf: [256]u8 = undefined;
            var dw: Io.File.Writer = .init(.stderr(), io, &dbuf);
            _ = dw.interface.writeAll("z-agent-core: warning: cannot open sessions directory\n") catch {};
            _ = dw.interface.flush() catch {};
        }
        return &.{};
    };
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
            parent_id: ?[]const u8 = null,
            msg_count: ?usize = null,
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
                    if (parsed.value.object.get("parent_id")) |pv| {
                        if (pv == .string and pv.string.len > 0) header.parent_id = try allocator.dupe(u8, pv.string);
                    }
                    if (parsed.value.object.get("msg_count")) |cv| {
                        if (cv == .integer) header.msg_count = @intCast(cv.integer);
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

        // Exact count from the header when present; otherwise count message lines
        // (fallback for legacy files written before msg_count was stored); the
        // size-based estimate is the last resort.
        const msg_count: usize = header.msg_count orelse blk: {
            var cnt: usize = 0;
            var it = std.mem.splitScalar(u8, content[0..n], '\n');
            while (it.next()) |ln| {
                if (std.mem.indexOf(u8, ln, "\"role\"") != null) cnt += 1;
            }
            break :blk if (cnt > 0) cnt else @max(size / 150, 0);
        };

        try results.append(allocator, .{
            .id = try allocator.dupe(u8, stem),
            .name = header.name,
            .file_path = try allocator.dupe(u8, file_path),
            .timestamp = header.timestamp,
            .model = header.model,
            .msg_count = msg_count,
            .parent_id = header.parent_id,
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

/// Paged session list: the most recent `limit` sessions with timestamp strictly
/// before `after_ts` (when provided). Delegates to list() for the full snapshot
/// then filters — session counts are small, so simplicity wins over an early-exit
/// traversal. Sorted timestamp desc (same as list()). Deep-copies the kept
/// SessionInfo (id/file_path/name dup'd) so the intermediate list() snapshot can
/// be freed. Caller owns the returned slice (freeSessionInfoList).
pub fn listPage(allocator: std.mem.Allocator, io: Io, session_dir: []const u8, limit: usize, after_ts: ?i64) ![]SessionInfo {
    const all = try list(allocator, io, session_dir);
    defer freeSessionInfoList(allocator, all);
    if (all.len == 0) return &.{};

    var kept: std.ArrayListAligned(SessionInfo, null) = .empty;
    defer kept.deinit(allocator);
    for (all) |s| {
        if (after_ts) |at| {
            if (s.timestamp >= at) continue;
        }
        if (kept.items.len >= limit) break; // newest-first, stop at limit
        try kept.append(allocator, .{
            .id = try allocator.dupe(u8, s.id),
            .name = try allocator.dupe(u8, s.name),
            .file_path = try allocator.dupe(u8, s.file_path),
            .timestamp = s.timestamp,
            .model = try allocator.dupe(u8, s.model),
            .msg_count = s.msg_count,
            .parent_id = if (s.parent_id) |pid| try allocator.dupe(u8, pid) else null,
        });
    }
    return kept.toOwnedSlice(allocator);
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
    try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(allocator, &.{ test_root, sessions_subdir }));

    var orig_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const orig_len = Io.Dir.cwd().realPath(io, &orig_cwd_buf) catch unreachable;

    try std.process.setCurrentPath(io, test_root);

    var sess = try Session.init(allocator, io, "deepseek/model");
    defer sess.deinit();
    try sess.append(.{ .role = .user, .content = "hello", .timestamp = 1752062401 });

    try sess.flush();
    try std.testing.expect(!sess.modified);

    const real_dir = try Io.Dir.cwd().openDir(io, sessions_subdir, .{ .iterate = true });
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
    const sessions_dir = try std.fs.path.join(allocator, &.{ test_root, sessions_subdir });
    defer allocator.free(sessions_dir);
    try Io.Dir.cwd().createDirPath(io, sessions_dir);

    const content =
        \\{"type":"header","timestamp":"2026-07-09T12:00:00Z","model":"deepseek/model","name":"Test Session"}
        \\{"role":"user","content":"hello","timestamp":1752062401}
        \\{"role":"assistant","content":"Hi!","model":"deepseek/model","timestamp":1752062402}
        \\
    ;

    const file_path = try std.fs.path.join(allocator, &.{ test_root, sessions_subdir, "test.jsonl" });
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
    try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(allocator, &.{ test_root, sessions_subdir }));

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

test "session: rename keeps file name (stable id)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-session-rename";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {};
    try Io.Dir.cwd().createDirPath(io, test_root);
    const sessions_dir = try std.fs.path.join(allocator, &.{ test_root, sessions_subdir });
    defer allocator.free(sessions_dir);
    try Io.Dir.cwd().createDirPath(io, sessions_dir);

    const file_path = try std.fs.path.join(allocator, &.{ test_root, sessions_subdir, "test.jsonl" });
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
    // id (file name) is stable — renaming must not move the file
    try std.testing.expect(std.mem.eql(u8, file_path, sess.path orelse ""));
    try sess.flush();

    // reload from the same path shows the renamed header
    var reloaded = try Session.load(allocator, io, file_path);
    defer reloaded.deinit();
    try std.testing.expectEqualStrings("My Session", reloaded.name);
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
    const sessions_dir = try std.fs.path.join(allocator, &.{ test_root, sessions_subdir });
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

test "session: listPage limit and after filter" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-session-listpage";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {};
    try Io.Dir.cwd().createDirPath(io, test_root);
    const sessions_dir = try std.fs.path.join(allocator, &.{ test_root, sessions_subdir });
    defer allocator.free(sessions_dir);
    try Io.Dir.cwd().createDirPath(io, sessions_dir);

    // Three sessions: newest (13:00) → mid (12:30) → oldest (12:00).
    const specs = [_]struct { file: []const u8, ts: []const u8, name: []const u8 }{
        .{ .file = "old.jsonl", .ts = "2026-07-09T12:00:00Z", .name = "Old" },
        .{ .file = "mid.jsonl", .ts = "2026-07-09T12:30:00Z", .name = "Mid" },
        .{ .file = "new.jsonl", .ts = "2026-07-09T13:00:00Z", .name = "New" },
    };
    for (specs) |sp| {
        const file_path = try std.fs.path.join(allocator, &.{ sessions_dir, sp.file });
        defer allocator.free(file_path);
        const file = try Io.Dir.cwd().createFile(io, file_path, .{});
        defer file.close(io);
        const content = try std.fmt.allocPrint(allocator, "{{\"type\":\"header\",\"timestamp\":\"{s}\",\"model\":\"m\",\"name\":\"{s}\"}}\n", .{ sp.ts, sp.name });
        defer allocator.free(content);
        try file.writeStreamingAll(io, content);
    }

    // limit=2 → newest two (New, Mid), newest first.
    const p1 = try listPage(allocator, io, sessions_dir, 2, null);
    defer freeSessionInfoList(allocator, p1);
    try std.testing.expectEqual(@as(usize, 2), p1.len);
    try std.testing.expectEqualStrings("New", p1[0].name);
    try std.testing.expectEqualStrings("Mid", p1[1].name);

    // after = mid timestamp → only sessions strictly older than it (Old).
    const after_ts = parseISO8601Epoch("2026-07-09T12:30:00Z");
    const p2 = try listPage(allocator, io, sessions_dir, 10, after_ts);
    defer freeSessionInfoList(allocator, p2);
    try std.testing.expectEqual(@as(usize, 1), p2.len);
    try std.testing.expectEqualStrings("Old", p2[0].name);
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

test "session: append assigns monotonic ids" {
    const io = std.testing.io;
    var sess = try Session.init(std.testing.allocator, io, "test");
    defer sess.deinit();

    try sess.append(.{ .role = .user, .content = "u1" });
    try sess.append(.{ .role = .assistant, .content = "a1" });
    try sess.append(.{ .role = .tool, .content = "t1" });

    const msgs = sess.messages();
    try std.testing.expectEqual(@as(usize, 3), msgs.len);
    try std.testing.expectEqual(@as(u64, 1), msgs[0].id);
    try std.testing.expect(msgs[0].id < msgs[1].id);
    try std.testing.expect(msgs[1].id < msgs[2].id);
}

test "session: indexOfId finds position and misses" {
    const io = std.testing.io;
    var sess = try Session.init(std.testing.allocator, io, "test");
    defer sess.deinit();

    try sess.append(.{ .role = .system, .content = "sys" });
    try sess.append(.{ .role = .user, .content = "u1" });
    const id2 = sess.messages()[1].id;
    try std.testing.expectEqual(@as(?usize, 1), sess.indexOfId(id2));
    try std.testing.expectEqual(@as(?usize, null), sess.indexOfId(999));
}

test "session: updateFirstSystem prepend assigns id, replace keeps id" {
    const io = std.testing.io;
    var sess = try Session.init(std.testing.allocator, io, "test");
    defer sess.deinit();

    try sess.append(.{ .role = .user, .content = "u1" });
    try sess.updateFirstSystem("sys");
    const sys_id = sess.messages()[0].id;
    try std.testing.expect(sys_id > 0);
    try std.testing.expect(sys_id != sess.messages()[1].id);

    try sess.updateFirstSystem("sys2");
    try std.testing.expectEqual(sys_id, sess.messages()[0].id);
    try std.testing.expectEqualStrings("sys2", sess.messages()[0].content);
}

test "session: load legacy file assigns ids and persists migration" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-session-migrate";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {};
    try Io.Dir.cwd().createDirPath(io, test_root);

    const file_path = try std.fs.path.join(allocator, &.{ test_root, "legacy.jsonl" });
    defer allocator.free(file_path);
    {
        const content =
            \\{"type":"header","timestamp":"2026-07-09T12:00:00Z","model":"deepseek/model","name":"Test"}
            \\{"role":"system","content":"sys","timestamp":1}
            \\{"role":"user","content":"u1","timestamp":2}
            \\{"role":"assistant","content":"a1","timestamp":3}
        ;
        const file = try Io.Dir.cwd().createFile(io, file_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, content);
    }

    var loaded = try Session.load(allocator, io, file_path);
    defer loaded.deinit();
    const msgs = loaded.messages();
    try std.testing.expectEqual(@as(usize, 3), msgs.len);
    const ids0 = msgs[0].id;
    const ids1 = msgs[1].id;
    const ids2 = msgs[2].id;
    try std.testing.expect(ids0 < ids1);
    try std.testing.expect(ids1 < ids2);

    // Migration flushed ids to disk — reload must produce identical ids.
    var reloaded = try Session.load(allocator, io, file_path);
    defer reloaded.deinit();
    const rmsgs = reloaded.messages();
    try std.testing.expectEqual(ids0, rmsgs[0].id);
    try std.testing.expectEqual(ids1, rmsgs[1].id);
    try std.testing.expectEqual(ids2, rmsgs[2].id);
}

test "session: load persisted ids preserved and bump next" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var sess = try Session.init(allocator, io, "test");
    defer sess.deinit();
    try sess.append(.{ .role = .system, .content = "sys" });
    try sess.append(.{ .role = .user, .content = "u1" });
    const saved_ids = [_]u64{ sess.messages()[0].id, sess.messages()[1].id };

    const test_root = ".zig-test-session-idroundtrip";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {};
    try Io.Dir.cwd().createDirPath(io, test_root);
    const file_path = try std.fs.path.join(allocator, &.{ test_root, "s.jsonl" });
    defer allocator.free(file_path);
    sess.path = file_path;
    try sess.flush();

    var loaded = try Session.load(allocator, io, file_path);
    defer loaded.deinit();
    try std.testing.expectEqual(saved_ids[0], loaded.messages()[0].id);
    try std.testing.expectEqual(saved_ids[1], loaded.messages()[1].id);
    try loaded.append(.{ .role = .assistant, .content = "a1" });
    const new_id = loaded.messages()[2].id;
    try std.testing.expect(new_id > saved_ids[1]);
    try std.testing.expectEqual(loaded.messages()[2].id, new_id);
}
