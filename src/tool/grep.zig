const std = @import("std");
const builtin = @import("builtin");
const types = @import("../types.zig");
const path_util = @import("../util/path.zig");

pub const tool_name = "grep";
pub const tool_description = "Search for a pattern in file contents. Supports file and directory search with optional file filter.";
pub const tool_params =
    \\{"type":"object","properties":{"pattern":{"type":"string","description":"Substring or pattern to search for"},"path":{"type":"string","description":"File or directory path to search"},"include":{"type":"string","description":"Glob pattern to filter files (e.g. *.zig)"}},"required":["pattern","path"]}
;

const MAX_OUTPUT: usize = 50 * 1024;
const MAX_MATCHES: usize = 500;

/// Search file contents for a pattern. Returns allocator-owned match lines.
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

    const path_val = args.value.object.get("path") orelse {
        return try std.fmt.allocPrint(ctx.allocator, "Error: missing 'path' argument", .{});
    };
    if (path_val != .string) {
        return try std.fmt.allocPrint(ctx.allocator, "Error: 'path' must be a string", .{});
    }

    const include = if (args.value.object.get("include")) |inc|
        if (inc == .string) inc.string else null
    else
        null;

    const resolved = path_util.resolvePath(ctx.allocator, ctx.project_root, path_val.string) catch |err| switch (err) {
        error.PathEscape => return try std.fmt.allocPrint(ctx.allocator, "Error: path escapes project root", .{}),
        else => return err,
    };
    defer ctx.allocator.free(resolved);

    if (Io.Dir.cwd().openDir(ctx.io, resolved, .{ .iterate = true })) |dir| {
        defer dir.close(ctx.io);
        const result = try searchDir(ctx, dir, pattern_val.string, path_val.string, include);
        const count = countMatches(result);
        try writeDisplay(ctx, pattern_val.string, path_val.string, count);
        return result;
    } else |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied => {},
        else => return err,
    }

    const result = try searchFile(ctx, resolved, pattern_val.string, path_val.string);
    const count = countMatches(result);
    try writeDisplay(ctx, pattern_val.string, path_val.string, count);
    return result;
}

fn countMatches(result: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, result, '\n');
    while (lines.next()) |line| {
        if (line.len > 0 and line[0] >= '0' and line[0] <= '9') count += 1;
    }
    return count;
}

fn searchFile(ctx: types.ToolContext, abs_path: []const u8, pattern: []const u8, display_path: []const u8) ![]const u8 {
    const file = Io.Dir.cwd().openFile(ctx.io, abs_path, .{ .mode = .read_only }) catch |err| {
        return try std.fmt.allocPrint(ctx.allocator, "Error: cannot open '{s}': {s}", .{ display_path, @errorName(err) });
    };
    defer file.close(ctx.io);

    const size: usize = @intCast((try file.stat(ctx.io)).size);
    if (size > 1024 * 1024) {
        return try std.fmt.allocPrint(ctx.allocator, "Error: file too large for grep: {s} ({d} bytes)", .{ display_path, size });
    }

    const content = try ctx.allocator.alloc(u8, size);
    defer ctx.allocator.free(content);
    const n = try file.readPositionalAll(ctx.io, content, 0);

    var buf = std.ArrayListAligned(u8, null).empty;

    var matches: usize = 0;
    var lines = std.mem.splitScalar(u8, content[0..n], '\n');
    var line_num: usize = 1;
    while (lines.next()) |raw_line| : (line_num += 1) {
        const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r') raw_line[0 .. raw_line.len - 1] else raw_line;
        if (std.mem.indexOf(u8, line, pattern)) |_| {
            matches += 1;
            if (matches > MAX_MATCHES) {
                try buf.appendSlice(ctx.allocator, "... (max matches reached)\n");
                break;
            }
            if (buf.items.len >= MAX_OUTPUT) {
                try buf.appendSlice(ctx.allocator, "[truncated]\n");
                break;
            }
            var num_buf: [16]u8 = undefined;
            const num_str = try std.fmt.bufPrint(&num_buf, "{d}", .{line_num});
            try buf.appendSlice(ctx.allocator, num_str);
            try buf.appendSlice(ctx.allocator, ": ");
            try buf.appendSlice(ctx.allocator, line);
            try buf.appendSlice(ctx.allocator, "\n");
        }
    }

    if (matches == 0) {
        return try std.fmt.allocPrint(ctx.allocator, "No matches found for '{s}' in {s}", .{ pattern, display_path });
    }

    return buf.toOwnedSlice(ctx.allocator);
}

