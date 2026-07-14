const std = @import("std");
const types = @import("../types.zig");
const path_util = @import("../util/path.zig");

pub const tool_name = "read";
pub const tool_description = "Read a file or list a directory from the filesystem. For text files, returns content with optional offset/limit. For directories, lists entries.";
pub const tool_params =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Path to the file or directory"},"offset":{"type":"integer","description":"Starting line (1-indexed)"},"limit":{"type":"integer","description":"Max lines to return"}},"required":["path"]}
;

const MAX_BYTES: usize = 50 * 1024;
const MAX_DIR_FILES: usize = 100;
const BINARY_CHECK_SIZE: usize = 4096;

/// Read a file or directory. Returns structured ToolResult.
pub fn execute(ctx: types.ToolContext, args_json: []const u8) anyerror!types.ToolResult {
    const args = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{ .ignore_unknown_fields = true }) catch {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: invalid arguments JSON: {s}", .{args_json});
        errdefer ctx.allocator.free(msg);
        return types.ToolResult{
            .session_content = msg,
                    };
    };
    defer args.deinit();

    const path_val = args.value.object.get("path") orelse {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: missing 'path' argument", .{});
        errdefer ctx.allocator.free(msg);
        return types.ToolResult{
            .session_content = msg,
                    };
    };
    if (path_val != .string) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: 'path' must be a string", .{});
        errdefer ctx.allocator.free(msg);
        return types.ToolResult{
            .session_content = msg,
                    };
    }

    const path = path_util.resolvePath(ctx.allocator, ctx.project_root, path_val.string) catch |err| switch (err) {
        error.PathEscape => {
            const msg = try std.fmt.allocPrint(ctx.allocator, "Error: path escapes project root", .{});
            errdefer ctx.allocator.free(msg);
            return types.ToolResult{
                .session_content = msg,
            };
        },
        else => return err,
    };
    defer ctx.allocator.free(path);

    const offset: usize = if (args.value.object.get("offset")) |o| @intCast(@max(1, o.integer)) else 1;
    const limit: ?usize = if (args.value.object.get("limit")) |l| @intCast(@max(0, l.integer)) else null;

    if (Io.Dir.cwd().openDir(ctx.io, path, .{ .iterate = true })) |dir| {
        defer dir.close(ctx.io);
        const dir_content = try listDir(ctx, dir, offset, limit);
        return types.ToolResult{
            .session_content = dir_content,
        };
    } else |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied => {},
        else => return err,
    }

    const file = Io.Dir.cwd().openFile(ctx.io, path, .{ .mode = .read_only }) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: cannot open '{s}': {s}", .{ path_val.string, @errorName(err) });
        errdefer ctx.allocator.free(msg);
        return types.ToolResult{
            .session_content = msg,
        };
    };
    defer file.close(ctx.io);

    const stat = file.stat(ctx.io) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: cannot stat '{s}': {s}", .{ path_val.string, @errorName(err) });
        errdefer ctx.allocator.free(msg);
        return types.ToolResult{
            .session_content = msg,
        };
    };
    const file_size: usize = @intCast(stat.size);

    if (file_size == 0) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "File is empty: {s}", .{path_val.string});
        errdefer ctx.allocator.free(msg);
        return types.ToolResult{
            .session_content = msg,
        };
    }

    const check_size = @min(file_size, BINARY_CHECK_SIZE);
    const head_buf = try ctx.allocator.alloc(u8, check_size);
    defer ctx.allocator.free(head_buf);
    _ = file.readPositionalAll(ctx.io, head_buf, 0) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: cannot read '{s}': {s}", .{ path_val.string, @errorName(err) });
        errdefer ctx.allocator.free(msg);
        return types.ToolResult{
            .session_content = msg,
        };
    };

    if (isBinary(head_buf)) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: cannot read binary file '{s}'", .{path_val.string});
        errdefer ctx.allocator.free(msg);
        return types.ToolResult{
            .session_content = msg,
        };
    }

    if (!std.unicode.utf8ValidateSlice(head_buf)) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: file is not valid UTF-8 at '{s}'", .{path_val.string});
        errdefer ctx.allocator.free(msg);
        return types.ToolResult{
            .session_content = msg,
        };
    }

    var content = try ctx.allocator.alloc(u8, file_size);
    defer ctx.allocator.free(content);
    const n = file.readPositionalAll(ctx.io, content, 0) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: cannot read '{s}': {s}", .{ path_val.string, @errorName(err) });
        errdefer ctx.allocator.free(msg);
        return types.ToolResult{
            .session_content = msg,
        };
    };
    content = content[0..n];

    const result = try readLines(ctx.allocator, content, offset, limit);

    if (result.len > MAX_BYTES) {
        const truncated = result[0..MAX_BYTES];
        const content_with_note = try std.fmt.allocPrint(ctx.allocator, "{s}\n[truncated: {d} more bytes]", .{ truncated, result.len - MAX_BYTES });
        ctx.allocator.free(result);
        return types.ToolResult{
            .session_content = content_with_note,
        };
    }
    return types.ToolResult{
        .session_content = result,
    };
}

