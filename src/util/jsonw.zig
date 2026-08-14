const std = @import("std");

/// Minimal JSON writer: auto-comma, full escaping, self-balancing containers.
/// Serialization path only — parse side uses std.json. Zero external deps.
///
/// Two buffer modes:
///   - init(allocator): allocating (owns an Io.Writer.Allocating)
///   - initFixed(buf):  fixed stack buffer (borrowed, zero-alloc hot path)
/// All writes go through the unified `out()` target. Callers finalize with
/// `result()` (borrow or transfer) — see Result.
pub const JsonWriter = struct {
    pub const max_depth: usize = 16;

    allocator: std.mem.Allocator,
    /// Unified write target. alloc mode: aliases aw.writer (authoritative end
    /// lives in aw); fixed mode: the Io.Writer.fixed instance (end lives here).
    writer: std.Io.Writer,
    aw: ?std.Io.Writer.Allocating = null,
    fixed_buf: ?[]u8 = null,
    depth: usize = 0,
    stack: [max_depth]ContainerState = undefined,

    const ContainerState = struct {
        is_object: bool,
        has_elements: bool,
    };

    /// Allocating writer (owns an Io.Writer.Allocating buffer).
    pub fn init(allocator: std.mem.Allocator) JsonWriter {
        const aw = std.Io.Writer.Allocating.init(allocator);
        const w = aw.writer;
        return .{ .allocator = allocator, .writer = w, .aw = aw };
    }

    /// Fixed-buffer writer over an external stack slice (zero-alloc hot path).
    /// `result()` returns a borrowed view; `deinit` is a no-op.
    pub fn initFixed(buf: []u8) JsonWriter {
        return .{
            .allocator = undefined,
            .writer = std.Io.Writer.fixed(buf),
            .fixed_buf = buf,
        };
    }

    /// Error-path cleanup: alloc mode frees the aw buffer; fixed mode is a
    /// no-op. Idempotent after `result()` (aw transferred/reset).
    pub fn deinit(self: *JsonWriter) void {
        if (self.aw) |*a| {
            a.deinit();
            self.aw = null;
        }
    }

    /// Finalize: alloc mode transfers ownership (toOwnedSlice, may OOM);
    /// fixed mode returns a borrowed view (allocator=null, deinit no-op).
    /// Callers: `var out = try jw.result(); defer out.deinit();`
    pub fn result(self: *JsonWriter) !Result {
        if (self.aw) |*a| {
            const bytes = try a.toOwnedSlice();
            return .{ .bytes = bytes, .allocator = self.allocator };
        }
        return .{ .bytes = self.writer.buffered(), .allocator = null };
    }

    fn out(self: *JsonWriter) *std.Io.Writer {
        return if (self.aw) |*a| &a.writer else &self.writer;
    }

    fn comma(self: *JsonWriter) !void {
        if (self.depth == 0) return error.JsonUnderflow;
        const top = &self.stack[self.depth - 1];
        if (top.has_elements) try self.out().writeAll(",");
        top.has_elements = true;
    }

    fn beginContainer(self: *JsonWriter, key: ?[]const u8, is_object: bool) !void {
        if (self.depth >= max_depth) return error.JsonOverflow;
        if (key) |k| {
            try self.comma();
            try self.out().writeByte('"');
            try escapeInto(self.out(), k);
            try self.out().writeByte('"');
            try self.out().writeByte(':');
        } else if (self.depth > 0) {
            try self.comma();
        }
        try self.out().writeByte(if (is_object) '{' else '[');
        self.stack[self.depth] = .{ .is_object = is_object, .has_elements = false };
        self.depth += 1;
    }

    /// Open an object container. `key` null = top-level/array element (writes
    /// `{`), non-null = object field (writes `"key":{`). Returns
    /// `error.JsonOverflow` at depth >= max_depth.
    pub fn beginObject(self: *JsonWriter, key: ?[]const u8) !void {
        try self.beginContainer(key, true);
    }

    /// Open an array container. Same key semantics as beginObject.
    pub fn beginArray(self: *JsonWriter, key: ?[]const u8) !void {
        try self.beginContainer(key, false);
    }

    /// Close the innermost container (`}` or `]` per its type). Returns
    /// `error.JsonUnderflow` when no container is open.
    pub fn endValue(self: *JsonWriter) !void {
        if (self.depth == 0) return error.JsonUnderflow;
        const is_object = self.stack[self.depth - 1].is_object;
        try self.out().writeByte(if (is_object) '}' else ']');
        self.depth -= 1;
    }

    fn writeKey(self: *JsonWriter, key: []const u8) !void {
        try self.comma();
        try self.out().writeByte('"');
        try escapeInto(self.out(), key);
        try self.out().writeByte('"');
        try self.out().writeByte(':');
    }

    /// Write an object string field: `"key":"escaped"`. Auto-comma + full escaping.
    pub fn stringField(self: *JsonWriter, key: []const u8, value: []const u8) !void {
        try self.writeKey(key);
        try self.out().writeByte('"');
        try escapeInto(self.out(), value);
        try self.out().writeByte('"');
    }

    pub fn intField(self: *JsonWriter, key: []const u8, value: anytype) !void {
        try self.writeKey(key);
        try self.out().print("{d}", .{value});
    }

    pub fn boolField(self: *JsonWriter, key: []const u8, value: bool) !void {
        try self.writeKey(key);
        try self.out().writeAll(if (value) "true" else "false");
    }

    pub fn rawField(self: *JsonWriter, key: []const u8, raw: []const u8) !void {
        try self.writeKey(key);
        try self.out().writeAll(raw);
    }

    pub fn stringElem(self: *JsonWriter, value: []const u8) !void {
        try self.comma();
        try self.out().writeByte('"');
        try escapeInto(self.out(), value);
        try self.out().writeByte('"');
    }

    pub fn intElem(self: *JsonWriter, value: anytype) !void {
        try self.comma();
        try self.out().print("{d}", .{value});
    }

    pub fn boolElem(self: *JsonWriter, value: bool) !void {
        try self.comma();
        try self.out().writeAll(if (value) "true" else "false");
    }

    pub fn rawElem(self: *JsonWriter, raw: []const u8) !void {
        try self.comma();
        try self.out().writeAll(raw);
    }

    /// Append raw bytes directly to the output (e.g. JSONL trailing newline).
    /// No escaping, no comma handling — for structural delimiters only.
    pub fn rawBytes(self: *JsonWriter, bytes: []const u8) !void {
        try self.out().writeAll(bytes);
    }

    /// Append a raw integer value (no key, no comma). For pre-formed fragments
    /// like `"max_tokens":<n>` assembled via rawBytes + this.
    pub fn rawInt(self: *JsonWriter, value: anytype) !void {
        try self.out().print("{d}", .{value});
    }
};

