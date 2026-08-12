const std = @import("std");
const types = @import("types.zig");
const session_mod = @import("core/session.zig");

const Io = std.Io;

/// Sanitize a display name into a URL- and filesystem-safe session id.
/// Keeps `[A-Za-z0-9._-()]`; everything else (space, tab, `#`, `%`, `&`, ...)
/// becomes `_`. The session id is used in URLs — `#` in `(fork #N)` would be
/// stripped as a fragment by browsers, so it must never survive into the id.
pub fn sanitizeForkName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var buf: std.ArrayListAligned(u8, null) = .empty;
    errdefer buf.deinit(allocator);
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or
            c == '.' or c == '_' or c == '-' or c == '(' or c == ')';
        try buf.append(allocator, if (ok) c else '_');
    }
    return buf.toOwnedSlice(allocator);
}

pub fn new(allocator: std.mem.Allocator, io: Io, model: []const u8) !session_mod.Session {
    return session_mod.Session.init(allocator, io, model);
}

pub fn loadById(allocator: std.mem.Allocator, io: Io, session_dir: []const u8, name: []const u8) !session_mod.Session {
    const path = try std.fs.path.join(allocator, &.{ session_dir, name });
    defer allocator.free(path);
    const load_path = try std.fmt.allocPrint(allocator, "{s}.jsonl", .{path});
    defer allocator.free(load_path);
    return session_mod.Session.load(allocator, io, load_path);
}

pub fn fork(allocator: std.mem.Allocator, io: Io, source: *session_mod.Session, session_dir: []const u8, fork_name_raw: []const u8) !session_mod.Session {
    const fork_name = std.mem.trim(u8, fork_name_raw, " \t");
    if (fork_name.len == 0) return error.InvalidForkName;
    if (std.mem.indexOfAny(u8, fork_name, "/\\") != null) return error.PathSeparatorInName;

    const safe_name = try sanitizeForkName(allocator, fork_name);
    defer allocator.free(safe_name);

    const target_path = try std.fmt.allocPrint(allocator, "{s}/{s}.jsonl", .{ session_dir, safe_name });
    defer allocator.free(target_path);

    const f_check = Io.Dir.cwd().openFile(io, target_path, .{ .mode = .read_only }) catch null;
    if (f_check) |f| {
        f.close(io);
        return error.SessionAlreadyExists;
    }

    try source.writeTo(target_path, io);
    return session_mod.Session.load(allocator, io, target_path);
}

/// Compute the next fork title for a branch: `{base} (fork #N)` where base is
/// the title with any trailing ` (fork #N)` stripped, and N = max existing fork
/// number across sessions whose title matches `^<base>( \(fork #\d+\))?$` + 1.
/// Scans the sessions dir; caller frees the returned slice.
pub fn forkTitle(allocator: std.mem.Allocator, io: Io, session_dir: []const u8, base_title: []const u8) ![]const u8 {
    var base = base_title;
    if (std.mem.lastIndexOf(u8, base_title, " (fork #")) |pos| {
        if (std.mem.endsWith(u8, base_title, ")")) base = base_title[0..pos];
    }

    var max_n: usize = 0;
    const infos = try session_mod.list(allocator, io, session_dir);
    defer session_mod.freeSessionInfoList(allocator, infos);
    for (infos) |info| {
        if (!std.mem.startsWith(u8, info.name, base)) continue;
        const suffix = info.name[base.len..];
        if (suffix.len == 0) continue; // plain base — no fork count
        if (std.mem.startsWith(u8, suffix, " (fork #") and std.mem.endsWith(u8, suffix, ")")) {
            const num_str = suffix[" (fork #".len .. suffix.len - 1];
            const n = std.fmt.parseUnsigned(usize, num_str, 10) catch continue;
            if (n > max_n) max_n = n;
        }
    }

    return std.fmt.allocPrint(allocator, "{s} (fork #{d})", .{ base, max_n + 1 });
}

