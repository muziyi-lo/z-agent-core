const std = @import("std");
const builtin = @import("builtin");
const types = @import("../types.zig");
const signal = @import("../util/signal.zig");

pub const tool_name = "bash";
pub const tool_description =
    "Execute a shell command in the specified working directory. Returns stdout, stderr, and exit code. " ++
    "Use for CLI tools, scripts, and system commands. " ++
    "DO NOT use for file operations (reading, writing, editing, searching, finding files) " ++
    "- use the dedicated tools instead: glob for file search, grep for content search, " ++
    "read for reading files, edit for editing, write for writing. " ++
    "Use the workdir parameter instead of 'cd'.";
pub const tool_params =
    \\{"type":"object","properties":{"command":{"type":"string","description":"Shell command to execute"},"workdir":{"type":"string","description":"Working directory (default: current)"},"timeout":{"type":"integer","description":"Timeout in seconds (informational only — process execution is blocking)"}},"required":["command"]}
;

const MAX_OUTPUT_BYTES: usize = 512 * 1024;
const MAX_STREAM_BYTES: usize = 256 * 1024;
const MAX_USER_OUTPUT: usize = 4096;

pub fn execute(ctx: types.ToolContext, args: std.json.Value) anyerror!types.ToolResult {
    const cmd_val = args.object.get("command") orelse {
        const content = try std.fmt.allocPrint(ctx.allocator, "Error: missing 'command' argument", .{});
        return types.ToolResult{ .session_content = content };
    };
    if (cmd_val != .string) {
        const content = try std.fmt.allocPrint(ctx.allocator, "Error: 'command' must be a string", .{});
        return types.ToolResult{ .session_content = content };
    }

    const workdir: ?[]const u8 = if (args.object.get("workdir")) |wv| blk: {
        if (wv == .string) break :blk wv.string;
        break :blk null;
    } else null;

    // Optional execution timeout (seconds). Not provided → .none (keep existing
    // blocking behavior — do not break long-running commands). When provided,
    // clamp to [1, 3600] to keep @intCast safe. On timeout the child is killed
    // and the model is told the command timed out (tool honesty, D6).
    const timeout_opt: Io.Timeout = if (args.object.get("timeout")) |tv| blk: {
        if (tv == .integer and tv.integer > 0) {
            const secs: u32 = @intCast(@min(tv.integer, 3600));
            break :blk Io.Timeout{ .duration = .{
                .raw = Io.Duration.fromSeconds(secs),
                .clock = Io.Clock.real,
            } };
        }
        break :blk .none;
    } else .none;

    const shell_cmd = if (builtin.os.tag == .windows)
        try std.fmt.allocPrint(ctx.allocator, "[Console]::OutputEncoding=[System.Text.UTF8Encoding]::new($false);$OutputEncoding=[System.Text.UTF8Encoding]::new($false);{s}", .{cmd_val.string})
    else
        cmd_val.string;
    defer if (builtin.os.tag == .windows) ctx.allocator.free(shell_cmd);

    const argv = if (builtin.os.tag == .windows)
        &[_][]const u8{ "pwsh.exe", "-NoProfile", "-Command", shell_cmd }
    else
        &[_][]const u8{ "sh", "-c", shell_cmd };

    var cwd_buf: [4096]u8 = undefined;
    const cwd_str: []const u8 = if (workdir) |wd| wd else blk: {
        const len = std.Io.Dir.cwd().realPath(ctx.io, &cwd_buf) catch return error.NoProjectRoot;
        break :blk cwd_buf[0..len];
    };

    const limit: std.Io.Limit = @enumFromInt(MAX_STREAM_BYTES);
    const proc_result = (if (builtin.os.tag == .windows)
        std.process.run(ctx.allocator, ctx.io, .{
            .argv = argv,
            .stdout_limit = limit,
            .stderr_limit = limit,
            .cwd = .{ .path = cwd_str },
            .timeout = timeout_opt,
        })
    else
        std.process.run(ctx.allocator, ctx.io, .{
            .argv = argv,
            .stdout_limit = limit,
            .stderr_limit = limit,
            .cwd = .{ .path = cwd_str },
            .timeout = timeout_opt,
        })) catch |err| {
        // Interrupt takes priority over auto-timeout (user intent > timeout).
        if (signal.isInterrupted()) {
            signal.reset();
            const content = try std.fmt.allocPrint(ctx.allocator, "Command aborted by user.", .{});
            return types.ToolResult{ .session_content = content };
        }
        // Timeout is distinct from a generic exec failure — the model must know
        // the command did NOT complete (tool honesty, D6).
        if (err == error.Timeout) {
            const content = try std.fmt.allocPrint(ctx.allocator, "Command timed out after {d}s.", .{timeoutSecs(timeout_opt)});
            return types.ToolResult{ .session_content = content, .meta = .{ .bash = .{
                .command = cmd_val.string,
                .exit_code = -1,
                .byte_count = 0,
                .truncated = false,
                .timed_out = true,
            } } };
        }
        const content = try std.fmt.allocPrint(ctx.allocator, "Error: execution failed: {s}", .{@errorName(err)});
        return types.ToolResult{ .session_content = content };
    };
    defer ctx.allocator.free(proc_result.stdout);
    defer ctx.allocator.free(proc_result.stderr);

    const exit_code: i32 = switch (proc_result.term) {
        .exited => |code| @intCast(code),
        else => -1,
    };

    const raw_total: usize = proc_result.stdout.len + proc_result.stderr.len;
    const stdout_truncated = proc_result.stdout.len > MAX_STREAM_BYTES or proc_result.stderr.len > MAX_STREAM_BYTES;

    const out_clean = try stripAnsi(ctx.allocator, proc_result.stdout);
    defer if (out_clean.ptr != proc_result.stdout.ptr) ctx.allocator.free(out_clean);
    const err_clean = if (proc_result.stderr.len > 0) try stripAnsi(ctx.allocator, proc_result.stderr) else @as([]const u8, &[_]u8{});
    defer if (err_clean.ptr != proc_result.stderr.ptr and proc_result.stderr.len > 0) ctx.allocator.free(err_clean);

    const total_len = out_clean.len + err_clean.len;
    const out_binary = isBinaryContent(out_clean);
    const err_binary = isBinaryContent(err_clean);

    var result_buf = std.ArrayListAligned(u8, null).empty;

    if (signal.isInterrupted()) {
        try result_buf.appendSlice(ctx.allocator, "Command aborted by user.");
        signal.reset();
    } else if (total_len == 0) {
        try result_buf.appendSlice(ctx.allocator, "(no output)");
    } else if (out_binary and err_binary) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "[binary output: {d} bytes]", .{raw_total});
        defer ctx.allocator.free(msg);
        try result_buf.appendSlice(ctx.allocator, msg);
    } else {
        const max_out = out_clean.len;
        const truncated = (out_clean.len > MAX_OUTPUT_BYTES or err_clean.len > MAX_OUTPUT_BYTES);
        if (truncated) {
            const half = MAX_OUTPUT_BYTES / 2;
            try result_buf.appendSlice(ctx.allocator, out_clean[0..@min(max_out, half)]);
            if (err_clean.len > 0) {
                try result_buf.appendSlice(ctx.allocator, "\nstderr:\n");
                try result_buf.appendSlice(ctx.allocator, err_clean[0..@min(err_clean.len, half)]);
            }
            try result_buf.appendSlice(ctx.allocator, "\n... output truncated ...");
        } else {
            try result_buf.appendSlice(ctx.allocator, out_clean);
            if (err_clean.len > 0) {
                if (out_clean.len > 0) try result_buf.appendSlice(ctx.allocator, "\n");
                try result_buf.appendSlice(ctx.allocator, "stderr:\n");
                try result_buf.appendSlice(ctx.allocator, err_clean);
            }
        }
    }

    if (exit_code != 0 and !signal.isInterrupted()) {
        var ec_buf: [64]u8 = undefined;
        const ec_str = try std.fmt.bufPrint(&ec_buf, "\nCommand exited with code {d}.", .{exit_code});
        try result_buf.appendSlice(ctx.allocator, ec_str);
    }

    const session_content = try result_buf.toOwnedSlice(ctx.allocator);
    return types.ToolResult{
        .session_content = session_content,
        .user_output = if (session_content.len > 0) session_content[0..@min(session_content.len, MAX_USER_OUTPUT)] else null,
        .meta = .{ .bash = .{
            .command = cmd_val.string,
            .exit_code = exit_code,
            .byte_count = raw_total,
            .truncated = stdout_truncated,
            .timed_out = false,
        }},
    };
}

