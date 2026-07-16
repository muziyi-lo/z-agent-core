const std = @import("std");
const types = @import("../types.zig");
const read_tool = @import("read.zig");
const write_tool = @import("write.zig");
const bash_tool = @import("bash.zig");
const grep_tool = @import("grep.zig");
const glob_tool = @import("glob.zig");
const skill_tool = @import("skill.zig");
const edit_tool = @import("edit.zig");
const compact_tool = @import("compact.zig");

pub const ToolEntry = struct {
    name: []const u8,
    description: []const u8,
    params: []const u8,
    validate: ?*const fn (args: std.json.Value) ?[]const u8 = null,
    execute: *const fn (ctx: types.ToolContext, args: std.json.Value) anyerror!types.ToolResult,
};

pub const Registry = struct {
    handlers: []const ToolEntry,

    pub fn execute(self: Registry, ctx: types.ToolContext, name: []const u8, args_json: []const u8) anyerror!types.ToolResult {
        const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{ .ignore_unknown_fields = true }) catch {
            const msg = try std.fmt.allocPrint(ctx.allocator, "Error: invalid arguments JSON", .{});
            return types.ToolResult{ .session_content = msg };
        };
        defer parsed.deinit();

        for (self.handlers) |h| {
            if (std.mem.eql(u8, h.name, name)) {
                if (h.validate) |v| {
                    if (v(parsed.value)) |err| {
                        const msg = try std.fmt.allocPrint(ctx.allocator, "{s}", .{err});
                        return types.ToolResult{ .session_content = msg, .err_msg = err };
                    }
                }
                return h.execute(ctx, parsed.value);
            }
        }
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: unknown tool '{s}'", .{name});
        return types.ToolResult{ .session_content = msg };
    }

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
            .{ .name = edit_tool.tool_name, .description = edit_tool.tool_description, .params = edit_tool.tool_params, .execute = edit_tool.execute },
            .{ .name = compact_tool.tool_name, .description = compact_tool.tool_description, .params = compact_tool.tool_params, .execute = compact_tool.execute },
        },
    };
}

test "registry: match and execute" {
    const reg = buildRegistry();

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = ".",
    };

    var result = try reg.execute(ctx, "read", "{}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "missing") != null);
}

test "registry: unknown tool error" {
    const reg = buildRegistry();

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = ".",
    };

    var result = try reg.execute(ctx, "nonexistent", "{}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "unknown") != null);
}

test "registry: toTools generates array" {
    const reg = buildRegistry();
    const tools = try reg.toTools(std.testing.allocator);
    defer std.testing.allocator.free(tools);

    try std.testing.expect(tools.len == 8);
    try std.testing.expect(std.mem.eql(u8, tools[0].name, "read"));
    try std.testing.expect(std.mem.eql(u8, tools[1].name, "write"));
    try std.testing.expect(std.mem.eql(u8, tools[5].name, "skill"));
}