fn searchDir(ctx: types.ToolContext, dir: Io.Dir, pattern: []const u8, display_path: []const u8, include: ?[]const u8) ![]const u8 {
    var buf = std.ArrayListAligned(u8, null).empty;
    var matches: usize = 0;
    var truncated = false;

    var iter = dir.iterate();
    while (try iter.next(ctx.io)) |entry| {
        if (entry.kind != .file) continue;

        if (include) |inc| {
            if (!globMatch(entry.name, inc)) continue;
        }

        if (buf.items.len >= MAX_OUTPUT) {
            truncated = true;
            break;
        }

        const file = dir.openFile(ctx.io, entry.name, .{ .mode = .read_only }) catch continue;
        defer file.close(ctx.io);

        const size: usize = @intCast((file.stat(ctx.io) catch continue).size);
        if (size > 512 * 1024) continue;

        const content = ctx.allocator.alloc(u8, size) catch continue;
        defer ctx.allocator.free(content);
        const n = file.readPositionalAll(ctx.io, content, 0) catch continue;

        var file_has_match = false;
        var lines = std.mem.splitScalar(u8, content[0..n], '\n');
        var line_num: usize = 1;
        while (lines.next()) |raw_line| : (line_num += 1) {
            const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r') raw_line[0 .. raw_line.len - 1] else raw_line;
            if (std.mem.indexOf(u8, line, pattern)) |_| {
                matches += 1;
                if (matches > MAX_MATCHES) {
                    try buf.appendSlice(ctx.allocator, "... (max matches reached)\n");
                    return buf.toOwnedSlice(ctx.allocator);
                }
                if (buf.items.len >= MAX_OUTPUT) {
                    truncated = true;
                    break;
                }
                if (!file_has_match) {
                    try buf.appendSlice(ctx.allocator, display_path);
                    if (!std.mem.endsWith(u8, display_path, "/") and !std.mem.endsWith(u8, display_path, "\\")) {
                        try buf.append(ctx.allocator, if (builtin.os.tag == .windows) '\\' else '/');
                    }
                    try buf.appendSlice(ctx.allocator, entry.name);
                    try buf.appendSlice(ctx.allocator, "\n");
                    file_has_match = true;
                }
                var num_buf: [16]u8 = undefined;
                const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{line_num}) catch continue;
                try buf.appendSlice(ctx.allocator, "  ");
                try buf.appendSlice(ctx.allocator, num_str);
                try buf.appendSlice(ctx.allocator, ": ");
                try buf.appendSlice(ctx.allocator, line);
                try buf.appendSlice(ctx.allocator, "\n");
            }
        }
    }

    if (matches == 0) {
        return try std.fmt.allocPrint(ctx.allocator, "No matches found for '{s}' in {s}", .{ pattern, display_path });
    }
    if (truncated) {
        try buf.appendSlice(ctx.allocator, "[truncated: output limit reached]\n");
    }

    return buf.toOwnedSlice(ctx.allocator);
}

fn globMatch(name: []const u8, pattern: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;
    if (std.mem.eql(u8, name, pattern)) return true;
    if (pattern.len > 1 and pattern[0] == '*' and pattern[1] == '.') {
        const ext = pattern[1..];
        return std.mem.endsWith(u8, name, ext);
    }
    return false;
}

fn writeDisplay(ctx: types.ToolContext, pattern: []const u8, path: []const u8, count: usize) !void {
    const msg = try std.fmt.allocPrint(ctx.allocator, "grep \"{s}\" in {s} -> {d} matches", .{ pattern, path, count });
    defer ctx.allocator.free(msg);
    ctx.display_writer.print("{s}\n", .{msg}) catch {}; // display failures are non-fatal
    ctx.display_writer.flush() catch {}; // display failures are non-fatal
}

const Io = std.Io;

test "grep: finds matches in file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-grep-file";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {}; // best-effort cleanup
    try Io.Dir.cwd().createDirPath(io, test_root);
    const test_path = try std.fs.path.join(allocator, &.{ test_root });
    defer allocator.free(test_path);

    const fp = try std.fs.path.join(allocator, &.{ test_root, "search.txt" });
    defer allocator.free(fp);
    const f = try Io.Dir.cwd().createFile(io, fp, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, "hello world\nfoo bar\nhello again\n");

    var dbuf: [256]u8 = undefined;
    var dw: Io.File.Writer = .init(.stderr(), io, &dbuf);
    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = test_path,
        .display_writer = &dw.interface,
    };

    const result = try execute(ctx, "{\"pattern\":\"hello\",\"path\":\"search.txt\"}");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "hello world") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "hello again") != null);
}

test "grep: no matches" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-grep-none";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {}; // best-effort cleanup
    try Io.Dir.cwd().createDirPath(io, test_root);
    const test_path = try std.fs.path.join(allocator, &.{ test_root });
    defer allocator.free(test_path);

    const fp = try std.fs.path.join(allocator, &.{ test_root, "search.txt" });
    defer allocator.free(fp);
    const f = try Io.Dir.cwd().createFile(io, fp, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, "hello world\n");

    var dbuf: [256]u8 = undefined;
    var dw: Io.File.Writer = .init(.stderr(), io, &dbuf);
    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = test_path,
        .display_writer = &dw.interface,
    };

    const result = try execute(ctx, "{\"pattern\":\"xyzzy\",\"path\":\"search.txt\"}");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "No matches") != null);
}
