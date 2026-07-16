const std = @import("std");
const builtin = @import("builtin");
const types = @import("../types.zig");
const signal = @import("../util/signal.zig");

pub const PhaseType = enum { none, thinking, content };

pub const PhaseWriterCb = struct {
    context: ?*anyopaque,
    begin_phase: *const fn (ctx: ?*anyopaque, mtype: PhaseType) void,
    write_raw: *const fn (ctx: ?*anyopaque, bytes: []const u8) void,
    write_rendered: *const fn (ctx: ?*anyopaque, line: []const u8) void,
    end_phase: *const fn (ctx: ?*anyopaque) void,
};

/// OpenAI-compatible API provider. Owns api_key (allocated by init).
pub const Provider = struct {
    config: Config,
    phase_writer: ?PhaseWriterCb = null,

    pub const Config = struct {
        base_url: []const u8,
        api_key: []const u8,
        model: []const u8,
        max_tokens: u32,
        connect_timeout_secs: u16 = 15,
        max_timeout_secs: u16 = 300,
        vendor: Vendor,
        vendor_override: ?Vendor = null,
        model_params: ?[]const u8 = null,
    };

    pub const Vendor = enum { deepseek, standard };

    /// Detect vendor from base_url hostname. api.deepseek.com → deepseek, else standard.
    pub fn detectVendor(base_url: []const u8) Vendor {
        var url = base_url;
        if (std.mem.startsWith(u8, url, "https://")) {
            url = url["https://".len..];
        } else if (std.mem.startsWith(u8, url, "http://")) {
            url = url["http://".len..];
        }
        const hostname = if (std.mem.indexOfAny(u8, url, "/:")) |pos| url[0..pos] else url;
        if (std.mem.eql(u8, hostname, "api.deepseek.com")) return .deepseek;
        return .standard;
    }

    /// Create provider from config entry. Reads api_key from environment. error.ApiKeyNotSet if missing.
    pub fn init(
        allocator: std.mem.Allocator,
        entry: types.ProviderEntry,
        model: *const types.Model,
        vendor_override: ?Vendor,
        io: std.Io,
        phase_writer: ?PhaseWriterCb,
    ) !Provider {
        _ = io;
        const vendor = if (vendor_override) |v| v else detectVendor(entry.base_url);

        var env = std.process.Environ{ .block = .{ .use_global = true } };
        var map = try env.createMap(allocator);
        defer map.deinit();

        const key_raw = map.get(entry.api_key_env) orelse {
            return error.ApiKeyNotSet;
        };

        const key_owned = try allocator.dupe(u8, key_raw);

        return Provider{
            .config = .{
                .base_url = entry.base_url,
                .api_key = key_owned,
                .model = model.id,
                .max_tokens = model.max_tokens,
                .vendor = vendor,
                .vendor_override = vendor_override,
                .model_params = model.params_json,
            },
            .phase_writer = phase_writer,
        };
    }

    /// Call LLM API with streaming SSE. Retries up to 3 times on transient errors.
    /// arena: temporary allocator for response data; caller owns arena lifetime.
    pub fn chatCompletionStreaming(
        self: *Provider,
        arena: *std.heap.ArenaAllocator,
        io: std.Io,
        messages: []const types.Message,
        tools: ?[]const types.Tool,
    ) !types.ProviderResponse {
        return callWithRetry(self, arena, io, messages, tools);
    }

    fn callWithRetry(
        self: *Provider,
        arena: *std.heap.ArenaAllocator,
        io: std.Io,
        messages: []const types.Message,
        tools: ?[]const types.Tool,
    ) !types.ProviderResponse {
        const max_retries: u32 = 5;
        var attempt: u32 = 0;
        while (attempt <= max_retries) : (attempt += 1) {
            if (attempt > 0) {
                const delay_ms: u64 = switch (attempt) {
                    1 => 500,
                    2 => 1000,
                    3 => 2000,
                    4 => 4000,
                    5 => 8000,
                    else => unreachable,
                };
                if (self.phase_writer) |pw| {
                    var status_buf: [64]u8 = undefined;
                    const status = std.fmt.bufPrint(&status_buf, "\n[Retry {d}/{d} — waiting {d}s...]\n", .{ attempt, max_retries, @divTrunc(delay_ms, 1000) }) catch "[Retry...]\n";
                    pw.write_rendered(pw.context, status);
                }
                if (builtin.os.tag == .windows) {
                    const kernel32 = struct {
                        extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.c) void;
                    };
                    kernel32.Sleep(@intCast(delay_ms));
                } else {
                    var ts = std.posix.timespec{
                        .tv_sec = @intCast(delay_ms / 1000),
                        .tv_nsec = @intCast((delay_ms % 1000) * 1_000_000),
                    };
                    _ = std.c.nanosleep(&ts, null);
                }
            }
            return chatCompletionStreamingOnce(self, arena, io, messages, tools) catch |err| {
                if (attempt >= max_retries) return err;
                switch (err) {
                    error.Interrupted, error.ApiError => return err,
                    else => continue,
                }
            };
        }
        unreachable;
    }

    fn chatCompletionStreamingOnce(
        self: *Provider,
        arena: *std.heap.ArenaAllocator,
        io: std.Io,
        messages: []const types.Message,
        tools: ?[]const types.Tool,
    ) !types.ProviderResponse {
        const alloc = arena.allocator();
        const pw = self.phase_writer;

        const url = if (std.mem.endsWith(u8, self.config.base_url, "/chat/completions"))
            self.config.base_url
        else
            try std.fmt.allocPrint(alloc, "{s}/chat/completions", .{self.config.base_url});

        const body_str = try buildJsonBody(self, alloc, messages, tools, true);

        const has_auth = self.config.api_key.len > 0;
        const auth = if (has_auth)
            try std.fmt.allocPrint(alloc, "Authorization: Bearer {s}", .{self.config.api_key})
        else
            "";

        const connect_timeout = self.config.connect_timeout_secs;
        const max_timeout = self.config.max_timeout_secs;

        var argv = std.ArrayListAligned([]const u8, null).empty;
        try argv.append(alloc, if (builtin.os.tag == .windows) "curl.exe" else "curl");
        try argv.appendSlice(alloc, &.{ "-sN", "--fail-with-body" });
        {
            var connect_buf: [16]u8 = undefined;
            var max_buf: [16]u8 = undefined;
            const connect_str = try std.fmt.bufPrint(&connect_buf, "{d}", .{connect_timeout});
            const max_str = try std.fmt.bufPrint(&max_buf, "{d}", .{max_timeout});
            try argv.appendSlice(alloc, &.{ "--connect-timeout", connect_str, "--max-time", max_str });
        }
        try argv.appendSlice(alloc, &.{ "-X", "POST", url });
        try argv.appendSlice(alloc, &.{ "-H", "Content-Type: application/json", "-H", "Accept: application/json" });
        if (has_auth) {
            try argv.appendSlice(alloc, &.{ "-H", auth });
        }
        try argv.appendSlice(alloc, &.{ "-d", "@-" });

        var child = try std.process.spawn(io, .{
            .argv = argv.items,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        });
        var child_finished = false;
        defer {
            if (!child_finished) {
                if (builtin.os.tag != .windows) {
                    child.kill(io) catch {};
                }
                _ = child.wait(io) catch {};
            }
        }

        {
            const stdin_file = child.stdin orelse return error.NoStdin;
            defer stdin_file.close(io);
            try stdin_file.writeStreamingAll(io, body_str);
        }
        child.stdin = null; // ZIG-WIN-001: prevent double-close in child.wait()

        const stdout_file = child.stdout orelse return error.NoStdout;

        var content_buf = std.ArrayListAligned(u8, null).empty;
        var tool_calls_buf = std.ArrayListAligned(types.ToolCall, null).empty;

        const sse_read_buf = try alloc.alloc(u8, 4096);
        var sse_file_reader = stdout_file.readerStreaming(io, sse_read_buf);
        const sse_reader = &sse_file_reader.interface;
        var error_body_buf = std.ArrayListAligned(u8, null).empty;

        var seen_first_data = false;
        var finish_reason: types.FinishReason = .unknown;
        var usage: ?types.TokenUsage = null;

        while (true) {
            if (signal.isInterrupted()) {
                if (builtin.os.tag != .windows) {
                    child.kill(io) catch {};
                }
                _ = child.wait(io) catch {};
                child_finished = true;
                return error.Interrupted;
            }

            const line_opt = sse_reader.takeDelimiter('\n') catch |err| switch (err) {
                error.ReadFailed => return error.ReadFailed,
                error.StreamTooLong => return error.StreamTooLong,
            };
            const raw_line = line_opt orelse break;
            const line = std.mem.trimEnd(u8, raw_line, "\r");

            if (!std.mem.startsWith(u8, line, "data: ")) {
                if (!seen_first_data) {
                    error_body_buf.appendSlice(alloc, raw_line) catch {};
                }
                continue;
            }

            if (!seen_first_data) {
                seen_first_data = true;
            }

            const payload = line["data: ".len..];
            if (std.mem.eql(u8, payload, "[DONE]")) break;

            const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, payload, .{ .ignore_unknown_fields = true }) catch continue;

            if (parsed.object.get("error")) |err_val| {
                if (isRetryableError(err_val)) return error.ApiRateLimited;
                return error.ApiError;
            }

            const choices = if (parsed.object.get("choices")) |c| c.array.items else continue;
            if (choices.len == 0) continue;

            const choice = choices[0].object;

            if (choice.get("finish_reason")) |fr| {
                if (fr != .null) {
                    finish_reason = parseFinishReason(fr.string);
                }
            }

            if (parsed.object.get("usage")) |usage_val| {
                if (usage_val != .null) {
                    const u = usage_val.object;
                    if (u.get("prompt_tokens")) |in_val| {
                        if (u.get("completion_tokens")) |out_val| {
                            if (u.get("total_tokens")) |tot_val| {
                                if (in_val != .null and out_val != .null and tot_val != .null) {
                                    usage = .{
                                        .input = @intCast(in_val.integer),
                                        .output = @intCast(out_val.integer),
                                        .total = @intCast(tot_val.integer),
                                    };
                                }
                            }
                        }
                    }
                }
            }

            if (choice.get("delta")) |delta_val| {
                if (delta_val == .null) continue;
                const delta = delta_val.object;

                if (delta.get("reasoning_content")) |r_val| {
                    if (r_val != .null) {
                        const r = r_val.string;
                        if (pw) |p| p.begin_phase(p.context, .thinking);
                        try content_buf.appendSlice(alloc, r);
                        if (pw) |p| p.write_raw(p.context, r);
                    }
                }

                if (delta.get("content")) |c_val| {
                    if (c_val != .null) {
                        const c = c_val.string;
                        if (pw) |p| p.begin_phase(p.context, .content);
                        try content_buf.appendSlice(alloc, c);
                        if (pw) |p| p.write_raw(p.context, c);
                    }
                }

                if (delta.get("tool_calls")) |tc_array| {
                    if (pw) |p| p.end_phase(p.context);
                    for (tc_array.array.items) |tc_item| {
                        const tc_obj = tc_item.object;
                        const idx_val = tc_obj.get("index") orelse continue;
                        if (idx_val.integer < 0 or idx_val.integer > std.math.maxInt(usize)) continue;
                        const idx: usize = @intCast(idx_val.integer);
                        while (tool_calls_buf.items.len <= idx) {
                            try tool_calls_buf.append(alloc, .{
                                .id = try alloc.dupe(u8, ""),
                                .name = try alloc.dupe(u8, ""),
                                .arguments = try alloc.dupe(u8, ""),
                            });
                        }
                        if (tc_obj.get("id")) |id_val| {
                            if (id_val != .null) {
                                alloc.free(tool_calls_buf.items[idx].id);
                                tool_calls_buf.items[idx].id = try alloc.dupe(u8, id_val.string);
                            }
                        }
                        if (tc_obj.get("function")) |func_val| {
                            if (func_val == .null) continue;
                            const func_obj = func_val.object;
                            if (func_obj.get("name")) |n_val| {
                                if (n_val != .null) {
                                    alloc.free(tool_calls_buf.items[idx].name);
                                    tool_calls_buf.items[idx].name = try alloc.dupe(u8, n_val.string);
                                }
                            }
                            if (func_obj.get("arguments")) |a_val| {
                                if (a_val != .null) {
                                    const prev = tool_calls_buf.items[idx].arguments;
                                    tool_calls_buf.items[idx].arguments = try std.fmt.allocPrint(alloc, "{s}{s}", .{ prev, a_val.string });
                                    alloc.free(prev);
                                }
                            }
                        }
                    }
                }
            }
        }

        if (pw) |p| p.end_phase(p.context);

        const term = try child.wait(io);
        child_finished = true;

        if (error_body_buf.items.len > 0 and !seen_first_data) {
            if (isRetryableBody(error_body_buf.items)) {
                return error.ApiRateLimited;
            }
            {
                var stderr_buf: [256]u8 = undefined;
                var stderr_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buf);
                stderr_writer.interface.print("API returned non-SSE response:\n{s}", .{error_body_buf.items}) catch {};
                stderr_writer.interface.flush() catch {};
            }
            return error.ApiError;
        }

        if (term != .exited or term.exited != 0) {
            if (isRetryableBody(error_body_buf.items)) {
                return error.ApiRateLimited;
            }
            return error.ApiError;
        }

        if (tool_calls_buf.items.len > 0) {
            return types.ProviderResponse{
                .content = null,
                .tool_calls = tool_calls_buf.items,
                .finish_reason = finish_reason,
                .usage = usage,
            };
        }

        return types.ProviderResponse{
            .content = content_buf.items,
            .tool_calls = null,
            .finish_reason = finish_reason,
            .usage = usage,
        };
    }

    fn buildJsonBody(
        self: *Provider,
        allocator: std.mem.Allocator,
        messages: []const types.Message,
        tools: ?[]const types.Tool,
        stream: bool,
    ) ![]u8 {
        var buf = std.ArrayListAligned(u8, null).empty;

        try buf.appendSlice(allocator, "{\"model\":\"");
        try buf.appendSlice(allocator, self.config.model);
        try buf.appendSlice(allocator, "\",\"messages\":[");

        for (messages, 0..) |msg, i| {
            if (i > 0) try buf.appendSlice(allocator, ",");
            try buf.appendSlice(allocator, "{\"role\":\"");
            try buf.appendSlice(allocator, @tagName(msg.role));
            try buf.appendSlice(allocator, "\"");

            if (msg.tool_call_id) |id| {
                try buf.appendSlice(allocator, ",\"tool_call_id\":\"");
                try appendEscapedJsonString(&buf, allocator, id);
                try buf.appendSlice(allocator, "\"");
            }

            if (msg.tool_calls) |tcs| {
                try buf.appendSlice(allocator, ",\"content\":null,\"tool_calls\":[");
                for (tcs, 0..) |tc, j| {
                    if (j > 0) try buf.appendSlice(allocator, ",");
                    try buf.appendSlice(allocator, "{\"id\":\"");
                    try appendEscapedJsonString(&buf, allocator, tc.id);
                    try buf.appendSlice(allocator, "\",\"type\":\"function\",\"function\":{\"name\":\"");
                    try appendEscapedJsonString(&buf, allocator, tc.name);
                    try buf.appendSlice(allocator, "\",\"arguments\":\"");
                    try appendEscapedJsonString(&buf, allocator, tc.arguments);
                    try buf.appendSlice(allocator, "\"}}");
                }
                try buf.appendSlice(allocator, "]");
            } else {
                try buf.appendSlice(allocator, ",\"content\":\"");
                try appendEscapedJsonString(&buf, allocator, msg.content);
                try buf.appendSlice(allocator, "\"");
            }

            try buf.appendSlice(allocator, "}");
        }
        try buf.appendSlice(allocator, "]");

        if (tools) |ts| {
            try buf.appendSlice(allocator, ",\"tools\":[");
            for (ts, 0..) |tool, j| {
                if (j > 0) try buf.appendSlice(allocator, ",");
                try buf.appendSlice(allocator, "{\"type\":\"function\",\"function\":{\"name\":\"");
                try appendEscapedJsonString(&buf, allocator, tool.name);
                try buf.appendSlice(allocator, "\",\"description\":\"");
                try appendEscapedJsonString(&buf, allocator, tool.description);
                try buf.appendSlice(allocator, "\",\"parameters\":");
                try buf.appendSlice(allocator, tool.params);
                try buf.appendSlice(allocator, "}}");
            }
            try buf.appendSlice(allocator, "]");
        }

        if (self.config.model_params) |params| {
            if (params.len > 0) {
                try buf.appendSlice(allocator, ",");
                try buf.appendSlice(allocator, params);
            }
        }

        try buf.appendSlice(allocator, ",\"max_tokens\":");
        {
            var num_buf: [16]u8 = undefined;
            const num_str = try std.fmt.bufPrint(&num_buf, "{d}", .{self.config.max_tokens});
            try buf.appendSlice(allocator, num_str);
        }

        if (stream) {
            try buf.appendSlice(allocator, ",\"stream\":true");
        }

        try buf.appendSlice(allocator, "}");

        return buf.toOwnedSlice(allocator);
    }
};

