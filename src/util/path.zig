const std = @import("std");
const builtin = @import("builtin");

/// Returns allocator-owned absolute path -- caller must free.
/// Rejects paths that escape project_root.
pub fn resolvePath(allocator: std.mem.Allocator, project_root: []const u8, user_path: []const u8) ![]const u8 {
    const normalized_root = normalize(allocator, project_root) catch |e| return e;

    if (user_path.len == 0 or std.mem.eql(u8, user_path, ".")) {
        return normalized_root;
    }

    const candidate = if (isAbsolutePlatform(user_path))
        allocator.dupe(u8, user_path)
    else
        std.fs.path.join(allocator, &.{ project_root, user_path });
    const candidate_val = candidate catch |e| {
        allocator.free(normalized_root);
        return e;
    };

    const result = normalize(allocator, candidate_val) catch |e| {
        allocator.free(normalized_root);
        allocator.free(candidate_val);
        return e;
    };

    std.debug.assert(normalized_root.len > 0);

    const sep = separator();
    if (!std.mem.startsWith(u8, result, normalized_root)) {
        allocator.free(normalized_root);
        allocator.free(candidate_val);
        allocator.free(result);
        return error.PathEscape;
    }
    if (result.len > normalized_root.len and result[normalized_root.len] != sep) {
        allocator.free(normalized_root);
        allocator.free(candidate_val);
        allocator.free(result);
        return error.PathEscape;
    }

    allocator.free(normalized_root);
    allocator.free(candidate_val);
    return result;
}

fn separator() u8 {
    return if (builtin.os.tag == .windows) '\\' else '/';
}

fn normalize(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const sep = separator();
    const is_abs = isAbsolutePlatform(path);

    var rest = path;
    var drive_prefix: []const u8 = "";
    var _drive_buf: [2]u8 = undefined;
    if (builtin.os.tag == .windows and path.len >= 2 and path[1] == ':') {
        _drive_buf = [_]u8{ std.ascii.toUpper(path[0]), ':' };
        drive_prefix = &_drive_buf;
        if (path.len > 2) {
            rest = path[2..];
        } else {
            rest = "";
        }
    }

    var segments = std.ArrayListAligned([]const u8, null).empty;
    defer segments.deinit(allocator);

    var it = std.mem.tokenizeAny(u8, rest, "/\\");
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (segments.items.len == 0) {
                if (is_abs) return error.PathEscape;
                try segments.append(allocator, "..");
            } else {
                const last = segments.items[segments.items.len - 1];
                if (std.mem.eql(u8, last, "..")) {
                    try segments.append(allocator, "..");
                } else {
                    _ = segments.pop();
                }
            }
            continue;
        }
        try segments.append(allocator, seg);
    }

    if (is_abs) {
        if (drive_prefix.len > 0) {
            if (segments.items.len == 0) return std.fmt.allocPrint(allocator, "{s}{c}", .{ drive_prefix, sep });
            var buf = std.ArrayListAligned(u8, null).empty;
            defer buf.deinit(allocator);
            try buf.appendSlice(allocator, drive_prefix);
            try buf.append(allocator, sep);
            for (segments.items, 0..) |s, i| {
                if (i > 0) try buf.append(allocator, sep);
                try buf.appendSlice(allocator, s);
            }
            return allocator.dupe(u8, buf.items);
        }
        if (segments.items.len == 0) {
            const sep_str = [_]u8{sep};
            return allocator.dupe(u8, &sep_str);
        }
        var buf = std.ArrayListAligned(u8, null).empty;
        defer buf.deinit(allocator);
        try buf.append(allocator, sep);
        for (segments.items, 0..) |s, i| {
            if (i > 0) try buf.append(allocator, sep);
            try buf.appendSlice(allocator, s);
        }
        return allocator.dupe(u8, buf.items);
    }

    if (segments.items.len == 0) return allocator.dupe(u8, ".");

    var buf = std.ArrayListAligned(u8, null).empty;
    defer buf.deinit(allocator);
    for (segments.items, 0..) |s, i| {
        if (i > 0) try buf.append(allocator, sep);
        try buf.appendSlice(allocator, s);
    }
    return allocator.dupe(u8, buf.items);
}

fn isAbsolutePlatform(path: []const u8) bool {
    if (builtin.os.tag == .windows) {
        if (path.len >= 3 and path[1] == ':' and (path[2] == '\\' or path[2] == '/')) return true;
        if (path.len >= 2 and path[0] == '\\' and path[1] == '\\') return true;
        return false;
    }
    return std.fs.path.isAbsolute(path);
}

