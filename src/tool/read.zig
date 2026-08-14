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
const MAX_LINE_LEN: usize = 2000;
const EXTENSION_BLACKLIST = [_][]const u8{ ".zip", ".exe", ".dll", ".so", ".dylib", ".bin", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".ico", ".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".mp3", ".mp4", ".avi", ".mov", ".mkv", ".wav", ".flac", ".ogg", ".tar", ".gz", ".bz2", ".xz", ".7z" };

fn isBlacklisted(path: []const u8) bool {
    for (EXTENSION_BLACKLIST) |ext| {
        if (path.len >= ext.len and std.mem.eql(u8, path[path.len - ext.len ..], ext)) return true;
    }
    return false;
}

fn countLines(content: []const u8) usize {
    var count: usize = 0;
    for (content) |b| {
        if (b == '\n') count += 1;
    }
    if (content.len > 0 and content[content.len - 1] != '\n') count += 1;
    return count;
}

const ReadLinesResult = struct {
    text: []const u8,
    total_lines: usize,
    next_offset: ?u32,
};

fn readLinesResult(allocator: std.mem.Allocator, content: []const u8, offset: usize, limit: ?usize) !ReadLinesResult {
    const total_lines = countLines(content);
    var buf = std.ArrayListAligned(u8, null).empty;
    var line_count: usize = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    var lines_returned: usize = 0;

    while (i < content.len) : (i += 1) {
        if (content[i] == '\n') {
            line_count += 1;
            const line_end = if (i > 0 and content[i - 1] == '\r') i - 1 else i;
            if (line_count >= offset) {
                lines_returned += 1;
                const raw_len = line_end - line_start;
                if (raw_len > MAX_LINE_LEN) {
                    try buf.appendSlice(allocator, content[line_start .. line_start + MAX_LINE_LEN]);
                    try buf.appendSlice(allocator, "... (line truncated)");
                } else {
                    try buf.appendSlice(allocator, content[line_start..line_end]);
                }
                try buf.append(allocator, '\n');
                if (limit) |l| {
                    if (line_count >= offset + l - 1) break;
                }
            }
            line_start = i + 1;
        }
    }

    if (line_start < content.len and (limit == null or lines_returned < limit.?)) {
        if (line_count + 1 >= offset) {
            lines_returned += 1;
            const raw_len = content.len - line_start;
            if (raw_len > MAX_LINE_LEN) {
                try buf.appendSlice(allocator, content[line_start .. line_start + MAX_LINE_LEN]);
                try buf.appendSlice(allocator, "... (line truncated)");
            } else {
                try buf.appendSlice(allocator, content[line_start..]);
            }
        }
    }

    const end_line = offset + lines_returned -| 1;
    const next_offset: ?u32 = if (end_line < total_lines) @intCast(end_line + 1) else null;

    return .{
        .text = try buf.toOwnedSlice(allocator),
        .total_lines = total_lines,
        .next_offset = next_offset,
    };
}

/// Read a file or directory. Returns structured ToolResult.
pub fn execute(ctx: types.ToolContext, args: std.json.Value) anyerror!types.ToolResult {
    const path_val = args.object.get("path") orelse {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: missing 'path' argument", .{});
        return types.ToolResult{ .session_content = msg };
    };
    if (path_val != .string) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: 'path' must be a string", .{});
        return types.ToolResult{ .session_content = msg };
    }

    const path = path_util.resolvePath(ctx.allocator, ctx.project_root, path_val.string) catch |err| switch (err) {
        error.PathEscape => {
            const msg = try std.fmt.allocPrint(ctx.allocator, "Error: path escapes project root", .{});
            return types.ToolResult{ .session_content = msg };
        },
        else => return err,
    };
    defer ctx.allocator.free(path);

    const offset: usize = @intCast(@max(1, if (args.object.get("offset")) |o| o.integer else 1));
    const limit: ?usize = if (args.object.get("limit")) |l| @intCast(@max(0, l.integer)) else null;

    if (Io.Dir.cwd().openDir(ctx.io, path, .{ .iterate = true })) |dir| {
        defer dir.close(ctx.io);
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

        return types.ToolResult{
            .session_content = try buf.toOwnedSlice(ctx.allocator),
            .meta = .{ .read = .{
                .path = path_val.string,
                .is_directory = true,
                .total_lines = shown,
                .byte_count = 0,
                .truncated = shown >= MAX_DIR_FILES,
                .next_offset = if (shown >= MAX_DIR_FILES) @intCast(count + 0) else null,
            }},
        };
    } else |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied => {},
        else => return err,
    }

    if (isBlacklisted(path_val.string)) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: binary file extension not supported: '{s}'", .{path_val.string});
        return types.ToolResult{ .session_content = msg };
    }

    const file = Io.Dir.cwd().openFile(ctx.io, path, .{ .mode = .read_only }) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: cannot open '{s}': {s}", .{ path_val.string, @errorName(err) });
        return types.ToolResult{ .session_content = msg };
    };
    defer file.close(ctx.io);

    const stat = file.stat(ctx.io) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: cannot stat '{s}': {s}", .{ path_val.string, @errorName(err) });
        return types.ToolResult{ .session_content = msg };
    };
    const file_size: usize = @intCast(stat.size);

    if (file_size == 0) {
        return types.ToolResult{
            .session_content = try std.fmt.allocPrint(ctx.allocator, "File is empty: {s}", .{path_val.string}),
            .meta = .{ .read = .{
                .path = path_val.string,
                .is_directory = false,
                .total_lines = 0,
                .byte_count = 0,
                .truncated = false,
                .next_offset = null,
            }},
        };
    }

    const check_size = @min(file_size, BINARY_CHECK_SIZE);
    const head_buf = try ctx.allocator.alloc(u8, check_size);
    defer ctx.allocator.free(head_buf);
    _ = file.readPositionalAll(ctx.io, head_buf, 0) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: cannot read '{s}': {s}", .{ path_val.string, @errorName(err) });
        return types.ToolResult{ .session_content = msg };
    };

    if (isBinary(head_buf)) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: cannot read binary file '{s}'", .{path_val.string});
        return types.ToolResult{ .session_content = msg };
    }

    var content = try ctx.allocator.alloc(u8, file_size);
    defer ctx.allocator.free(content);
    const n = file.readPositionalAll(ctx.io, content, 0) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: cannot read '{s}': {s}", .{ path_val.string, @errorName(err) });
        return types.ToolResult{ .session_content = msg };
    };
    content = content[0..n];

    if (!std.unicode.utf8ValidateSlice(content)) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: file is not valid UTF-8 at '{s}'", .{path_val.string});
        return types.ToolResult{ .session_content = msg };
    }

    if (limit != null and limit.? == 0) {
        const total_lines = countLines(content);
        return types.ToolResult{
            .session_content = try std.fmt.allocPrint(ctx.allocator, "[Read {s}: {d} lines, {d} bytes]", .{ path_val.string, total_lines, n }),
            .meta = .{ .read = .{
                .path = path_val.string,
                .is_directory = false,
                .total_lines = total_lines,
                .byte_count = n,
                .truncated = false,
                .next_offset = if (offset <= total_lines) @intCast(offset) else null,
            }},
        };
    }

    const rl = try readLinesResult(ctx.allocator, content, offset, limit);

    if (offset > rl.total_lines) {
        ctx.allocator.free(rl.text);
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: offset {d} exceeds file {s} ({d} lines)", .{ offset, path_val.string, rl.total_lines });
        return types.ToolResult{ .session_content = msg };
    }

    var session_content: []const u8 = rl.text;
    var truncated = rl.next_offset != null;

    if (session_content.len > MAX_BYTES) {
        const truncated_bytes = session_content[0..MAX_BYTES];
        const note = try std.fmt.allocPrint(ctx.allocator, "{s}\n[truncated: {d} more bytes]", .{ truncated_bytes, session_content.len - MAX_BYTES });
        ctx.allocator.free(session_content);
        session_content = note;
        truncated = true;
    }

    return types.ToolResult{
        .session_content = session_content,
        .meta = .{ .read = .{
            .path = path_val.string,
            .is_directory = false,
            .total_lines = rl.total_lines,
            .byte_count = n,
            .truncated = truncated,
            .next_offset = rl.next_offset,
        }},
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


const Io = std.Io;

fn testExec(ctx: types.ToolContext, args_json: []const u8) !types.ToolResult {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{ .ignore_unknown_fields = true }) catch {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: invalid arguments JSON: {s}", .{args_json});
        return types.ToolResult{ .session_content = msg };
    };
    return types.ToolResult.finishExec(execute, ctx, parsed.value, parsed);
}

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

    var result = try testExec(ctx, "{\"path\":\"test_read.txt\"}");
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

    var result = try testExec(ctx, "{\"path\":\"test_binary.bin\"}");
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

    var result = try testExec(ctx, "{\"path\":\".\"}");
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

    var result = try testExec(ctx, "{\"path\":\"test_lines.txt\",\"offset\":2,\"limit\":2}");
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

    var result = try testExec(ctx, "{}");
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

    var result = try testExec(ctx, "{\"path\":\"../outside\"}");
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

    var result = try testExec(ctx, "{\"path\":\"test_empty.txt\"}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "empty") != null);
}
