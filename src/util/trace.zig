const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// Dev-only JSONL event trace (PLAN-LOGGING-SYSTEM P3).
///
/// Enable with `ZAGENT_TRACE=1`. Writes one JSON line per event to
/// `.zagent/log/trace/<ts>-<pid>.jsonl`, plus a `latest.json` pointer (written
/// atomically via tmp + rename under the trace mutex). Default retention: files
/// older than `ZAGENT_TRACE_RETENTION_DAYS` (7) or beyond the newest
/// `ZAGENT_TRACE_MAX_FILES` (100) are deleted at startup (in `trace.init`).
///
/// Lazy-initialized: the first call to init() decides whether tracing is
/// active based on the env var, then caches the result.

var _enabled: bool = false;
var _checked: bool = false;
var _io: ?Io = null;
var _allocator: ?std.mem.Allocator = null;
var _dir: []const u8 = "";
var _file_path: []const u8 = "";
var _file: ?Io.File = null;
var _mutex: std.Io.Mutex = .init;

pub const TRACE_SUBDIR = ".zagent/log/trace";
const DEFAULT_RETENTION_DAYS: i64 = 7;
const DEFAULT_MAX_FILES: usize = 100;

fn isEnabled(allocator: std.mem.Allocator) bool {
    if (_checked) return _enabled;
    _checked = true;
    const env = std.process.Environ{ .block = .{ .use_global = true } };
    var map = env.createMap(allocator) catch return false;
    defer map.deinit();
    const v = map.get("ZAGENT_TRACE") orelse return false;
    _enabled = std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true");
    return _enabled;
}

fn nowMs() i64 {
    const io = _io orelse return 0;
    return @as(i64, @intCast(Io.Timestamp.toMilliseconds(Io.Clock.Timestamp.now(io, .real).raw)));
}

fn processId() u32 {
    if (builtin.os.tag == .windows) {
        return std.os.windows.GetCurrentProcessId();
    }
    return @intCast(std.posix.getpid());
}

/// Initialize trace: read env, create the trace directory, open the per-process
/// file, and run startup cleanup (retention by days and by file count). Called
/// from both entry points so CLI/Web behave identically.
pub fn init(allocator: std.mem.Allocator, io: Io, project_root: []const u8) void {
    if (!isEnabled(allocator)) return;
    _io = io;
    _allocator = allocator;

    const dir = std.fs.path.join(allocator, &.{ project_root, TRACE_SUBDIR }) catch return;
    _dir = dir;
    Io.Dir.cwd().createDirPath(io, dir) catch return;

    _file_path = std.fmt.allocPrint(allocator, "{s}/{d}-{d}.jsonl", .{ dir, @divTrunc(nowMs(), 1000), processId() }) catch return;
    _file = Io.Dir.cwd().createFile(io, _file_path, .{}) catch null;
    writeLatest(io);
    cleanup(io, allocator, dir);
}

fn writeLatest(io: Io) void {
    if (_file_path.len == 0) return;
    const a = _allocator orelse return;
    const latest = std.fs.path.join(a, &.{ _dir, "latest.json" }) catch return;
    defer a.free(latest);
    const tmp = std.fs.path.join(a, &.{ _dir, "latest.json.tmp" }) catch return;
    defer a.free(tmp);
    const f = Io.Dir.cwd().createFile(io, tmp, .{}) catch return;
    f.writeStreamingAll(io, _file_path) catch {
        f.close(io);
        // M-04: clean up the temp file so a failed latest.json write leaves no residue.
        Io.Dir.cwd().deleteFile(io, tmp) catch {};
        return;
    };
    f.close(io);
    Io.Dir.rename(Io.Dir.cwd(), tmp, Io.Dir.cwd(), latest, io) catch {};
}

/// Startup cleanup: delete trace files older than the retention window OR
/// beyond the newest N files. `latest.json` is kept.
fn cleanup(io: Io, allocator: std.mem.Allocator, dir: []const u8) void {
    const env = std.process.Environ{ .block = .{ .use_global = true } };
    var map = env.createMap(allocator) catch return;
    defer map.deinit();

    var retention_days: i64 = DEFAULT_RETENTION_DAYS;
    if (map.get("ZAGENT_TRACE_RETENTION_DAYS")) |v| {
        retention_days = std.fmt.parseInt(i64, v, 10) catch DEFAULT_RETENTION_DAYS;
    }
    var max_files: usize = DEFAULT_MAX_FILES;
    if (map.get("ZAGENT_TRACE_MAX_FILES")) |v| {
        max_files = std.fmt.parseInt(usize, v, 10) catch DEFAULT_MAX_FILES;
    }

    var names: std.ArrayListAligned([]const u8, null) = .empty;
    defer {
        for (names.items) |n| allocator.free(@constCast(n));
        names.deinit(allocator);
    }

    var it_dir = Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
    defer it_dir.close(io);
    var iter = it_dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".jsonl") and !std.mem.eql(u8, entry.name, "latest.json")) {
            names.append(allocator, allocator.dupe(u8, entry.name) catch continue) catch continue;
        }
    }
    if (names.items.len == 0) return;

    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    const now_secs = @divTrunc(nowMs(), 1000);
    var kept: usize = 0;
    var i: usize = names.items.len;
    while (i > 0) {
        i -= 1;
        const name = names.items[i];
        if (kept >= max_files) {
            deleteTrace(io, dir, name);
            continue;
        }
        // Filename is "<secs>-<pid>.jsonl"; parse the leading integer.
        const dash = std.mem.indexOfScalar(u8, name, '-') orelse {
            deleteTrace(io, dir, name);
            continue;
        };
        const secs = std.fmt.parseInt(i64, name[0..dash], 10) catch {
            deleteTrace(io, dir, name);
            continue;
        };
        const age_days = @divTrunc(now_secs - secs, 86400);
        if (age_days > retention_days) {
            deleteTrace(io, dir, name);
            continue;
        }
        kept += 1;
    }
}

fn deleteTrace(io: Io, dir: []const u8, name: []const u8) void {
    var buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch return;
    Io.Dir.cwd().deleteFile(io, path) catch {};
}

/// Write one JSONL event line to the per-process trace file (no-op unless
/// `ZAGENT_TRACE=1`). `data` must be a pre-escaped JSON fragment (object or
/// string) — trace does no escaping of its own (I-01): callers building `data`
/// with user-controlled strings must escape quotes/backslashes first.
pub fn write(type_: []const u8, tid: u32, rid: u32, data: []const u8) void {
    const io = _io orelse return;
    if (!_enabled) return;
    _mutex.lock(io) catch return;
    defer _mutex.unlock(io);

    const f = _file orelse return;
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{{\"ts\":{d},\"type\":\"{s}\",\"tid\":{d},\"rid\":{d},\"data\":{s}}}\n", .{ nowMs(), type_, tid, rid, data }) catch return;
    f.writeStreamingAll(io, line) catch {};
}

test "trace: TRACE_SUBDIR matches log" {
    try std.testing.expectEqualStrings(".zagent/log/trace", TRACE_SUBDIR);
}