fn isBinary(data: []const u8) bool {
    if (data.len == 0) return false;
    var control: usize = 0;
    for (data) |b| {
        if (b == 0) return true;
        if (b < 0x20 and b != '\n' and b != '\r' and b != '\t') {
            control += 1;
        }
    }
    return control * 100 / data.len > 30;
}

fn readLines(allocator: std.mem.Allocator, content: []const u8, offset: usize, limit: ?usize) ![]const u8 {
    var buf = std.ArrayListAligned(u8, null).empty;
    var line_count: usize = 0;
    var line_start: usize = 0;
    var i: usize = 0;

    while (i < content.len) {
        if (content[i] == '\n') {
            line_count += 1;
            const line_end = if (i > 0 and content[i - 1] == '\r') i - 1 else i;
            if (line_count >= offset) {
                try buf.appendSlice(allocator, content[line_start..line_end]);
                try buf.append(allocator, '\n');
                if (limit) |l| {
                    if (line_count >= offset + l - 1) break;
                }
            }
            line_start = i + 1;
        }
        i += 1;
    }

    if (line_start < content.len and (line_count == 0 or (limit == null or line_count < offset + (limit orelse std.math.maxInt(usize)) - 1))) {
        if (line_count + 1 >= offset) {
            try buf.appendSlice(allocator, content[line_start..]);
        }
    }

    return buf.toOwnedSlice(allocator);
}

fn listDir(ctx: types.ToolContext, dir: Io.Dir, offset: usize, limit: ?usize) ![]const u8 {
    var buf = std.ArrayListAligned(u8, null).empty;
    var iter = dir.iterate();
    var count: usize = 0;
    var shown: usize = 0;

    while (try iter.next(ctx.io)) |entry| {
        count += 1;
        if (count < offset) continue;
        shown += 1;
        if (shown > MAX_DIR_FILES) {
            try buf.appendSlice(ctx.allocator, "... (more entries)\n");
            break;
        }
        if (limit) |l| {
            if (shown > l) break;
        }
        const kind: u8 = switch (entry.kind) {
            .directory => 'd',
            .file => 'f',
            .sym_link => 'l',
            else => '?',
        };
        var line_buf: [512]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "{c} {s}\n", .{ kind, entry.name });
        try buf.appendSlice(ctx.allocator, line);
    }

    return buf.toOwnedSlice(ctx.allocator);
}

const Io = std.Io;

