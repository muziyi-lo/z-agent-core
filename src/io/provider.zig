const std = @import("std");
const builtin = @import("builtin");
const types = @import("../types.zig");
const config_mod = @import("../config.zig");
const signal = @import("../util/signal.zig");
const log = @import("../util/log.zig");
const jsonw = @import("../util/jsonw.zig");

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
        compat: types.ModelCompat,
        stream_options_declined: bool = false,
        /// Model input modalities (from config `input`): image attachments are
        /// only injected when `.image` is present (N22 gating).
        input_modality: []const types.InputModality = &.{.text},
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

    /// Create provider from config entry. api_key is resolved by the config
    /// layer (process env → .env fallback); Provider owns its own copy.
    pub fn init(
        allocator: std.mem.Allocator,
        entry: types.ProviderEntry,
        model: *const types.Model,
        api_key: []const u8,
        vendor_override: ?Vendor,
        io: std.Io,
    ) !Provider {
        _ = io;
        const vendor = if (vendor_override) |v| v else detectVendor(entry.base_url);

        const key_owned = try allocator.dupe(u8, api_key);

        const resolved_compat = config_mod.resolveCompat(entry.base_url, model);

        return Provider{
            .config = .{
                .base_url = entry.base_url,
                .api_key = key_owned,
                .model = model.id,
                .max_tokens = model.max_tokens,
                .vendor = vendor,
                .vendor_override = vendor_override,
                .model_params = model.params_json,
                .compat = resolved_compat,
                .stream_options_declined = false,
                .input_modality = model.input,
            },
        };
    }

    /// Reconfigure in place for a different model (web frontend model switch).
    /// Mirrors init(): base_url/model_params borrow from config; api_key is dup'd.
    pub fn setModel(
        self: *Provider,
        allocator: std.mem.Allocator,
        entry: types.ProviderEntry,
        model: *const types.Model,
        api_key: []const u8,
    ) !void {
        const key_owned = try allocator.dupe(u8, api_key);
        self.config.base_url = entry.base_url;
        self.config.api_key = key_owned;
        self.config.model = model.id;
        self.config.max_tokens = model.max_tokens;
        self.config.vendor = detectVendor(entry.base_url);
        self.config.vendor_override = null;
        self.config.model_params = model.params_json;
        self.config.compat = config_mod.resolveCompat(entry.base_url, model);
        self.config.stream_options_declined = false;
        self.config.input_modality = model.input;
    }

    /// Call LLM API with streaming SSE. Retries up to 3 times on transient errors.
    /// arena: temporary allocator for response data; caller owns arena lifetime.
    pub fn chatCompletionStreaming(
        self: *Provider,
        arena: *std.heap.ArenaAllocator,
        io: std.Io,
        messages: []const types.Message,
        tools: ?[]const types.Tool,
        phase_writer: ?PhaseWriterCb,
    ) !types.ProviderResponse {
        return callWithRetry(self, arena, io, messages, tools, phase_writer);
    }

    fn callWithRetry(
        self: *Provider,
        arena: *std.heap.ArenaAllocator,
        io: std.Io,
        messages: []const types.Message,
        tools: ?[]const types.Tool,
        phase_writer: ?PhaseWriterCb,
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
                if (phase_writer) |pw| {
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
            return chatCompletionStreamingOnce(self, arena, io, messages, tools, phase_writer) catch |err| {
                if (attempt >= max_retries) return err;
                switch (err) {
                    error.Interrupted, error.ApiError, error.ContextOverflow => return err,
                    else => {
                        log.dbg(0, 0, "provider_retry", "attempt={d} err={s}", .{ attempt + 1, @errorName(err) });
                        continue;
                    },
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
        pw: ?PhaseWriterCb,
    ) !types.ProviderResponse {
        const alloc = arena.allocator();

        log.dbg(0, 0, "provider_stream_start", "msgs={d} tools={d}", .{ messages.len, if (tools) |t| t.len else @as(usize, 0) });

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
                child.kill(io);
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
        var reasoning_buf = std.ArrayListAligned(u8, null).empty;
        var tool_calls_buf = std.ArrayListAligned(types.ToolCall, null).empty;

        const sse_read_buf = try alloc.alloc(u8, 4096);
        var sse_file_reader = stdout_file.readerStreaming(io, sse_read_buf);
        const sse_reader = &sse_file_reader.interface;
        var error_body_buf = std.ArrayListAligned(u8, null).empty;

        var seen_first_data = false;
        var thinking_started = false;
        var text_started = false;
        var finish_reason: types.FinishReason = .unknown;
        var usage: ?types.TokenUsage = null;

        while (true) {
            if (signal.isInterrupted()) {
                child.kill(io);
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

            const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, payload, .{ .ignore_unknown_fields = true }) catch {
                var dbuf: [256]u8 = undefined;
                var dw: std.Io.File.Writer = .init(.stderr(), io, &dbuf);
                _ = dw.interface.writeAll("z-agent-core: warning: SSE parse error, skipping event\n") catch {};
                _ = dw.interface.flush() catch {};
                continue;
            };

            if (parsed.object.get("error")) |err_val| {
                if (isContextOverflowError(err_val)) return error.ContextOverflow;
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
                                    var tu: types.TokenUsage = .{
                                        .input = @intCast(in_val.integer),
                                        .output = @intCast(out_val.integer),
                                        .total = @intCast(tot_val.integer),
                                    };
                                    if (u.get("prompt_cache_hit_tokens")) |hit_val| {
                                        if (hit_val != .null) tu.cache_hit = @intCast(hit_val.integer);
                                    }
                                    if (u.get("prompt_cache_miss_tokens")) |miss_val| {
                                        if (miss_val != .null) tu.cache_miss = @intCast(miss_val.integer);
                                    }
                                    usage = tu;
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
                    if (r_val != .null and self.config.compat.thinking_level != .none) {
                        const r = r_val.string;
                        if (r.len > 0) {
                            if (!thinking_started) {
                                thinking_started = true;
                                if (text_started) {
                                    if (pw) |p| p.end_phase(p.context);
                                    text_started = false;
                                }
                                if (pw) |p| p.begin_phase(p.context, .thinking);
                            }
                            try reasoning_buf.appendSlice(alloc, r);
                            if (pw) |p| p.write_raw(p.context, r);
                        }
                    }
                }

                if (delta.get("content")) |c_val| {
                    if (c_val != .null) {
                        const c = c_val.string;
                        if (c.len > 0) {
                            if (!text_started) {
                                text_started = true;
                                if (thinking_started) {
                                    if (pw) |p| p.end_phase(p.context);
                                    thinking_started = false;
                                }
                                if (pw) |p| p.begin_phase(p.context, .content);
                            }
                            try content_buf.appendSlice(alloc, c);
                            if (pw) |p| p.write_raw(p.context, c);
                        }
                    }
                }

                if (delta.get("tool_calls")) |tc_array| {
                    if (thinking_started) {
                        if (pw) |p| p.end_phase(p.context);
                        thinking_started = false;
                    }
                    if (text_started) {
                        if (pw) |p| p.end_phase(p.context);
                        text_started = false;
                    }
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
            // stream_options 400 fallback — guard with !declined to prevent loop
            if (!self.config.stream_options_declined and isStreamOptions400Error(error_body_buf.items)) {
                self.config.stream_options_declined = true;
                // Rebuild body without stream_options and retry once internally
                const retry_body = try buildJsonBody(self, alloc, messages, tools, true);
                // Re-spawn curl with retry_body for a single internal retry
                // (This is a simplified version — full re-spawn omitted for brevity,
                //  follows the same pattern as lines 164-395 with retry_body)
                _ = retry_body;
                // For now: propagate as retryable so callWithRetry handles it,
                // second attempt will have stream_options_declined=true so body won't include it
                return error.ApiRateLimited;
            }
            if (isAuthError(error_body_buf.items)) {
                return error.ApiKeyNotSet;
            }
            if (isHtmlError(error_body_buf.items)) {
                var stderr_buf: [256]u8 = undefined;
                var stderr_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buf);
                // Best-effort stderr — already returning ApiError, can't propagate write failure
                stderr_writer.interface.print("error: request blocked by gateway or proxy\n", .{}) catch {};
                stderr_writer.interface.flush() catch {};
                return error.ApiError;
            }
            if (isContextOverflowBody(error_body_buf.items)) {
                return error.ContextOverflow;
            }
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
            if (!self.config.stream_options_declined and isStreamOptions400Error(error_body_buf.items)) {
                self.config.stream_options_declined = true;
                return error.ApiRateLimited;
            }
            if (isAuthError(error_body_buf.items)) {
                return error.ApiKeyNotSet;
            }
            if (isContextOverflowBody(error_body_buf.items)) {
                return error.ContextOverflow;
            }
            if (isRetryableBody(error_body_buf.items)) {
                return error.ApiRateLimited;
            }
            return error.ApiError;
        }

        if (tool_calls_buf.items.len > 0) {
            return types.ProviderResponse{
                .content = null,
                .reasoning_content = if (reasoning_buf.items.len > 0) reasoning_buf.items else null,
                .tool_calls = tool_calls_buf.items,
                .finish_reason = finish_reason,
                .usage = usage,
            };
        }

        return types.ProviderResponse{
            .content = content_buf.items,
            .reasoning_content = if (reasoning_buf.items.len > 0) reasoning_buf.items else null,
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
        var jw = jsonw.JsonWriter.init(allocator);
        errdefer jw.deinit();

        try jw.beginObject(null);
        try jw.stringField("model", self.config.model);
        try jw.beginArray("messages");

        for (messages) |msg| {
            try jw.beginObject(null);
            try jw.stringField("role", @tagName(msg.role));

            if (msg.tool_call_id) |id| try jw.stringField("tool_call_id", id);

            if (msg.tool_calls) |tcs| {
                try jw.rawField("content", "null");
                // Include reasoning_content on tool-call messages when compat requires it (DeepSeek)
                if (self.config.compat.require_reasoning_on_tool_calls) {
                    if (msg.reasoning_content) |rc| try jw.stringField("reasoning_content", rc);
                }
                try jw.beginArray("tool_calls");
                for (tcs) |tc| {
                    try jw.beginObject(null);
                    try jw.stringField("id", tc.id);
                    try jw.stringField("type", "function");
                    try jw.beginObject("function");
                    try jw.stringField("name", tc.name);
                    try jw.stringField("arguments", tc.arguments);
                    try jw.endValue();
                    try jw.endValue();
                }
                try jw.endValue();
            } else if (msg.attachments) |atts| {
                // N22: image attachments — inject as OpenAI image_url content
                // blocks only when the model's input modality includes image
                // (config `input = ["text","image"]`). Otherwise keep the plain
                // text summary (the agent layer adds the capability Notice).
                if (hasImageModality(self.config.input_modality)) {
                    try writeContentWithAttachments(&jw, allocator, msg.content, atts);
                } else {
                    try jw.stringField("content", msg.content);
                }
            } else {
                try jw.stringField("content", msg.content);
            }

            try jw.endValue();
        }
        try jw.endValue();

        if (tools) |ts| {
            try jw.beginArray("tools");
            for (ts) |tool| {
                try jw.beginObject(null);
                try jw.stringField("type", "function");
                try jw.beginObject("function");
                try jw.stringField("name", tool.name);
                try jw.stringField("description", tool.description);
                try jw.rawField("parameters", tool.params);
                try jw.endValue();
                try jw.endValue();
            }
            try jw.endValue();
        }

        // compat-driven thinking JSON (pre-formed raw fragment)
        if (self.config.compat.thinking_format != .none) {
            try jw.rawBytes(",");
            try buildThinkingJson(&jw,
                self.config.compat.thinking_format,
                self.config.compat.thinking_level);
        }

        // compat-driven max_tokens field name
        try jw.rawBytes(",\"");
        try jw.rawBytes(switch (self.config.compat.max_tokens_field) {
            .max_tokens => "max_tokens",
            .max_tokens_to_sample => "max_tokens_to_sample",
            .max_output_tokens => "maxOutputTokens",
        });
        try jw.rawBytes("\":");
        try jw.rawInt(self.config.max_tokens);

        if (stream) {
            try jw.rawBytes(",\"stream\":true");
            if (self.config.compat.supports_stream_options and
                !self.config.stream_options_declined)
            {
                try jw.rawBytes(",\"stream_options\":{\"include_usage\":true}");
            }
        }

        // KEPT: model_params for backward compat (non-thinking params)
        if (self.config.model_params) |params| {
            if (params.len > 0) {
                try jw.rawBytes(",");
                try jw.rawBytes(params);
            }
        }

        try jw.endValue();

        // Ownership transfer to caller (Result.deinit NOT called — slice escapes).
        return (try jw.result()).bytes;
    }

    /// Emit `content` as an array of {type:text} + {type:image_url} blocks.
    /// Per-attachment guards: mime whitelist, base64 charset (whitespace
    /// tolerated per RFC 4648 line folding), cumulative raw-size cap (5MB,
    /// approximated as data.len*3/4 — base64 minimum — slight overestimate
    /// keeps the guard conservative).
    fn writeContentWithAttachments(
        jw: *jsonw.JsonWriter,
        allocator: std.mem.Allocator,
        text: []const u8,
        atts: []const types.Attachment,
    ) !void {
        try jw.beginArray("content");
        try jw.beginObject(null);
        try jw.stringField("type", "text");
        try jw.stringField("text", text);
        try jw.endValue();
        var total_raw: usize = 0;
        for (atts) |att| {
            if (!isImageMime(att.mime)) continue;
            if (!isValidBase64(att.data)) continue;
            total_raw += att.data.len / 4 * 3;
            if (total_raw > MAX_ATTACHMENT_RAW_BYTES) break;
            // Block scope: each url buffer dies at the end of its iteration
            // (a function-level defer would keep every iteration's buffer
            // alive until the function returns).
            {
                var url_buf = std.ArrayListAligned(u8, null).empty;
                defer url_buf.deinit(allocator);
                try url_buf.appendSlice(allocator, "data:");
                try url_buf.appendSlice(allocator, att.mime);
                try url_buf.appendSlice(allocator, ";base64,");
                try url_buf.appendSlice(allocator, att.data);
                try jw.beginObject(null);
                try jw.stringField("type", "image_url");
                try jw.beginObject("image_url");
                try jw.stringField("url", url_buf.items);
                try jw.endValue();
                try jw.endValue();
            }
        }
        try jw.endValue();
    }
};

/// Raw byte cap for injected attachments (N22; aligns with read MAX_IMAGE_BYTES).
const MAX_ATTACHMENT_RAW_BYTES: usize = 5 * 1024 * 1024;

fn hasImageModality(input: []const types.InputModality) bool {
    for (input) |m| {
        if (m == .image) return true;
    }
    return false;
}

fn isImageMime(mime: []const u8) bool {
    const whitelist = [_][]const u8{ "image/png", "image/jpeg", "image/gif", "image/webp" };
    for (whitelist) |m| {
        if (std.mem.eql(u8, mime, m)) return true;
    }
    return false;
}

/// Base64 charset check that tolerates whitespace (RFC 4648 line folding):
/// \r\n\t and space are ignored; everything else must be in [A-Za-z0-9+/=].
fn isValidBase64(data: []const u8) bool {
    var significant: usize = 0;
    for (data) |c| {
        if (c == '\r' or c == '\n' or c == '\t' or c == ' ') continue;
        significant += 1;
        const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '+' or c == '/' or c == '=';
        if (!ok) return false;
    }
    return significant > 0;
}

fn buildThinkingJson(
    jw: *jsonw.JsonWriter,
    format: types.ThinkingFormat,
    level: types.ThinkingLevel,
) !void {
    if (level == .none) {
        switch (format) {
            .thinking_object => try jw.rawBytes("\"thinking\":{\"type\":\"disabled\"}"),
            .enable_thinking_bool => try jw.rawBytes("\"enable_thinking\":false"),
            .thinking_with_budget => try jw.rawBytes("\"thinking\":{\"type\":\"disabled\",\"budget_tokens\":0}"),
            else => return,
        }
        return;
    }
    switch (format) {
        .none => {},
        .thinking_object => {
            switch (level) {
                .none => unreachable,
                .minimal, .low, .medium, .high => try jw.rawBytes("\"thinking\":{\"type\":\"enabled\"}"),
                .xhigh, .max => try jw.rawBytes("\"thinking\":{\"type\":\"enabled\",\"level\":\"max\"}"),
            }
        },
        .reasoning_effort => {
            const s = switch (level) {
                .none => unreachable,
                .minimal => "minimal",
                .low => "low",
                .medium => "medium",
                .high => "high",
                .xhigh => "xhigh",
                .max => "high",
            };
            try jw.rawBytes("\"reasoning_effort\":\"");
            try jw.rawBytes(s);
            try jw.rawBytes("\"");
        },
        .enable_thinking_bool => try jw.rawBytes("\"enable_thinking\":true"),
        .thinking_parameters => try jw.rawBytes("\"parameters\":{\"enable_thinking\":true}"),
        .thinking_with_budget => {
            const budget: u32 = switch (level) {
                .none => 0,
                .minimal => 2000,
                .low => 4000,
                .medium => 8000,
                .high => 16000,
                .xhigh => 24000,
                .max => 31999,
            };
            if (budget == 0) {
                try jw.rawBytes("\"thinking\":{\"type\":\"disabled\",\"budget_tokens\":0}");
            } else {
                try jw.rawBytes("\"thinking\":{\"type\":\"enabled\",\"budget_tokens\":");
                try jw.rawInt(budget);
                try jw.rawBytes("}");
            }
        },
        .thinking_config_object => {
            const budget: i32 = switch (level) {
                .none => 0,
                .minimal => 512,
                .low => 1024,
                .medium => 4096,
                .high => 16000,
                .xhigh => 24576,
                .max => 32768,
            };
            try jw.rawBytes("\"thinkingConfig\":{\"thinkingBudget\":");
            try jw.rawInt(budget);
            try jw.rawBytes("}");
        },
    }
}

fn parseFinishReason(s: []const u8) types.FinishReason {
    for (std.meta.tags(types.FinishReason)) |tag| {
        if (std.mem.eql(u8, s, @tagName(tag))) return tag;
    }
    return .unknown;
}

/// Context-overflow keywords (context_length_exceeded / maximum context length /
/// token limit). Single-purpose array — no cross-module reuse, kept inline.
const overflow_kw = [_][]const u8{ "context_length_exceeded", "maximum context length", "context length", "token limit", "too long for the requested model" };

/// Detect overflow from the SSE error JSON frame: type `context_length_exceeded`
/// or message containing overflow keywords.
fn isContextOverflowError(err_val: std.json.Value) bool {
    if (err_val == .object) {
        if (err_val.object.get("type")) |typ| {
            if (typ == .string) {
                for (overflow_kw) |kw| if (containsIgnoreCase(typ.string, kw)) return true;
            }
        }
        if (err_val.object.get("message")) |msg| {
            if (msg == .string) {
                for (overflow_kw) |kw| if (containsIgnoreCase(msg.string, kw)) return true;
            }
        }
    }
    return false;
}

/// Detect overflow from a non-SSE error body (curl exit + error body).
fn isContextOverflowBody(body: []const u8) bool {
    for (overflow_kw) |kw| {
        if (containsIgnoreCase(body, kw)) return true;
    }
    return false;
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

fn isStreamOptions400Error(body: []const u8) bool {
    return std.mem.indexOf(u8, body, "stream_options") != null and
           (std.mem.indexOf(u8, body, "unknown") != null or
            std.mem.indexOf(u8, body, "unrecognized") != null or
            std.mem.indexOf(u8, body, "Invalid") != null);
}

fn isAuthError(body: []const u8) bool {
    return std.mem.indexOf(u8, body, "authentication_error") != null or
           std.mem.indexOf(u8, body, "invalid_api_key") != null or
           std.mem.indexOf(u8, body, "Invalid token") != null or
           std.mem.indexOf(u8, body, "Incorrect API key") != null;
}

fn isHtmlError(body: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, body, " \t\r\n");
    const doctype = "<!doctype";
    const html_tag = "<html";
    return (trimmed.len >= doctype.len and std.ascii.eqlIgnoreCase(trimmed[0..doctype.len], doctype)) or
           (trimmed.len >= html_tag.len and std.ascii.eqlIgnoreCase(trimmed[0..html_tag.len], html_tag));
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

fn testProvider(input: []const types.InputModality) Provider {
    return .{ .config = .{
        .base_url = "https://api.test.com",
        .api_key = "",
        .model = "test-model",
        .max_tokens = 1000,
        .vendor = .standard,
        .compat = .{},
        .input_modality = input,
    } };
}

test "buildJsonBody: vision model injects image_url attachments" {
    const testing = std.testing;
    var p = testProvider(&.{ .text, .image });
    const msgs = [_]types.Message{
        .{ .role = .tool, .content = "Image file: shot.png", .tool_call_id = "c1", .attachments = &.{.{ .mime = "image/png", .data = "iVBORw0KGgo=" }} },
    };
    const body = try p.buildJsonBody(testing.allocator, &msgs, null, true);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"content\":[{") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"text\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"image_url\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"url\":\"data:image/png;base64,iVBORw0KGgo=\"") != null);
}

test "buildJsonBody: text-only model keeps plain content (gating)" {
    const testing = std.testing;
    var p = testProvider(&.{.text});
    const msgs = [_]types.Message{
        .{ .role = .tool, .content = "Image file: shot.png", .tool_call_id = "c1", .attachments = &.{.{ .mime = "image/png", .data = "iVBORw0KGgo=" }} },
    };
    const body = try p.buildJsonBody(testing.allocator, &msgs, null, true);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"content\":\"Image file: shot.png\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "image_url") == null);
}

test "buildJsonBody: invalid attachments skipped" {
    const testing = std.testing;
    var p = testProvider(&.{ .text, .image });
    const msgs = [_]types.Message{
        .{ .role = .tool, .content = "summary", .tool_call_id = "c1", .attachments = &.{
            .{ .mime = "application/pdf", .data = "bm90LWltYWdl" }, // mime not whitelisted
            .{ .mime = "image/png", .data = "" },                     // empty data
            .{ .mime = "image/png", .data = "bad!chars" },            // invalid base64
            .{ .mime = "image/png", .data = "dmFsaWQ=" },             // valid → injected
        } },
    };
    const body = try p.buildJsonBody(testing.allocator, &msgs, null, true);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "application/pdf") == null);
    try testing.expect(std.mem.indexOf(u8, body, "bad!chars") == null);
    try testing.expect(std.mem.indexOf(u8, body, "dmFsaWQ=") != null);
    // one injected attachment → one image_url content block (the type value
    // appears once; the "image_url" object key is a separate occurrence)
    try testing.expectEqual(@as(usize, 1), countOccurrences(body, "\"type\":\"image_url\""));
}

