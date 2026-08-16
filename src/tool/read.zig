const std = @import("std");
const types = @import("../types.zig");
const path_util = @import("../util/path.zig");
const text_util = @import("../util/text.zig");

pub const tool_name = "read";
pub const tool_description = "Read a file or list a directory from the filesystem. For text files, returns content with optional offset/limit. For directories, lists entries.";
pub const tool_params =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Path to the file or directory"},"offset":{"type":"integer","description":"Starting line (1-indexed)"},"limit":{"type":"integer","description":"Max lines to return"}},"required":["path"]}
;

const MAX_BYTES: usize = 50 * 1024;
const MAX_DIR_FILES: usize = 100;
const MAX_LINE_LEN: usize = 2000;
const EXTENSION_BLACKLIST = [_][]const u8{ ".zip", ".exe", ".dll", ".so", ".dylib", ".bin", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".ico", ".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".mp3", ".mp4", ".avi", ".mov", ".mkv", ".wav", ".flac", ".ogg", ".tar", ".gz", ".bz2", ".xz", ".7z" };

fn isBlacklisted(path: []const u8) bool {
    for (EXTENSION_BLACKLIST) |ext| {
        if (path.len >= ext.len and std.mem.eql(u8, path[path.len - ext.len ..], ext)) return true;
    }
    return false;
}

/// Preview-able image extensions — aligned with the Web preview raw whitelist
/// (handler.zig mimeForExtension): every image readable here must be
/// previewable there. bmp/ico stay blacklisted (no preview path). Case-insensitive.
fn isImage(path: []const u8) bool {
    const exts = [_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".webp" };
    for (exts) |e| {
        if (path.len >= e.len and std.ascii.eqlIgnoreCase(path[path.len - e.len ..], e)) return true;
    }
    return false;
}

/// Max raw image bytes attachable (base64 grows ~33%; aligns with preview 5MB).
const MAX_IMAGE_BYTES: usize = 5 * 1024 * 1024;
/// Short side cap — vision models charge by image tiles; oversized images are
/// rejected instead of attached (aligned with opencode max_width/max_height=2000).
const MAX_IMAGE_SIDE: u32 = 2000;
/// Header bytes read for magic sniffing + dimension parsing (JPEG SOF scanning
/// needs room for APPn segments; aligns with opencode SAMPLE_BYTES=4096).
const IMAGE_HEADER_BYTES: usize = 4096;

/// Magic-byte sniff: authoritative MIME (extension is only a pre-filter).
/// N22: prevents extension spoofing (a .png that is really text is rejected).
fn sniffImageMime(header: []const u8) ?[]const u8 {
    if (header.len >= 8 and header[0] == 0x89 and header[1] == 'P' and header[2] == 'N' and header[3] == 'G' and
        header[4] == 0x0D and header[5] == 0x0A and header[6] == 0x1A and header[7] == 0x0A) return "image/png";
    if (header.len >= 3 and header[0] == 0xFF and header[1] == 0xD8 and header[2] == 0xFF) return "image/jpeg";
    if (header.len >= 4 and std.mem.eql(u8, header[0..4], "GIF8")) return "image/gif";
    if (header.len >= 12 and std.mem.eql(u8, header[0..4], "RIFF") and std.mem.eql(u8, header[8..12], "WEBP")) return "image/webp";
    return null;
}

const Dimensions = struct { w: u32, h: u32 };

/// Parse pixel dimensions from the header. Original pixel size only — EXIF
/// Orientation rotation is deliberately NOT applied (models do not rotate
/// EXIF; judging the short side on raw pixels is conservative — a rotated
/// image's user-visible short side is never larger).
fn imageDimensions(mime: []const u8, header: []const u8) ?Dimensions {
    if (std.mem.eql(u8, mime, "image/png")) {
        // IHDR at fixed offset: chunk header at 8, "IHDR" at 12-15, w 16-19, h 20-23 (BE)
        if (header.len >= 24 and std.mem.eql(u8, header[12..16], "IHDR")) {
            return .{ .w = readBe32(header[16..20]), .h = readBe32(header[20..24]) };
        }
        return null;
    }
    if (std.mem.eql(u8, mime, "image/gif")) {
        if (header.len >= 10) return .{ .w = readLe16(header[6..8]), .h = readLe16(header[8..10]) };
        return null;
    }
    if (std.mem.eql(u8, mime, "image/webp")) {
        // VP8X chunk: "VP8X" at 12-15, canvas 24-bit LE at 24-29, values are (size-1)
        if (header.len >= 30 and std.mem.eql(u8, header[12..16], "VP8X")) {
            return .{ .w = readLe24(header[24..27]) + 1, .h = readLe24(header[27..30]) + 1 };
        }
        // VP8 / VP8L: not parsed → null → conservative rejection
        return null;
    }
    if (std.mem.eql(u8, mime, "image/jpeg")) {
        var i: usize = 2; // skip SOI (FF D8)
        while (i + 9 <= header.len) {
            if (header[i] != 0xFF) {
                i += 1;
                continue;
            }
            const marker = header[i + 1];
            // SOF0-SOF3 carry the frame dimensions
            if (marker >= 0xC0 and marker <= 0xC3) {
                return .{ .w = readBe16(header[i + 7 .. i + 9]), .h = readBe16(header[i + 5 .. i + 7]) };
            }
            // Standalone markers / RSTn / TEM: no length field
            if (marker == 0xD8 or marker == 0xD9 or marker == 0x01 or (marker >= 0xD0 and marker <= 0xD7)) {
                i += 2;
                continue;
            }
            if (i + 4 > header.len) return null;
            const seg_len = readBe16(header[i + 2 .. i + 4]);
            if (seg_len < 2) return null;
            i += 2 + seg_len;
        }
        return null;
    }
    return null;
}

fn readBe32(b: []const u8) u32 {
    return (@as(u32, b[0]) << 24) | (@as(u32, b[1]) << 16) | (@as(u32, b[2]) << 8) | b[3];
}
fn readBe16(b: []const u8) u32 {
    return (@as(u32, b[0]) << 8) | b[1];
}
fn readLe16(b: []const u8) u32 {
    return (@as(u32, b[1]) << 8) | b[0];
}
fn readLe24(b: []const u8) u32 {
    return (@as(u32, b[2]) << 16) | (@as(u32, b[1]) << 8) | b[0];
}

fn base64Encode(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    const b64 = std.base64.standard.Encoder;
    const out_len = b64.calcSize(data.len);
    const buf = try allocator.alloc(u8, out_len);
    _ = b64.encode(buf, data);
    return buf;
}

/// Image files: attach base64 bytes for vision models (gated at the provider),
/// guarded by magic sniffing + size/dimension caps. The model-facing text stays
/// a factual summary; pixels travel as attachments. meta.path feeds the Web
/// Preview button (raw endpoint) for the user.
fn readImageSummary(ctx: types.ToolContext, path: []const u8, display_path: []const u8) !types.ToolResult {
    const file = Io.Dir.cwd().openFile(ctx.io, path, .{ .mode = .read_only }) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: cannot open '{s}': {s}", .{ display_path, @errorName(err) });
        return types.ToolResult{ .session_content = msg };
    };
    defer file.close(ctx.io);
    const stat = file.stat(ctx.io) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: cannot stat '{s}': {s}", .{ display_path, @errorName(err) });
        return types.ToolResult{ .session_content = msg };
    };
    const size: usize = @intCast(stat.size);
    const name = std.fs.path.basename(display_path);
    const ext = std.fs.path.extension(display_path);

    const head_len = @min(size, IMAGE_HEADER_BYTES);
    const head = try ctx.allocator.alloc(u8, head_len);
    defer ctx.allocator.free(head);
    const head_n = file.readPositionalAll(ctx.io, head, 0) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: cannot read '{s}': {s}", .{ display_path, @errorName(err) });
        return types.ToolResult{ .session_content = msg };
    };

    // 1) Magic sniff: extension claims image but bytes do not match → fall
    //    back to the binary-rejection path (spoof protection).
    const mime = sniffImageMime(head[0..head_n]) orelse {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: cannot read binary file '{s}'", .{display_path});
        return types.ToolResult{ .session_content = msg };
    };

    // 2) Dimension cap: short side > 2000px is rejected (token cost), the user
    //    still previews via the Preview button.
    if (imageDimensions(mime, head[0..head_n])) |d| {
        const short_side = @min(d.w, d.h);
        if (short_side > MAX_IMAGE_SIDE) {
            const msg = try std.fmt.allocPrint(ctx.allocator, "Image file: {s} ({d} bytes, {s}). Image too large ({d}x{d}px) — not attached; use Preview to view.", .{ name, size, ext, d.w, d.h });
            return types.ToolResult{
                .session_content = msg,
                .meta = .{ .read = .{ .path = display_path, .is_directory = false, .total_lines = 0, .byte_count = size, .truncated = false, .next_offset = null } },
            };
        }
    } else {
        // Magic matches but structure is broken/non-standard → conservative reject.
        const msg = try std.fmt.allocPrint(ctx.allocator, "Image file: {s} ({d} bytes, {s}). Image structure could not be parsed — not attached; use Preview to view.", .{ name, size, ext });
        return types.ToolResult{
            .session_content = msg,
            .meta = .{ .read = .{ .path = display_path, .is_directory = false, .total_lines = 0, .byte_count = size, .truncated = false, .next_offset = null } },
        };
    }

    // 3) Byte cap: oversized payload is not worth the base64 inflation.
    if (size > MAX_IMAGE_BYTES) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Image file: {s} ({d} bytes, {s}). Image too large to attach — use Preview to view.", .{ name, size, ext });
        return types.ToolResult{
            .session_content = msg,
            .meta = .{ .read = .{ .path = display_path, .is_directory = false, .total_lines = 0, .byte_count = size, .truncated = false, .next_offset = null } },
        };
    }

    // 4) Read all bytes → base64 attachment.
    const data = try ctx.allocator.alloc(u8, size);
    defer ctx.allocator.free(data);
    const data_n = file.readPositionalAll(ctx.io, data, 0) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: cannot read '{s}': {s}", .{ display_path, @errorName(err) });
        return types.ToolResult{ .session_content = msg };
    };
    const b64 = try base64Encode(ctx.allocator, data[0..data_n]);
    const mime_dup = try ctx.allocator.dupe(u8, mime);
    const msg = try std.fmt.allocPrint(ctx.allocator, "Image file: {s} ({d} bytes, {s}). Image read successfully — preview it separately to view (Web UI read/edit cards).", .{ name, size, ext });
    return types.ToolResult{
        .session_content = msg,
        .meta = .{ .read = .{ .path = display_path, .is_directory = false, .total_lines = 0, .byte_count = size, .truncated = false, .next_offset = null } },
        .attachments = &.{.{ .mime = mime_dup, .data = b64 }},
    };
}