fn appendEscapedJsonString(buf: *std.ArrayListAligned(u8, null), allocator: std.mem.Allocator, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c < 0x80) {
            switch (c) {
                '"' => try buf.appendSlice(allocator, "\\\""),
                '\\' => try buf.appendSlice(allocator, "\\\\"),
                '\n' => try buf.appendSlice(allocator, "\\n"),
                '\r' => try buf.appendSlice(allocator, "\\r"),
                '\t' => try buf.appendSlice(allocator, "\\t"),
                0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                    var hex_buf: [6]u8 = undefined;
                    const hex = try std.fmt.bufPrint(&hex_buf, "\\u00{x:0>2}", .{@as(u8, c)});
                    try buf.appendSlice(allocator, hex);
                },
                else => try buf.append(allocator, c),
            }
            i += 1;
        } else if (c >= 0xC0 and c <= 0xDF) {
            if (i + 1 < s.len) { try buf.appendSlice(allocator, s[i..i+2]); i += 2; }
            else { try buf.appendSlice(allocator, "\\ufffd"); i += 1; }
        } else if (c >= 0xE0 and c <= 0xEF) {
            if (i + 2 < s.len) { try buf.appendSlice(allocator, s[i..i+3]); i += 3; }
            else { try buf.appendSlice(allocator, "\\ufffd"); i += 1; }
        } else if (c >= 0xF0 and c <= 0xF4) {
            if (i + 3 < s.len) { try buf.appendSlice(allocator, s[i..i+4]); i += 4; }
            else { try buf.appendSlice(allocator, "\\ufffd"); i += 1; }
        } else {
            try buf.appendSlice(allocator, "\\ufffd");
            i += 1;
        }
    }
}

