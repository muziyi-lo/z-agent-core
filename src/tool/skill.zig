const std = @import("std");
const types = @import("../types.zig");
const path_util = @import("../util/path.zig");

pub const tool_name = "skill";
pub const tool_description = "Load a skill's SKILL.md file from .zagent/skills/<name>/SKILL.md.";
pub const tool_params =
    \\{"type":"object","properties":{"name":{"type":"string","description":"Name of the skill to load"}},"required":["name"]}
;

/// Load a skill's SKILL.md from .zagent/skills/<name>/. Returns allocator-owned ToolResult.
pub fn execute(ctx: types.ToolContext, args_json: []const u8) anyerror!types.ToolResult {
    const args = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{ .ignore_unknown_fields = true }) catch {
        const content = try std.fmt.allocPrint(ctx.allocator, "Error: invalid arguments JSON: {s}", .{args_json});
        return types.ToolResult{
            .session_content = content,
        };
    };
    defer args.deinit();

    const name_val = args.value.object.get("name") orelse {
        const content = try std.fmt.allocPrint(ctx.allocator, "Error: missing 'name' argument", .{});
        return types.ToolResult{
            .session_content = content,
        };
    };
    if (name_val != .string or name_val.string.len == 0) {
        const content = try std.fmt.allocPrint(ctx.allocator, "Error: 'name' must be a non-empty string", .{});
        return types.ToolResult{
            .session_content = content,
        };
    }

    const skill_rel = try std.fmt.allocPrint(ctx.allocator, ".zagent/skills/{s}/SKILL.md", .{name_val.string});
    defer ctx.allocator.free(skill_rel);
    const skill_path = path_util.resolvePath(ctx.allocator, ctx.project_root, skill_rel) catch |err| switch (err) {
        error.PathEscape => {
            const content = try std.fmt.allocPrint(ctx.allocator, "Error: path escapes project root", .{});
            return types.ToolResult{
                .session_content = content,
            };
        },
        else => return err,
    };
    defer ctx.allocator.free(skill_path);

    const file = Io.Dir.cwd().openFile(ctx.io, skill_path, .{ .mode = .read_only }) catch {
        const content = try std.fmt.allocPrint(ctx.allocator, "Error: skill '{s}' not found", .{name_val.string});
        return types.ToolResult{
            .session_content = content,
        };
    };
    defer file.close(ctx.io);

    const size: usize = @intCast((try file.stat(ctx.io)).size);
    const file_content = try ctx.allocator.alloc(u8, size);
    defer ctx.allocator.free(file_content);
    _ = try file.readPositionalAll(ctx.io, file_content, 0);

    var buf = std.ArrayListAligned(u8, null).empty;
    try buf.appendSlice(ctx.allocator, "{\"name\":\"");
    try appendJsonStr(&buf, ctx.allocator, name_val.string);
    try buf.appendSlice(ctx.allocator, "\",\"content\":\"");
    try appendJsonStr(&buf, ctx.allocator, file_content);
    try buf.appendSlice(ctx.allocator, "\"}");

    const session_content = try buf.toOwnedSlice(ctx.allocator);
    return types.ToolResult{
        .session_content = session_content,
    };
}

fn appendJsonStr(buf: *std.ArrayListAligned(u8, null), allocator: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => {
                const hex = try std.fmt.allocPrint(allocator, "\\u{d:0>4}", .{@as(u32, c)});
                defer allocator.free(hex);
                try buf.appendSlice(allocator, hex);
            },
            else => try buf.append(allocator, c),
        }
    }
}

const Io = std.Io;

test "skill: missing skill error" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-skill-missing";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {}; // best-effort cleanup
    try Io.Dir.cwd().createDirPath(io, test_root);
    const test_path = try std.fs.path.join(allocator, &.{ test_root });
    defer allocator.free(test_path);

    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = test_path,
    };

    var result = try execute(ctx, "{\"name\":\"nonexistent\"}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "not found") != null);
}

test "skill: loads skill file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-skill-load";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {}; // best-effort cleanup
    try Io.Dir.cwd().createDirPath(io, test_root);
    const test_path = try std.fs.path.join(allocator, &.{ test_root });
    defer allocator.free(test_path);

    const skills_dir = try std.fs.path.join(allocator, &.{ test_root, ".zagent", "skills", "test-skill" });
    defer allocator.free(skills_dir);
    try Io.Dir.cwd().createDirPath(io, skills_dir);

    const skill_file = try std.fs.path.join(allocator, &.{ test_root, ".zagent", "skills", "test-skill", "SKILL.md" });
    defer allocator.free(skill_file);
    const f = try Io.Dir.cwd().createFile(io, skill_file, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, "skill content here");

    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = test_path,
    };

    var result = try execute(ctx, "{\"name\":\"test-skill\"}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "test-skill") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "skill content here") != null);
}