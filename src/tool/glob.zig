const std = @import("std");
const types = @import("../types.zig");
const path_util = @import("../util/path.zig");
const text_util = @import("../util/text.zig");

pub const tool_name = "glob";
pub const tool_description = "Find files matching a glob pattern. Supports recursive search with **.";
pub const tool_params =
    \\{"type":"object","properties":{"pattern":{"type":"string","description":"Glob pattern (e.g. *.zig, src/**/*.zig)"},"path":{"type":"string","description":"Base directory (default \".\")"}},"required":["pattern"]}
;

const MAX_ENTRIES: usize = 1000;

/// Find files matching a glob pattern. Supports recursive **. Returns allocator-owned ToolResult.
pub fn execute(ctx: types.ToolContext, args: std.json.Value) anyerror!types.ToolResult {
    const pattern_val = args.object.get("pattern") orelse {
        const content = try std.fmt.allocPrint(ctx.allocator, "Error: missing 'pattern' argument", .{});
        return types.ToolResult{
            .session_content = content,
        };
    };
    if (pattern_val != .string or pattern_val.string.len == 0) {
        const content = try std.fmt.allocPrint(ctx.allocator, "Error: 'pattern' must be a non-empty string", .{});
        return types.ToolResult{
            .session_content = content,
        };
    }

    const path_arg: []const u8 = if (args.object.get("path")) |p|
        if (p == .string) p.string else "."
    else
        ".";

    const resolved = path_util.resolvePath(ctx.allocator, ctx.project_root, path_arg) catch |err| switch (err) {
        error.PathEscape => {
            const content = try std.fmt.allocPrint(ctx.allocator, "Error: path escapes project root", .{});
            return types.ToolResult{
                .session_content = content,
            };
        },
        else => return err,
    };
    defer ctx.allocator.free(resolved);

    const dir = Io.Dir.cwd().openDir(ctx.io, resolved, .{ .iterate = true }) catch |err| {
        const content = try std.fmt.allocPrint(ctx.allocator, "Error: cannot open directory '{s}': {s}", .{ path_arg, @errorName(err) });
        return types.ToolResult{
            .session_content = content,
        };
    };
    defer dir.close(ctx.io);

    var buf = std.ArrayListAligned(u8, null).empty;
    var count: usize = 0;
    var truncated = false;

    try walkDir(ctx, &buf, dir, pattern_val.string, path_arg, &count, &truncated);

    if (count == 0) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "No files matched '{s}' in {s}", .{ pattern_val.string, path_arg });
        return types.ToolResult{
            .session_content = msg,
            .meta = .{ .glob = .{
                .pattern = pattern_val.string,
                .path = if (path_arg.len > 0) path_arg else null,
                .file_count = 0,
                .truncated = false,
            }},
        };
    }
    if (truncated) {
        try buf.appendSlice(ctx.allocator, "[truncated]\n");
    }

    const session_content = try buf.toOwnedSlice(ctx.allocator);
    return types.ToolResult{
        .session_content = session_content,
        .meta = .{ .glob = .{
            .pattern = pattern_val.string,
            .path = if (path_arg.len > 0) path_arg else null,
            .file_count = count,
            .truncated = truncated,
        }},
    };
}

fn walkDir(ctx: types.ToolContext, buf: *std.ArrayListAligned(u8, null), dir: Io.Dir, pattern: []const u8, prefix: []const u8, count: *usize, truncated: *bool) !void {
    var iter = dir.iterate();
    while (try iter.next(ctx.io)) |entry| {
        if (buf.items.len >= text_util.TOOL_COLLECT_LIMIT or count.* >= MAX_ENTRIES) {
            truncated.* = true;
            return;
        }

        const full_path = if (prefix.len == 0 or std.mem.eql(u8, prefix, "."))
            try ctx.allocator.dupe(u8, entry.name)
        else if (std.mem.endsWith(u8, prefix, "/") or std.mem.endsWith(u8, prefix, "\\"))
            try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ prefix, entry.name })
        else
            try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ prefix, entry.name });
        defer ctx.allocator.free(full_path);

        if (matchEntry(entry.name, pattern)) {
            count.* += 1;
            try buf.appendSlice(ctx.allocator, full_path);
            try buf.append(ctx.allocator, '\n');
        }

        if (entry.kind == .directory) {
            if (dir.openDir(ctx.io, entry.name, .{ .iterate = true })) |subdir| {
                defer subdir.close(ctx.io);
                try walkDir(ctx, buf, subdir, pattern, full_path, count, truncated);
            } else |err| switch (err) {
                error.FileNotFound, error.NotDir, error.AccessDenied => {},
                else => return err,
            }
        }
    }
}