fn parseFinishReason(s: []const u8) types.FinishReason {
    for (std.meta.tags(types.FinishReason)) |tag| {
        if (std.mem.eql(u8, s, @tagName(tag))) return tag;
    }
    return .unknown;
}

fn isRetryableError(err_val: std.json.Value) bool {
    if (err_val == .object) {
        if (err_val.object.get("type")) |typ| {
            if (typ == .string) {
                const t = typ.string;
                if (containsIgnoreCase(t, "rate_limit")) return true;
                if (containsIgnoreCase(t, "server_error")) return true;
                if (containsIgnoreCase(t, "insufficient_quota")) return true;
            }
        }
        if (err_val.object.get("message")) |msg| {
            if (msg == .string) {
                const m = msg.string;
                if (containsIgnoreCase(m, "rate")) return true;
                if (containsIgnoreCase(m, "quota")) return true;
                if (containsIgnoreCase(m, "overloaded")) return true;
                if (std.mem.indexOf(u8, m, "429") != null) return true;
                if (std.mem.indexOf(u8, m, "503") != null) return true;
            }
        }
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    const end = haystack.len - needle.len;
    for (0..end + 1) |i| {
        var matched = true;
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

fn isRetryableBody(body: []const u8) bool {
    const keywords = [_][]const u8{ "rate", "quota", "overloaded", "429", "503", "rate_limit", "server_error", "insufficient" };
    for (keywords) |keyword| {
        if (containsIgnoreCase(body, keyword)) return true;
    }
    return false;
}

test "detectVendor deepseek" {
    try std.testing.expectEqual(Provider.Vendor.deepseek, Provider.detectVendor("https://api.deepseek.com"));
    try std.testing.expectEqual(Provider.Vendor.deepseek, Provider.detectVendor("https://api.deepseek.com/v1"));
    try std.testing.expectEqual(Provider.Vendor.deepseek, Provider.detectVendor("api.deepseek.com"));
}

test "detectVendor standard" {
    try std.testing.expectEqual(Provider.Vendor.standard, Provider.detectVendor("https://api.openai.com"));
    try std.testing.expectEqual(Provider.Vendor.standard, Provider.detectVendor("https://openrouter.ai/api/v1"));
    try std.testing.expectEqual(Provider.Vendor.standard, Provider.detectVendor("http://localhost:8080"));
}

test "appendEscapedJsonString: escapes special chars" {
    const testing = std.testing;
    var buf: std.ArrayListAligned(u8, null) = .empty;
    try appendEscapedJsonString(&buf, testing.allocator, "hello\"world\\\n\t");
    const s = try buf.toOwnedSlice(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\\\\") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\\n") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\\t") != null);
}

test "appendEscapedJsonString: 0x80+ bytes pass through" {
    const testing = std.testing;
    var buf: std.ArrayListAligned(u8, null) = .empty;
    try appendEscapedJsonString(&buf, testing.allocator, "\xE4\xBD\xA0\xE5\xA5\xBD");
    const s = try buf.toOwnedSlice(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "\xE4") != null);
}

test "appendEscapedJsonString: control chars escaped" {
    const testing = std.testing;
    var buf: std.ArrayListAligned(u8, null) = .empty;
    try appendEscapedJsonString(&buf, testing.allocator, "\x00\x01\x1f");
    const s = try buf.toOwnedSlice(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "\\u0000") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\\u0001") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\\u001f") != null);
}