fn countLines(content: []const u8) usize {
    var count: usize = 0;
    for (content) |b| {
        if (b == '\n') count += 1;
    }
    if (content.len > 0 and content[content.len - 1] != '\n') count += 1;
    return count;
}

const ReadLinesResult = struct {
    text: []const u8,
    total_lines: usize,
    next_offset: ?u32,
};

fn readLinesResult(allocator: std.mem.Allocator, content: []const u8, offset: usize, limit: ?usize) !ReadLinesResult {
    const total_lines = countLines(content);
    var buf = std.ArrayListAligned(u8, null).empty;
    var line_count: usize = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    var lines_returned: usize = 0;

    while (i < content.len) : (i += 1) {
        if (content[i] == '\n') {
            line_count += 1;
            const line_end = if (i > 0 and content[i - 1] == '\r') i - 1 else i;
            if (line_count >= offset) {
                lines_returned += 1;
                const raw_len = line_end - line_start;
                if (raw_len > MAX_LINE_LEN) {
                    try buf.appendSlice(allocator, content[line_start .. line_start + MAX_LINE_LEN]);
                    try buf.appendSlice(allocator, "... (line truncated)");
                } else {
                    try buf.appendSlice(allocator, content[line_start..line_end]);
                }
                try buf.append(allocator, '\n');
                if (limit) |l| {
                    if (line_count >= offset + l - 1) break;
                }
            }
            line_start = i + 1;
        }
    }

    if (line_start < content.len and (limit == null or lines_returned < limit.?)) {
        if (line_count + 1 >= offset) {
            lines_returned += 1;
            const raw_len = content.len - line_start;
            if (raw_len > MAX_LINE_LEN) {
                try buf.appendSlice(allocator, content[line_start .. line_start + MAX_LINE_LEN]);
                try buf.appendSlice(allocator, "... (line truncated)");
            } else {
                try buf.appendSlice(allocator, content[line_start..]);
            }
        }
    }

    const end_line = offset + lines_returned -| 1;
    const next_offset: ?u32 = if (end_line < total_lines) @intCast(end_line + 1) else null;

    return .{
        .text = try buf.toOwnedSlice(allocator),
        .total_lines = total_lines,
        .next_offset = next_offset,
    };
}