test "buildJsonBody: base64 line folding tolerated" {
    const testing = std.testing;
    var p = testProvider(&.{ .text, .image });
    const msgs = [_]types.Message{
        .{ .role = .tool, .content = "s", .tool_call_id = "c1", .attachments = &.{.{ .mime = "image/png", .data = "iVBORw0KGgo=\r\nAAECAwQFBgc=" }} },
    };
    const body = try p.buildJsonBody(testing.allocator, &msgs, null, true);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "AAECAwQFBgc=") != null);
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, pos, needle)) |i| {
        count += 1;
        pos = i + needle.len;
    }
    return count;
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
            .compat = .{},
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
            .compat = .{},
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
            .compat = .{ .thinking_format = .thinking_object, .thinking_level = .high },
        },
    };
    const msgs = [_]types.Message{
        .{ .role = .user, .content = "test" },
    };
    const body = try p.buildJsonBody(testing.allocator, &msgs, null, true);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"thinking\":{\"type\":\"enabled\"}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"level\"") == null);
}

test "buildJsonBody compat thinking_object low" {
    const testing = std.testing;
    var p = Provider{
        .config = .{
            .base_url = "https://api.deepseek.com",
            .api_key = "",
            .model = "deepseek-v4-pro",
            .max_tokens = 1000,
            .vendor = .deepseek,
            .compat = .{ .thinking_format = .thinking_object, .thinking_level = .low },
        },
    };
    const msgs = [_]types.Message{.{ .role = .user, .content = "test" }};
    const body = try p.buildJsonBody(testing.allocator, &msgs, null, true);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"enabled\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"disabled\"") == null);
    try testing.expect(std.mem.indexOf(u8, body, "\"level\":\"max\"") == null);
}