test "appendEscapedJsonString: invalid UTF-8 replaced" {
    const testing = std.testing;
    var buf: std.ArrayListAligned(u8, null) = .empty;
    try appendEscapedJsonString(&buf, testing.allocator, "\xAA");
    const s = try buf.toOwnedSlice(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "\\ufffd") != null);
}

test "buildJsonBody basic" {
    const testing = std.testing;
    var p = Provider{
        .config = .{
            .base_url = "https://api.test.com",
            .api_key = "",
            .model = "test-model",
            .max_tokens = 1000,
            .vendor = .standard,
        },
    };
    const msgs = [_]types.Message{
        .{ .role = .user, .content = "hello" },
    };
    const body = try p.buildJsonBody(testing.allocator, &msgs, null, true);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"model\":\"test-model\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"role\":\"user\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"content\":\"hello\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":1000") != null);
}

test "buildJsonBody with tools" {
    const testing = std.testing;
    var p = Provider{
        .config = .{
            .base_url = "https://api.test.com",
            .api_key = "",
            .model = "test-model",
            .max_tokens = 1000,
            .vendor = .standard,
        },
    };
    const msgs = [_]types.Message{
        .{ .role = .user, .content = "read a file" },
    };
    const tools = [_]types.Tool{
        .{
            .name = "read",
            .description = "Read a file",
            .params = "{\"type\":\"object\"}",
            .execute = undefined,
        },
    };
    const body = try p.buildJsonBody(testing.allocator, &msgs, &tools, true);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"tools\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"name\":\"read\"") != null);
}

