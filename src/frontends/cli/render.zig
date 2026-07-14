const std = @import("std");
const builtin = @import("builtin");
const types = @import("../../types.zig");

pub const Color = struct {
    reset: []const u8 = "\x1b[0m",
    green: []const u8 = "\x1b[32m",
    yellow: []const u8 = "\x1b[33m",
    red: []const u8 = "\x1b[31m",
    bold: []const u8 = "\x1b[1m",
    dim: []const u8 = "\x1b[2m",
    cyan: []const u8 = "\x1b[36m",
    blue: []const u8 = "\x1b[34m",
    magenta: []const u8 = "\x1b[35m",
    white:    []const u8 = "\x1b[37m",
    italic:   []const u8 = "\x1b[3m",
    bright_black: []const u8 = "\x1b[90m",
    bg_blue: []const u8 = "\x1b[44m",
    bg_gray: []const u8 = "\x1b[100m",
    bg_green: []const u8 = "\x1b[42m",
    bg_bright_cyan: []const u8 = "\x1b[106m",
    bg_bright_magenta: []const u8 = "\x1b[105m",
};

pub const C: Color = .{};

pub const MessageType = enum {
    user,
    think,
    tool,
    output,
    err,
    warning,
    success,
};

var colorize: bool = false;

pub fn isColorized() bool {
    return colorize;
}

pub fn init() void {
    if (checkNoColor()) {
        colorize = false;
        return;
    }
    if (builtin.os.tag == .windows) {
        _ = windows.SetConsoleCP(65001); // UTF-8 console input
        _ = windows.SetConsoleOutputCP(65001); // UTF-8 console output
        colorize = enableWindowsVT();
    } else {
        colorize = true;
    }
}

fn checkNoColor() bool {
    const key = "NO_COLOR";
    if (builtin.os.tag == .windows) {
        const ret = windows.GetEnvironmentVariableA(key, null, 0);
        return ret > 0;
    } else {
        if (@hasDecl(std.c, "getenv")) {
            return std.c.getenv(key) != null;
        }
        return false;
    }
}

