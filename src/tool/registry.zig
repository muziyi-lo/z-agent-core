const std = @import("std");
const types = @import("../types.zig");
const read_tool = @import("read.zig");
const write_tool = @import("write.zig");
const bash_tool = @import("bash.zig");
const grep_tool = @import("grep.zig");
const glob_tool = @import("glob.zig");
const skill_tool = @import("skill.zig");

/// Registered tool handler: name, LLM description, JSON params schema, execute function.
pub const ToolEntry = struct {
    name: []const u8,
    description: []const u8,
    params: []const u8,
    /// Returns allocator-owned result slice; caller must free with ctx.allocator.
    execute: *const fn (ctx: types.ToolContext, args: []const u8) anyerror![]const u8,
};

/// Tool registry dispatched by name. Holds compile-time array of ToolEntry.
pub const Registry = struct {
    handlers: []const ToolEntry,

    /// Look up tool by name and execute. Unknown names return error string.
    /// Returns ctx.allocator-owned slice; caller must free.
    pub fn execute(self: Registry, ctx: types.ToolContext, name: []const u8, args_json: []const u8) anyerror![]const u8 {
        for (self.handlers) |h| {
            if (std.mem.eql(u8, h.name, name)) {
                return h.execute(ctx, args_json);
            }
        }
        return try std.fmt.allocPrint(ctx.allocator, "Error: unknown tool '{s}'", .{name});
    }

    /// Convert handlers to Tool array for OpenAI API. Caller owns returned slice.
    pub fn toTools(self: Registry, allocator: std.mem.Allocator) ![]types.Tool {
        var list = std.ArrayListAligned(types.Tool, null).empty;
        for (self.handlers) |h| {
            try list.append(allocator, .{
                .name = h.name,
                .description = h.description,
                .params = h.params,
                .execute = h.execute,
            });
        }
        return list.toOwnedSlice(allocator);
    }
};

/// Build the default registry with all built-in tools (read, write, bash, grep, glob, skill).
pub fn buildRegistry() Registry {
    return .{
        .handlers = &.{
            .{ .name = read_tool.tool_name, .description = read_tool.tool_description, .params = read_tool.tool_params, .execute = read_tool.execute },
            .{ .name = write_tool.tool_name, .description = write_tool.tool_description, .params = write_tool.tool_params, .execute = write_tool.execute },
            .{ .name = bash_tool.tool_name, .description = bash_tool.tool_description, .params = bash_tool.tool_params, .execute = bash_tool.execute },
            .{ .name = grep_tool.tool_name, .description = grep_tool.tool_description, .params = grep_tool.tool_params, .execute = grep_tool.execute },
            .{ .name = glob_tool.tool_name, .description = glob_tool.tool_description, .params = glob_tool.tool_params, .execute = glob_tool.execute },
            .{ .name = skill_tool.tool_name, .description = skill_tool.tool_description, .params = skill_tool.tool_params, .execute = skill_tool.execute },
        },
    };
}

test "registry: match and execute" {
    const reg = buildRegistry();

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var dbuf: [256]u8 = undefined;
    var dw: std.Io.File.Writer = .init(.stderr(), io, &dbuf);
    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = ".",
        .display_writer = &dw.interface,
    };

    const result = try reg.execute(ctx, "read", "{}");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "missing") != null);
}

test "registry: unknown tool error" {
    const reg = buildRegistry();

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var dbuf: [256]u8 = undefined;
    var dw: std.Io.File.Writer = .init(.stderr(), io, &dbuf);
    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = ".",
        .display_writer = &dw.interface,
    };

    const result = try reg.execute(ctx, "nonexistent", "{}");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "unknown") != null);
}

test "registry: toTools generates array" {
    const reg = buildRegistry();
    const tools = try reg.toTools(std.testing.allocator);
    defer std.testing.allocator.free(tools);

    try std.testing.expect(tools.len == 6);
    try std.testing.expect(std.mem.eql(u8, tools[0].name, "read"));
    try std.testing.expect(std.mem.eql(u8, tools[1].name, "write"));
    try std.testing.expect(std.mem.eql(u8, tools[5].name, "skill"));
}