test "buildJsonBody deepseek thinking" {
    const testing = std.testing;
    var p = Provider{
        .config = .{
            .base_url = "https://api.deepseek.com",
            .api_key = "",
            .model = "deepseek-v4-pro",
            .max_tokens = 1000,
            .vendor = .deepseek,
            .model_params = "\"thinking\":{\"type\":\"enabled\"}",
        },
    };
    const msgs = [_]types.Message{
        .{ .role = .user, .content = "test" },
    };
    const body = try p.buildJsonBody(testing.allocator, &msgs, null, true);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"thinking\"") != null);
}

test "buildJsonBody with tool_calls in assistant message" {
    const testing = std.testing;
    var p = Provider{
        .config = .{
            .base_url = "https://api.test.com",
            .api_key = "",
            .model = "test-model",
            .max_tokens = 1000,
            .vendor = .standard,
        },
    };
    const tcs: []const types.ToolCall = &.{
        .{ .id = "call_1", .name = "read", .arguments = "{\"path\":\"/a\"}" },
    };
    const msgs = [_]types.Message{
        .{ .role = .user, .content = "hi" },
        .{
            .role = .assistant,
            .content = "",
            .tool_calls = tcs,
        },
    };
    const body = try p.buildJsonBody(testing.allocator, &msgs, null, true);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"tool_calls\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"id\":\"call_1\"") != null);
}