fn enableWindowsVT() bool {
    const ENABLE_VIRTUAL_TERMINAL_PROCESSING: u32 = 0x0004;
    const STD_OUTPUT_HANDLE: u32 = @bitCast(@as(i32, -11));
    const handle = windows.GetStdHandle(STD_OUTPUT_HANDLE);
    if (handle == @as(*anyopaque, @ptrFromInt(@as(usize, @bitCast(@as(isize, -1)))))) {
        return false;
    }
    var mode: u32 = 0;
    if (windows.GetConsoleMode(handle, &mode) == 0) return false;
    _ = windows.SetConsoleMode(handle, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
    return true;
}

pub fn visibleWidth(s: []const u8) usize {
    var width: usize = 0;
    var iter = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
    while (iter.nextCodepoint()) |cp| {
        width += if (isWideChar(cp)) @as(usize, 2) else @as(usize, 1);
    }
    return width;
}

fn isWideChar(cp: u21) bool {
    return (cp >= 0x1100 and cp <= 0x115F) or
        (cp >= 0x2E80 and cp <= 0x9FFF) or
        (cp >= 0xA000 and cp <= 0xA4CF) or
        (cp >= 0xAC00 and cp <= 0xD7AF) or
        (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0xFE30 and cp <= 0xFE6F) or
        (cp >= 0xFF01 and cp <= 0xFF60) or
        (cp >= 0xFFE0 and cp <= 0xFFE6) or
        (cp >= 0x1F300 and cp <= 0x1F64F) or
        (cp >= 0x20000 and cp <= 0x2FFFF);
}

pub fn writeLabeled(writer: *std.Io.Writer, mtype: MessageType, text: []const u8) !void {
    if (!colorize) {
        try writer.print("{s}{s}\n", .{ labelPlain(mtype), text });
        return;
    }
    switch (mtype) {
        .user => {
            try writer.print("{s}{s} 用户 {s}{s}{s}{s}\n", .{
                C.bg_blue, C.white, C.reset, C.white, text, C.reset,
            });
        },
        .think => {
            try writer.print("{s}{s} 思考 {s}{s}{s}{s}\n", .{
                C.bg_gray, C.white, C.reset, C.dim, text, C.reset,
            });
        },
        .tool => {
            try writer.print("{s}{s} 工具 {s}{s}{s}{s}\n", .{
                C.bg_bright_magenta, C.white, C.reset, C.dim, text, C.reset,
            });
        },
        .output => {
            try writer.print("{s}{s} 输出 {s}{s}{s}\n", .{
                C.bg_green, C.white, C.reset, text, C.reset,
            });
        },
        .err => {
            try writer.print("{s}ERROR {s}{s}\n", .{ C.red, text, C.reset });
        },
        .warning => {
            try writer.print("{s}WARN  {s}{s}\n", .{ C.yellow, text, C.reset });
        },
        .success => {
            try writer.print("{s}OK    {s}{s}\n", .{ C.green, text, C.reset });
        },
    }
}

pub fn writeLabelBegin(writer: *std.Io.Writer, mtype: MessageType) !void {
    if (!colorize) {
        try writer.print("{s}\n", .{labelPlain(mtype)});
        return;
    }
    switch (mtype) {
        .user => {
            try writer.print("{s}{s} 用户 {s}{s}\n", .{ C.bg_blue, C.white, C.reset, C.white });
        },
        .think => {
            try writer.print("{s}{s} 思考 {s}{s}\n", .{ C.bg_gray, C.white, C.reset, C.dim });
        },
        .tool => {
            try writer.print("{s}{s} 工具 {s}{s}\n", .{ C.bg_bright_magenta, C.white, C.reset, C.dim });
        },
        .output => {
            try writer.print("{s}{s} 输出 {s}{s}\n", .{ C.bg_green, C.white, C.reset, C.reset });
        },
        .err => {
            try writer.print("{s}ERROR {s}\n", .{ C.red, C.reset });
        },
        .warning => {
            try writer.print("{s}WARN  {s}\n", .{ C.yellow, C.reset });
        },
        .success => {
            try writer.print("{s}OK    {s}\n", .{ C.green, C.reset });
        },
    }
}

pub fn writeLabelEnd(writer: *std.Io.Writer) !void {
    if (colorize) {
        try writer.print("{s}\n", .{C.reset});
    } else {
        try writer.print("\n", .{});
    }
}

pub const PhaseWriter = struct {
    inner: *std.Io.Writer,
    phase: enum { none, thinking, content } = .none,

    pub fn init(inner: *std.Io.Writer) PhaseWriter {
        return .{ .inner = inner };
    }

    pub fn beginPhase(self: *PhaseWriter, mtype: MessageType) !void {
        switch (mtype) {
            .think => {
                if (self.phase == .thinking) return;
                if (self.phase != .none) try writeLabelEnd(self.inner);
                self.phase = .thinking;
            },
            .output => {
                if (self.phase == .content) return;
                if (self.phase != .none) try writeLabelEnd(self.inner);
                self.phase = .content;
            },
            else => return,
        }
        try writeLabelBegin(self.inner, mtype);
    }

    pub fn endPhase(self: *PhaseWriter) !void {
        if (self.phase != .none) {
            try writeLabelEnd(self.inner);
            self.phase = .none;
        }
    }

    pub fn writeRaw(self: *PhaseWriter, bytes: []const u8) !void {
        try self.inner.print("{s}", .{bytes});
        try self.inner.flush();
    }

    pub fn innerWriter(self: *PhaseWriter) *std.Io.Writer {
        return self.inner;
    }
};

pub const RenderContext = struct {
    code_block_active: bool = false,
    colorize: bool,

    pub fn reset(self: *RenderContext) void {
        self.code_block_active = false;
    }
};

pub const LineBuffer = struct {
    buf: std.ArrayListAligned(u8, null),
    allocator: std.mem.Allocator,
    render_ctx: *RenderContext,

    pub fn init(allocator: std.mem.Allocator, render_ctx: *RenderContext) LineBuffer {
        return .{
            .buf = .empty,
            .allocator = allocator,
            .render_ctx = render_ctx,
        };
    }

    pub fn feed(self: *LineBuffer, bytes: []const u8, writer: *std.Io.Writer) !void {
        try self.buf.appendSlice(self.allocator, bytes);

        while (true) {
            const nl_pos = std.mem.indexOfScalar(u8, self.buf.items, '\n') orelse break;
            const line_end = nl_pos + 1;

            var line_start: usize = 0;
            if (nl_pos > 0 and self.buf.items[nl_pos - 1] == '\r') {
                line_start = @intCast(nl_pos - 1);
            } else {
                line_start = @intCast(nl_pos);
            }

            const line_raw = if (line_start > 0) blk: {
                const idx = lastFullCodepoint(self.buf.items[0..line_start]);
                if (idx < line_start) {
                    break :blk idx;
                }
                break :blk line_start;
            } else line_start;

            if (line_raw == 0) break;

            const line = self.buf.items[0..line_raw];

            if (!std.unicode.utf8ValidateSlice(line)) {
                drainBuf(&self.buf, line_end);
                continue;
            }

            const styled = renderLine(self.render_ctx, self.allocator, line) catch {
                drainBuf(&self.buf, line_end);
                continue;
            };
            defer self.allocator.free(styled);

            writer.print("{s}\n", .{styled}) catch {};
            writer.flush() catch {};

            drainBuf(&self.buf, line_end);
        }

        // Stream remaining partial content immediately, then clear for next feed
        if (self.buf.items.len > 0 and std.unicode.utf8ValidateSlice(self.buf.items)) {
            writer.print("{s}", .{self.buf.items}) catch {};
            writer.flush() catch {};
        }
        self.buf.clearRetainingCapacity();
    }

    pub fn flush(self: *LineBuffer, writer: *std.Io.Writer) !void {
        if (self.buf.items.len == 0) return;

        const line = try self.allocator.dupe(u8, self.buf.items);
        defer self.allocator.free(line);
        self.buf.clearRetainingCapacity();

        if (!std.unicode.utf8ValidateSlice(line)) return;

        const styled = renderLine(self.render_ctx, self.allocator, line) catch return;
        defer self.allocator.free(styled);

        writer.print("{s}", .{styled}) catch {};
    }

    pub fn reset(self: *LineBuffer) void {
        self.buf.clearRetainingCapacity();
    }

    fn lastFullCodepoint(data: []const u8) usize {
        var i: usize = data.len;
        while (i > 0) {
            i -= 1;
            const len = std.unicode.utf8ByteSequenceLength(data[i]) catch continue;
            if (i + len <= data.len) return i + len;
            if (i + len > data.len) return i;
        }
        return data.len;
    }
};

fn drainBuf(buf: *std.ArrayListAligned(u8, null), keep_start: usize) void {
    const rem_len = buf.items.len -| keep_start;
    if (rem_len > 0) {
        std.mem.copyForwards(u8, buf.items[0..rem_len], buf.items[keep_start..]);
        buf.shrinkRetainingCapacity(rem_len);
    } else {
        buf.clearRetainingCapacity();
    }
}

threadlocal var DISPLAY_BUF: [256]u8 = undefined;

fn shorten(s: []const u8, max: usize) []const u8 {
    return s[0..@min(s.len, max)];
}

fn labelFromValue(tool_name: []const u8, value: std.json.Value) []const u8 {
    if (std.mem.eql(u8, tool_name, "read")) {
        if (value.object.get("path")) |v| if (v == .string)
            return std.fmt.bufPrint(&DISPLAY_BUF, "Read {s}", .{v.string}) catch return tool_name;
        return tool_name;
    }
    if (std.mem.eql(u8, tool_name, "write")) {
        if (value.object.get("path")) |v| if (v == .string)
            return std.fmt.bufPrint(&DISPLAY_BUF, "Write {s}", .{v.string}) catch return tool_name;
        return tool_name;
    }
    if (std.mem.eql(u8, tool_name, "bash")) {
        if (value.object.get("command")) |v| if (v == .string)
            return std.fmt.bufPrint(&DISPLAY_BUF, "$ {s}", .{shorten(v.string, 60)}) catch return tool_name;
        return tool_name;
    }
    if (std.mem.eql(u8, tool_name, "grep")) {
        const pattern = if (value.object.get("pattern")) |v| if (v == .string) v.string else "" else "";
        const path = if (value.object.get("path")) |v| if (v == .string) v.string else "" else "";
        if (pattern.len > 0 and path.len > 0) {
            return std.fmt.bufPrint(&DISPLAY_BUF, "Grep \"{s}\" {s}", .{ shorten(pattern, 40), shorten(path, 40) }) catch return tool_name;
        }
        return tool_name;
    }
    if (std.mem.eql(u8, tool_name, "glob")) {
        const pattern = if (value.object.get("pattern")) |v| if (v == .string) v.string else "" else "";
        const path = if (value.object.get("path")) |v| if (v == .string) v.string else "" else "";
        if (pattern.len > 0) {
            if (path.len > 0) {
                return std.fmt.bufPrint(&DISPLAY_BUF, "Glob {s} [{s}]", .{ shorten(pattern, 40), shorten(path, 40) }) catch return tool_name;
            }
            return std.fmt.bufPrint(&DISPLAY_BUF, "Glob {s}", .{shorten(pattern, 80)}) catch return tool_name;
        }
        return tool_name;
    }
    if (std.mem.eql(u8, tool_name, "skill")) {
        if (value.object.get("name")) |v| if (v == .string)
            return std.fmt.bufPrint(&DISPLAY_BUF, "Skill {s}", .{v.string}) catch return tool_name;
        return tool_name;
    }
    return tool_name;
}

pub const ToolDisplay = struct {
    ctx: *RenderContext,
    writer: *std.Io.Writer,

        pub fn renderCb(context: ?*anyopaque, tool_name: []const u8, tool_args: []const u8, had_error: bool, user_output: ?[]const u8) anyerror!void {
            const self: *ToolDisplay = @ptrCast(@alignCast(context orelse return error.NullContext));
            try self.render(tool_name, tool_args, had_error, user_output);
        }

        pub fn render(self: *ToolDisplay, tool_name: []const u8, args_json: []const u8, had_error: bool, user_output: ?[]const u8) anyerror!void {
            _ = had_error;
            writeToolLabelOpen(self.writer);

            const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, args_json, .{ .ignore_unknown_fields = true }) catch {
                self.writer.print("{s}", .{tool_name}) catch |err| return err;
                writeToolLabelClose(self.writer);
                return;
            };
            defer parsed.deinit();

            const label = labelFromValue(tool_name, parsed.value);
            self.writer.print("{s}", .{label}) catch |err| {
                return err;
            };

            writeToolLabelClose(self.writer);

            if (user_output) |out| {
                self.writer.print("\n{s}", .{out}) catch |err| {
                    return err;
                };
            }
        }

    fn writeToolLabelOpen(writer: *std.Io.Writer) void {
        if (colorize) {
            writer.print("{s}{s} 工具 {s} ", .{ C.bg_bright_magenta, C.white, C.reset }) catch |err| {
                if (err == error.BrokenPipe) return; // BrokenPipe non-fatal; best-effort display
                // other IO errors non-fatal; best-effort display
            };
        }
    }

    fn writeToolLabelClose(writer: *std.Io.Writer) void {
        _ = writer.print("\n", .{}) catch {}; // EPIPE non-fatal; other IO errors lost to stderr
    }
};

