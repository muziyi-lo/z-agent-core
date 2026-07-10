const std = @import("std");
const types = @import("../types.zig");
const path_util = @import("../util/path.zig");

pub const tool_name = "write";
pub const tool_description = "Create or overwrite a file with the given content. Parent directories are created automatically.";
pub const tool_params =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Path to the file to write"},"content":{"type":"string","description":"Content to write to the file"}},"required":["path","content"]}
;

const MAX_CONTENT: usize = 512 * 1024;

/// Create or overwrite a file. Creates parent directories. Returns allocator-owned result.
pub fn execute(ctx: types.ToolContext, args_json: []const u8) anyerror![]const u8 {
    const args = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{ .ignore_unknown_fields = true }) catch {
        return try std.fmt.allocPrint(ctx.allocator, "Error: invalid arguments JSON: {s}", .{args_json});
    };
    defer args.deinit();

    const path_val = args.value.object.get("path") orelse {
        return try std.fmt.allocPrint(ctx.allocator, "Error: missing 'path' argument", .{});
    };
    if (path_val != .string) {
        return try std.fmt.allocPrint(ctx.allocator, "Error: 'path' must be a string", .{});
    }

    const content_val = args.value.object.get("content") orelse {
        return try std.fmt.allocPrint(ctx.allocator, "Error: missing 'content' argument", .{});
    };
    if (content_val != .string) {
        return try std.fmt.allocPrint(ctx.allocator, "Error: 'content' must be a string", .{});
    }

    if (content_val.string.len > MAX_CONTENT) {
        return try std.fmt.allocPrint(ctx.allocator, "Error: content too large: {d} bytes (max 512KB)", .{content_val.string.len});
    }

    const path = path_util.resolvePath(ctx.allocator, ctx.project_root, path_val.string) catch |err| switch (err) {
        error.PathEscape => return try std.fmt.allocPrint(ctx.allocator, "Error: path escapes project root", .{}),
        else => return err,
    };
    defer ctx.allocator.free(path);

    if (std.fs.path.dirname(path)) |parent| {
        Io.Dir.cwd().createDirPath(ctx.io, parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    const existed = blk: {
        if (Io.Dir.cwd().openFile(ctx.io, path, .{ .mode = .read_only })) |f| {
            f.close(ctx.io);
            break :blk true;
        } else |_| {
            break :blk false;
        }
    };

    Io.Dir.cwd().deleteFile(ctx.io, path) catch |err| switch (err) {
        error.FileNotFound => {}, // best-effort: file may not exist yet
        else => {}, // non-fatal, proceed with createFile
    };
    const file = try Io.Dir.cwd().createFile(ctx.io, path, .{});
    defer file.close(ctx.io);
    try file.writeStreamingAll(ctx.io, content_val.string);

    const msg: []const u8 = if (existed)
        try std.fmt.allocPrint(ctx.allocator, "Updated {s} ({d} bytes)", .{ path_val.string, content_val.string.len })
    else
        try std.fmt.allocPrint(ctx.allocator, "Created {s} ({d} bytes)", .{ path_val.string, content_val.string.len });
    ctx.display_writer.print("{s}\n", .{msg}) catch {}; // display failures are non-fatal
    ctx.display_writer.flush() catch {}; // display failures are non-fatal
    ctx.allocator.free(msg);

    return try std.fmt.allocPrint(ctx.allocator, "Wrote {s}: {d} bytes", .{ path_val.string, content_val.string.len });
}

const Io = std.Io;

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const f = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer f.close(io);
    const size: usize = @intCast((try f.stat(io)).size);
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    const n = try f.readPositionalAll(io, buf, 0);
    return buf[0..n];
}

test "write: creates file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-write-create";
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

    const result = try execute(ctx, "{\"path\":\"new.txt\",\"content\":\"hello world\"}");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "Wrote") != null);

    const verify_path = try std.fs.path.join(allocator, &.{ test_root, "new.txt" });
    defer allocator.free(verify_path);
    const data = try readFile(allocator, io, verify_path);
    defer allocator.free(data);
    try std.testing.expectEqualStrings("hello world", data);
}

test "write: parent dirs auto-created" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-write-parent";
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

    const result = try execute(ctx, "{\"path\":\"sub/dir/deep.txt\",\"content\":\"deep\"}");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "Wrote") != null);

    const verify_path = try std.fs.path.join(allocator, &.{ test_root, "sub", "dir", "deep.txt" });
    defer allocator.free(verify_path);
    const data = try readFile(allocator, io, verify_path);
    defer allocator.free(data);
    try std.testing.expectEqualStrings("deep", data);
}

test "write: content too large" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-write-large";
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

    const big = try allocator.alloc(u8, MAX_CONTENT + 1);
    defer allocator.free(big);
    @memset(big, 'x');

    var json_buf = std.ArrayListAligned(u8, null).empty;
    defer json_buf.deinit(allocator);
    try json_buf.appendSlice(allocator, "{\"path\":\"big.txt\",\"content\":\"");
    for (big) |b| {
        switch (b) {
            '"', '\\' => {
                try json_buf.append(allocator, '\\');
                try json_buf.append(allocator, b);
            },
            else => try json_buf.append(allocator, b),
        }
    }
    try json_buf.appendSlice(allocator, "\"}");

    const result = try execute(ctx, json_buf.items);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "too large") != null);
}

test "write: overwrites existing file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-write-ovr";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {}; // best-effort cleanup
    try Io.Dir.cwd().createDirPath(io, test_root);

    const test_path = try std.fs.path.join(allocator, &.{ test_root });
    defer allocator.free(test_path);

    {
        const fp = try std.fs.path.join(allocator, &.{ test_root, "exist.txt" });
        defer allocator.free(fp);
        const f = try Io.Dir.cwd().createFile(io, fp, .{});
        f.close(io);
    }

    var dbuf: [256]u8 = undefined;
    var dw: Io.File.Writer = .init(.stderr(), io, &dbuf);
    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = test_path,
        .display_writer = &dw.interface,
    };

    const result = try execute(ctx, "{\"path\":\"exist.txt\",\"content\":\"updated\"}");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "Wrote") != null);

    const verify_path = try std.fs.path.join(allocator, &.{ test_root, "exist.txt" });
    defer allocator.free(verify_path);
    const data = try readFile(allocator, io, verify_path);
    defer allocator.free(data);
    try std.testing.expectEqualStrings("updated", data);
}
