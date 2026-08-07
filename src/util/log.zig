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

pub const Level = enum(u8) {
    error_,
    warn,
    info,
    debug,
    trace,
};

var current_level: std.atomic.Value(Level) = std.atomic.Value(Level).init(.debug);

pub fn init(io: Io, level: Level) void {
    _io = io;
    current_level.store(level, .release);
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