pub fn writePrompt(writer: *std.Io.Writer) !void {
    if (!colorize) {
        try writer.print("> ", .{});
        return;
    }
    try writer.print("{s}{s} 用户 {s} ", .{ C.bg_blue, C.white, C.reset });
}

fn labelPlain(mtype: MessageType) []const u8 {
    return switch (mtype) {
        .user => "用户 ",
        .think => "思考 ",
        .tool => "工具 ",
        .output => "输出 ",
        .err => "ERROR ",
        .warning => "WARN  ",
        .success => "OK    ",
    };
}

const LinkEntry = struct {
    placeholder: []const u8,
    text: []const u8,
    url: []const u8,
};

pub fn renderLine(ctx: *RenderContext, allocator: std.mem.Allocator, line: []const u8) ![]const u8 {
    if (line.len == 0) return try allocator.dupe(u8, "");

    // 0. code block boundary detection
    if (std.mem.startsWith(u8, line, "```")) {
        ctx.code_block_active = !ctx.code_block_active;
        if (!ctx.colorize) return try allocator.dupe(u8, line);
        return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ C.dim, line, C.reset });
    }

    if (!ctx.colorize) return try allocator.dupe(u8, line);

    // Inside code block
    if (ctx.code_block_active) {
        return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ C.dim, line, C.reset });
    }

    // 1. heading
    if (isHeading(line)) |len| {
        const rest = line[len..];
        return std.fmt.allocPrint(allocator, "{s}{s}{s}{s}{s}", .{ C.bold, C.cyan, line[0..len], rest, C.reset });
    }

    // 2. blockquote
    if (std.mem.startsWith(u8, line, "> ")) {
        return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ C.dim, line, C.reset });
    }

    // 3. list -- keep as-is
    if (isListItem(line)) {
        return try allocator.dupe(u8, line);
    }

    return renderInline(allocator, line);
}

