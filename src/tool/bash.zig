const std = @import("std");
const builtin = @import("builtin");
const types = @import("../types.zig");

pub const tool_name = "bash";
pub const tool_description = "Execute a shell command. Returns stdout and stderr output.";
pub const tool_params =
    \\{"type":"object","properties":{"command":{"type":"string","description":"Shell command to execute"},"timeout":{"type":"integer","description":"Timeout in seconds (default 30)"}},"required":["command"]}
;

const MAX_OUTPUT: usize = 50 * 1024;
const MAX_STREAM: usize = 25 * 1024;

/// Execute a shell command via powershell/sh. Returns allocator-owned stdout/stderr output.
pub fn execute(ctx: types.ToolContext, args_json: []const u8) anyerror![]const u8 {
    const args = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{ .ignore_unknown_fields = true }) catch {
        return try std.fmt.allocPrint(ctx.allocator, "Error: invalid arguments JSON: {s}", .{args_json});
    };
    defer args.deinit();

    const cmd_val = args.value.object.get("command") orelse {
        return try std.fmt.allocPrint(ctx.allocator, "Error: missing 'command' argument", .{});
    };
    if (cmd_val != .string) {
        return try std.fmt.allocPrint(ctx.allocator, "Error: 'command' must be a string", .{});
    }

    const shell = if (builtin.os.tag == .windows) "powershell.exe" else "sh";
    const shell_flag = if (builtin.os.tag == .windows) "-Command" else "-c";

    const argv = [_][]const u8{ shell, shell_flag, cmd_val.string };

    const limit: std.Io.Limit = @enumFromInt(MAX_STREAM);
    const result = std.process.run(ctx.allocator, ctx.io, .{
        .argv = &argv,
        .stdout_limit = limit,
        .stderr_limit = limit,
    }) catch |err| {
        return std.fmt.allocPrint(ctx.allocator, "Error: execution failed: {s}", .{@errorName(err)}) catch "Error: execution failed";
    };
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);

    try ctx.display_writer.print("> {s}\n", .{cmd_val.string});

    const exit_code: i32 = switch (result.term) {
        .exited => |code| @intCast(code),
        else => -1,
    };

    const out_len = @min(result.stdout.len, MAX_STREAM);
    const err_len = @min(result.stderr.len, MAX_STREAM);
    const total = out_len + err_len;

    var result_buf = std.ArrayListAligned(u8, null).empty;
    if (total > 0) {
        if (total > MAX_OUTPUT) {
            const half = MAX_OUTPUT / 2;
            if (out_len > half) try result_buf.appendSlice(ctx.allocator, result.stdout[0..half]) else try result_buf.appendSlice(ctx.allocator, result.stdout[0..out_len]);
            if (err_len > half) try result_buf.appendSlice(ctx.allocator, result.stderr[0..half]) else try result_buf.appendSlice(ctx.allocator, result.stderr[0..err_len]);
            try result_buf.appendSlice(ctx.allocator, "\n[truncated]");
        } else {
            try result_buf.appendSlice(ctx.allocator, result.stdout[0..out_len]);
            try result_buf.appendSlice(ctx.allocator, result.stderr[0..err_len]);
        }
    }
    ctx.display_writer.print("{s}", .{result_buf.items}) catch {};
    ctx.display_writer.flush() catch {};

    if (exit_code != 0) {
        var num_buf: [16]u8 = undefined;
        const code_str = try std.fmt.bufPrint(&num_buf, "\n[exit code: {d}]", .{exit_code});
        try result_buf.appendSlice(ctx.allocator, code_str);
    }

    return result_buf.toOwnedSlice(ctx.allocator);
}

const Io = std.Io;

test "bash: echo hello" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var dbuf: [256]u8 = undefined;
    var dw: Io.File.Writer = .init(.stderr(), io, &dbuf);
    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = ".",
        .display_writer = &dw.interface,
    };
    const result = try execute(ctx, "{\"command\":\"echo hello\"}");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "hello") != null);
}

test "bash: missing command" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var dbuf: [256]u8 = undefined;
    var dw: Io.File.Writer = .init(.stderr(), io, &dbuf);
    const ctx = types.ToolContext{ .allocator = allocator, .io = io, .project_root = ".", .display_writer = &dw.interface };
    const result = try execute(ctx, "{}");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "missing") != null);
}

test "bash: invalid JSON" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var dbuf: [256]u8 = undefined;
    var dw: Io.File.Writer = .init(.stderr(), io, &dbuf);
    const ctx = types.ToolContext{ .allocator = allocator, .io = io, .project_root = ".", .display_writer = &dw.interface };
    const result = try execute(ctx, "not json");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "invalid") != null);
}
