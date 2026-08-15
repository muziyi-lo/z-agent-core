const std = @import("std");

/// Trim whitespace from both ends. Returns slice borrowed from input.
pub fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

/// Max bytes a tool accumulates before stopping collection (collection cutoff).
/// Unit: BYTES. Matches the legacy 50*1024 limit in grep/glob.
pub const TOOL_COLLECT_LIMIT: usize = 50 * 1024;

/// Binary-sniff check window, in BYTES (first bytes only).
pub const BINARY_CHECK_SIZE: usize = 4096;

/// Control-char ratio threshold, in percent (control*100/len > 30 means binary).
pub const BINARY_CONTROL_RATIO: usize = 30;

/// Binary-sniff check over a byte slice: NUL byte anywhere in the check
/// window or a control-char ratio above BINARY_CONTROL_RATIO marks binary.
/// Same semantics as the legacy bash/read implementations.
pub fn isBinary(data: []const u8) bool {
    if (data.len == 0) return false;
    const check_len = @min(data.len, BINARY_CHECK_SIZE);
    var control: usize = 0;
    for (data[0..check_len]) |b| {
        if (b == 0) return true;
        if (b < 0x20 and b != '\n' and b != '\r' and b != '\t') control += 1;
    }
    return control * 100 / check_len > BINARY_CONTROL_RATIO;
}

test "trim spaces" {
    try std.testing.expectEqualStrings("hello", trim("  hello  "));
}

test "trim empty" {
    try std.testing.expectEqualStrings("", trim("   "));
}

fn legacyIsBinary(data: []const u8) bool {
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

fn expectSameAsLegacy(data: []const u8) !void {
    try std.testing.expectEqual(legacyIsBinary(data), isBinary(data));
}

test "isBinary: empty" {
    try std.testing.expectEqual(false, isBinary(&[_]u8{}));
    try expectSameAsLegacy(&[_]u8{});
}

test "isBinary: length exactly window (all text)" {
    const data = "a" ** 4096;
    try std.testing.expectEqual(false, isBinary(data));
    try expectSameAsLegacy(data);
}

test "isBinary: window truncation (control char outside window)" {
    var data: [4097]u8 = [_]u8{'a'} ** 4097;
    data[4096] = 0x01;
    try std.testing.expectEqual(false, isBinary(&data));
    try expectSameAsLegacy(&data);
}

test "isBinary: NUL early return" {
    const data = "ab\x00cd";
    try std.testing.expectEqual(true, isBinary(data));
    try expectSameAsLegacy(data);
}

test "isBinary: control ratio exactly 30% (false, strict greater)" {
    const data = "\x01\x01\x01" ++ "aaaaaaa";
    try std.testing.expectEqual(false, isBinary(data));
    try expectSameAsLegacy(data);
}

test "isBinary: control ratio 30%+1 (true)" {
    const data = "\x01\x01\x01\x01" ++ "aaaaaa";
    try std.testing.expectEqual(true, isBinary(data));
    try expectSameAsLegacy(data);
}

test "isBinary: tab/newline/carriage-return not control" {
    const data = "\t\n\r" ++ "aaaaaaa";
    try std.testing.expectEqual(false, isBinary(data));
    try expectSameAsLegacy(data);
}