fn isHeading(line: []const u8) ?usize {
    var hash_count: usize = 0;
    for (line[0..@min(line.len, 6)]) |ch| {
        if (ch == '#') {
            hash_count += 1;
        } else if (ch == ' ' and hash_count > 0) {
            return hash_count + 1;
        } else {
            break;
        }
    }
    return null;
}

fn isListItem(line: []const u8) bool {
    if (line.len < 2) return false;
    return (line[0] == '-' or line[0] == '*' or line[0] == '+') and line[1] == ' ';
}

fn renderInline(allocator: std.mem.Allocator, line: []const u8) ![]const u8 {
    var links: std.ArrayListAligned(LinkEntry, null) = .empty;
    defer {
        for (links.items) |entry| {
            allocator.free(entry.placeholder);
            allocator.free(entry.text);
            allocator.free(entry.url);
        }
        links.deinit(allocator);
    }

    const r0 = try extractLinks(allocator, line, &links);
    errdefer allocator.free(r0);

    const r1 = try applyBold(allocator, r0);
    allocator.free(r0);

    const r2 = try applyItalic(allocator, r1);
    allocator.free(r1);

    const r3 = try applyInlineCode(allocator, r2);
    allocator.free(r2);

    if (links.items.len > 0) {
        const r4 = try restoreLinks(allocator, r3, links.items);
        allocator.free(r3);
        return r4;
    }

    return r3;
}