test "read: reads text file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-read-text";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {}; // best-effort cleanup
    try Io.Dir.cwd().createDirPath(io, test_root);

    const test_path = try std.fs.path.join(allocator, &.{ test_root });
    defer allocator.free(test_path);

    const file_path = try std.fs.path.join(allocator, &.{ test_root, "test_read.txt" });
    defer allocator.free(file_path);
    const file = try Io.Dir.cwd().createFile(io, file_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "hello\nworld\n");



    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = test_path,
    };

    var result = try execute(ctx, "{\"path\":\"test_read.txt\"}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "world") != null);
}

test "read: detects binary" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-read-binary";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {}; // best-effort cleanup
    try Io.Dir.cwd().createDirPath(io, test_root);

    const test_path = try std.fs.path.join(allocator, &.{ test_root });
    defer allocator.free(test_path);

    const file_path = try std.fs.path.join(allocator, &.{ test_root, "test_binary.bin" });
    defer allocator.free(file_path);
    const data = [_]u8{ 0x00, 0x01, 0x02, 'h', 'e', 'l', 'l', 'o' };
    const file = try Io.Dir.cwd().createFile(io, file_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, &data);



    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = test_path,
    };

    var result = try execute(ctx, "{\"path\":\"test_binary.bin\"}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "binary") != null);
}

test "read: directory listing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-read-dir";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {}; // best-effort cleanup
    try Io.Dir.cwd().createDirPath(io, test_root);

    const test_path = try std.fs.path.join(allocator, &.{ test_root });
    defer allocator.free(test_path);

    {
        const p = try std.fs.path.join(allocator, &.{ test_root, "foo.txt" });
        defer allocator.free(p);
        (try Io.Dir.cwd().createFile(io, p, .{})).close(io);
    }
    {
        const p = try std.fs.path.join(allocator, &.{ test_root, "bar.txt" });
        defer allocator.free(p);
        (try Io.Dir.cwd().createFile(io, p, .{})).close(io);
    }



    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = test_path,
    };

    var result = try execute(ctx, "{\"path\":\".\"}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "foo.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "bar.txt") != null);
}

test "read: offset/limit range" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-read-offset";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {}; // best-effort cleanup
    try Io.Dir.cwd().createDirPath(io, test_root);

    const test_path = try std.fs.path.join(allocator, &.{ test_root });
    defer allocator.free(test_path);

    const file_path = try std.fs.path.join(allocator, &.{ test_root, "test_lines.txt" });
    defer allocator.free(file_path);
    const file = try Io.Dir.cwd().createFile(io, file_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "line1\nline2\nline3\nline4\n");



    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = test_path,
    };

    var result = try execute(ctx, "{\"path\":\"test_lines.txt\",\"offset\":2,\"limit\":2}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "line1") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "line2") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "line3") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "line4") == null);
}

test "read: missing path" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-read-missing";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {}; // best-effort cleanup
    try Io.Dir.cwd().createDirPath(io, test_root);

    const test_path = try std.fs.path.join(allocator, &.{ test_root });
    defer allocator.free(test_path);



    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = test_path,
    };

    var result = try execute(ctx, "{}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "missing") != null);
}

test "read: path escape rejected" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-read-escape";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {}; // best-effort cleanup
    try Io.Dir.cwd().createDirPath(io, test_root);

    const test_path = try std.fs.path.join(allocator, &.{ test_root });
    defer allocator.free(test_path);



    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = test_path,
    };

    var result = try execute(ctx, "{\"path\":\"../outside\"}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "escapes") != null);
}

test "read: empty file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-read-empty";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {}; // best-effort cleanup
    try Io.Dir.cwd().createDirPath(io, test_root);

    const test_path = try std.fs.path.join(allocator, &.{ test_root });
    defer allocator.free(test_path);

    const file_path = try std.fs.path.join(allocator, &.{ test_root, "test_empty.txt" });
    defer allocator.free(file_path);
    (try Io.Dir.cwd().createFile(io, file_path, .{})).close(io);



    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = test_path,
    };

    var result = try execute(ctx, "{\"path\":\"test_empty.txt\"}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "empty") != null);
}
