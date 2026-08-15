const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;

const WinApi = struct {
    const SYSTEMTIME = extern struct {
        wYear: u16,
        wMonth: u16,
        wDayOfWeek: u16,
        wDay: u16,
        wHour: u16,
        wMinute: u16,
        wSecond: u16,
        wMilliseconds: u16,
    };
    extern "kernel32" fn GetLocalTime(lpSystemTime: *SYSTEMTIME) callconv(.winapi) void;
};

fn getLocalTime(io: Io) struct { h: u32, m: u32, s: u32, ms: u32 } {
    if (builtin.os.tag == .windows) {
        var st: WinApi.SYSTEMTIME = undefined;
        WinApi.GetLocalTime(&st);
        return .{ .h = st.wHour, .m = st.wMinute, .s = st.wSecond, .ms = st.wMilliseconds };
    }
    const now = Io.Timestamp.toMilliseconds(Io.Clock.Timestamp.now(io, .real).raw);
    const secs: u64 = @intCast(@divTrunc(now, 1000));
    const ms: u32 = @intCast(@mod(now, 1000));
    return .{
        .h = @intCast((secs / 3600) % 24),
        .m = @intCast((secs / 60) % 60),
        .s = @intCast(secs % 60),
        .ms = ms,
    };
}

var _io: ?Io = null;
var _allocator: ?std.mem.Allocator = null;

pub const Level = enum(u8) {
    error_,
    warn,
    info,
    debug,
    trace,
};

var current_level: std.atomic.Value(Level) = std.atomic.Value(Level).init(.info);

/// Parse a level name from `ZAGENT_LOG_LEVEL` env (trace/debug/info/warn/error).
/// Unknown or empty values fall back to info.
pub fn parseLevel(s: []const u8) Level {
    if (std.mem.eql(u8, s, "trace")) return .trace;
    if (std.mem.eql(u8, s, "debug")) return .debug;
    if (std.mem.eql(u8, s, "info")) return .info;
    if (std.mem.eql(u8, s, "warn")) return .warn;
    if (std.mem.eql(u8, s, "error")) return .error_;
    return .info;
}

/// Log file settings (P2/P2.5 of PLAN-LOGGING-SYSTEM).
pub const MAX_LOG_SIZE: u64 = 5 * 1024 * 1024;
pub const MAX_ROTATIONS: usize = 3;
pub const LOG_SUBDIR = ".zagent/log";
pub const TRACE_SUBDIR = ".zagent/log/trace";
pub const LOG_FILENAME = "z-agent-core.log";

// File-backed logging state. Guarded by _log_mutex (multi-request threads).
var _log_mutex: std.Io.Mutex = .init;
var _log_file: ?Io.File = null;
var _log_path: []const u8 = "";
var _log_dir: []const u8 = "";
var _file_size: u64 = 0;
var _io_broken: bool = false;

/// Initialize the logger: read `ZAGENT_LOG_LEVEL`, create log directories under
/// `project_root`, open the main log file. Must be called once from both the
/// CLI and Web entry points (server.zig:138 already; cli/main.zig to be added).
pub fn init(allocator: std.mem.Allocator, io: Io, project_root: []const u8) void {
    _io = io;
    _allocator = allocator;

    const env = std.process.Environ{ .block = .{ .use_global = true } };
    var env_map = env.createMap(allocator) catch null;
    defer if (env_map) |*m| m.deinit();
    if (env_map) |m| {
        if (m.get("ZAGENT_LOG_LEVEL")) |v| {
            current_level.store(parseLevel(v), .release);
        }
    }

    const dir_path = std.fs.path.join(allocator, &.{ project_root, LOG_SUBDIR }) catch return;
    _log_dir = dir_path;
    _log_path = std.fs.path.join(allocator, &.{ dir_path, LOG_FILENAME }) catch return;

    Io.Dir.cwd().createDirPath(io, dir_path) catch {};
    // Trace directory is created by the trace module on demand; pre-create here
    // so both entry points behave identically (P2.5 cleanup runs in init).
    const trace_dir = std.fs.path.join(allocator, &.{ project_root, TRACE_SUBDIR }) catch return;
    Io.Dir.cwd().createDirPath(io, trace_dir) catch {};

    _log_file = Io.Dir.cwd().createFile(io, _log_path, .{ .truncate = false }) catch {
        _io_broken = true;
        return;
    };
    _file_size = blk: {
        const st = _log_file.?.stat(io) catch break :blk 0;
        break :blk @as(u64, @intCast(st.size));
    };
}

