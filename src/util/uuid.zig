const std = @import("std");

/// Generate a UUID v4 (random) string. Caller owns returned memory (allocator).
pub fn v4(allocator: std.mem.Allocator) ![]const u8 {
    var bytes: [16]u8 = undefined;
    var rng = std.Random.DefaultPrng.init(@intFromPtr(&bytes));
    rng.random().bytes(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    var buf: [36]u8 = undefined;
    _ = try std.fmt.bufPrint(&buf, "{s}-{s}-{s}-{s}-{s}", .{
        hex(4, &bytes, 0),
        hex(2, &bytes, 4),
        hex(2, &bytes, 6),
        hex(2, &bytes, 8),
        hex(6, &bytes, 10),
    });
    return allocator.dupe(u8, &buf);
}

fn hex(comptime len: usize, data: *const [16]u8, start: usize) [len * 2]u8 {
    const hex_chars = "0123456789abcdef";
    var result: [len * 2]u8 = undefined;
    for (data[start..start + len], 0..) |b, i| {
        result[i * 2] = hex_chars[b >> 4];
        result[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    return result;
}

pub fn isUuid(s: []const u8) bool {
    if (s.len != 36) return false;
    if (s[8] != '-' or s[13] != '-' or s[18] != '-' or s[23] != '-') return false;
    if (s[14] != '4') return false;
    if (s[19] != '8' and s[19] != '9' and s[19] != 'a' and s[19] != 'b') return false;
    for (s, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) continue;
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}