/// Read a file or directory. Returns structured ToolResult.
pub fn execute(ctx: types.ToolContext, args: std.json.Value) anyerror!types.ToolResult {
    const path_val = args.object.get("path") orelse {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: missing 'path' argument", .{});
        return types.ToolResult{ .session_content = msg };
    };
    if (path_val != .string) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: 'path' must be a string", .{});
        return types.ToolResult{ .session_content = msg };
    }

    const path = path_util.resolvePath(ctx.allocator, ctx.project_root, path_val.string) catch |err| switch (err) {
        error.PathEscape => {
            const msg = try std.fmt.allocPrint(ctx.allocator, "Error: path escapes project root", .{});
            return types.ToolResult{ .session_content = msg };
        },
        else => return err,
    };
    defer ctx.allocator.free(path);

    const offset: usize = @intCast(@max(1, if (args.object.get("offset")) |o| o.integer else 1));
    const limit: ?usize = if (args.object.get("limit")) |l| @intCast(@max(0, l.integer)) else null;

    if (Io.Dir.cwd().openDir(ctx.io, path, .{ .iterate = true })) |dir| {
        defer dir.close(ctx.io);
        var buf = std.ArrayListAligned(u8, null).empty;
        var iter = dir.iterate();
        var count: usize = 0;
        var shown: usize = 0;

        while (try iter.next(ctx.io)) |entry| {
            count += 1;
            if (count < offset) continue;
            shown += 1;
            if (shown > MAX_DIR_FILES) {
                try buf.appendSlice(ctx.allocator, "... (more entries)\n");
                break;
            }
            if (limit) |l| {
                if (shown > l) break;
            }
            const kind: u8 = switch (entry.kind) {
                .directory => 'd',
                .file => 'f',
                .sym_link => 'l',
                else => '?',
            };
            var line_buf: [512]u8 = undefined;
            const line = try std.fmt.bufPrint(&line_buf, "{c} {s}\n", .{ kind, entry.name });
            try buf.appendSlice(ctx.allocator, line);
        }

        return types.ToolResult{
            .session_content = try buf.toOwnedSlice(ctx.allocator),
            .meta = .{ .read = .{
                .path = path_val.string,
                .is_directory = true,
                .total_lines = shown,
                .byte_count = 0,
                .truncated = shown >= MAX_DIR_FILES,
                .next_offset = if (shown >= MAX_DIR_FILES) @intCast(count + 0) else null,
            }},
        };
    } else |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied => {},
        else => return err,
    }

    if (isImage(path_val.string)) {
        return readImageSummary(ctx, path, path_val.string);
    }

    if (isBlacklisted(path_val.string)) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: binary file extension not supported: '{s}'", .{path_val.string});
        return types.ToolResult{ .session_content = msg };
    }

    const file = Io.Dir.cwd().openFile(ctx.io, path, .{ .mode = .read_only }) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: cannot open '{s}': {s}", .{ path_val.string, @errorName(err) });
        return types.ToolResult{ .session_content = msg };
    };
    defer file.close(ctx.io);

    const stat = file.stat(ctx.io) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: cannot stat '{s}': {s}", .{ path_val.string, @errorName(err) });
        return types.ToolResult{ .session_content = msg };
    };
    const file_size: usize = @intCast(stat.size);

    if (file_size == 0) {
        return types.ToolResult{
            .session_content = try std.fmt.allocPrint(ctx.allocator, "File is empty: {s}", .{path_val.string}),
            .meta = .{ .read = .{
                .path = path_val.string,
                .is_directory = false,
                .total_lines = 0,
                .byte_count = 0,
                .truncated = false,
                .next_offset = null,
            }},
        };
    }

    const check_size = @min(file_size, text_util.BINARY_CHECK_SIZE);
    const head_buf = try ctx.allocator.alloc(u8, check_size);
    defer ctx.allocator.free(head_buf);
    _ = file.readPositionalAll(ctx.io, head_buf, 0) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: cannot read '{s}': {s}", .{ path_val.string, @errorName(err) });
        return types.ToolResult{ .session_content = msg };
    };

    if (text_util.isBinary(head_buf)) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: cannot read binary file '{s}'", .{path_val.string});
        return types.ToolResult{ .session_content = msg };
    }

    var content = try ctx.allocator.alloc(u8, file_size);
    defer ctx.allocator.free(content);
    const n = file.readPositionalAll(ctx.io, content, 0) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: cannot read '{s}': {s}", .{ path_val.string, @errorName(err) });
        return types.ToolResult{ .session_content = msg };
    };
    content = content[0..n];

    if (!std.unicode.utf8ValidateSlice(content)) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: file is not valid UTF-8 at '{s}'", .{path_val.string});
        return types.ToolResult{ .session_content = msg };
    }

    if (limit != null and limit.? == 0) {
        const total_lines = countLines(content);
        return types.ToolResult{
            .session_content = try std.fmt.allocPrint(ctx.allocator, "[Read {s}: {d} lines, {d} bytes]", .{ path_val.string, total_lines, n }),
            .meta = .{ .read = .{
                .path = path_val.string,
                .is_directory = false,
                .total_lines = total_lines,
                .byte_count = n,
                .truncated = false,
                .next_offset = if (offset <= total_lines) @intCast(offset) else null,
            }},
        };
    }

    const rl = try readLinesResult(ctx.allocator, content, offset, limit);

    if (offset > rl.total_lines) {
        ctx.allocator.free(rl.text);
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: offset {d} exceeds file {s} ({d} lines)", .{ offset, path_val.string, rl.total_lines });
        return types.ToolResult{ .session_content = msg };
    }

    var session_content: []const u8 = rl.text;
    var truncated = rl.next_offset != null;

    if (session_content.len > MAX_BYTES) {
        const truncated_bytes = session_content[0..MAX_BYTES];
        const note = try std.fmt.allocPrint(ctx.allocator, "{s}\n[truncated: {d} more bytes]", .{ truncated_bytes, session_content.len - MAX_BYTES });
        ctx.allocator.free(session_content);
        session_content = note;
        truncated = true;
    }

    return types.ToolResult{
        .session_content = session_content,
        .meta = .{ .read = .{
            .path = path_val.string,
            .is_directory = false,
            .total_lines = rl.total_lines,
            .byte_count = n,
            .truncated = truncated,
            .next_offset = rl.next_offset,
        }},
    };
}

