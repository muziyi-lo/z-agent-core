const std = @import("std");
const types = @import("../types.zig");
const path_util = @import("../util/path.zig");

pub const tool_name = "glob";
pub const tool_description = "Find files matching a glob pattern. Supports recursive search with **.";
pub const tool_params =
    \\{"type":"object","properties":{"pattern":{"type":"string","description":"Glob pattern (e.g. *.zig, src/**/*.zig)"},"path":{"type":"string","description":"Base directory (default \".\")"}},"required":["pattern"]}
;

const MAX_OUTPUT: usize = 50 * 1024;
const MAX_ENTRIES: usize = 1000;

/// Find files matching a glob pattern. Supports recursive **. Returns allocator-owned result.
pub fn execute(ctx: types.ToolContext, args_json: []const u8) anyerror![]const u8 {
    const args = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{ .ignore_unknown_fields = true }) catch {
        return try std.fmt.allocPrint(ctx.allocator, "Error: invalid arguments JSON: {s}", .{args_json});
    };
    defer args.deinit();

    const pattern_val = args.value.object.get("pattern") orelse {
        return try std.fmt.allocPrint(ctx.allocator, "Error: missing 'pattern' argument", .{});
    };
    if (pattern_val != .string or pattern_val.string.len == 0) {
        return try std.fmt.allocPrint(ctx.allocator, "Error: 'pattern' must be a non-empty string", .{});
    }

    const path_arg: []const u8 = if (args.value.object.get("path")) |p|
        if (p == .string) p.string else "."
    else
        ".";

    const resolved = path_util.resolvePath(ctx.allocator, ctx.project_root, path_arg) catch |err| switch (err) {
        error.PathEscape => return try std.fmt.allocPrint(ctx.allocator, "Error: path escapes project root", .{}),
        else => return err,
    };
    defer ctx.allocator.free(resolved);

    const dir = Io.Dir.cwd().openDir(ctx.io, resolved, .{ .iterate = true }) catch |err| {
        return try std.fmt.allocPrint(ctx.allocator, "Error: cannot open directory '{s}': {s}", .{ path_arg, @errorName(err) });
    };
    defer dir.close(ctx.io);

    var buf = std.ArrayListAligned(u8, null).empty;
    var count: usize = 0;
    var truncated = false;

    try walkDir(ctx, &buf, dir, pattern_val.string, path_arg, &count, &truncated);

    try writeDisplay(ctx, pattern_val.string, count);

    if (count == 0) {
        return try std.fmt.allocPrint(ctx.allocator, "No files matched '{s}' in {s}", .{ pattern_val.string, path_arg });
    }
    if (truncated) {
        try buf.appendSlice(ctx.allocator, "[truncated]\n");
    }

    return buf.toOwnedSlice(ctx.allocator);
}

fn walkDir(ctx: types.ToolContext, buf: *std.ArrayListAligned(u8, null), dir: Io.Dir, pattern: []const u8, prefix: []const u8, count: *usize, truncated: *bool) !void {
    var iter = dir.iterate();
    while (try iter.next(ctx.io)) |entry| {
        if (buf.items.len >= MAX_OUTPUT or count.* >= MAX_ENTRIES) {
            truncated.* = true;
            return;
        }

        const full_path = if (std.mem.eql(u8, prefix, ".") or std.mem.endsWith(u8, prefix, "/") or std.mem.endsWith(u8, prefix, "\\"))
            try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ prefix, entry.name })
        else
            try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ prefix, entry.name });
        defer ctx.allocator.free(full_path);

        if (globMatch(entry.name, pattern)) {
            count.* += 1;
            try buf.appendSlice(ctx.allocator, full_path);
            try buf.append(ctx.allocator, '\n');
        }

        if (entry.kind == .directory) {
            if (dir.openDir(ctx.io, entry.name, .{ .iterate = true })) |subdir| {
                defer subdir.close(ctx.io);
                try walkDir(ctx, buf, subdir, pattern, full_path, count, truncated);
            } else |err| switch (err) {
                error.FileNotFound, error.NotDir, error.AccessDenied => {},
                else => return err,
            }
        }
    }
}

fn globMatch(name: []const u8, pattern: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;
    if (std.mem.eql(u8, name, pattern)) return true;
    if (pattern.len > 1 and pattern[0] == '*' and pattern[1] == '.') {
        return std.mem.endsWith(u8, name, pattern[1..]);
    }
    var pi: usize = 0;
    var ni: usize = 0;
    var star_idx: ?usize = null;
    var match_idx: usize = 0;
    while (ni < name.len) {
        if (pi < pattern.len and (pattern[pi] == '?' or pattern[pi] == name[ni])) {
            pi += 1;
            ni += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            star_idx = pi;
            match_idx = ni;
            pi += 1;
        } else if (star_idx) |s| {
            pi = s + 1;
            match_idx += 1;
            ni = match_idx;
        } else {
            return false;
        }
    }
    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}

fn writeDisplay(ctx: types.ToolContext, pattern: []const u8, count: usize) !void {
    const msg = try std.fmt.allocPrint(ctx.allocator, "glob \"{s}\" -> {d} matches", .{ pattern, count });
    defer ctx.allocator.free(msg);
    ctx.display_writer.print("{s}\n", .{msg}) catch {}; // display failures are non-fatal
    ctx.display_writer.flush() catch {}; // display failures are non-fatal
}

const Io = std.Io;

test "glob: finds files by extension" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-glob-ext";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {}; // best-effort cleanup
    try Io.Dir.cwd().createDirPath(io, test_root);
    const test_path = try std.fs.path.join(allocator, &.{ test_root });
    defer allocator.free(test_path);

    {
        const p = try std.fs.path.join(allocator, &.{ test_root, "a.zig" });
        defer allocator.free(p);
        (try Io.Dir.cwd().createFile(io, p, .{})).close(io);
    }
    {
        const p = try std.fs.path.join(allocator, &.{ test_root, "b.txt" });
        defer allocator.free(p);
        (try Io.Dir.cwd().createFile(io, p, .{})).close(io);
    }

    var dbuf: [256]u8 = undefined;
    var dw: Io.File.Writer = .init(.stderr(), io, &dbuf);
    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = test_path,
        .display_writer = &dw.interface,
    };

    const result = try execute(ctx, "{\"pattern\":\"*.zig\",\"path\":\".\"}");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "a.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "b.txt") == null);
}

test "glob: no matches" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-glob-none";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {}; // best-effort cleanup
    try Io.Dir.cwd().createDirPath(io, test_root);
    const test_path = try std.fs.path.join(allocator, &.{ test_root });
    defer allocator.free(test_path);

    var dbuf: [256]u8 = undefined;
    var dw: Io.File.Writer = .init(.stderr(), io, &dbuf);
    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = test_path,
        .display_writer = &dw.interface,
    };

    const result = try execute(ctx, "{\"pattern\":\"*.xyz\",\"path\":\".\"}");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "No files") != null);
}