/// Extract the seconds from a Io.Timeout for reporting (0 for .none/.deadline).
fn timeoutSecs(t: Io.Timeout) u32 {
    return switch (t) {
        .duration => |d| @intCast(@max(d.raw.toSeconds(), 1)),
        else => 0,
    };
}

fn isBinaryContent(data: []const u8) bool {
    if (data.len == 0) return false;
    var control: usize = 0;
    const check_len = @min(data.len, 4096);
    for (data[0..check_len]) |b| {
        if (b == 0) return true;
        if (b < 0x20 and b != '\n' and b != '\r' and b != '\t') {
            control += 1;
        }
    }
    return control * 100 / check_len > 30;
}

fn stripAnsi(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, input, 0x1B) == null) return input;
    var buf = std.ArrayListAligned(u8, null).empty;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == 0x1B and i + 1 < input.len and input[i + 1] == '[') {
            i += 2;
            while (i < input.len and input[i] != 'm') i += 1;
            if (i < input.len) i += 1;
        } else {
            try buf.append(allocator, input[i]);
            i += 1;
        }
    }
    return buf.toOwnedSlice(allocator);
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
    const ctx = types.ToolContext{ .allocator = allocator, .io = io, .project_root = "." };
    var result = try testExec(ctx, "{\"command\":\"echo hello\"}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "hello") != null);
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

test "bash: exit code formatting" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const ctx = types.ToolContext{ .allocator = allocator, .io = io, .project_root = "." };
    var result = try testExec(ctx, "{\"command\":\"exit 1\"}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "exited with code 1") != null);
}

test "bash: no output" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const ctx = types.ToolContext{ .allocator = allocator, .io = io, .project_root = "." };
    var result = try testExec(ctx, "{\"command\":\"exit 0\"}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "no output") != null);
}

test "bash: workdir parameter" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const ctx = types.ToolContext{ .allocator = allocator, .io = io, .project_root = "." };
    var result = try testExec(ctx, "{\"command\":\"echo workdir_test\", \"workdir\":\".\"}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "workdir_test") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "exited with code") == null);
}

test "bash: timeout kills long command and reports timed_out" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const ctx = types.ToolContext{ .allocator = allocator, .io = io, .project_root = "." };
    const cmd = if (builtin.os.tag == .windows) "Start-Sleep -Seconds 5" else "sleep 5";
    const args_json = try std.fmt.allocPrint(allocator, "{{\"command\":\"{s}\",\"timeout\":1}}", .{cmd});
    defer allocator.free(args_json);
    var result = try testExec(ctx, args_json);
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "timed out after 1s") != null);
    try std.testing.expect(result.meta.bash.timed_out);
}

test "bash: no timeout keeps blocking (no timed_out)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const ctx = types.ToolContext{ .allocator = allocator, .io = io, .project_root = "." };
    var result = try testExec(ctx, "{\"command\":\"echo ok\"}");
    defer result.deinit(allocator);
    try std.testing.expect(!result.meta.bash.timed_out);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "ok") != null);
}