const Io = std.Io;

fn testExec(ctx: types.ToolContext, args_json: []const u8) !types.ToolResult {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{ .ignore_unknown_fields = true }) catch {
        const msg = try std.fmt.allocPrint(ctx.allocator, "Error: invalid arguments JSON: {s}", .{args_json});
        return types.ToolResult{ .session_content = msg };
    };
    return types.ToolResult.finishExec(execute, ctx, parsed.value, parsed);
}

test "read: reads text file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-read-text";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {}; // best-effort cleanup
    try Io.Dir.cwd().createDirPath(io, test_root);

    const test_path = try std.fs.path.join(allocator, &.{ test_root });
    defer allocator.free(test_path);

    const file_path = try std.fs.path.join(allocator, &.{ test_root, "test_read.txt" });
    defer allocator.free(file_path);
    const file = try Io.Dir.cwd().createFile(io, file_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "hello\nworld\n");



    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = test_path,
    };

    var result = try testExec(ctx, "{\"path\":\"test_read.txt\"}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "world") != null);
}

test "read: detects binary" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-read-binary";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {}; // best-effort cleanup
    try Io.Dir.cwd().createDirPath(io, test_root);

    const test_path = try std.fs.path.join(allocator, &.{ test_root });
    defer allocator.free(test_path);

    const file_path = try std.fs.path.join(allocator, &.{ test_root, "test_binary.bin" });
    defer allocator.free(file_path);
    const data = [_]u8{ 0x00, 0x01, 0x02, 'h', 'e', 'l', 'l', 'o' };
    const file = try Io.Dir.cwd().createFile(io, file_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, &data);



    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = test_path,
    };

    var result = try testExec(ctx, "{\"path\":\"test_binary.bin\"}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "binary") != null);
}