fn extractLinks(allocator: std.mem.Allocator, line: []const u8, links: *std.ArrayListAligned(LinkEntry, null)) ![]const u8 {
    var buf: std.ArrayListAligned(u8, null) = .empty;
    errdefer buf.deinit(allocator);
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '[') {
            if (findLinkEnd(line, i)) |info| {
                const link_text = line[info.text_start..info.text_end];
                const link_url = line[info.url_start..info.url_end];

                const pid = links.items.len;
                const placeholder = try std.fmt.allocPrint(allocator, "\x01LINK{d}\x01", .{pid});
                errdefer allocator.free(placeholder);

                const text_dup = try allocator.dupe(u8, link_text);
                errdefer allocator.free(text_dup);

                const url_dup = try allocator.dupe(u8, link_url);
                errdefer allocator.free(url_dup);

                try links.append(allocator, .{
                    .placeholder = placeholder,
                    .text = text_dup,
                    .url = url_dup,
                });
                try buf.appendSlice(allocator, placeholder);
                i = info.end;
                continue;
            }
        }
        try buf.append(allocator, line[i]);
        i += 1;
    }
    const result = buf.toOwnedSlice(allocator);
    buf = .empty;
    return result;
}

const LinkInfo = struct {
    text_start: usize,
    text_end: usize,
    url_start: usize,
    url_end: usize,
    end: usize,
};

fn findLinkEnd(line: []const u8, start: usize) ?LinkInfo {
    var i = start + 1;
    var depth: usize = 1;
    while (i < line.len) : (i += 1) {
        if (line[i] == '[') {
            depth += 1;
        } else if (line[i] == ']') {
            depth -= 1;
            if (depth == 0) break;
        }
    } else return null;

    const text_end = i;
    i += 1;
    if (i >= line.len or line[i] != '(') return null;
    i += 1;
    const url_start = i;
    var paren_depth: usize = 1;
    while (i < line.len) : (i += 1) {
        if (line[i] == '(') {
            paren_depth += 1;
        } else if (line[i] == ')') {
            paren_depth -= 1;
            if (paren_depth == 0) break;
        }
    } else return null;

    return .{
        .text_start = start + 1,
        .text_end = text_end,
        .url_start = url_start,
        .url_end = i,
        .end = i + 1,
    };
}

fn applyBold(allocator: std.mem.Allocator, line: []const u8) ![]const u8 {
    return applyWrapped(allocator, line, "**", C.bold);
}