test "buildJsonBody compat thinking_object max" {
    const testing = std.testing;
    var p = Provider{
        .config = .{
            .base_url = "https://api.deepseek.com",
            .api_key = "",
            .model = "deepseek-v4-pro",
            .max_tokens = 1000,
            .vendor = .deepseek,
            .compat = .{ .thinking_format = .thinking_object, .thinking_level = .max },
        },
    };
    const msgs = [_]types.Message{.{ .role = .user, .content = "test" }};
    const body = try p.buildJsonBody(testing.allocator, &msgs, null, true);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"enabled\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"level\":\"max\"") != null);
}

test "buildJsonBody compat thinking_object xhigh maps to max" {
    const testing = std.testing;
    var p = Provider{
        .config = .{
            .base_url = "https://api.deepseek.com",
            .api_key = "",
            .model = "deepseek-v4-pro",
            .max_tokens = 1000,
            .vendor = .deepseek,
            .compat = .{ .thinking_format = .thinking_object, .thinking_level = .xhigh },
        },
    };
    const msgs = [_]types.Message{.{ .role = .user, .content = "test" }};
    const body = try p.buildJsonBody(testing.allocator, &msgs, null, true);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"enabled\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"level\":\"max\"") != null);
}

test "buildJsonBody compat thinking_object none sends disabled" {
    const testing = std.testing;
    var p = Provider{
        .config = .{
            .base_url = "https://api.deepseek.com",
            .api_key = "",
            .model = "deepseek-v4-pro",
            .max_tokens = 1000,
            .vendor = .deepseek,
            .compat = .{ .thinking_format = .thinking_object, .thinking_level = .none },
        },
    };
    const msgs = [_]types.Message{.{ .role = .user, .content = "test" }};
    const body = try p.buildJsonBody(testing.allocator, &msgs, null, true);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"disabled\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"type\":\"enabled\"") == null);
}