test "read: image returns summary with meta.path (preview bridge)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-read-image";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {}; // best-effort cleanup
    try Io.Dir.cwd().createDirPath(io, test_root);

    const test_path = try std.fs.path.join(allocator, &.{ test_root });
    defer allocator.free(test_path);

    const file_path = try std.fs.path.join(allocator, &.{ test_root, "shot.png" });
    defer allocator.free(file_path);
    // Minimal real PNG header: 8-byte magic + IHDR (w=4, h=4)
    const png_head = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 'I', 'H', 'D', 'R', 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x08, 0x06, 0x00, 0x00, 0x00 };
    const file = try Io.Dir.cwd().createFile(io, file_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, &png_head);

    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = test_path,
    };

    var result = try testExec(ctx, "{\"path\":\"shot.png\"}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "Image file") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "preview") != null);
    const meta = result.meta;
    try std.testing.expect(meta == .read);
    try std.testing.expectEqualStrings("shot.png", meta.read.path);
    try std.testing.expect(!meta.read.is_directory);
    try std.testing.expect(meta.read.byte_count > 0);
    // Attachment present with correct mime; base64 decodes back to the bytes.
    try std.testing.expectEqual(@as(usize, 1), result.attachments.len);
    try std.testing.expectEqualStrings("image/png", result.attachments[0].mime);
    const dec_calc = try std.base64.standard.Decoder.calcSizeForSlice(result.attachments[0].data);
    const decoded = try allocator.alloc(u8, dec_calc);
    defer allocator.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, result.attachments[0].data);
    try std.testing.expectEqualSlices(u8, &png_head, decoded);
}

