const std = @import("std");
const types = @import("../../types.zig");
const config_mod = @import("../../config.zig");
const session_mod = @import("../../core/session.zig");
const agent_mod = @import("../../core/agent.zig");
const sse = @import("sse.zig");
const err_mod = @import("error.zig");
const uuid_mod = @import("../../util/uuid.zig");
const log = @import("../../util/log.zig");

const AlignedU8 = std.ArrayListAligned(u8, null);
const Io = std.Io;

const INDEX_HTML = @embedFile("index.html");
const APP_CSS = @embedFile("app.css");
const APP_JS = @embedFile("app.js");
const MARKED_JS = @embedFile("vendor/marked.min.js");
const HIGHLIGHT_JS = @embedFile("vendor/highlight.min.js");
const PURIFY_JS = @embedFile("vendor/purify.min.js");
const INTER_WOFF2 = @embedFile("vendor/inter.woff2");
const JETBRAINS_TTF = @embedFile("vendor/jetbrains-mono.ttf");
const FAVICON = @embedFile("../../Logo.ico");

const STYLE_MARKER = "<!-- STYLES -->";
const FONT_MARKER = "/* FONTS */";
const SCRIPT_MARKER = "<!-- SCRIPTS -->";

pub const Context = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    project_root: []const u8,
    sessions_dir: []const u8,
    config: *config_mod.Config,
    agent: *anyopaque,
    provider: *anyopaque,
    default_session: *anyopaque,
    sse_writer: ?*anyopaque = null,
    abort_map: *std.StringHashMap(*agent_mod.AgentLoop),
    abort_mutex: *std.Io.Mutex,
    current_abort_session: ?[]const u8 = null,
    thread_id: u32,
    request_id: u32,
};

pub fn handleRequest(ctx: *Context, method: std.http.Method, path: []const u8, request: *std.http.Server.Request) !void {
    log.req_info(ctx.thread_id, ctx.request_id, "request", "method={s} path={s}", .{ @tagName(method), path });

    var req_arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer req_arena.deinit();
    const a = req_arena.allocator();

    if (method == .GET) {
        if (std.mem.eql(u8, path, "/")) return serveIndex(ctx, request, a);
        if (std.mem.eql(u8, path, "/favicon.ico")) return handleFavicon(ctx, request, a);
        if (std.mem.eql(u8, path, "/api/health")) return respondJson(request, "{\"status\":\"ok\"}");
        if (std.mem.eql(u8, path, "/api/model")) return handleModelList(ctx, request, a);
        if (std.mem.eql(u8, path, "/api/provider")) return handleProviderList(ctx, request, a);
        if (std.mem.eql(u8, path, "/api/session")) return handleSessionList(ctx, request, a);
        if (std.mem.startsWith(u8, path, "/api/session/")) {
            const rest = path["/api/session/".len..];
            if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
                const id = rest[0..slash];
                const sub = rest[slash + 1 ..];
                const sub_path = if (std.mem.indexOfScalar(u8, sub, '?')) |qm| sub[0..qm] else sub;
                if (std.mem.eql(u8, sub_path, "message")) return handleSessionMessages(ctx, request, id, a);
                if (std.mem.eql(u8, sub_path, "prompt")) return handlePrompt(ctx, request, id);
            } else {
                const id = if (std.mem.indexOfScalar(u8, rest, '?')) |qm| rest[0..qm] else rest;
                return handleSessionGet(ctx, request, id, a);
            }
        }
    } else if (method == .POST) {
        if (std.mem.eql(u8, path, "/api/session")) return handleSessionCreate(ctx, request, a);
        if (std.mem.startsWith(u8, path, "/api/session/")) {
            const rest = path["/api/session/".len..];
            if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
                const id = rest[0..slash];
                const sub = rest[slash + 1 ..];
                const sub_path = if (std.mem.indexOfScalar(u8, sub, '?')) |qm| sub[0..qm] else sub;
                if (std.mem.eql(u8, sub_path, "abort")) return handleAbort(ctx, request, id, a);
            }
        }
    } else if (method == .PATCH) {
        if (std.mem.startsWith(u8, path, "/api/session/")) {
            const rest = path["/api/session/".len..];
            const id = if (std.mem.indexOfScalar(u8, rest, '?')) |qm| rest[0..qm] else rest;
            if (std.mem.indexOfScalar(u8, id, '/') == null) {
                return handleSessionRename(ctx, request, id, a);
            }
        }
    } else if (method == .DELETE) {
        if (std.mem.startsWith(u8, path, "/api/session/")) {
            const rest = path["/api/session/".len..];
            if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
                const id = rest[0..slash];
                const sub = rest[slash + 1 ..];
                const sub_path = if (std.mem.indexOfScalar(u8, sub, '?')) |qm| sub[0..qm] else sub;
                if (std.mem.startsWith(u8, sub_path, "message/")) {
                    const idx_str = sub_path["message/".len..];
                    return handleMessageDelete(ctx, request, id, idx_str, a);
                }
            } else {
                const id = if (std.mem.indexOfScalar(u8, rest, '?')) |qm| rest[0..qm] else rest;
                if (std.mem.indexOfScalar(u8, id, '/') == null) {
                    return handleSessionDelete(ctx, request, id, a);
                }
            }
        }
    }

    return err_mod.respondError(request, .not_found, "endpoint not found", a);
}