/// Fork the session BEFORE a message: the new session contains messages strictly
/// before the message whose id == boundary_id (found by position, so the system
/// prompt at index 0 is always preserved). Auto-name via forkTitle and record the
/// source session as parent_id (branch-tree lineage). The boundary message is NOT
/// copied — the frontend re-sends it as a fresh prompt (方案 B auto-reanswer).
pub fn forkAt(allocator: std.mem.Allocator, io: Io, source: *session_mod.Session, session_dir: []const u8, boundary_id: u64, parent_id: ?[]const u8) !session_mod.Session {
    const boundary_idx = source.indexOfId(boundary_id) orelse return error.MessageNotFound;
    if (boundary_idx == 0) return error.MessageNotFound;

    const fork_name = try forkTitle(allocator, io, session_dir, source.name);
    defer allocator.free(fork_name);
    if (std.mem.indexOfAny(u8, fork_name, "/\\") != null) return error.PathSeparatorInName;

    const safe_name = try sanitizeForkName(allocator, fork_name);
    defer allocator.free(safe_name);

    const target_path = try std.fmt.allocPrint(allocator, "{s}/{s}.jsonl", .{ session_dir, safe_name });
    defer allocator.free(target_path);

    const f_check = Io.Dir.cwd().openFile(io, target_path, .{ .mode = .read_only }) catch null;
    if (f_check) |f| {
        f.close(io);
        return error.SessionAlreadyExists;
    }

    try source.writePrefixTo(target_path, io, boundary_idx, fork_name, parent_id);
    return session_mod.Session.load(allocator, io, target_path);
}

/// Delete a session file by id. Validates the id (rejects path traversal),
/// returns the deleted file path — callers compare it (after resolve) against
/// the active session before/after deletion. FileNotFound propagates so callers
/// can distinguish "session not found".
pub fn deleteById(allocator: std.mem.Allocator, io: Io, session_dir: []const u8, id: []const u8) ![]const u8 {
    if (!session_mod.Session.isValidId(id)) return error.InvalidSessionId;
    const path = try std.fs.path.join(allocator, &.{ session_dir, id });
    defer allocator.free(path);
    const file_path = try std.fmt.allocPrint(allocator, "{s}.jsonl", .{path});
    errdefer allocator.free(file_path);
    try session_mod.Session.deleteFile(io, file_path);
    return file_path;
}

pub fn rollbackTurn(session: *session_mod.Session, pre_count: usize) void {
    session.truncateTo(pre_count);
}

/// Clear the conversation, keeping the system prompt (if any) and the session
/// id/name. Distinct from `new` (fresh session with a new id).
pub fn reset(session: *session_mod.Session) void {
    const msgs = session.messages();
    const keep: usize = if (msgs.len > 0 and msgs[0].role == .system) 1 else 0;
    session.truncateTo(keep);
}

test "session_ops: reset keeps system prompt" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var sess = try new(allocator, io, "deepseek/deepseek-v4-flash");
    defer sess.deinit();
    try sess.updateFirstSystem("system-text");
    try sess.append(.{ .role = .user, .content = "hello" });
    try sess.append(.{ .role = .assistant, .content = "hi" });
    try std.testing.expectEqual(@as(usize, 3), sess.messages().len);
    reset(&sess);
    try std.testing.expectEqual(@as(usize, 1), sess.messages().len);
    try std.testing.expectEqualStrings("system-text", sess.messages()[0].content);
}

test "session_ops: reset empty session stays empty" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var sess = try new(allocator, io, "deepseek/deepseek-v4-flash");
    defer sess.deinit();
    reset(&sess);
    try std.testing.expectEqual(@as(usize, 0), sess.messages().len);
}

test "session_ops: deleteById deletes session file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const dir = ".zig-test-deletebyid";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    try Io.Dir.cwd().createDirPath(io, dir);

    const path = try std.fs.path.join(allocator, &.{ dir, "sess.jsonl" });
    defer allocator.free(path);
    const f = try Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, "x");

    const deleted = try deleteById(allocator, io, dir, "sess");
    defer allocator.free(deleted);
    try std.testing.expect(std.mem.endsWith(u8, deleted, "sess.jsonl"));
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }));
}