test "read: image extension is case-insensitive" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-read-image-jpg";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {}; // best-effort cleanup
    try Io.Dir.cwd().createDirPath(io, test_root);

    const test_path = try std.fs.path.join(allocator, &.{ test_root });
    defer allocator.free(test_path);

    const file_path = try std.fs.path.join(allocator, &.{ test_root, "photo.JPG" });
    defer allocator.free(file_path);
    // Minimal JPEG: SOI + SOF0 (h=8, w=10)
    const jpeg_head = [_]u8{ 0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00, 0x08, 0x00, 0x0A, 0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01 };
    const file = try Io.Dir.cwd().createFile(io, file_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, &jpeg_head);

    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = test_path,
    };

    var result = try testExec(ctx, "{\"path\":\"photo.JPG\"}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "Image file") != null);
    try std.testing.expectEqual(@as(usize, 1), result.attachments.len);
    try std.testing.expectEqualStrings("image/jpeg", result.attachments[0].mime);
}

test "read: image spoof (extension png, magic text) rejected" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-read-image-spoof";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {}; // best-effort cleanup
    try Io.Dir.cwd().createDirPath(io, test_root);

    const test_path = try std.fs.path.join(allocator, &.{ test_root });
    defer allocator.free(test_path);

    const file_path = try std.fs.path.join(allocator, &.{ test_root, "fake.png" });
    defer allocator.free(file_path);
    const file = try Io.Dir.cwd().createFile(io, file_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "not-really-png-bytes");

    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = test_path,
    };

    var result = try testExec(ctx, "{\"path\":\"fake.png\"}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "binary") != null);
    try std.testing.expectEqual(@as(usize, 0), result.attachments.len);
}