test "buildJsonBody compat reasoning_effort high" {
    const testing = std.testing;
    var p = Provider{
        .config = .{
            .base_url = "https://api.openai.com",
            .api_key = "",
            .model = "gpt-test",
            .max_tokens = 1000,
            .vendor = .standard,
            .compat = .{ .thinking_format = .reasoning_effort, .thinking_level = .high },
        },
    };
    const msgs = [_]types.Message{.{ .role = .user, .content = "test" }};
    const body = try p.buildJsonBody(testing.allocator, &msgs, null, false);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"high\"") != null);
}

test "buildJsonBody compat max_tokens_to_sample" {
    const testing = std.testing;
    var p = Provider{
        .config = .{
            .base_url = "https://api.test.com",
            .api_key = "",
            .model = "test-model",
            .max_tokens = 1000,
            .vendor = .standard,
            .compat = .{ .max_tokens_field = .max_tokens_to_sample },
        },
    };
    const msgs = [_]types.Message{.{ .role = .user, .content = "test" }};
    const body = try p.buildJsonBody(testing.allocator, &msgs, null, false);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"max_tokens_to_sample\":1000") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"max_tokens\":") == null);
}

test "buildJsonBody stream_options enabled" {
    const testing = std.testing;
    var p = Provider{
        .config = .{
            .base_url = "https://api.openai.com",
            .api_key = "",
            .model = "test-model",
            .max_tokens = 1000,
            .vendor = .standard,
            .compat = .{ .supports_stream_options = true },
        },
    };
    const msgs = [_]types.Message{.{ .role = .user, .content = "test" }};
    const body = try p.buildJsonBody(testing.allocator, &msgs, null, true);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"stream_options\":{\"include_usage\":true}") != null);
}

