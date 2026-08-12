const std = @import("std");
const types = @import("types.zig");

/// Command metadata (pure data). Execution is frontend-local: CLI and Web each
/// map a command name to their own handler (the core registry never imports a
/// frontend).
pub const Command = struct {
    name: []const u8,
    description: []const u8,
    args_hint: []const u8 = "",
    kind: enum { action, prompt },
    source: enum { builtin } = .builtin, // reserved for config/skill sources
};

/// Generate an args hint from an enum's field names, joined by '|'.
/// Comptime-derived so the hint stays in sync with the enum (no drift).
pub fn enumHint(comptime T: type) []const u8 {
    comptime var result: []const u8 = "";
    inline for (@typeInfo(T).@"enum".fields, 0..) |f, i| {
        if (i > 0) result = result ++ "|";
        result = result ++ f.name;
    }
    return result;
}

/// Shared (core) command registry — cross-frontend session operations.
pub const builtin = [_]Command{
    .{ .name = "new", .description = "Start a new session", .kind = .action },
    .{ .name = "name", .description = "Rename current session", .args_hint = "name", .kind = .action },
    .{ .name = "list", .description = "List saved sessions", .kind = .action },
    .{ .name = "load", .description = "Load a session", .args_hint = "name", .kind = .action },
    .{ .name = "fork", .description = "Fork current session", .args_hint = "name", .kind = .action },
    .{ .name = "thinking", .description = "Set thinking level", .args_hint = enumHint(types.ThinkingLevel), .kind = .action },
    .{ .name = "reset", .description = "Reset current session", .kind = .action },
    .{ .name = "delete", .description = "Delete a saved session", .args_hint = "id", .kind = .action },
};

/// Look up a command by name in the shared registry.
pub fn find(name: []const u8) ?*const Command {
    for (&builtin) |*c| {
        if (std.mem.eql(u8, c.name, name)) return c;
    }
    return null;
}

test "command: enumHint joins enum field names" {
    try std.testing.expectEqualStrings("none|minimal|low|medium|high|xhigh|max", enumHint(types.ThinkingLevel));
}

test "command: find returns builtin command" {
    const c = find("fork") orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("fork", c.name);
    try std.testing.expect(c.kind == .action);
    try std.testing.expectEqualStrings("name", c.args_hint);
}

test "command: find unknown returns null" {
    try std.testing.expect(find("nonexistent") == null);
}

test "command: find returns delete command" {
    const c = find("delete") orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("delete", c.name);
    try std.testing.expect(c.kind == .action);
    try std.testing.expectEqualStrings("id", c.args_hint);
}

test "command: thinking hint is enum-derived" {
    const c = find("thinking") orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings(enumHint(types.ThinkingLevel), c.args_hint);
}