test "read: image dimension cap rejects oversized short side" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-read-image-big";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {}; // best-effort cleanup
    try Io.Dir.cwd().createDirPath(io, test_root);

    const test_path = try std.fs.path.join(allocator, &.{ test_root });
    defer allocator.free(test_path);

    const file_path = try std.fs.path.join(allocator, &.{ test_root, "wide.png" });
    defer allocator.free(file_path);
    // PNG header with w=4000, h=4000 (short side 4000 > 2000)
    var png_head: [29]u8 = .{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 'I', 'H', 'D', 'R', 0, 0, 0, 0, 0, 0, 0, 0, 0x08, 0x06, 0x00, 0x00, 0x00 };
    png_head[16] = 0x0F; // w = 0x0FA0 = 4000
    png_head[17] = 0xA0;
    png_head[20] = 0x0F;
    png_head[21] = 0xA0;
    const file = try Io.Dir.cwd().createFile(io, file_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, &png_head);

    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = test_path,
    };

    var result = try testExec(ctx, "{\"path\":\"wide.png\"}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "too large") != null);
    try std.testing.expectEqual(@as(usize, 0), result.attachments.len);
}

test "read: long image (4000x400) not rejected (short side 400)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-read-image-long";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {}; // best-effort cleanup
    try Io.Dir.cwd().createDirPath(io, test_root);

    const test_path = try std.fs.path.join(allocator, &.{ test_root });
    defer allocator.free(test_path);

    const file_path = try std.fs.path.join(allocator, &.{ test_root, "banner.png" });
    defer allocator.free(file_path);
    var png_head: [29]u8 = .{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 'I', 'H', 'D', 'R', 0, 0, 0, 0, 0, 0, 0, 0, 0x08, 0x06, 0x00, 0x00, 0x00 };
    png_head[18] = 0x0F; // w BE = 0x00000FA0 = 4000
    png_head[19] = 0xA0;
    png_head[22] = 0x01; // h BE = 0x00000190 = 400
    png_head[23] = 0x90;
    const file = try Io.Dir.cwd().createFile(io, file_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, &png_head);

    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = test_path,
    };

    var result = try testExec(ctx, "{\"path\":\"banner.png\"}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "Image file") != null);
    try std.testing.expectEqual(@as(usize, 1), result.attachments.len);
}

test "read: broken image header (magic ok, structure bad) conservatively rejected" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-read-image-broken";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {}; // best-effort cleanup
    try Io.Dir.cwd().createDirPath(io, test_root);

    const test_path = try std.fs.path.join(allocator, &.{ test_root });
    defer allocator.free(test_path);

    const file_path = try std.fs.path.join(allocator, &.{ test_root, "broken.png" });
    defer allocator.free(file_path);
    // PNG magic + random bytes but no IHDR chunk signature at offset 12.
    const png_broken = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 'X', 'Y', 'Z', 'W', 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x08, 0x06, 0x00, 0x00, 0x00 };
    const file = try Io.Dir.cwd().createFile(io, file_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, &png_broken);

    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = test_path,
    };

    var result = try testExec(ctx, "{\"path\":\"broken.png\"}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "could not be parsed") != null);
    try std.testing.expectEqual(@as(usize, 0), result.attachments.len);
}