fn applyItalic(allocator: std.mem.Allocator, line: []const u8) ![]const u8 {
    return applyWrappedSingle(allocator, line, C.italic);
}

fn applyInlineCode(allocator: std.mem.Allocator, line: []const u8) ![]const u8 {
    return applyWrapped(allocator, line, "`", C.dim);
}

fn applyWrapped(allocator: std.mem.Allocator, line: []const u8, marker: []const u8, ansi: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, line, marker)) |first| {
        if (std.mem.indexOfPos(u8, line, first + marker.len, marker)) |second| {
            if (second > first + marker.len) {
                var buf: std.ArrayListAligned(u8, null) = .empty;
                errdefer buf.deinit(allocator);
                try buf.appendSlice(allocator, line[0..first]);
                try buf.appendSlice(allocator, ansi);
                try buf.appendSlice(allocator, line[first + marker.len .. second]);
                try buf.appendSlice(allocator, C.reset);
                try buf.appendSlice(allocator, line[second + marker.len ..]);
                const remainder = try buf.toOwnedSlice(allocator);
                buf = .empty;
                defer allocator.free(remainder);
                return applyWrapped(allocator, remainder, marker, ansi);
            }
        }
    }
    return try allocator.dupe(u8, line);
}

fn applyWrappedSingle(allocator: std.mem.Allocator, line: []const u8, ansi: []const u8) ![]const u8 {
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '*') {
            if (i + 1 < line.len and line[i + 1] == '*') {
                i += 2;
                continue;
            }
            if (std.mem.indexOfScalarPos(u8, line, i + 1, '*')) |end| {
                if (end > i + 1) {
                    var buf: std.ArrayListAligned(u8, null) = .empty;
                    errdefer buf.deinit(allocator);
                    try buf.appendSlice(allocator, line[0..i]);
                    try buf.appendSlice(allocator, ansi);
                    try buf.appendSlice(allocator, line[i + 1 .. end]);
                    try buf.appendSlice(allocator, C.reset);
                    try buf.appendSlice(allocator, line[end + 1 ..]);
                    const remainder = try buf.toOwnedSlice(allocator);
                    buf = .empty;
                    defer allocator.free(remainder);
                    return applyWrappedSingle(allocator, remainder, ansi);
                }
            }
        }
        i += 1;
    }
    return try allocator.dupe(u8, line);
}

fn restoreLinks(allocator: std.mem.Allocator, line: []const u8, links: []const LinkEntry) ![]const u8 {
    var result: std.ArrayListAligned(u8, null) = .empty;
    errdefer result.deinit(allocator);
    var i: usize = 0;
    while (i < line.len) {
        var found: bool = false;
        for (links, 0..) |entry, idx| {
            if (std.mem.startsWith(u8, line[i..], entry.placeholder)) {
                const inner = try applyBold(allocator, entry.text);
                defer allocator.free(inner);
                const inner2 = try applyItalic(allocator, inner);
                defer allocator.free(inner2);
                const inner3 = try applyInlineCode(allocator, inner2);
                defer allocator.free(inner3);
                try result.appendSlice(allocator, C.blue);
                try result.appendSlice(allocator, inner3);
                try result.appendSlice(allocator, C.reset);
                i += entry.placeholder.len;
                _ = idx;
                found = true;
                break;
            }
        }
        if (!found) {
            try result.append(allocator, line[i]);
            i += 1;
        }
    }
    const res = result.toOwnedSlice(allocator);
    result = .empty;
    return res;
}

const windows = struct {
    extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetConsoleMode(hConsoleHandle: ?*anyopaque, lpMode: *u32) callconv(.winapi) u32;
    extern "kernel32" fn SetConsoleMode(hConsoleHandle: ?*anyopaque, dwMode: u32) callconv(.winapi) u32;
    extern "kernel32" fn GetEnvironmentVariableA(
        lpName: [*:0]const u8,
        lpBuffer: ?[*]u8,
        nSize: u32,
    ) callconv(.winapi) u32;
    extern "kernel32" fn SetConsoleCP(wCodePageID: u32) callconv(.winapi) i32;
    extern "kernel32" fn SetConsoleOutputCP(wCodePageID: u32) callconv(.winapi) i32;
};

// ──────────────────────────── tests ────────────────────────────