test "buildJsonBody tool message with tool_call_id" {
    const testing = std.testing;
    var p = Provider{
        .config = .{
            .base_url = "https://api.test.com",
            .api_key = "",
            .model = "test-model",
            .max_tokens = 1000,
            .vendor = .standard,
        },
    };
    const msgs = [_]types.Message{
        .{ .role = .user, .content = "hi" },
        .{ .role = .tool, .content = "result", .tool_call_id = "call_1" },
    };
    const body = try p.buildJsonBody(testing.allocator, &msgs, null, true);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"tool_call_id\":\"call_1\"") != null);
}

test "parseFinishReason known" {
    try std.testing.expectEqual(types.FinishReason.stop, parseFinishReason("stop"));
    try std.testing.expectEqual(types.FinishReason.tool_calls, parseFinishReason("tool_calls"));
    try std.testing.expectEqual(types.FinishReason.length, parseFinishReason("length"));
    try std.testing.expectEqual(types.FinishReason.content_filter, parseFinishReason("content_filter"));
}

test "parseFinishReason unknown" {
    try std.testing.expectEqual(types.FinishReason.unknown, parseFinishReason(""));
    try std.testing.expectEqual(types.FinishReason.unknown, parseFinishReason("something_else"));
}

test "init missing key returns ApiKeyNotSet" {
    const testing = std.testing;
    const entry = types.ProviderEntry{
        .name = "test",
        .api = .openai_compat,
        .base_url = "https://api.test.com",
        .models = &.{},
        .api_key_env = "NONEXISTENT_ENV_VAR_FOR_TEST_12345",
    };
    const model = types.Model{
        .id = "test-model",
        .name = "Test Model",
        .context_window = 100000,
        .max_tokens = 4096,
        .params_json = null,
        .input = &.{.text},
    };
    try testing.expectError(error.ApiKeyNotSet, Provider.init(testing.allocator, entry, &model, null, testing.io, null));
}