/// Final ownership holder. `allocator` non-null => owning (deinit frees);
/// null => borrowed view (deinit no-op). Callers always `defer out.deinit()`.
pub const Result = struct {
    bytes: []u8,
    allocator: ?std.mem.Allocator = null,

    /// Release owned bytes (alloc mode) or no-op (borrowed view). Idempotent.
    pub fn deinit(self: *Result) void {
        if (self.allocator) |a| a.free(self.bytes);
        self.* = undefined;
    }
};

/// Escape a string for JSON output (full escaping: control chars -> \u00XX,
/// invalid UTF-8 -> \ufffd, valid multi-byte passes through). Mirrors the
/// legacy session.zig appendEscapedJsonString (removed in F7) implementation.
pub fn escapeInto(out: *std.Io.Writer, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c < 0x80) {
            switch (c) {
                '"' => try out.writeAll("\\\""),
                '\\' => try out.writeAll("\\\\"),
                '\n' => try out.writeAll("\\n"),
                '\r' => try out.writeAll("\\r"),
                '\t' => try out.writeAll("\\t"),
                0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                    var hex_buf: [6]u8 = undefined;
                    const hex = try std.fmt.bufPrint(&hex_buf, "\\u00{x:0>2}", .{@as(u8, c)});
                    try out.writeAll(hex);
                },
                else => try out.writeByte(c),
            }
            i += 1;
        } else if (c >= 0xC0 and c <= 0xDF) {
            if (i + 1 < s.len) {
                try out.writeAll(s[i .. i + 2]);
                i += 2;
            } else {
                try out.writeAll("\\ufffd");
                i += 1;
            }
        } else if (c >= 0xE0 and c <= 0xEF) {
            if (i + 2 < s.len) {
                try out.writeAll(s[i .. i + 3]);
                i += 3;
            } else {
                try out.writeAll("\\ufffd");
                i += 1;
            }
        } else if (c >= 0xF0 and c <= 0xF4) {
            if (i + 3 < s.len) {
                try out.writeAll(s[i .. i + 4]);
                i += 4;
            } else {
                try out.writeAll("\\ufffd");
                i += 1;
            }
        } else {
            try out.writeAll("\\ufffd");
            i += 1;
        }
    }
}

