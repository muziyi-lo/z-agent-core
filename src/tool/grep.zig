const std = @import("std");
const builtin = @import("builtin");
const types = @import("../types.zig");
const path_util = @import("../util/path.zig");

pub const tool_name = "grep";
pub const tool_description = "Search for a pattern in file contents. Supports file and directory search with optional file filter.";
pub const tool_params =
    \\{"type":"object","properties":{"pattern":{"type":"string","description":"Substring or pattern to search for"},"path":{"type":"string","description":"File or directory path (defaults to project root)"},"include":{"type":"string","description":"Glob pattern to filter files (e.g. *.zig)"}},"required":["pattern"]}
;

const MAX_OUTPUT: usize = 50 * 1024;
const MAX_MATCHES: usize = 500;

/// Search file contents for a pattern. Returns allocator-owned ToolResult.
pub fn execute(ctx: types.ToolContext, args: std.json.Value) anyerror!types.ToolResult {
    const pattern_val = args.object.get("pattern") orelse {
        const content = try std.fmt.allocPrint(ctx.allocator, "Error: missing 'pattern' argument", .{});
        return types.ToolResult{
            .session_content = content,
        };
    };
    if (pattern_val != .string or pattern_val.string.len == 0) {
        const content = try std.fmt.allocPrint(ctx.allocator, "Error: 'pattern' must be a non-empty string", .{});
        return types.ToolResult{
            .session_content = content,
        };
    }

    const path_val = if (args.object.get("path")) |pv| pv else std.json.Value{ .string = ctx.project_root };
    if (path_val != .string) {
        const content = try std.fmt.allocPrint(ctx.allocator, "Error: 'path' must be a string", .{});
        return types.ToolResult{
            .session_content = content,
        };
    }

    const include = if (args.object.get("include")) |inc|
        if (inc == .string) inc.string else null
    else
        null;

    const resolved = path_util.resolvePath(ctx.allocator, ctx.project_root, path_val.string) catch |err| switch (err) {
        error.PathEscape => {
            const content = try std.fmt.allocPrint(ctx.allocator, "Error: path escapes project root", .{});
            return types.ToolResult{
                .session_content = content,
            };
        },
        else => return err,
    };
    defer ctx.allocator.free(resolved);

    if (Io.Dir.cwd().openDir(ctx.io, resolved, .{ .iterate = true })) |dir| {
        defer dir.close(ctx.io);
        const gr = try searchDir(ctx, dir, pattern_val.string, include);
        return types.ToolResult{
            .session_content = gr.content,
            .meta = .{ .grep = .{
                .pattern = pattern_val.string,
                .path = path_val.string,
                .match_count = gr.match_count,
                .files_scanned = gr.files_scanned,
                .truncated = gr.truncated,
            }},
        };
    } else |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied => {},
        else => return err,
    }

    const gr = try searchFile(ctx, resolved, pattern_val.string);
    return types.ToolResult{
        .session_content = gr.content,
        .meta = .{ .grep = .{
            .pattern = pattern_val.string,
            .path = path_val.string,
            .match_count = gr.match_count,
            .files_scanned = gr.files_scanned,
            .truncated = gr.truncated,
        }},
    };
}

const GrepResult = struct {
    content: []const u8,
    match_count: usize,
    files_scanned: usize,
    truncated: bool,
};

fn countMatches(result: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, result, '\n');
    while (lines.next()) |line| {
        if (line.len > 0 and line[0] >= '0' and line[0] <= '9') count += 1;
    }
    return count;
}