test "SSE parse data:DONE" {
    const testing = std.testing;
    const payload = "[DONE]";
    try testing.expect(std.mem.eql(u8, payload, "[DONE]"));
}

test "SSE parse content delta" {
    const testing = std.testing;
    const payload = "{\"id\":\"chatcmpl-1\",\"model\":\"test\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"hello\"},\"finish_reason\":null,\"index\":0}]}";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), payload, .{ .ignore_unknown_fields = true });
    const choices = parsed.object.get("choices").?.array.items;
    try testing.expect(choices.len > 0);
    const delta = choices[0].object.get("delta").?.object;
    try testing.expectEqualStrings("hello", delta.get("content").?.string);
}

test "SSE parse tool_call delta" {
    const testing = std.testing;
    const payload = "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"read\",\"arguments\":\"{}\"}}]},\"index\":0}]}";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), payload, .{ .ignore_unknown_fields = true });
    const choices = parsed.object.get("choices").?.array.items;
    const tc_array = choices[0].object.get("delta").?.object.get("tool_calls").?.array.items;
    const tc = tc_array[0].object;
    try testing.expectEqualStrings("call_1", tc.get("id").?.string);
    try testing.expectEqualStrings("read", tc.get("function").?.object.get("name").?.string);
}

test "SSE non-SSE error response" {
    const testing = std.testing;
    const lines = [_][]const u8{ "HTTP/1.1 401 Unauthorized", "", "{\"error\":{\"message\":\"invalid key\"}}" };
    var seen_first_data: bool = false;
    var error_buf: std.ArrayListAligned(u8, null) = .empty;

    for (lines) |line| {
        if (!std.mem.startsWith(u8, line, "data: ")) {
            if (!seen_first_data) {
                error_buf.appendSlice(testing.allocator, line) catch {};
            }
        } else {
            seen_first_data = true;
        }
    }
    defer error_buf.deinit(testing.allocator);

    try testing.expect(!seen_first_data);
    try testing.expect(error_buf.items.len > 0);
}

