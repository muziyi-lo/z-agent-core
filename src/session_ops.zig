const std = @import("std");
const types = @import("types.zig");
const session_mod = @import("core/session.zig");

const Io = std.Io;

pub fn sanitizeForkName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var buf: std.ArrayListAligned(u8, null) = .empty;
    errdefer buf.deinit(allocator);
    for (name) |c| {
        try buf.append(allocator, if (c == ' ' or c == '\t') '_' else c);
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

pub fn rollbackTurn(session: *session_mod.Session, pre_count: usize) void {
    session.truncateTo(pre_count);
}