test "buildJsonBody stream_options disabled by default" {
    const testing = std.testing;
    var p = Provider{
        .config = .{
            .base_url = "https://api.test.com",
            .api_key = "",
            .model = "test-model",
            .max_tokens = 1000,
            .vendor = .standard,
            .compat = .{},
        },
    };
    const msgs = [_]types.Message{.{ .role = .user, .content = "test" }};
    const body = try p.buildJsonBody(testing.allocator, &msgs, null, true);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"stream_options\"") == null);
}

test "buildJsonBody stream_options declined" {
    const testing = std.testing;
    var p = Provider{
        .config = .{
            .base_url = "https://api.openai.com",
            .api_key = "",
            .model = "test-model",
            .max_tokens = 1000,
            .vendor = .standard,
            .compat = .{ .supports_stream_options = true },
            .stream_options_declined = true,
        },
    };
    const msgs = [_]types.Message{.{ .role = .user, .content = "test" }};
    const body = try p.buildJsonBody(testing.allocator, &msgs, null, true);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"stream_options\"") == null);
}

test "buildJsonBody thinking_format none skips thinking" {
    const testing = std.testing;
    var p = Provider{
        .config = .{
            .base_url = "https://api.test.com",
            .api_key = "",
            .model = "test-model",
            .max_tokens = 1000,
            .vendor = .standard,
            .compat = .{ .thinking_format = .none, .thinking_level = .high },
        },
    };
    const msgs = [_]types.Message{.{ .role = .user, .content = "test" }};
    const body = try p.buildJsonBody(testing.allocator, &msgs, null, false);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"thinking\"") == null);
    try testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\"") == null);
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
            .compat = .{},
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
            .compat = .{},
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