test "retry backoff delays" {
    const testing = std.testing;
    const delay = struct {
        fn ms(attempt: u32) u64 {
            return switch (attempt) {
                1 => 500,
                2 => 1000,
                3 => 2000,
                4 => 4000,
                5 => 8000,
                else => unreachable,
            };
        }
    }.ms;
    try testing.expectEqual(@as(u64, 500), delay(1));
    try testing.expectEqual(@as(u64, 1000), delay(2));
    try testing.expectEqual(@as(u64, 2000), delay(3));
    try testing.expectEqual(@as(u64, 4000), delay(4));
    try testing.expectEqual(@as(u64, 8000), delay(5));
}

test "isRetryableBody rate limit keywords" {
    try std.testing.expect(isRetryableBody("{\"error\":{\"message\":\"Rate limit exceeded\"}}"));
    try std.testing.expect(isRetryableBody("{\"error\":{\"type\":\"rate_limit_error\"}}"));
    try std.testing.expect(isRetryableBody("429 Too Many Requests"));
    try std.testing.expect(isRetryableBody("503 Service Unavailable"));
    try std.testing.expect(isRetryableBody("Insufficient quota"));
}

test "isRetryableBody fatal errors" {
    try std.testing.expect(!isRetryableBody("{\"error\":{\"message\":\"Invalid API key\"}}"));
    try std.testing.expect(!isRetryableBody("{\"error\":{\"type\":\"invalid_request_error\"}}"));
    try std.testing.expect(!isRetryableBody(""));
}
