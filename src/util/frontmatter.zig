const std = @import("std");

/// Parse a field from YAML frontmatter (`---\nkey: value\n---`).
/// Returns a borrowed slice into content; null if there is no frontmatter or
/// the field is missing/empty. No allocation.
pub fn parseField(content: []const u8, comptime field: []const u8) ?[]const u8 {
    if (content.len < 3 or !std.mem.eql(u8, content[0..3], "---")) return null;
    const normalized = content[3..];
    const end = std.mem.indexOfPosLinear(u8, normalized, 0, "---") orelse return null;
    const fm = normalized[0..end];

    const prefix = field ++ ":";
    const pos = std.mem.indexOfPosLinear(u8, fm, 0, prefix) orelse return null;
    const value_start = pos + prefix.len;
    const line_end = std.mem.indexOfScalarPos(u8, fm, value_start, '\n') orelse fm.len;
    var val = fm[value_start..line_end];
    val = std.mem.trim(u8, val, " \t\r");
    if (val.len == 0) return null;
    return val;
}

test "frontmatter: parseField returns field value" {
    const content =
        \\---
        \\name: memory-manager
        \\description: 管理 AI 记忆——记录经验、召回知识
        \\---
        \\
        \\# Body
    ;
    const d = parseField(content, "description") orelse return error.TestUnexpectedNull;
    try std.testing.expect(std.mem.eql(u8, d, "管理 AI 记忆——记录经验、召回知识"));
}

test "frontmatter: parseField no frontmatter returns null" {
    const content = "plain text description: xxx";
    try std.testing.expect(parseField(content, "description") == null);
}

test "frontmatter: parseField empty value returns null" {
    const content =
        \\---
        \\description:   
        \\---
    ;
    try std.testing.expect(parseField(content, "description") == null);
}

test "frontmatter: parseField missing field returns null" {
    const content =
        \\---
        \\name: x
        \\---
    ;
    try std.testing.expect(parseField(content, "description") == null);
}