fn serveIndex(_: *Context, request: *std.http.Server.Request, a: std.mem.Allocator) !void {
    var body: AlignedU8 = .empty;

    if (std.mem.indexOf(u8, INDEX_HTML, STYLE_MARKER)) |style_pos| {
        try body.appendSlice(a, INDEX_HTML[0..style_pos]);
        // inject <style> with APP_CSS, substituting the /* FONTS */ marker with
        // base64-embedded font faces.
        try body.appendSlice(a, "<style>");
        if (std.mem.indexOf(u8, APP_CSS, FONT_MARKER)) |font_pos| {
            try body.appendSlice(a, APP_CSS[0..font_pos]);
            const inter_b64 = try base64Encode(a, INTER_WOFF2);
            defer a.free(inter_b64);
            const jet_b64 = try base64Encode(a, JETBRAINS_TTF);
            defer a.free(jet_b64);
            try body.appendSlice(a, "@font-face{font-family:'Inter';src:url(data:font/woff2;base64,");
            try body.appendSlice(a, inter_b64);
            try body.appendSlice(a, ") format('woff2')}@font-face{font-family:'JetBrainsMono';src:url(data:font/truetype;base64,");
            try body.appendSlice(a, jet_b64);
            try body.appendSlice(a, ") format('truetype')}");
            const after_font = font_pos + FONT_MARKER.len;
            try body.appendSlice(a, APP_CSS[after_font..]);
        } else {
            try body.appendSlice(a, APP_CSS);
        }
        try body.appendSlice(a, "</style>");

        const rest = INDEX_HTML[style_pos + STYLE_MARKER.len ..];

        if (std.mem.indexOf(u8, rest, SCRIPT_MARKER)) |script_pos| {
            try body.appendSlice(a, rest[0..script_pos]);
            // inject scripts: marked + highlight + purify, order matters (marked first for global assignment)
            try body.appendSlice(a, "<script>");
            try body.appendSlice(a, MARKED_JS);
            try body.appendSlice(a, "</script><script>");
            try body.appendSlice(a, PURIFY_JS);
            try body.appendSlice(a, "</script><script>");
            try body.appendSlice(a, HIGHLIGHT_JS);
            try body.appendSlice(a, "</script><script>");
            try body.appendSlice(a, APP_JS);
            try body.appendSlice(a, "</script>");
            const after_script = script_pos + SCRIPT_MARKER.len;
            try body.appendSlice(a, rest[after_script..]);
        } else {
            try body.appendSlice(a, rest);
        }
    } else {
        try body.appendSlice(a, INDEX_HTML);
    }

    try request.respond(body.items, .{
        .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
    });
}