/// Allocating escape: returns a newly allocated, fully-escaped string.
/// Caller owns the result (free with allocator). Convenience for callers that
/// embed escaped fragments into a larger hand-built string.
pub fn escapeAlloc(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try escapeInto(&aw.writer, s);
    var list = aw.toArrayList();
    defer list.deinit(allocator);
    return try list.toOwnedSlice(allocator);
}

test "jsonw: escapeInto escapes special chars and control chars" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try escapeInto(&aw.writer, "a\"b\\c\nd\re\tf\x00\x01\x1f");
    var list = aw.toArrayList();
    defer list.deinit(std.testing.allocator);
    const s = list.items;
    try std.testing.expect(std.mem.indexOf(u8, s, "\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\\\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\\r") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\\t") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\\u0000") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\\u0001") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\\u001f") != null);
}

test "jsonw: escapeInto invalid UTF-8 replaced" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try escapeInto(&aw.writer, "\xAA");
    var list = aw.toArrayList();
    defer list.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, list.items, "\\ufffd") != null);
}

test "jsonw: object with nested array and object" {
    var jw = JsonWriter.init(std.testing.allocator);
    errdefer jw.deinit();
    try jw.beginObject(null);
    try jw.stringField("model", "deepseek/model");
    try jw.intField("count", 42);
    try jw.boolField("ok", true);
    try jw.beginArray("items");
    try jw.stringElem("x");
    try jw.intElem(7);
    try jw.endValue();
    try jw.beginObject("sub");
    try jw.stringField("k", "v");
    try jw.endValue();
    try jw.endValue();
    var out = try jw.result();
    defer out.deinit();
    try std.testing.expectEqualStrings(
        "{\"model\":\"deepseek/model\",\"count\":42,\"ok\":true,\"items\":[\"x\",7],\"sub\":{\"k\":\"v\"}}",
        out.bytes,
    );
}

test "jsonw: empty object and empty array" {
    var jw = JsonWriter.init(std.testing.allocator);
    errdefer jw.deinit();
    try jw.beginObject(null);
    try jw.endValue();
    try jw.beginObject(null);
    try jw.beginArray("a");
    try jw.endValue();
    try jw.endValue();
    var out = try jw.result();
    defer out.deinit();
    try std.testing.expectEqualStrings("{}{\"a\":[]}", out.bytes);
}

test "jsonw: initFixed overflow WriteFailed, result borrows view" {
    var stack_buf: [16]u8 = undefined;
    var jw = JsonWriter.initFixed(&stack_buf);
    try jw.beginObject(null);
    try jw.stringField("key", "hello");
    // buffer exhausted -> WriteFailed on further write
    try std.testing.expectError(error.WriteFailed, jw.stringField("k2", "overflow"));
    var out = try jw.result();
    defer out.deinit(); // fixed mode: no-op
    try std.testing.expect(std.mem.startsWith(u8, out.bytes, "{\"key\":\"hello\""));
}

test "jsonw: depth overflow and underflow" {
    var jw = JsonWriter.init(std.testing.allocator);
    defer jw.deinit();
    var i: usize = 0;
    while (i < JsonWriter.max_depth) : (i += 1) {
        try jw.beginObject(null);
    }
    try std.testing.expectError(error.JsonOverflow, jw.beginObject(null));

    var jw2 = JsonWriter.init(std.testing.allocator);
    defer jw2.deinit();
    try std.testing.expectError(error.JsonUnderflow, jw2.endValue());
}

test "jsonw: result not called then deinit frees (error-path cleanup)" {
    var jw = JsonWriter.init(std.testing.allocator);
    try jw.beginObject(null);
    try jw.stringField("a", "b");
    jw.deinit(); // must not leak; testing.allocator catches if it does
}