test "render: Color constants" {
    try std.testing.expectEqualStrings("\x1b[0m", C.reset);
    try std.testing.expectEqualStrings("\x1b[32m", C.green);
    try std.testing.expectEqualStrings("\x1b[33m", C.yellow);
    try std.testing.expectEqualStrings("\x1b[31m", C.red);
    try std.testing.expectEqualStrings("\x1b[1m", C.bold);
    try std.testing.expectEqualStrings("\x1b[2m", C.dim);
    try std.testing.expectEqualStrings("\x1b[36m", C.cyan);
    try std.testing.expectEqualStrings("\x1b[34m", C.blue);
    try std.testing.expectEqualStrings("\x1b[35m", C.magenta);
    try std.testing.expectEqualStrings("\x1b[37m", C.white);
    try std.testing.expectEqualStrings("\x1b[3m", C.italic);
    try std.testing.expectEqualStrings("\x1b[90m", C.bright_black);
    try std.testing.expectEqualStrings("\x1b[44m", C.bg_blue);
    try std.testing.expectEqualStrings("\x1b[100m", C.bg_gray);
    try std.testing.expectEqualStrings("\x1b[42m", C.bg_green);
    try std.testing.expectEqualStrings("\x1b[105m", C.bg_bright_magenta);
}

test "render: visibleWidth ASCII" {
    try std.testing.expectEqual(@as(usize, 5), visibleWidth("hello"));
    try std.testing.expectEqual(@as(usize, 0), visibleWidth(""));
}

test "render: visibleWidth CJK" {
    try std.testing.expectEqual(@as(usize, 4), visibleWidth("你好"));
    try std.testing.expectEqual(@as(usize, 5), visibleWidth("a你好"));
    try std.testing.expectEqual(@as(usize, 5), visibleWidth("你好b"));
    try std.testing.expectEqual(@as(usize, 6), visibleWidth("a你好b"));
}

test "render: writeLabeled user" {
    colorize = true;
    defer colorize = false;

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    try writeLabeled(&aw.writer, .user, "read src/main.zig");

    var result = aw.toArrayList();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.startsWith(u8, result.items, C.bg_blue));
    try std.testing.expect(std.mem.indexOf(u8, result.items, "read src/main.zig") != null);
}

test "render: writeLabeled tool" {
    colorize = true;
    defer colorize = false;

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    try writeLabeled(&aw.writer, .tool, "Read \"C:/Project/read.md\" [limit=30]");

    var result = aw.toArrayList();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.startsWith(u8, result.items, C.bg_bright_magenta));
    try std.testing.expect(std.mem.indexOf(u8, result.items, "read.md") != null);
}

test "render: writeLabeled think" {
    colorize = true;
    defer colorize = false;

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    try writeLabeled(&aw.writer, .think, "analyzing requirements...");

    var result = aw.toArrayList();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.startsWith(u8, result.items, C.bg_gray));
    try std.testing.expect(std.mem.indexOf(u8, result.items, "analyzing") != null);
}

test "render: writeLabeled output" {
    colorize = true;
    defer colorize = false;

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    try writeLabeled(&aw.writer, .output, "Result: file contents");

    var result = aw.toArrayList();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.startsWith(u8, result.items, C.bg_green));
    try std.testing.expect(std.mem.indexOf(u8, result.items, "Result") != null);
}

test "render: writeLabeled err" {
    colorize = true;
    defer colorize = false;

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    try writeLabeled(&aw.writer, .err, "API key not set");

    var result = aw.toArrayList();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.startsWith(u8, result.items, C.red));
    try std.testing.expect(std.mem.indexOf(u8, result.items, "ERROR") != null);
}

test "render: writeLabeled warning" {
    colorize = true;
    defer colorize = false;

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    try writeLabeled(&aw.writer, .warning, "context may overflow");

    var result = aw.toArrayList();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.startsWith(u8, result.items, C.yellow));
    try std.testing.expect(std.mem.indexOf(u8, result.items, "WARN") != null);
}

test "render: writeLabeled success" {
    colorize = true;
    defer colorize = false;

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    try writeLabeled(&aw.writer, .success, "session saved");

    var result = aw.toArrayList();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.startsWith(u8, result.items, C.green));
    try std.testing.expect(std.mem.indexOf(u8, result.items, "OK") != null);
}