test "session_ops: deleteById rejects invalid ids" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const dir = ".zig-test-deletebyid-invalid";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    try Io.Dir.cwd().createDirPath(io, dir);

    for ([_][]const u8{ "", "..", ".", "a/b", "a\\b", "sess.jsonl" }) |id| {
        try std.testing.expectError(error.InvalidSessionId, deleteById(allocator, io, dir, id));
    }
}

test "session_ops: deleteById missing file propagates FileNotFound" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const dir = ".zig-test-deletebyid-missing";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    try Io.Dir.cwd().createDirPath(io, dir);

    const deleted = deleteById(allocator, io, dir, "ghost");
    try std.testing.expectError(error.FileNotFound, deleted);
}

test "session_ops: sanitizeForkName URL-safe" {
    const allocator = std.testing.allocator;
    const s = try sanitizeForkName(allocator, "E2E Test (fork #1)");
    defer allocator.free(s);
    try std.testing.expectEqualStrings("E2E_Test_(fork__1)", s);
    try std.testing.expect(std.mem.indexOfScalar(u8, s, '#') == null);
}

test "session_ops: forkTitle increments per base" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const dir = ".zig-test-forktitle";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    try Io.Dir.cwd().createDirPath(io, dir);

    const files = [_][]const u8{ "a.jsonl", "b.jsonl", "c.jsonl" };
    const names = [_][]const u8{ "x", "x (fork #1)", "y" };
    for (files, names) |f, n| {
        const path = try std.fs.path.join(allocator, &.{ dir, f });
        defer allocator.free(path);
        const content = try std.fmt.allocPrint(allocator, "{{\"type\":\"header\",\"timestamp\":\"2026-01-01T00:00:00Z\",\"model\":\"m\",\"name\":\"{s}\"}}\n", .{n});
        defer allocator.free(content);
        const file = try Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, content);
    }

    const t1 = try forkTitle(allocator, io, dir, "x");
    defer allocator.free(t1);
    try std.testing.expectEqualStrings("x (fork #2)", t1);

    const t2 = try forkTitle(allocator, io, dir, "y");
    defer allocator.free(t2);
    try std.testing.expectEqualStrings("y (fork #1)", t2);

    const t3 = try forkTitle(allocator, io, dir, "x (fork #1)");
    defer allocator.free(t3);
    try std.testing.expectEqualStrings("x (fork #2)", t3);
}

test "session_ops: forkAt copies before boundary message" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const dir = ".zig-test-forkat";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    try Io.Dir.cwd().createDirPath(io, dir);

    var src = try new(allocator, io, "model");
    defer src.deinit();
    try src.append(.{ .role = .system, .content = "sys" });
    try src.append(.{ .role = .user, .content = "u1" });
    try src.append(.{ .role = .assistant, .content = "a1" });
    const u1_id = src.messages()[1].id;
    const a1_id = src.messages()[2].id;

    // Fork before u1 → only the system message.
    var fork1 = try forkAt(allocator, io, &src, dir, u1_id, null);
    defer fork1.deinit();
    const m1 = fork1.messages();
    try std.testing.expectEqual(@as(usize, 1), m1.len);
    try std.testing.expectEqualStrings("sys", m1[0].content);

    // Fork before a1 → system + u1, boundary excluded.
    var fork2 = try forkAt(allocator, io, &src, dir, a1_id, "parent-id");
    defer fork2.deinit();
    const m2 = fork2.messages();
    try std.testing.expectEqual(@as(usize, 2), m2.len);
    try std.testing.expectEqualStrings("sys", m2[0].content);
    try std.testing.expectEqualStrings("u1", m2[1].content);
    try std.testing.expectEqualStrings("parent-id", fork2.parent_id.?);
}

test "session_ops: forkAt message not found errors" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const dir = ".zig-test-forkat-missing";
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    try Io.Dir.cwd().createDirPath(io, dir);

    var src = try new(allocator, io, "model");
    defer src.deinit();
    try src.append(.{ .role = .system, .content = "sys" });
    try std.testing.expectError(error.MessageNotFound, forkAt(allocator, io, &src, dir, 999, null));
    // System message (index 0) is not a valid branch point either.
    try std.testing.expectError(error.MessageNotFound, forkAt(allocator, io, &src, dir, src.messages()[0].id, null));
}