fn root(comptime sub: []const u8) []const u8 {
    if (builtin.os.tag == .windows) {
        return "C:\\" ++ sub;
    }
    return "/" ++ sub;
}

test "resolvePath: relative within root" {
    const rt = root("project");
    const r = try resolvePath(std.testing.allocator, rt, "src/main.zig");
    defer std.testing.allocator.free(r);
    const expected: []const u8 = if (builtin.os.tag == .windows) "C:\\project\\src\\main.zig" else "/project/src/main.zig";
    try std.testing.expect(std.mem.eql(u8, r, expected));
}

test "resolvePath: dot returns root" {
    const rt = root("project");
    const r = try resolvePath(std.testing.allocator, rt, ".");
    defer std.testing.allocator.free(r);
    try std.testing.expect(std.mem.eql(u8, r, rt));
}

test "resolvePath: empty path returns root" {
    const rt = root("project");
    const r = try resolvePath(std.testing.allocator, rt, "");
    defer std.testing.allocator.free(r);
    try std.testing.expect(std.mem.eql(u8, r, rt));
}

test "resolvePath: double dot is normalized" {
    const rt = root("project");
    const r = try resolvePath(std.testing.allocator, rt, "src/../lib");
    defer std.testing.allocator.free(r);
    const expected: []const u8 = if (builtin.os.tag == .windows) "C:\\project\\lib" else "/project/lib";
    try std.testing.expect(std.mem.eql(u8, r, expected));
}

test "resolvePath: path escape rejected" {
    const rt = root("project");
    try std.testing.expectError(error.PathEscape, resolvePath(std.testing.allocator, rt, "../etc"));
}

test "resolvePath: absolute path escape rejected" {
    const rt = root("project");
    const escaped: []const u8 = if (builtin.os.tag == .windows) "C:\\etc\\passwd" else "/etc/passwd";
    try std.testing.expectError(error.PathEscape, resolvePath(std.testing.allocator, rt, escaped));
}

test "resolvePath: normalizes redundant separators" {
    const rt = root("project");
    const r = try resolvePath(std.testing.allocator, rt, "src//main.zig");
    defer std.testing.allocator.free(r);
    const expected: []const u8 = if (builtin.os.tag == .windows) "C:\\project\\src\\main.zig" else "/project/src/main.zig";
    try std.testing.expect(std.mem.eql(u8, r, expected));
}

test "resolvePath: normalizes dots" {
    const rt = root("project");
    const r = try resolvePath(std.testing.allocator, rt, "src/./main.zig");
    defer std.testing.allocator.free(r);
    const expected: []const u8 = if (builtin.os.tag == .windows) "C:\\project\\src\\main.zig" else "/project/src/main.zig";
    try std.testing.expect(std.mem.eql(u8, r, expected));
}

test "resolvePath: root equality passes" {
    const expected_src: []const u8 = if (builtin.os.tag == .windows) "C:\\project\\src" else "/project/src";
    const r = try resolvePath(std.testing.allocator, root("project"), expected_src);
    defer std.testing.allocator.free(r);
    try std.testing.expect(std.mem.eql(u8, r, expected_src));
}

test "resolvePath: mixed separators normalize" {
    const rt = root("project");
    const r = try resolvePath(std.testing.allocator, rt, "src/main\\zig/../main.zig");
    defer std.testing.allocator.free(r);
    const expected: []const u8 = if (builtin.os.tag == .windows) "C:\\project\\src\\main\\main.zig" else "/project/src/main/main.zig";
    try std.testing.expect(std.mem.eql(u8, r, expected));
}

test "resolvePath: Windows absolute within root" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const r = try resolvePath(std.testing.allocator, "C:\\project", "C:\\project\\src");
    defer std.testing.allocator.free(r);
    try std.testing.expect(std.mem.eql(u8, r, "C:\\project\\src"));
}

test "resolvePath: Windows absolute escape" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try std.testing.expectError(error.PathEscape, resolvePath(std.testing.allocator, "C:\\project", "D:\\other"));
}

test "resolvePath: Windows lowercase drive letter within root" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const r = try resolvePath(std.testing.allocator, "C:\\project", "c:\\project\\src");
    defer std.testing.allocator.free(r);
    try std.testing.expect(std.mem.eql(u8, r, "C:\\project\\src"));
}