/// Close the main log file. Called by CLI/Web entry points on normal exit;
/// Zig has no atexit hook — a panic leaves the file to the OS (which also
/// reaps the handle). Writes are flushed per line, so no buffered data is lost.
pub fn deinit() void {
    const io = _io orelse return;
    _log_mutex.lock(io) catch return;
    defer _log_mutex.unlock(io);
    if (_log_file) |f| f.close(io);
    _log_file = null;
    if (_allocator) |a| {
        if (_log_path.len > 0) a.free(@constCast(_log_path));
        if (_log_dir.len > 0) a.free(@constCast(_log_dir));
        _log_path = "";
        _log_dir = "";
    }
}

/// Rotate the main log: `.log` → `.log.1` → `.log.2`, dropping the oldest.
/// Must be called with _log_mutex held. Silent on failure (E-05 rationale):
/// rotation is best-effort — a failed rename leaves the previous file intact
/// and the next write re-tries; never failing the log path is more important
/// than rotating. Caller re-opens a fresh file afterwards.
fn rotateLocked(io: Io) void {
    const f = _log_file orelse return;
    f.close(io);
    _log_file = null;

    var buf: [512]u8 = undefined;
    var buf2: [512]u8 = undefined;

    const oldest = std.fmt.bufPrint(&buf, "{s}.{d}", .{ _log_path, MAX_ROTATIONS - 1 }) catch return;
    Io.Dir.cwd().deleteFile(io, oldest) catch {};

    var i: usize = MAX_ROTATIONS - 1;
    while (i > 1) : (i -= 1) {
        const src = std.fmt.bufPrint(&buf, "{s}.{d}", .{ _log_path, i - 1 }) catch return;
        const dst = std.fmt.bufPrint(&buf2, "{s}.{d}", .{ _log_path, i }) catch return;
        Io.Dir.rename(Io.Dir.cwd(), src, Io.Dir.cwd(), dst, io) catch {};
    }
    {
        const dst = std.fmt.bufPrint(&buf, "{s}.1", .{_log_path}) catch return;
        Io.Dir.rename(Io.Dir.cwd(), _log_path, Io.Dir.cwd(), dst, io) catch {};
    }

    _log_file = Io.Dir.cwd().createFile(io, _log_path, .{}) catch {
        _io_broken = true;
        return;
    };
    _file_size = 0;
}

/// Append a plain (ANSI-stripped) line to the main log file. On disk-full /
/// permission errors set the broken flag once and fall back to stderr only.
fn writeFile(io: Io, msg: []const u8) void {
    _log_mutex.lock(io) catch return;
    defer _log_mutex.unlock(io);
    if (_io_broken) return;
    if (_log_file == null) return;
    if (_file_size + msg.len > MAX_LOG_SIZE) rotateLocked(io);
    const f2 = _log_file orelse return;
    f2.writePositionalAll(io, msg, _file_size) catch {
        _io_broken = true;
        return;
    };
    _file_size += msg.len;
}

fn shouldLog(level: Level) bool {
    const cur = current_level.load(.acquire);
    return @intFromEnum(cur) >= @intFromEnum(level);
}