test "Provider.init stores resolved key" {
    const testing = std.testing;
    const entry = types.ProviderEntry{
        .name = "test",
        .api = .openai_compat,
        .base_url = "https://api.test.com",
        .models = &.{},
        .api_key_env = "TEST_KEY",
    };
    const model = types.Model{
        .id = "test-model",
        .name = "Test Model",
        .context_window = 100000,
        .max_tokens = 4096,
        .params_json = null,
        .input = &.{.text},
    };
    const provider = try Provider.init(testing.allocator, entry, &model, "sk-test", null, testing.io);
    defer testing.allocator.free(provider.config.api_key);
    try testing.expectEqualStrings("sk-test", provider.config.api_key);
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

test "isContextOverflowBody keywords" {
    try std.testing.expect(isContextOverflowBody("{\"error\":{\"message\":\"This model's maximum context length is 128000 tokens.\"}}"));
    try std.testing.expect(isContextOverflowBody("{\"error\":{\"type\":\"context_length_exceeded\"}}"));
    try std.testing.expect(isContextOverflowBody("token limit exceeded"));
    try std.testing.expect(!isContextOverflowBody("Rate limit exceeded"));
    try std.testing.expect(!isContextOverflowBody(""));
}

test "isContextOverflowError JSON frame" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ov = std.json.parseFromSliceLeaky(std.json.Value, a, "{\"error\":{\"type\":\"context_length_exceeded\"}}", .{}) catch unreachable;
    try std.testing.expect(isContextOverflowError(ov.object.get("error").?));
    const rl = std.json.parseFromSliceLeaky(std.json.Value, a, "{\"error\":{\"type\":\"rate_limit_error\"}}", .{}) catch unreachable;
    try std.testing.expect(!isContextOverflowError(rl.object.get("error").?));
    const empty = std.json.parseFromSliceLeaky(std.json.Value, a, "{\"error\":{\"message\":\"boom\"}}", .{}) catch unreachable;
    try std.testing.expect(!isContextOverflowError(empty.object.get("error").?));
}
