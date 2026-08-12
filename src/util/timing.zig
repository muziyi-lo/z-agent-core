const std = @import("std");
const Io = std.Io;
const trace = @import("trace.zig");

/// Stage timing instrumentation (PLAN-LOGGING-SYSTEM P4).
///
/// `timing.mark(label)` records the elapsed ms since the previous mark.
/// - When `ZAGENT_TRACE=1`: writes a `type:"timing"` event into the trace JSONL
///   so one file carries both behavior and duration.
/// - When `ZAGENT_TIMING=1`: additionally prints `label: Xms` lines to stderr.
/// The two switches are orthogonal.

var _io: ?Io = null;
var _last_ms: i64 = 0;
var _started: bool = false;
var _timing_enabled: bool = false;
var _timing_checked: bool = false;

pub fn init(io: Io) void {
    _io = io;
}

fn timingEnabled() bool {
    if (_timing_checked) return _timing_enabled;
    _timing_checked = true;
    const env = std.process.Environ{ .block = .{ .use_global = true } };
    var map = env.createMap(std.heap.page_allocator) catch return false;
    defer map.deinit();
    const v = map.get("ZAGENT_TIMING") orelse return false;
    _timing_enabled = std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true");
    return _timing_enabled;
}

fn nowMs() i64 {
    const io = _io orelse return 0;
    return @as(i64, @intCast(Io.Timestamp.toMilliseconds(Io.Clock.Timestamp.now(io, .real).raw)));
}

/// Record the elapsed time since the previous mark under `label`.
pub fn mark(label: []const u8, tid: u32, rid: u32) void {
    const now = nowMs();
    const ms: i64 = if (_started) now - _last_ms else 0;
    _last_ms = now;
    _started = true;

    var buf: [128]u8 = undefined;
    const data = std.fmt.bufPrint(&buf, "{{\"label\":\"{s}\",\"ms\":{d}}}", .{ label, ms }) catch return;
    trace.write("timing", tid, rid, data);

    if (timingEnabled()) {
        var obuf: [256]u8 = undefined;
        const io = _io orelse return;
        var ow: Io.File.Writer = .init(.stderr(), io, &obuf);
        ow.interface.print("  {s}: {d}ms\n", .{ label, ms }) catch {};
        ow.interface.flush() catch {};
    }
}

test "timing: labels accept empty" {
    // No-op coverage: mark without init must not crash.
    mark("", 0, 0);
}