fn colorCode(level: Level) []const u8 {
    return switch (level) {
        .error_ => "\x1b[31m",
        .warn => "\x1b[33m",
        .info => "\x1b[32m",
        .debug => "\x1b[36m",
        .trace => "\x1b[90m",
    };
}

fn levelName(level: Level) []const u8 {
    return switch (level) {
        .error_ => "ERROR",
        .warn => "WARN ",
        .info => "INFO ",
        .debug => "DEBUG",
        .trace => "TRACE",
    };
}

fn writeLog(tid: u32, rid: u32, level: Level, event: []const u8, comptime extra: []const u8, args: anytype) void {
    if (!shouldLog(level)) return;
    const io = _io orelse return;

    const lt = getLocalTime(io);
    const h = lt.h;
    const m = lt.m;
    const s = lt.s;
    const ms = lt.ms;

    var buf: [512]u8 = undefined;
    var extra_buf: [256]u8 = undefined;

    const extra_str: []const u8 = if (extra.len > 0)
        std.fmt.bufPrint(&extra_buf, extra, args) catch "?"
    else
        "";

    const msg = std.fmt.bufPrint(&buf, "\x1b[0m[{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}] {s}[{s}]\x1b[0m [TID:{d}] ctx:r{d} event={s} {s}\n", .{ h, m, s, ms, colorCode(level), levelName(level), tid, rid, event, extra_str }) catch return;

    var obuf: [256]u8 = undefined;
    var ow: Io.File.Writer = .init(.stderr(), io, &obuf);
    ow.interface.writeAll(msg) catch {};
    ow.interface.flush() catch {};

    var plain_buf: [512]u8 = undefined;
    const plain_msg = std.fmt.bufPrint(&plain_buf, "[{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}] [{s}] [TID:{d}] ctx:r{d} event={s} {s}\n", .{ h, m, s, ms, levelName(level), tid, rid, event, extra_str }) catch return;
    writeFile(io, plain_msg);
}

pub fn info(comptime event: []const u8, comptime extra: []const u8, args: anytype) void {
    writeLog(0, 0, .info, event, extra, args);
}

pub fn errorLog(comptime event: []const u8, comptime extra: []const u8, args: anytype) void {
    writeLog(0, 0, .error_, event, extra, args);
}

pub fn req_info(tid: u32, rid: u32, comptime event: []const u8, comptime extra: []const u8, args: anytype) void {
    writeLog(tid, rid, .info, event, extra, args);
}

pub fn req_warn(tid: u32, rid: u32, comptime event: []const u8, comptime extra: []const u8, args: anytype) void {
    writeLog(tid, rid, .warn, event, extra, args);
}

pub fn biz_info(tid: u32, rid: u32, comptime event: []const u8, comptime extra: []const u8, args: anytype) void {
    writeLog(tid, rid, .info, event, extra, args);
}

pub fn biz_error(tid: u32, rid: u32, comptime event: []const u8, comptime extra: []const u8, args: anytype) void {
    writeLog(tid, rid, .error_, event, extra, args);
}

pub fn dbg(tid: u32, rid: u32, comptime event: []const u8, comptime extra: []const u8, args: anytype) void {
    writeLog(tid, rid, .debug, event, extra, args);
}

pub fn trace(tid: u32, rid: u32, comptime event: []const u8, comptime extra: []const u8, args: anytype) void {
    writeLog(tid, rid, .trace, event, extra, args);
}

test "log: parseLevel maps names" {
    try std.testing.expectEqual(Level.trace, parseLevel("trace"));
    try std.testing.expectEqual(Level.debug, parseLevel("debug"));
    try std.testing.expectEqual(Level.info, parseLevel("info"));
    try std.testing.expectEqual(Level.warn, parseLevel("warn"));
    try std.testing.expectEqual(Level.error_, parseLevel("error"));
    try std.testing.expectEqual(Level.info, parseLevel("bogus"));
    try std.testing.expectEqual(Level.info, parseLevel(""));
}