/// Unified matching entry: a `**/` prefix matches at any depth under the
/// recursive walk, so it reduces to matching `rest` against the single-level
/// name. walkDir and the fixture test share this — the prefix handling lives
/// only here.
fn matchEntry(name: []const u8, pattern: []const u8) bool {
    const effective = if (std.mem.startsWith(u8, pattern, "**/")) pattern[3..] else pattern;
    return globMatch(name, effective);
}

fn globMatch(name: []const u8, pattern: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;
    if (std.mem.eql(u8, name, pattern)) return true;
    if (pattern.len > 1 and pattern[0] == '*' and pattern[1] == '.') {
        return std.mem.endsWith(u8, name, pattern[1..]);
    }
    var pi: usize = 0;
    var ni: usize = 0;
    var star_idx: ?usize = null;
    var match_idx: usize = 0;
    while (ni < name.len) {
        if (pi < pattern.len and (pattern[pi] == '?' or pattern[pi] == name[ni])) {
            pi += 1;
            ni += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            star_idx = pi;
            match_idx = ni;
            pi += 1;
        } else if (star_idx) |s| {
            pi = s + 1;
            match_idx += 1;
            ni = match_idx;
        } else {
            return false;
        }
    }
    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}

const Io = std.Io;

fn testExec(ctx: types.ToolContext, args_json: []const u8) !types.ToolResult {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{ .ignore_unknown_fields = true }) catch {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: invalid arguments JSON: {s}", .{args_json});
        return types.ToolResult{ .session_content = msg };
    };
    return types.ToolResult.finishExec(execute, ctx, parsed.value, parsed);
}

test "glob: finds files by extension" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-glob-ext";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {}; // best-effort cleanup
    try Io.Dir.cwd().createDirPath(io, test_root);
    const test_path = try std.fs.path.join(allocator, &.{ test_root });
    defer allocator.free(test_path);

    {
        const p = try std.fs.path.join(allocator, &.{ test_root, "a.zig" });
        defer allocator.free(p);
        (try Io.Dir.cwd().createFile(io, p, .{})).close(io);
    }
    {
        const p = try std.fs.path.join(allocator, &.{ test_root, "b.txt" });
        defer allocator.free(p);
        (try Io.Dir.cwd().createFile(io, p, .{})).close(io);
    }

    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = test_path,
    };

    var result = try testExec(ctx, "{\"pattern\":\"*.zig\",\"path\":\".\"}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "a.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "b.txt") == null);
}

test "glob: dot path yields unprefixed top-level names" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-glob-prefix";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {}; // best-effort cleanup
    try Io.Dir.cwd().createDirPath(io, test_root);
    {
        const p = try std.fs.path.join(allocator, &.{ test_root, "a.zig" });
        defer allocator.free(p);
        (try Io.Dir.cwd().createFile(io, p, .{})).close(io);
    }
    {
        const sub = try std.fs.path.join(allocator, &.{ test_root, "sub" });
        defer allocator.free(sub);
        try Io.Dir.cwd().createDirPath(io, sub);
        const p = try std.fs.path.join(allocator, &.{ test_root, "sub", "b.zig" });
        defer allocator.free(p);
        (try Io.Dir.cwd().createFile(io, p, .{})).close(io);
    }

    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = test_root,
    };

    var result = try testExec(ctx, "{\"pattern\":\"**/*.zig\",\"path\":\".\"}");
    defer result.deinit(allocator);
    // top-level name must NOT carry a "." prefix (".a.zig" regression)
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, ".a.zig") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "a.zig") != null);
    // nested path must be "sub/b.zig", not ".sub/b.zig" nor "./sub/b.zig"
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "sub/b.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, ".sub/b.zig") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "./sub/b.zig") == null);
}

