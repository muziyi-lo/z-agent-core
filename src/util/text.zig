const std = @import("std");

/// Trim whitespace from both ends. Returns slice borrowed from input.
pub fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

test "trim spaces" {
    try std.testing.expectEqualStrings("hello", trim("  hello  "));
}

test "trim empty" {
    try std.testing.expectEqualStrings("", trim("   "));
}