test "read: non-preview binary extensions still rejected" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-read-bmp";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {}; // best-effort cleanup
    try Io.Dir.cwd().createDirPath(io, test_root);

    const test_path = try std.fs.path.join(allocator, &.{ test_root });
    defer allocator.free(test_path);

    const file_path = try std.fs.path.join(allocator, &.{ test_root, "pic.bmp" });
    defer allocator.free(file_path);
    const file = try Io.Dir.cwd().createFile(io, file_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "bmp-bytes");

    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = test_path,
    };

    var result = try testExec(ctx, "{\"path\":\"pic.bmp\"}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "not supported") != null);
}

test "read: directory listing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-read-dir";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {}; // best-effort cleanup
    try Io.Dir.cwd().createDirPath(io, test_root);

    const test_path = try std.fs.path.join(allocator, &.{ test_root });
    defer allocator.free(test_path);

    {
        const p = try std.fs.path.join(allocator, &.{ test_root, "foo.txt" });
        defer allocator.free(p);
        (try Io.Dir.cwd().createFile(io, p, .{})).close(io);
    }
    {
        const p = try std.fs.path.join(allocator, &.{ test_root, "bar.txt" });
        defer allocator.free(p);
        (try Io.Dir.cwd().createFile(io, p, .{})).close(io);
    }



    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = test_path,
    };

    var result = try testExec(ctx, "{\"path\":\".\"}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "foo.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "bar.txt") != null);
}

test "read: offset/limit range" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-read-offset";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {}; // best-effort cleanup
    try Io.Dir.cwd().createDirPath(io, test_root);

    const test_path = try std.fs.path.join(allocator, &.{ test_root });
    defer allocator.free(test_path);

    const file_path = try std.fs.path.join(allocator, &.{ test_root, "test_lines.txt" });
    defer allocator.free(file_path);
    const file = try Io.Dir.cwd().createFile(io, file_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "line1\nline2\nline3\nline4\n");



    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = test_path,
    };

    var result = try testExec(ctx, "{\"path\":\"test_lines.txt\",\"offset\":2,\"limit\":2}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "line1") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "line2") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "line3") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "line4") == null);
}

test "read: missing path" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-read-missing";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {}; // best-effort cleanup
    try Io.Dir.cwd().createDirPath(io, test_root);

    const test_path = try std.fs.path.join(allocator, &.{ test_root });
    defer allocator.free(test_path);



    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = test_path,
    };

    var result = try testExec(ctx, "{}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "missing") != null);
}

test "read: path escape rejected" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-read-escape";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {}; // best-effort cleanup
    try Io.Dir.cwd().createDirPath(io, test_root);

    const test_path = try std.fs.path.join(allocator, &.{ test_root });
    defer allocator.free(test_path);



    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = test_path,
    };

    var result = try testExec(ctx, "{\"path\":\"../outside\"}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "escapes") != null);
}

test "read: empty file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-read-empty";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {}; // best-effort cleanup
    try Io.Dir.cwd().createDirPath(io, test_root);

    const test_path = try std.fs.path.join(allocator, &.{ test_root });
    defer allocator.free(test_path);

    const file_path = try std.fs.path.join(allocator, &.{ test_root, "test_empty.txt" });
    defer allocator.free(file_path);
    (try Io.Dir.cwd().createFile(io, file_path, .{})).close(io);



    const ctx = types.ToolContext{
        .allocator = allocator,
        .io = io,
        .project_root = test_path,
    };

    var result = try testExec(ctx, "{\"path\":\"test_empty.txt\"}");
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.session_content, "empty") != null);
}