test "glob: no matches" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-glob-none";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {}; // best-effort cleanup
    try Io.Dir.cwd().createDirPath(io, test_root);
    const test_path = try std.fs.path.join(allocator, &.{ test_root });
    defer allocator.free(test_path);

    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = test_path,
    };

    var result = try testExec(ctx, "{\"pattern\":\"*.xyz\",\"path\":\".\"}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "No files") != null);
}

const MatchCase = struct {
    name: []const u8,
    pattern: []const u8,
    file: []const u8,
    want: bool,
};

// Data-driven: adding a glob pattern = adding one row. Covers existing
// behavior (regression), the new `**/` prefix family, and an explicit
// out-of-scope probe for mid-pattern `**`.
const match_cases = [_]MatchCase{
    .{ .name = "bare-star",    .pattern = "*",       .file = "any.txt", .want = true },
    .{ .name = "exact",        .pattern = "a.zig",   .file = "a.zig",   .want = true },
    .{ .name = "ext",          .pattern = "*.zig",   .file = "a.zig",   .want = true },
    .{ .name = "ext-reject",   .pattern = "*.zig",   .file = "b.txt",   .want = false },
    .{ .name = "double-star",  .pattern = "**/*",    .file = "any.txt", .want = true },
    .{ .name = "dstar-ext",    .pattern = "**/*.md", .file = "doc.md",  .want = true },
    .{ .name = "dstar-reject", .pattern = "**/*.md", .file = "doc.zig", .want = false },
    .{ .name = "dstar-name",   .pattern = "**/foo",  .file = "foo",     .want = true },
    .{ .name = "mid-dstar-out-of-scope", .pattern = "a/**/b", .file = "b", .want = false },
};

test "glob: fixture-driven matchEntry" {
    inline for (match_cases) |c| {
        const got = matchEntry(c.file, c.pattern);
        if (got != c.want) {
            std.debug.print("FAIL {s}: pattern={s} file={s} got={} want={}\n", .{ c.name, c.pattern, c.file, got, c.want });
            return error.TestUnexpectedResult;
        }
    }
}

test "glob: recursive **/* finds files in nested dirs" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-glob-dstar";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {};
    try Io.Dir.cwd().createDirPath(io, test_root);
    // test_root 是字符串字面量，不需 allocator.free

    // a/root.txt, a/sub/nested.zig
    {
        const sub = try std.fs.path.join(allocator, &.{ test_root, "sub" });
        defer allocator.free(sub);
        try Io.Dir.cwd().createDirPath(io, sub);
    }
    {
        const p = try std.fs.path.join(allocator, &.{ test_root, "root.txt" });
        defer allocator.free(p);
        (try Io.Dir.cwd().createFile(io, p, .{})).close(io);
    }
    {
        const p = try std.fs.path.join(allocator, &.{ test_root, "sub", "nested.zig" });
        defer allocator.free(p);
        (try Io.Dir.cwd().createFile(io, p, .{})).close(io);
    }

    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = test_root,
    };

    var result = try testExec(ctx, "{\"pattern\":\"**/*\",\"path\":\".\"}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "root.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "nested.zig") != null);
}

test "glob: **/*.md matches md at any depth" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-glob-dstar-md";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {};
    try Io.Dir.cwd().createDirPath(io, test_root);
    // test_root 是字符串字面量，不需 allocator.free

    {
        const sub = try std.fs.path.join(allocator, &.{ test_root, "deep" });
        defer allocator.free(sub);
        try Io.Dir.cwd().createDirPath(io, sub);
    }
    {
        const p = try std.fs.path.join(allocator, &.{ test_root, "top.md" });
        defer allocator.free(p);
        (try Io.Dir.cwd().createFile(io, p, .{})).close(io);
    }
    {
        const p = try std.fs.path.join(allocator, &.{ test_root, "deep", "doc.md" });
        defer allocator.free(p);
        (try Io.Dir.cwd().createFile(io, p, .{})).close(io);
    }
    {
        const p = try std.fs.path.join(allocator, &.{ test_root, "deep", "other.zig" });
        defer allocator.free(p);
        (try Io.Dir.cwd().createFile(io, p, .{})).close(io);
    }

    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = test_root,
    };

    var result = try testExec(ctx, "{\"pattern\":\"**/*.md\",\"path\":\".\"}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "top.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "doc.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "other.zig") == null);
}