fn base64Encode(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    const b64 = std.base64.standard.Encoder;
    const out_len = b64.calcSize(data.len);
    const buf = try allocator.alloc(u8, out_len);
    _ = b64.encode(buf, data);
    return buf;
}

fn respondJson(request: *std.http.Server.Request, body: []const u8) !void {
    try request.respond(body, .{
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

fn handleFavicon(_: *Context, request: *std.http.Server.Request, a: std.mem.Allocator) !void {
    _ = a;
    try request.respond(FAVICON, .{
        .extra_headers = &.{.{ .name = "content-type", .value = "image/x-icon" }},
    });
}

fn handleModelList(ctx: *Context, request: *std.http.Server.Request, a: std.mem.Allocator) !void {
    var buf: AlignedU8 = .empty;
    try buf.appendSlice(a, "[");
    var first = true;
    for (ctx.config.providers) |p| {
        for (p.models) |m| {
            if (!first) try buf.appendSlice(a, ",");
            first = false;
            var item: [256]u8 = undefined;
            const s = try std.fmt.bufPrint(&item, "{{\"id\":\"{s}/{s}\",\"name\":\"{s}\",\"provider\":\"{s}\",\"context_window\":{d}}}", .{ p.name, m.id, m.name, p.name, m.context_window });
            try buf.appendSlice(a, s);
        }
    }
    try buf.appendSlice(a, "]");
    try respondJson(request, buf.items);
}

fn handleProviderList(ctx: *Context, request: *std.http.Server.Request, a: std.mem.Allocator) !void {
    var buf: AlignedU8 = .empty;
    try buf.appendSlice(a, "[");
    var first = true;
    for (ctx.config.providers) |p| {
        if (!first) try buf.appendSlice(a, ",");
        first = false;
        var item: [256]u8 = undefined;
        const s = try std.fmt.bufPrint(&item, "{{\"name\":\"{s}\",\"base_url\":\"{s}\"}}", .{ p.name, p.base_url });
        try buf.appendSlice(a, s);
    }
    try buf.appendSlice(a, "]");
    try respondJson(request, buf.items);
}

fn handleSessionList(ctx: *Context, request: *std.http.Server.Request, a: std.mem.Allocator) !void {
    log.req_info(ctx.thread_id, ctx.request_id, "session_list", "dir={s}", .{ctx.sessions_dir});

    const list = session_mod.list(a, ctx.io, ctx.sessions_dir) catch |err| {
        var dbuf: [256]u8 = undefined;
        var dw: std.Io.File.Writer = .init(.stderr(), ctx.io, &dbuf);
        _ = dw.interface.print("z-agent-core: error: session listing failed ({s})\n", .{@errorName(err)}) catch {};
        _ = dw.interface.flush() catch {};
        return respondJson(request, "[]");
    };

    var buf: AlignedU8 = .empty;
    try buf.appendSlice(a, "[");
    var first = true;
    for (list) |s| {
        if (!first) try buf.appendSlice(a, ",");
        first = false;
        var item: [256]u8 = undefined;
        const display_name = if (uuid_mod.isUuid(s.name)) "New Session" else s.name;
        const ss = try std.fmt.bufPrint(&item, "{{\"id\":\"{s}\",\"name\":\"{s}\",\"model\":\"{s}\",\"msg_count\":{d},\"timestamp\":{d}}}", .{ s.id, display_name, s.model, s.msg_count, s.timestamp });
        try buf.appendSlice(a, ss);
    }
    try buf.appendSlice(a, "]");
    try respondJson(request, buf.items);
}

fn handleSessionGet(ctx: *Context, request: *std.http.Server.Request, id: []const u8, a: std.mem.Allocator) !void {
    var session = loadSession(ctx, id) catch |err| {
        if (err == error.InvalidSessionId) return err_mod.respondError(request, .bad_request, "invalid session id", a);
        if (err == error.FileNotFound) return err_mod.respondError(request, .session_not_found, "session not found", a);
        return err_mod.respondError(request, .internal_error, "failed to load session", a);
    };
    defer session.deinit();

    var buf: AlignedU8 = .empty;
    var hdr: [512]u8 = undefined;
    const display_name = if (uuid_mod.isUuid(session.name)) "New Session" else session.name;
    const h = try std.fmt.bufPrint(&hdr, "{{\"name\":\"{s}\",\"model\":\"{s}\",\"messages\":[", .{ display_name, session.model });
    try buf.appendSlice(a, h);
    const msgs = session.messages();
    var first = true;
    for (msgs) |m| {
        if (!first) try buf.appendSlice(a, ",");
        first = false;
        try formatMessageJson(a, &buf, m);
    }
    try buf.appendSlice(a, "]}");
    try respondJson(request, buf.items);
}

fn handleSessionMessages(ctx: *Context, request: *std.http.Server.Request, id: []const u8, a: std.mem.Allocator) !void {
    var session = loadSession(ctx, id) catch |err| {
        if (err == error.InvalidSessionId) return err_mod.respondError(request, .bad_request, "invalid session id", a);
        if (err == error.FileNotFound) return err_mod.respondError(request, .session_not_found, "session not found", a);
        return err_mod.respondError(request, .internal_error, "failed to load session", a);
    };
    defer session.deinit();

    var buf: AlignedU8 = .empty;
    try buf.appendSlice(a, "[");
    const msgs = session.messages();
    var first = true;
    for (msgs) |m| {
        if (!first) try buf.appendSlice(a, ",");
        first = false;
        try formatMessageJson(a, &buf, m);
    }
    try buf.appendSlice(a, "]");
    try respondJson(request, buf.items);
}

fn handleSessionCreate(ctx: *Context, request: *std.http.Server.Request, a: std.mem.Allocator) !void {
    const id = try uuid_mod.v4(a);
    var model: []const u8 = ctx.config.default_model;
    if (request.head.method == .POST) {
        var transfer_buf: [512]u8 = undefined;
        var body_reader = request.readerExpectNone(&transfer_buf);
        const body = body_reader.allocRemaining(a, @enumFromInt(1024)) catch null;
        if (body) |b| {
            const parsed = std.json.parseFromSlice(std.json.Value, a, b, .{ .ignore_unknown_fields = true }) catch null;
            if (parsed) |p| {
                if (p.value.object.get("model")) |mv| {
                    if (mv == .string) model = mv.string;
                }
            }
        }
    }
    var s = try session_mod.Session.init(ctx.allocator, ctx.io, model);
    defer s.deinit();
    try Io.Dir.cwd().createDirPath(ctx.io, ctx.sessions_dir);
    const filename = try std.fmt.allocPrint(a, "{s}.jsonl", .{id});
    const path = try std.fs.path.join(a, &.{ ctx.sessions_dir, filename });
    s.path = path;
    try s.flush(); // 空会话落盘，刷新不消失
    var buf: [256]u8 = undefined;
    const response = try std.fmt.bufPrint(&buf, "{{\"id\":\"{s}\",\"name\":\"New Session\",\"model\":\"{s}\"}}", .{ id, model });
    try respondJson(request, response);
}

fn handleAbort(ctx: *Context, request: *std.http.Server.Request, session_id: []const u8, a: std.mem.Allocator) !void {
    _ = a;
    ctx.abort_mutex.lock(ctx.io) catch unreachable;
    defer ctx.abort_mutex.unlock(ctx.io);

    const agent_ptr = ctx.abort_map.get(session_id) orelse
        return err_mod.respondError(request, .not_found, "no active prompt for this session", ctx.allocator);

    agent_ptr.abort();
    try respondJson(request, "{\"status\":\"aborted\"}");
}

fn handleSessionRename(ctx: *Context, request: *std.http.Server.Request, id: []const u8, a: std.mem.Allocator) !void {
    var session = loadSession(ctx, id) catch |err| {
        if (err == error.InvalidSessionId) return err_mod.respondError(request, .bad_request, "invalid session id", a);
        if (err == error.FileNotFound) return err_mod.respondError(request, .session_not_found, "session not found", a);
        return err_mod.respondError(request, .internal_error, "failed to load session", a);
    };
    defer session.deinit();

    var transfer_buf: [512]u8 = undefined;
    var body_reader = request.readerExpectNone(&transfer_buf);
    const body = try body_reader.allocRemaining(a, @enumFromInt(1024));
    const parsed = std.json.parseFromSlice(std.json.Value, a, body, .{}) catch
        return err_mod.respondError(request, .bad_request, "invalid JSON body", a);
    const new_name = if (parsed.value.object.get("name")) |nv| nv.string
        else return err_mod.respondError(request, .bad_request, "missing name field", a);

    try session.rename(new_name);
    try session.flush();
    try respondJson(request, "{\"status\":\"renamed\"}");
}

fn handleSessionDelete(ctx: *Context, request: *std.http.Server.Request, id: []const u8, a: std.mem.Allocator) !void {
    if (!isValidSessionId(id)) return err_mod.respondError(request, .bad_request, "invalid session id", a);
    const filename = try std.fmt.allocPrint(a, "{s}.jsonl", .{id});
    defer a.free(filename);
    const path = try std.fs.path.join(a, &.{ ctx.sessions_dir, filename });
    defer a.free(path);
    session_mod.Session.deleteFile(ctx.io, path) catch |err| {
        if (err == error.FileNotFound) return err_mod.respondError(request, .session_not_found, "session not found", a);
        return err_mod.respondError(request, .internal_error, "failed to delete session", a);
    };
    try respondJson(request, "{\"status\":\"deleted\"}");
}

fn handleMessageDelete(ctx: *Context, request: *std.http.Server.Request, session_id: []const u8, idx_str: []const u8, a: std.mem.Allocator) !void {
    if (!isValidSessionId(session_id)) return err_mod.respondError(request, .bad_request, "invalid session id", a);

    const index = std.fmt.parseUnsigned(usize, idx_str, 10) catch
        return err_mod.respondError(request, .bad_request, "invalid message index", a);

    var session = loadSession(ctx, session_id) catch |err| {
        if (err == error.InvalidSessionId) return err_mod.respondError(request, .bad_request, "invalid session id", a);
        if (err == error.FileNotFound) return err_mod.respondError(request, .session_not_found, "session not found", a);
        return err_mod.respondError(request, .internal_error, "failed to load session", a);
    };
    defer session.deinit();

    session.removeMessage(index) catch |err| {
        if (err == error.IndexOutOfBounds) return err_mod.respondError(request, .bad_request, "message index out of bounds", a);
        return err_mod.respondError(request, .internal_error, "failed to remove message", a);
    };

    try respondJson(request, "{\"status\":\"deleted\"}");
}

fn handlePrompt(ctx: *Context, request: *std.http.Server.Request, session_id: []const u8) !void {
    const target = request.head.target;
    const prompt = extractPrompt(target, ctx.allocator) orelse return err_mod.respondError(request, .bad_request, "missing ?prompt= parameter", ctx.allocator);

    var is_new: bool = false;
    var session = loadSession(ctx, session_id) catch |err| blk: {
        if (err == error.InvalidSessionId) return err_mod.respondError(request, .bad_request, "invalid session id", ctx.allocator);
        if (err != error.FileNotFound) return err_mod.respondError(request, .internal_error, "failed to load session", ctx.allocator);

        var s = try session_mod.Session.init(ctx.allocator, ctx.io, ctx.config.default_model);
        defer s.deinit();
        try s.append(.{ .role = .user, .content = prompt });
        const title_len = @min(prompt.len, 30);
        s.name = try ctx.allocator.dupe(u8, prompt[0..title_len]);
        const filename = try std.fmt.allocPrint(ctx.allocator, "{s}.jsonl", .{session_id});
        const path2 = try std.fs.path.join(ctx.allocator, &.{ ctx.sessions_dir, filename });
        s.path = path2;
        try Io.Dir.cwd().createDirPath(ctx.io, ctx.sessions_dir);
        try s.flush();
        is_new = true;

        log.biz_info(ctx.thread_id, ctx.request_id, "session_new", "path={s}", .{path2});

        break :blk try session_mod.Session.load(ctx.allocator, ctx.io, path2);
    };
    defer session.deinit();

    if (!is_new) {
        if (session.messages().len == 0) is_new = true; // 空会话标记为新（session_ready 用）；不 rename（rename 会改文件名破坏 UUID 映射）
        try session.append(.{ .role = .user, .content = prompt });
    }

    const agent: *agent_mod.AgentLoop = @ptrCast(@alignCast(ctx.agent));
    agent.setSession(&session);

    const sw: *sse.SseWriter = @ptrCast(@alignCast(ctx.sse_writer orelse return err_mod.respondError(request, .internal_error, "SSE writer not available", ctx.allocator)));
    try sw.writeAll("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: keep-alive\r\nCache-Control: no-cache\r\n\r\n");
    try sw.flush();

    log.biz_info(ctx.thread_id, ctx.request_id, "sse_stream_start", "session={s}", .{session_id});

    var sse_state = sse.SseState{
        .w = sw.*,
        .io = ctx.io,
        .agent = agent,
    };
    const phase_cb = sse.createPhaseWriter(&sse_state);
    const tool_cb = sse.createToolDisplay(&sse_state);

    ctx.abort_mutex.lock(ctx.io) catch unreachable;
    ctx.abort_map.put(session_id, agent) catch {};
    ctx.current_abort_session = session_id;
    ctx.abort_mutex.unlock(ctx.io);

    defer {
        ctx.abort_mutex.lock(ctx.io) catch unreachable;
        defer ctx.abort_mutex.unlock(ctx.io);
        _ = ctx.abort_map.remove(session_id);
        ctx.current_abort_session = null;
    }

    if (is_new) {
        const esc_name = try escapeJsonDynamic(ctx.allocator, session.name);
        defer ctx.allocator.free(esc_name);
        var sid_buf: [256]u8 = undefined;
        const sid_payload = try std.fmt.bufPrint(&sid_buf, "{{\"id\":\"{s}\",\"name\":\"{s}\"}}", .{ session_id, esc_name });
        try sse_state.writeFrame("session_ready", sid_payload);
    }

    const result = agent.runTurn(tool_cb, phase_cb) catch |err| {
        log.biz_error(ctx.thread_id, ctx.request_id, "sse_runTurn_error", "err={s}", .{@errorName(err)});

        const err_msg = @errorName(err);
        var buf: [256]u8 = undefined;
        const payload = std.fmt.bufPrint(&buf, "{{\"code\":\"api_error\",\"message\":\"{s}\"}}", .{err_msg}) catch "{}";
        sse_state.writeFrame("error", payload) catch {};
        sse_state.writeFrame("done", "{}") catch {};
        session.flush() catch |flush_err| {
            var flogbuf: [256]u8 = undefined;
            var flogw: std.Io.File.Writer = .init(.stderr(), ctx.io, &flogbuf);
            flogw.interface.print("z-agent-core: error: session flush failed ({s})\n", .{@errorName(flush_err)}) catch {};
            flogw.interface.flush() catch {};
        };
        const def_session2: *session_mod.Session = @ptrCast(@alignCast(ctx.default_session));
        agent.setSession(def_session2);
        return;
    };

    session.flush() catch |err| {
        var f2buf: [256]u8 = undefined;
        var f2w: std.Io.File.Writer = .init(.stderr(), ctx.io, &f2buf);
        f2w.interface.print("z-agent-core: error: session flush failed ({s})\n", .{@errorName(err)}) catch {};
        f2w.interface.flush() catch {};
    };

    const def_session: *session_mod.Session = @ptrCast(@alignCast(ctx.default_session));
    agent.setSession(def_session);

    var done_buf: [4096]u8 = undefined;
    const msg = buildDonePayload(ctx.allocator, &done_buf, @as(u32, @intCast(result.new_message_count)), session.messages(), session.model, session_id) catch
        try std.fmt.bufPrint(&done_buf, "{{\"new_messages\":{d},\"session_id\":\"{s}\"}}", .{ result.new_message_count, session_id });
    log.dbg(ctx.thread_id, ctx.request_id, "sse_pre_done", "msgs={d}", .{result.new_message_count});
    try sse_state.writeFrame("done", msg);

    log.biz_info(ctx.thread_id, ctx.request_id, "sse_done", "msgs={d}", .{result.new_message_count});
}

fn buildDonePayload(allocator: std.mem.Allocator, buf: []u8, new_msgs: u32, msgs: []const types.Message, model: []const u8, session_id: []const u8) ![]const u8 {
    var usage_input: u32 = 0;
    var usage_output: u32 = 0;
    var usage_total: u32 = 0;
    var cache_hit: ?u32 = null;
    var cache_miss: ?u32 = null;
    var has_usage = false;

    var i: usize = msgs.len;
    while (i > 0) {
        i -= 1;
        if (msgs[i].role == .assistant) {
            if (msgs[i].usage) |u| {
                usage_input = u.input;
                usage_output = u.output;
                usage_total = u.total;
                cache_hit = u.cache_hit;
                cache_miss = u.cache_miss;
                has_usage = true;
            }
            break;
        }
    }

    var first_msg_json: AlignedU8 = .empty;
    if (msgs.len > 0) {
        try formatMessageJson(allocator, &first_msg_json, msgs[0]);
    } else {
        try first_msg_json.appendSlice(allocator, "null");
    }

    if (has_usage) {
        var usage_buf: [256]u8 = undefined;
        const usage_json = if (cache_hit) |ch| blk: {
            const cm = cache_miss orelse 0;
            break :blk try std.fmt.bufPrint(&usage_buf, "{{\"input\":{d},\"output\":{d},\"total\":{d},\"cache_hit\":{d},\"cache_miss\":{d}}}", .{ usage_input, usage_output, usage_total, ch, cm });
        } else try std.fmt.bufPrint(&usage_buf, "{{\"input\":{d},\"output\":{d},\"total\":{d}}}", .{ usage_input, usage_output, usage_total });

        return try std.fmt.bufPrint(buf, "{{\"new_messages\":{d},\"usage\":{s},\"model\":\"{s}\",\"first_message\":{s},\"session_id\":\"{s}\"}}", .{ new_msgs, usage_json, model, first_msg_json.items, session_id });
    }
    return try std.fmt.bufPrint(buf, "{{\"new_messages\":{d},\"usage\":null,\"model\":\"{s}\",\"first_message\":{s},\"session_id\":\"{s}\"}}", .{ new_msgs, model, first_msg_json.items, session_id });
}

fn isValidSessionId(id: []const u8) bool {
    return session_mod.Session.isValidId(id);
}

fn isNumericId(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

fn loadSession(ctx: *Context, id: []const u8) !session_mod.Session {
    if (!isValidSessionId(id)) return error.InvalidSessionId;
    const filename = try std.fmt.allocPrint(ctx.allocator, "{s}.jsonl", .{id});
    defer ctx.allocator.free(filename);
    const path = try std.fs.path.join(ctx.allocator, &.{ ctx.sessions_dir, filename });
    defer ctx.allocator.free(path);
    return session_mod.Session.load(ctx.allocator, ctx.io, path);
}

fn formatMessageJson(allocator: std.mem.Allocator, buf: *AlignedU8, msg: types.Message) !void {
    const role = @tagName(msg.role);
    const escaped = try escapeJsonDynamic(allocator, msg.content);
    defer allocator.free(escaped);
    try buf.appendSlice(allocator, "{\"role\":\"");
    try buf.appendSlice(allocator, role);
    try buf.appendSlice(allocator, "\",\"content\":\"");
    try buf.appendSlice(allocator, escaped);
    try buf.appendSlice(allocator, "\"");

    if (msg.reasoning_content) |rc| {
        const resc = try escapeJsonDynamic(allocator, rc);
        defer allocator.free(resc);
        try buf.appendSlice(allocator, ",\"reasoning_content\":\"");
        try buf.appendSlice(allocator, resc);
        try buf.appendSlice(allocator, "\"");
    }

    if (msg.tool_calls) |tc| {
        try buf.appendSlice(allocator, ",\"tool_calls\":[");
        for (tc, 0..) |c, i| {
            if (i > 0) try buf.appendSlice(allocator, ",");
            const arg_esc = try escapeJsonDynamic(allocator, c.arguments);
            defer allocator.free(arg_esc);
            const s = try std.fmt.allocPrint(allocator, "{{\"id\":\"{s}\",\"name\":\"{s}\",\"arguments\":\"{s}\"}}", .{ c.id, c.name, arg_esc });
            defer allocator.free(s);
            try buf.appendSlice(allocator, s);
        }
        try buf.appendSlice(allocator, "]");
    }

    if (msg.tool_call_id) |tcid| {
        try buf.appendSlice(allocator, ",\"tool_call_id\":\"");
        try buf.appendSlice(allocator, tcid);
        try buf.appendSlice(allocator, "\"");
    }

    if (msg.usage) |u| {
        const ch = if (u.cache_hit) |v| blk: {
            const s = try std.fmt.allocPrint(allocator, "{d}", .{v});
            break :blk s;
        } else blk: {
            break :blk try allocator.dupe(u8, "null");
        };
        defer allocator.free(ch);
        const cm = if (u.cache_miss) |v| blk: {
            const s = try std.fmt.allocPrint(allocator, "{d}", .{v});
            break :blk s;
        } else blk: {
            break :blk try allocator.dupe(u8, "null");
        };
        defer allocator.free(cm);
        const s = try std.fmt.allocPrint(allocator, ",\"usage\":{{\"input\":{d},\"output\":{d},\"total\":{d},\"cache_hit\":{s},\"cache_miss\":{s}}}", .{ u.input, u.output, u.total, ch, cm });
        defer allocator.free(s);
        try buf.appendSlice(allocator, s);
    }

    if (msg.model) |m| {
        if (m.len > 0) {
            try buf.appendSlice(allocator, ",\"model\":\"");
            try buf.appendSlice(allocator, m);
            try buf.appendSlice(allocator, "\"");
        }
    }

    try buf.appendSlice(allocator, "}");
}

fn escapeJsonDynamic(allocator: std.mem.Allocator, src: []const u8) ![]const u8 {
    var result: AlignedU8 = .empty;
    try result.ensureTotalCapacityPrecise(allocator, src.len + 16);
    for (src) |c| {
        switch (c) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            else => try result.append(allocator, c),
        }
    }
    return result.toOwnedSlice(allocator);
}

fn extractPrompt(target: []const u8, a: std.mem.Allocator) ?[]const u8 {
    const qm = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    const query = target[qm + 1 ..];
    const prefix = "prompt=";
    if (!std.mem.startsWith(u8, query, prefix)) return null;
    var value = query[prefix.len..];
    if (std.mem.indexOfScalar(u8, value, '&')) |amp| {
        value = value[0..amp];
    }
    if (value.len == 0) return null;
    return percentDecode(a, value) catch null;
}

fn percentDecode(allocator: std.mem.Allocator, src: []const u8) ![]const u8 {
    var buf: AlignedU8 = .empty;
    try buf.ensureTotalCapacityPrecise(allocator, src.len);
    var i: usize = 0;
    while (i < src.len) {
        if (src[i] == '%' and i + 2 < src.len) {
            const hi = std.fmt.charToDigit(src[i + 1], 16) catch return error.InvalidPercentEncoding;
            const lo = std.fmt.charToDigit(src[i + 2], 16) catch return error.InvalidPercentEncoding;
            try buf.append(allocator, @as(u8, @intCast(hi * 16 + lo)));
            i += 3;
        } else if (src[i] == '+') {
            try buf.append(allocator, ' ');
            i += 1;
        } else {
            try buf.append(allocator, src[i]);
            i += 1;
        }
    }
    return buf.toOwnedSlice(allocator);
}
