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
const MAX_USER_OUTPUT: usize = 4096;

/// Execute a shell command via powershell/sh. Returns allocator-owned ToolResult.
pub fn execute(ctx: types.ToolContext, args: std.json.Value) anyerror!types.ToolResult {
    const cmd_val = args.object.get("command") orelse {
        const content = try std.fmt.allocPrint(ctx.allocator, "Error: missing 'command' argument", .{});
        return types.ToolResult{
            .session_content = content,
        };
    };
    if (cmd_val != .string) {
        const content = try std.fmt.allocPrint(ctx.allocator, "Error: 'command' must be a string", .{});
        return types.ToolResult{
            .session_content = content,
        };
    }

    const shell = if (builtin.os.tag == .windows) "pwsh.exe" else "sh";
    const cmd = if (builtin.os.tag == .windows)
        try std.fmt.allocPrint(ctx.allocator, "[Console]::OutputEncoding=[System.Text.UTF8Encoding]::new($false);$OutputEncoding=[System.Text.UTF8Encoding]::new($false);{s}", .{cmd_val.string})
    else
        cmd_val.string;
    defer if (builtin.os.tag == .windows) ctx.allocator.free(cmd);

    const limit: std.Io.Limit = @enumFromInt(MAX_STREAM);
    const proc_result = (if (builtin.os.tag == .windows)
        std.process.run(ctx.allocator, ctx.io, .{
            .argv = &[_][]const u8{ shell, "-NoProfile", "-Command", cmd },
            .stdout_limit = limit,
            .stderr_limit = limit,
        })
    else
        std.process.run(ctx.allocator, ctx.io, .{
            .argv = &[_][]const u8{ shell, "-c", cmd },
            .stdout_limit = limit,
            .stderr_limit = limit,
        })) catch |err| {
        const content = try std.fmt.allocPrint(ctx.allocator, "Error: execution failed: {s}", .{@errorName(err)});
        return types.ToolResult{
            .session_content = content,
        };
    };
    defer ctx.allocator.free(proc_result.stdout);
    defer ctx.allocator.free(proc_result.stderr);

    const exit_code: i32 = switch (proc_result.term) {
        .exited => |code| @intCast(code),
        else => -1,
    };

    const raw_total: usize = proc_result.stdout.len + proc_result.stderr.len;
    const out_len = @min(proc_result.stdout.len, MAX_STREAM);
    const err_len = @min(proc_result.stderr.len, MAX_STREAM);
    const total = out_len + err_len;
    var truncated = out_len < proc_result.stdout.len or err_len < proc_result.stderr.len;

    var result_buf = std.ArrayListAligned(u8, null).empty;
    if (total > 0) {
        if (total > MAX_OUTPUT) {
            truncated = true;
            const half = MAX_OUTPUT / 2;
            if (out_len > half) try result_buf.appendSlice(ctx.allocator, proc_result.stdout[0..half]) else try result_buf.appendSlice(ctx.allocator, proc_result.stdout[0..out_len]);
            if (err_len > half) try result_buf.appendSlice(ctx.allocator, proc_result.stderr[0..half]) else try result_buf.appendSlice(ctx.allocator, proc_result.stderr[0..err_len]);
            try result_buf.appendSlice(ctx.allocator, "\n[truncated]");
        } else {
            try result_buf.appendSlice(ctx.allocator, proc_result.stdout[0..out_len]);
            try result_buf.appendSlice(ctx.allocator, proc_result.stderr[0..err_len]);
        }
    }

    if (exit_code != 0) {
        var num_buf: [16]u8 = undefined;
        const code_str = try std.fmt.bufPrint(&num_buf, "\n[exit code: {d}]", .{exit_code});
        try result_buf.appendSlice(ctx.allocator, code_str);
    }

    const session_content = try result_buf.toOwnedSlice(ctx.allocator);
    return types.ToolResult{
        .session_content = session_content,
        .user_output = if (total > 0) session_content[0..@min(session_content.len, MAX_USER_OUTPUT)] else null,
        .meta = .{ .bash = .{
            .exit_code = exit_code,
            .byte_count = raw_total,
            .truncated = truncated,
            .timed_out = false,
        }},
    };
}

const Io = std.Io;

fn testExec(ctx: types.ToolContext, args_json: []const u8) !types.ToolResult {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{ .ignore_unknown_fields = true }) catch {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: invalid arguments JSON: {s}", .{args_json});
        return types.ToolResult{ .session_content = msg };
    };
    defer parsed.deinit();
    return execute(ctx, parsed.value);
}

test "bash: echo hello" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = ".",
    };
    var result = try testExec(ctx, "{\"command\":\"echo hello\"}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "hello") != null);
    try std.testing.expect(result.user_output != null);
    try std.testing.expect(std.mem.indexOf(u8, result.user_output.?, "hello") != null);
}

test "bash: missing command" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const ctx = types.ToolContext{ .allocator = allocator, .io = io, .project_root = "." };
    var result = try testExec(ctx, "{}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "missing") != null);
}

test "bash: invalid JSON" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const ctx = types.ToolContext{ .allocator = allocator, .io = io, .project_root = "." };
    var result = try testExec(ctx, "not json");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "invalid") != null);
}