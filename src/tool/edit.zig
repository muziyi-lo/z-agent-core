const std = @import("std");
const types = @import("../types.zig");
const path_util = @import("../util/path.zig");

pub const tool_name = "edit";
pub const tool_description = "Perform exact string replacements in a file. Supports replaceAll for multiple occurrences. Returns a diff preview.";
pub const tool_params =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Path to the file to edit"},"oldString":{"type":"string","description":"The text to replace"},"newString":{"type":"string","description":"The text to replace it with"},"replaceAll":{"type":"boolean","description":"Replace all occurrences (default false)"}},"required":["path","oldString","newString"]}
;

const MAX_FILE_SIZE: usize = 512 * 1024;
const MAX_DIFF_LINES: usize = 6;

const Io = std.Io;

pub fn execute(ctx: types.ToolContext, args: std.json.Value) anyerror!types.ToolResult {
    const path_val = args.object.get("path") orelse {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: missing 'path' argument", .{});
        return types.ToolResult{ .session_content = msg };
    };
    if (path_val != .string) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: 'path' must be a string", .{});
        return types.ToolResult{ .session_content = msg };
    }

    const old_val = args.object.get("oldString") orelse {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: missing 'oldString' argument", .{});
        return types.ToolResult{ .session_content = msg };
    };
    if (old_val != .string or old_val.string.len == 0) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: 'oldString' must be a non-empty string", .{});
        return types.ToolResult{ .session_content = msg };
    }

    const new_val = args.object.get("newString") orelse {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: missing 'newString' argument", .{});
        return types.ToolResult{ .session_content = msg };
    };
    if (new_val != .string) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: 'newString' must be a string", .{});
        return types.ToolResult{ .session_content = msg };
    }

    if (std.mem.eql(u8, old_val.string, new_val.string)) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: oldString and newString are identical", .{});
        return types.ToolResult{ .session_content = msg };
    }

    const replace_all = if (args.object.get("replaceAll")) |ra| ra.bool else false;

    const path = path_util.resolvePath(ctx.allocator, ctx.project_root, path_val.string) catch |err| switch (err) {
        error.PathEscape => {
            const msg = try std.fmt.allocPrint(ctx.allocator, "Error: path escapes project root", .{});
            return types.ToolResult{ .session_content = msg };
        },
        else => return err,
    };
    defer ctx.allocator.free(path);

    const file = Io.Dir.cwd().openFile(ctx.io, path, .{ .mode = .read_only }) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: cannot open '{s}': {s}", .{ path_val.string, @errorName(err) });
        return types.ToolResult{ .session_content = msg };
    };
    defer file.close(ctx.io);

    const file_size: usize = @intCast((try file.stat(ctx.io)).size);
    if (file_size > MAX_FILE_SIZE) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: file too large: {d} bytes", .{file_size});
        return types.ToolResult{ .session_content = msg };
    }

    const file_content = try ctx.allocator.alloc(u8, file_size);
    defer ctx.allocator.free(file_content);
    _ = try file.readPositionalAll(ctx.io, file_content, 0);

    var count: usize = 0;
    var search_start: usize = 0;
    while (std.mem.indexOfPosLinear(u8, file_content, search_start, old_val.string)) |pos| : (search_start = pos + new_val.string.len) {
        count += 1;
        if (!replace_all and count > 1) break;
    }

    if (count == 0) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: oldString not found in file", .{});
        return types.ToolResult{ .session_content = msg };
    }

    if (!replace_all and count > 1) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: oldString found {d} times. Use replaceAll to replace all occurrences or provide more context to make it unique.", .{count});
        return types.ToolResult{ .session_content = msg };
    }

    var new_content = std.ArrayListAligned(u8, null).empty;
    search_start = 0;
    var replacements: usize = 0;
    while (std.mem.indexOfPosLinear(u8, file_content, search_start, old_val.string)) |pos| {
        try new_content.appendSlice(ctx.allocator, file_content[search_start..pos]);
        try new_content.appendSlice(ctx.allocator, new_val.string);
        search_start = pos + old_val.string.len;
        replacements += 1;
    }
    try new_content.appendSlice(ctx.allocator, file_content[search_start..]);

    const new_content_bytes = try new_content.toOwnedSlice(ctx.allocator);
    defer ctx.allocator.free(new_content_bytes);

    var new_file = try Io.Dir.cwd().createFile(ctx.io, path, .{});
    defer new_file.close(ctx.io);
    try new_file.writeStreamingAll(ctx.io, new_content_bytes);

    var old_lines: usize = 1;
    for (file_content) |b| { if (b == '\n') old_lines += 1; }
    var new_lines: usize = 1;
    for (new_content_bytes) |b| { if (b == '\n') new_lines += 1; }

    var msg_buf = std.ArrayListAligned(u8, null).empty;
    const header = try std.fmt.allocPrint(ctx.allocator, "Edited file: {s}\nReplacements: {d}\n", .{ path_val.string, replacements });
    defer ctx.allocator.free(header);
    try msg_buf.appendSlice(ctx.allocator, header);

    const diff = try buildDiff(ctx.allocator, file_content, new_content_bytes, old_val.string, new_val.string);
    defer ctx.allocator.free(diff);
    try msg_buf.appendSlice(ctx.allocator, diff);

    return types.ToolResult{
        .session_content = try msg_buf.toOwnedSlice(ctx.allocator),
        .meta = .{ .edit = .{
            .path = path_val.string,
            .replacements = replacements,
            .old_lines = old_lines,
            .new_lines = new_lines,
        }},
    };
}

