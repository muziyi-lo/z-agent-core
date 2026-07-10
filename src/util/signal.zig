const std = @import("std");
const builtin = @import("builtin");

var interrupted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Check if Ctrl+C has been received. Acquire-ordered atomic load.
pub fn isInterrupted() bool {
    return interrupted.load(.acquire);
}

/// Signal that an interrupt has been received. Release-ordered atomic store.
pub fn setInterrupted() void {
    interrupted.store(true, .release);
}

/// Reset the interrupt state (used after handling or in tests).
pub fn reset() void {
    interrupted.store(false, .release);
}

/// Register OS-level Ctrl+C handler. Windows: SetConsoleCtrlHandler.
/// Must be called once at startup before any signal-sensitive operations.
pub fn init(io: std.Io) void {
    _ = io;
    if (builtin.os.tag == .windows) {
        const windows = struct {
            extern "kernel32" fn SetConsoleCtrlHandler(
                handler_routine: ?*const fn (dwCtrlType: u32) callconv(.winapi) u32,
                add: u32,
            ) callconv(.winapi) u32;
        };
        _ = windows.SetConsoleCtrlHandler(ctrlHandler, 1);
    }
}

fn ctrlHandler(dwCtrlType: u32) callconv(.winapi) u32 {
    _ = dwCtrlType;
    setInterrupted();
    return 1;
}

test "signal not interrupted by default" {
    try std.testing.expect(!isInterrupted());
}

test "signal set and reset" {
    setInterrupted();
    try std.testing.expect(isInterrupted());
    reset();
    try std.testing.expect(!isInterrupted());
}

test "signal init registers without crash" {
    reset();
    init(std.testing.io);
    try std.testing.expect(!isInterrupted());
}