fn searchFile(ctx: types.ToolContext, abs_path: []const u8, pattern: []const u8) !GrepResult {
    const file = Io.Dir.cwd().openFile(ctx.io, abs_path, .{ .mode = .read_only }) catch |err| {
        return .{
            .content = try std.fmt.allocPrint(ctx.allocator, "Error: cannot open '{s}': {s}", .{ abs_path, @errorName(err) }),
            .match_count = 0,
            .files_scanned = 1,
            .truncated = false,
        };
    };
    defer file.close(ctx.io);

    const size: usize = @intCast((try file.stat(ctx.io)).size);
    if (size > 1024 * 1024) {
        return .{
            .content = try std.fmt.allocPrint(ctx.allocator, "Error: file too large for grep: {s} ({d} bytes)", .{ abs_path, size }),
            .match_count = 0,
            .files_scanned = 1,
            .truncated = false,
        };
    }

    const file_content = try ctx.allocator.alloc(u8, size);
    defer ctx.allocator.free(file_content);
    const n = try file.readPositionalAll(ctx.io, file_content, 0);

    var buf = std.ArrayListAligned(u8, null).empty;

    var matches: usize = 0;
    var truncated = false;
    var lines = std.mem.splitScalar(u8, file_content[0..n], '\n');
    var line_num: usize = 1;
    while (lines.next()) |raw_line| : (line_num += 1) {
        const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r') raw_line[0 .. raw_line.len - 1] else raw_line;
        if (std.mem.indexOf(u8, line, pattern)) |_| {
            matches += 1;
            if (matches > MAX_MATCHES) {
                try buf.appendSlice(ctx.allocator, "... (max matches reached)\n");
                truncated = true;
                break;
            }
            if (buf.items.len >= MAX_OUTPUT) {
                try buf.appendSlice(ctx.allocator, "[truncated]\n");
                truncated = true;
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
        return .{
            .content = try std.fmt.allocPrint(ctx.allocator, "No matches found for '{s}' in file", .{pattern}),
            .match_count = 0,
            .files_scanned = 1,
            .truncated = false,
        };
    }

    return .{
        .content = try buf.toOwnedSlice(ctx.allocator),
        .match_count = matches,
        .files_scanned = 1,
        .truncated = truncated,
    };
}

fn searchDir(ctx: types.ToolContext, dir: Io.Dir, pattern: []const u8, include: ?[]const u8) !GrepResult {
    var buf = std.ArrayListAligned(u8, null).empty;
    var matches: usize = 0;
    var truncated = false;
    var files_scanned: usize = 0;

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

        files_scanned += 1;

        const file = dir.openFile(ctx.io, entry.name, .{ .mode = .read_only }) catch continue;
        defer file.close(ctx.io);

        const size: usize = @intCast((file.stat(ctx.io) catch continue).size);
        if (size > 512 * 1024) continue;

        const file_content = ctx.allocator.alloc(u8, size) catch continue;
        defer ctx.allocator.free(file_content);
        const n = file.readPositionalAll(ctx.io, file_content, 0) catch continue;

        var file_has_match = false;
        var lines = std.mem.splitScalar(u8, file_content[0..n], '\n');
        var line_num: usize = 1;
        while (lines.next()) |raw_line| : (line_num += 1) {
            const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r') raw_line[0 .. raw_line.len - 1] else raw_line;
            if (std.mem.indexOf(u8, line, pattern)) |_| {
                matches += 1;
                if (matches > MAX_MATCHES) {
                    try buf.appendSlice(ctx.allocator, "... (max matches reached)\n");
                    truncated = true;
                    return .{
                        .content = try buf.toOwnedSlice(ctx.allocator),
                        .match_count = matches,
                        .files_scanned = files_scanned,
                        .truncated = truncated,
                    };
                }
                if (buf.items.len >= MAX_OUTPUT) {
                    truncated = true;
                    break;
                }
                if (!file_has_match) {
                    try buf.appendSlice(ctx.allocator, entry.name);
                    try buf.appendSlice(ctx.allocator, ":\n");
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
        return .{
            .content = try std.fmt.allocPrint(ctx.allocator, "No matches found for '{s}'", .{pattern}),
            .match_count = 0,
            .files_scanned = files_scanned,
            .truncated = false,
        };
    }
    if (truncated) {
        try buf.appendSlice(ctx.allocator, "[truncated: output limit reached]\n");
    }

    return .{
        .content = try buf.toOwnedSlice(ctx.allocator),
        .match_count = matches,
        .files_scanned = files_scanned,
        .truncated = truncated,
    };
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

const Io = std.Io;

fn testExec(ctx: types.ToolContext, args_json: []const u8) !types.ToolResult {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{ .ignore_unknown_fields = true }) catch {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: invalid arguments JSON: {s}", .{args_json});
        return types.ToolResult{ .session_content = msg };
    };
    return types.ToolResult.finishExec(execute, ctx, parsed.value, parsed);
}

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

    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = test_path,
    };

    var result = try testExec(ctx, "{\"pattern\":\"hello\",\"path\":\"search.txt\"}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "hello world") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "hello again") != null);
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

    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = test_path,
    };

    var result = try testExec(ctx, "{\"pattern\":\"xyzzy\",\"path\":\"search.txt\"}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "No matches") != null);
}