test "render: renderLine heading" {
    var ctx = RenderContext{ .colorize = true };

    const result = try renderLine(&ctx, std.testing.allocator, "## Title");
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.startsWith(u8, result, C.bold));
    try std.testing.expect(std.mem.indexOf(u8, result, C.cyan) != null);
    try std.testing.expect(std.mem.endsWith(u8, result, C.reset));
}

test "render: renderLine code block" {
    var ctx = RenderContext{ .colorize = true };

    const open = try renderLine(&ctx, std.testing.allocator, "```zig");
    defer std.testing.allocator.free(open);

    const result = try renderLine(&ctx, std.testing.allocator, "const x = 1;");
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.startsWith(u8, result, C.dim));
    try std.testing.expect(std.mem.endsWith(u8, result, C.reset));

    const close = try renderLine(&ctx, std.testing.allocator, "```");
    defer std.testing.allocator.free(close);
}

test "render: renderLine bold" {
    var ctx = RenderContext{ .colorize = true };

    const result = try renderLine(&ctx, std.testing.allocator, "hello **world** here");
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, C.bold) != null);
    try std.testing.expectEqualStrings("world", result[std.mem.indexOf(u8, result, C.bold).? + C.bold.len .. std.mem.indexOf(u8, result, C.reset).?]);
}

test "render: renderLine inline code" {
    var ctx = RenderContext{ .colorize = true };

    const result = try renderLine(&ctx, std.testing.allocator, "use `foo()` for that");
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, C.dim) != null);
}

test "render: renderLine link" {
    var ctx = RenderContext{ .colorize = true };

    const result = try renderLine(&ctx, std.testing.allocator, "click [here](https://example.com) now");
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, C.blue) != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "here") != null);
}

test "render: renderLine link with bold" {
    var ctx = RenderContext{ .colorize = true };

    const result = try renderLine(&ctx, std.testing.allocator, "see [**important**](url) pls");
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, C.blue) != null);
    try std.testing.expect(std.mem.indexOf(u8, result, C.bold) != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "important") != null);
}

test "render: renderLine list" {
    var ctx = RenderContext{ .colorize = true };

    const result = try renderLine(&ctx, std.testing.allocator, "- item one");
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("- item one", result);
}

test "render: renderLine blockquote" {
    var ctx = RenderContext{ .colorize = true };

    const result = try renderLine(&ctx, std.testing.allocator, "> a quote");
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.startsWith(u8, result, C.dim));
    try std.testing.expect(std.mem.endsWith(u8, result, C.reset));
}

test "render: renderLine mixed" {
    var ctx = RenderContext{ .colorize = true };

    const result = try renderLine(&ctx, std.testing.allocator, "**bold** and `code` together");
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, C.bold) != null);
    try std.testing.expect(std.mem.indexOf(u8, result, C.dim) != null);
}

test "render: code block auto-detect" {
    var ctx = RenderContext{ .colorize = true };

    const open = try renderLine(&ctx, std.testing.allocator, "```");
    defer std.testing.allocator.free(open);
    try std.testing.expect(std.mem.startsWith(u8, open, C.dim));

    const inner = try renderLine(&ctx, std.testing.allocator, "code inside");
    defer std.testing.allocator.free(inner);
    try std.testing.expect(std.mem.startsWith(u8, inner, C.dim));

    const close = try renderLine(&ctx, std.testing.allocator, "```");
    defer std.testing.allocator.free(close);
    try std.testing.expect(std.mem.startsWith(u8, close, C.dim));

    const after = try renderLine(&ctx, std.testing.allocator, "normal text");
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings("normal text", after);
}

test "render: writeLabeled no colorize" {
    colorize = false;

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    try writeLabeled(&aw.writer, .user, "hello");

    var result = aw.toArrayList();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.items, "hello") != null);
}

test "render: renderLine no colorize" {
    var ctx = RenderContext{ .colorize = false };

    const result = try renderLine(&ctx, std.testing.allocator, "**bold** text");
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("**bold** text", result);
}

test "render: renderLine empty" {
    var ctx = RenderContext{ .colorize = true };

    const result = try renderLine(&ctx, std.testing.allocator, "");
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("", result);
}

test "render: renderLine italic" {
    var ctx = RenderContext{ .colorize = true };

    const result = try renderLine(&ctx, std.testing.allocator, "some *italic* text");
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, C.italic) != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "italic") != null);
}