fn truncateUtf8(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0) {
        const len = std.unicode.utf8ByteSequenceLength(s[end - 1]) catch {
            end -= 1;
            continue;
        };
        if (end - 1 + len <= s.len and end - 1 + len > max) {
            end -= 1;
            continue;
        }
        break;
    }
    return s[0..end];
}

fn buildDiff(allocator: std.mem.Allocator, old_content: []const u8, new_content: []const u8, old_str: []const u8, new_str: []const u8) ![]const u8 {
    var buf = std.ArrayListAligned(u8, null).empty;

    try buf.appendSlice(allocator, "```diff\n");

    var old_lines = std.mem.splitScalar(u8, old_content, '\n');
    var new_lines = std.mem.splitScalar(u8, new_content, '\n');
    var line_count: usize = 0;

    while (line_count < MAX_DIFF_LINES) {
        const old_line = old_lines.next();
        const new_line = new_lines.next();
        if (old_line == null and new_line == null) break;

        if (old_line) |ol| {
            var trimmed: []const u8 = ol;
            if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '\r') {
                trimmed = trimmed[0 .. trimmed.len - 1];
            }
            if (std.mem.indexOf(u8, ol, old_str) != null) {
                if (trimmed.len > 240) {
                    trimmed = truncateUtf8(trimmed, 240);
                }
                try buf.appendSlice(allocator, "-");
                try buf.appendSlice(allocator, trimmed);
                try buf.append(allocator, '\n');
                line_count += 1;
            }
        }
        if (new_line) |nl| {
            var trimmed: []const u8 = nl;
            if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '\r') {
                trimmed = trimmed[0 .. trimmed.len - 1];
            }
            if (std.mem.indexOf(u8, nl, new_str) != null) {
                if (trimmed.len > 240) {
                    trimmed = truncateUtf8(trimmed, 240);
                }
                try buf.appendSlice(allocator, "+");
                try buf.appendSlice(allocator, trimmed);
                try buf.append(allocator, '\n');
                line_count += 1;
            }
        }
    }

    try buf.appendSlice(allocator, "```\n");

    return buf.toOwnedSlice(allocator);
}

fn testExec(ctx: types.ToolContext, args_json: []const u8) !types.ToolResult {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{ .ignore_unknown_fields = true }) catch {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: invalid arguments JSON: {s}", .{args_json});
        return types.ToolResult{ .session_content = msg };
    };
    return types.ToolResult.finishExec(execute, ctx, parsed.value, parsed);
}

test "edit: replaces single occurrence" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-edit-single";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {};
    try Io.Dir.cwd().createDirPath(io, test_root);

    const test_path = try std.fs.path.join(allocator, &.{ test_root });
    defer allocator.free(test_path);

    const file_path = try std.fs.path.join(allocator, &.{ test_root, "edit_test.txt" });
    defer allocator.free(file_path);
    var file = try Io.Dir.cwd().createFile(io, file_path, .{});
    try file.writeStreamingAll(io, "hello world\nfoo bar\n");
    file.close(io);

    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = test_path,
    };

    var result = try testExec(ctx, "{\"path\":\"edit_test.txt\",\"oldString\":\"hello world\",\"newString\":\"hi there\"}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "Replacements: 1") != null);
    try std.testing.expect(result.meta.edit.replacements == 1);

    const updated = try Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .unlimited);
    defer allocator.free(updated);
    try std.testing.expect(std.mem.indexOf(u8, updated, "hi there") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "hello world") == null);
}

test "edit: identical strings error" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-edit-identical";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {};
    try Io.Dir.cwd().createDirPath(io, test_root);

    const test_path = try std.fs.path.join(allocator, &.{ test_root });
    defer allocator.free(test_path);

    const file_path = try std.fs.path.join(allocator, &.{ test_root, "test.txt" });
    defer allocator.free(file_path);
    var file = try Io.Dir.cwd().createFile(io, file_path, .{});
    try file.writeStreamingAll(io, "test content\n");
    file.close(io);

    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = test_path,
    };

    var result = try testExec(ctx, "{\"path\":\"test.txt\",\"oldString\":\"same\",\"newString\":\"same\"}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "identical") != null);
}

test "edit: not found error" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-edit-notfound";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {};
    try Io.Dir.cwd().createDirPath(io, test_root);

    const test_path = try std.fs.path.join(allocator, &.{ test_root });
    defer allocator.free(test_path);

    const file_path = try std.fs.path.join(allocator, &.{ test_root, "test.txt" });
    defer allocator.free(file_path);
    var file = try Io.Dir.cwd().createFile(io, file_path, .{});
    try file.writeStreamingAll(io, "hello\n");
    file.close(io);

    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = test_path,
    };

    var result = try testExec(ctx, "{\"path\":\"test.txt\",\"oldString\":\"notinthere\",\"newString\":\"x\"}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "not found") != null);
}

test "edit: replaceAll multiple" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-edit-replaceall";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {};
    try Io.Dir.cwd().createDirPath(io, test_root);

    const test_path = try std.fs.path.join(allocator, &.{ test_root });
    defer allocator.free(test_path);

    const file_path = try std.fs.path.join(allocator, &.{ test_root, "test.txt" });
    defer allocator.free(file_path);
    var file = try Io.Dir.cwd().createFile(io, file_path, .{});
    try file.writeStreamingAll(io, "foo foo foo\n");
    file.close(io);

    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = test_path,
    };

    var result = try testExec(ctx, "{\"path\":\"test.txt\",\"oldString\":\"foo\",\"newString\":\"bar\",\"replaceAll\":true}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "Replacements: 3") != null);
    try std.testing.expect(result.meta.edit.replacements == 3);

    const updated = try Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .unlimited);
    defer allocator.free(updated);
    try std.testing.expect(std.mem.indexOf(u8, updated, "foo") == null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "bar bar bar") != null);
}
