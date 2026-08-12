const std = @import("std");
const types = @import("../../types.zig");
const config_mod = @import("../../config.zig");
const session_mod = @import("../../core/session.zig");
const agent_mod = @import("../../core/agent.zig");
const sse = @import("sse.zig");
const err_mod = @import("error.zig");
const uuid_mod = @import("../../util/uuid.zig");
const log = @import("../../util/log.zig");
const command_mod = @import("../../command.zig");
const session_ops = @import("../../session_ops.zig");
const compact_mod = @import("../../core/compact.zig");
const trace = @import("../../util/trace.zig");
const timing = @import("../../util/timing.zig");

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

/// Session operation undo entries. Stored per-session (LIFO, cap 20) in the
/// server's persistent allocator. Each entry carries enough to reverse the op.
pub const UndoOp = union(enum) {
    delete: struct { index: usize, message: types.Message },
    truncate: struct { removed: []const types.Message },
    branch: struct { fork_id: []const u8 },
};

pub const Context = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    project_root: []const u8,
    sessions_dir: []const u8,
    config: *config_mod.Config,
    agent: *anyopaque,
    provider: *anyopaque,
    default_session: *anyopaque,
    env_snapshot: *const std.process.Environ.Map,
    dotenv: *const std.StringArrayHashMapUnmanaged([]const u8),
    sse_writer: ?*anyopaque = null,
    abort_map: *std.StringHashMap(*agent_mod.AgentLoop),
    abort_mutex: *std.Io.Mutex,
    current_abort_session: ?[]const u8 = null,
    /// Persistent allocator for the undo stack (survives per-request arenas).
    undo_allocator: std.mem.Allocator,
    undo_map: *std.StringHashMap(*std.ArrayListAligned(UndoOp, null)),
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
        if (std.mem.eql(u8, path, "/api/health")) {
            const cwd_esc = try escapeJsonDynamic(a, ctx.project_root);
            const body = try std.fmt.allocPrint(a, "{{\"status\":\"ok\",\"cwd\":\"{s}\"}}", .{cwd_esc});
            return respondJson(request, body);
        }
        if (std.mem.eql(u8, path, "/api/model")) return handleModelList(ctx, request, a);
        if (std.mem.eql(u8, path, "/api/provider")) return handleProviderList(ctx, request, a);
        if (std.mem.eql(u8, path, "/api/session")) return handleSessionList(ctx, request, a);
        if (std.mem.eql(u8, path, "/api/session/active")) return handleSessionActive(ctx, request, a);
        if (std.mem.eql(u8, path, "/api/command")) return handleCommandList(ctx, request, a);
        if (std.mem.startsWith(u8, path, "/api/session/")) {
            const rest = path["/api/session/".len..];
            if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
                const id = rest[0..slash];
                const sub = rest[slash + 1 ..];
                const sub_path = if (std.mem.indexOfScalar(u8, sub, '?')) |qm| sub[0..qm] else sub;
                if (std.mem.eql(u8, sub_path, "message")) return handleSessionMessages(ctx, request, id, a);
                if (std.mem.eql(u8, sub_path, "prompt")) return handlePrompt(ctx, request, id);
                if (std.mem.eql(u8, sub_path, "history")) return handleHistory(ctx, request, id, a);
            } else {
                const id = if (std.mem.indexOfScalar(u8, rest, '?')) |qm| rest[0..qm] else rest;
                return handleSessionGet(ctx, request, id, a);
            }
        }
    } else if (method == .POST) {
        if (std.mem.eql(u8, path, "/api/session")) return handleSessionCreate(ctx, request, a);
        if (std.mem.eql(u8, path, "/api/command")) return handleCommandExec(ctx, request, a);
        if (std.mem.startsWith(u8, path, "/api/session/")) {
            const rest = path["/api/session/".len..];
            if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
                const id = rest[0..slash];
                const sub = rest[slash + 1 ..];
                const sub_path = if (std.mem.indexOfScalar(u8, sub, '?')) |qm| sub[0..qm] else sub;
                if (std.mem.eql(u8, sub_path, "abort")) return handleAbort(ctx, request, id, a);
                if (std.mem.eql(u8, sub_path, "truncate")) return handleTruncate(ctx, request, id, a);
                if (std.mem.eql(u8, sub_path, "branch")) return handleBranch(ctx, request, id, a);
                if (std.mem.eql(u8, sub_path, "compact")) return handleCompact(ctx, request, id, a);
                if (std.mem.eql(u8, sub_path, "undo")) return handleUndo(ctx, request, id, a);
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
        const display_name = if (uuid_mod.isUuid(s.name)) "New Session" else s.name;
        if (s.parent_id) |pid| {
            const ss = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"name\":\"{s}\",\"model\":\"{s}\",\"msg_count\":{d},\"timestamp\":{d},\"parent_id\":\"{s}\"}}", .{ s.id, display_name, s.model, s.msg_count, s.timestamp, pid });
            defer a.free(ss);
            try buf.appendSlice(a, ss);
        } else {
            const ss = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"name\":\"{s}\",\"model\":\"{s}\",\"msg_count\":{d},\"timestamp\":{d},\"parent_id\":null}}", .{ s.id, display_name, s.model, s.msg_count, s.timestamp });
            defer a.free(ss);
            try buf.appendSlice(a, ss);
        }
    }
    try buf.appendSlice(a, "]");
    try respondJson(request, buf.items);
}

/// GET /api/session/active — most recently updated session (list is sorted by
/// timestamp desc). Lets the frontend resume where the user left off after a
/// refresh. Returns 200 with null id when no sessions exist (empty state is not
/// an error — the frontend init calls this unconditionally).
fn handleSessionActive(ctx: *Context, request: *std.http.Server.Request, a: std.mem.Allocator) !void {
    const list = session_mod.list(a, ctx.io, ctx.sessions_dir) catch |err| {
        if (err == error.FileNotFound or err == error.NotDir) return respondJson(request, "{\"id\":null}");
        return err_mod.respondError(request, .internal_error, "failed to list sessions", a);
    };
    defer session_mod.freeSessionInfoList(a, list);
    if (list.len == 0) return respondJson(request, "{\"id\":null}");

    const s = list[0];
    const display_name = if (uuid_mod.isUuid(s.name)) "New Session" else s.name;
    if (s.parent_id) |pid| {
        const body = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"name\":\"{s}\",\"model\":\"{s}\",\"msg_count\":{d},\"timestamp\":{d},\"parent_id\":\"{s}\"}}", .{ s.id, display_name, s.model, s.msg_count, s.timestamp, pid });
        return respondJson(request, body);
    }
    const body = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"name\":\"{s}\",\"model\":\"{s}\",\"msg_count\":{d},\"timestamp\":{d},\"parent_id\":null}}", .{ s.id, display_name, s.model, s.msg_count, s.timestamp });
    return respondJson(request, body);
}

fn handleSessionGet(ctx: *Context, request: *std.http.Server.Request, id: []const u8, a: std.mem.Allocator) !void {
    var session = loadSession(ctx, id) catch |err| {
        if (err == error.InvalidSessionId) return err_mod.respondError(request, .bad_request, "invalid session id", a);
        if (err == error.FileNotFound) return err_mod.respondError(request, .session_not_found, "session not found", a);
        return err_mod.respondError(request, .internal_error, "failed to load session", a);
    };
    defer session.deinit();

    const target = request.head.target;
    const limit_opt = extractQueryValue(target, "limit", a);
    defer if (limit_opt) |v| a.free(v);
    if (limit_opt) |lim_str| {
        const limit = std.fmt.parseUnsigned(usize, lim_str, 10) catch 50;
        return respondPagedSession(request, a, &session, computePage(session.messages(), null, limit));
    }

    var buf: AlignedU8 = .empty;
    var hdr: [512]u8 = undefined;
    const display_name = if (uuid_mod.isUuid(session.name)) "New Session" else session.name;
    if (session.parent_id) |pid| {
        const h = try std.fmt.bufPrint(&hdr, "{{\"name\":\"{s}\",\"model\":\"{s}\",\"parent_id\":\"{s}\",\"messages\":[", .{ display_name, session.model, pid });
        try buf.appendSlice(a, h);
    } else {
        const h = try std.fmt.bufPrint(&hdr, "{{\"name\":\"{s}\",\"model\":\"{s}\",\"messages\":[", .{ display_name, session.model });
        try buf.appendSlice(a, h);
    }
    const msgs = session.messages();
    try writeMessagesRange(a, &buf, msgs, 0, msgs.len);
    try buf.appendSlice(a, "]}");
    try respondJson(request, buf.items);
}

/// Page of messages: `before_id` null → the last `limit` messages; otherwise the
/// `limit` messages immediately before the one with id `before_id`. The page
/// start is pushed back over any leading tool messages so an assistant's tool
/// run (assistant + its tool results) is never split across the boundary.
fn computePage(msgs: []const types.Message, before_id: ?u64, limit: usize) struct { start: usize, end: usize, has_more: bool } {
    var end: usize = msgs.len;
    if (before_id) |bid| {
        var found = false;
        for (msgs, 0..) |m, i| {
            if (m.id == bid) { end = i; found = true; break; }
        }
        if (!found) end = 0;
    }
    var start = if (end > limit) end - limit else 0;
    while (start > 0 and start < end and msgs[start].role == .tool) start -= 1;
    return .{ .start = start, .end = end, .has_more = start > 0 };
}

fn writeMessagesRange(a: std.mem.Allocator, buf: *AlignedU8, msgs: []const types.Message, start: usize, end: usize) !void {
    var first = true;
    for (msgs[start..end]) |m| {
        if (!first) try buf.appendSlice(a, ",");
        first = false;
        try formatMessageJson(a, buf, m);
    }
}

/// Emit {name, model, parent_id, system, messages:[page], has_more}.
fn respondPagedSession(request: *std.http.Server.Request, a: std.mem.Allocator, session: *session_mod.Session, page: anytype) !void {
    const display_name = if (uuid_mod.isUuid(session.name)) "New Session" else session.name;
    const msgs = session.messages();
    var buf: AlignedU8 = .empty;
    // system content can be a large system prompt — use heap allocPrint, never a
    // fixed stack buffer (bufPrint overflows → 500).
    const sys = if (msgs.len > 0) try escapeJsonDynamic(a, msgs[0].content) else null;
    defer if (sys) |s| a.free(s);
    const sys_str = if (sys) |s| s else "";
    if (session.parent_id) |pid| {
        const h = try std.fmt.allocPrint(a, "{{\"name\":\"{s}\",\"model\":\"{s}\",\"parent_id\":\"{s}\",\"system\":\"{s}\",\"messages\":[", .{ display_name, session.model, pid, sys_str });
        defer a.free(h);
        try buf.appendSlice(a, h);
    } else {
        const h = try std.fmt.allocPrint(a, "{{\"name\":\"{s}\",\"model\":\"{s}\",\"system\":\"{s}\",\"messages\":[", .{ display_name, session.model, sys_str });
        defer a.free(h);
        try buf.appendSlice(a, h);
    }
    try writeMessagesRange(a, &buf, msgs, page.start, page.end);
    const more_str = if (page.has_more) "true" else "false";
    const tail = try std.fmt.allocPrint(a, "],\"has_more\":{s}}}", .{more_str});
    defer a.free(tail);
    try buf.appendSlice(a, tail);
    try respondJson(request, buf.items);
}

fn handleSessionMessages(ctx: *Context, request: *std.http.Server.Request, id: []const u8, a: std.mem.Allocator) !void {
    var session = loadSession(ctx, id) catch |err| {
        if (err == error.InvalidSessionId) return err_mod.respondError(request, .bad_request, "invalid session id", a);
        if (err == error.FileNotFound) return err_mod.respondError(request, .session_not_found, "session not found", a);
        return err_mod.respondError(request, .internal_error, "failed to load session", a);
    };
    defer session.deinit();

    const target = request.head.target;
    const limit_opt = extractQueryValue(target, "limit", a);
    defer if (limit_opt) |v| a.free(v);
    const before_opt = extractQueryValue(target, "before", a);
    defer if (before_opt) |v| a.free(v);

    const limit = if (limit_opt) |ls| std.fmt.parseUnsigned(usize, ls, 10) catch 50 else 50;
    const before_id: ?u64 = if (before_opt) |bs| std.fmt.parseUnsigned(u64, bs, 10) catch null else null;
    return respondPagedSession(request, a, &session, computePage(session.messages(), before_id, limit));
}

fn resolveModelSpec(config: *const config_mod.Config, opt: ?[]const u8) []const u8 {
    if (opt) |s| {
        if (s.len > 0) return s;
    }
    return config.default_model;
}

const ResolvedModel = struct {
    model: *const types.Model,
    entry: *const types.ProviderEntry,
};

fn resolveSessionModel(config: *const config_mod.Config, spec: []const u8) !ResolvedModel {
    const model = try config_mod.resolveModel(config, spec);
    for (config.providers) |*entry| {
        if (std.mem.eql(u8, entry.name, model.provider)) return .{ .model = model, .entry = entry };
    }
    return error.ProviderNotFound;
}

const CreatedSession = struct {
    id: []const u8,
    session: session_mod.Session,
};

/// Create an empty session and flush it to disk. `id_override` lets the caller
/// pin the file name (handlePrompt uses the frontend-generated session id);
/// null generates a fresh uuid (handleSessionCreate / handleCommandNew).
fn createSession(ctx: *Context, a: std.mem.Allocator, opt_model: ?[]const u8, id_override: ?[]const u8) !CreatedSession {
    const spec = resolveModelSpec(ctx.config, opt_model);
    const id = if (id_override) |oid| oid else try uuid_mod.v4(a);
    var s = try session_mod.Session.init(ctx.allocator, ctx.io, spec);
    try Io.Dir.cwd().createDirPath(ctx.io, ctx.sessions_dir);
    const filename = try std.fmt.allocPrint(a, "{s}.jsonl", .{id});
    const path = try std.fs.path.join(a, &.{ ctx.sessions_dir, filename });
    s.path = path;
    try s.flush(); // 空会话落盘，刷新不消失
    return .{ .id = id, .session = s };
}

/// Append `"provider/model_id"` comma-separated entries to buf. Shared by
/// handleModelList (full object array) and respondModelUnavailable (id list),
/// so the `provider/model_id` id scheme never drifts across the two.
fn writeModelIds(a: std.mem.Allocator, config: *const config_mod.Config, buf: *AlignedU8) !void {
    var first = true;
    for (config.providers) |p| {
        for (p.models) |m| {
            if (!first) try buf.appendSlice(a, ",");
            first = false;
            const item = try std.fmt.allocPrint(a, "\"{s}/{s}\"", .{ p.name, m.id });
            try buf.appendSlice(a, item);
        }
    }
}

/// 400 error whose body includes `available_models` so the user/frontend can
/// see which provider/model specs are actually selectable.
fn respondModelUnavailable(request: *std.http.Server.Request, ctx: *Context, spec: []const u8, a: std.mem.Allocator) !void {
    const esc_spec = try escapeJsonDynamic(a, spec);
    defer a.free(esc_spec);
    var body: AlignedU8 = .empty;
    try body.appendSlice(a, "{\"error\":{\"code\":\"bad_request\",\"message\":\"cannot resolve model \\\"");
    try body.appendSlice(a, esc_spec);
    try body.appendSlice(a, "\\\"\",\"available_models\":[");
    try writeModelIds(a, ctx.config, &body);
    try body.appendSlice(a, "]}}");
    try request.respond(body.items, .{ .status = .bad_request });
}

fn handleSessionCreate(ctx: *Context, request: *std.http.Server.Request, a: std.mem.Allocator) !void {
    var body_model: ?[]const u8 = null;
    if (request.head.method == .POST) {
        var transfer_buf: [512]u8 = undefined;
        var body_reader = request.readerExpectNone(&transfer_buf);
        const body = body_reader.allocRemaining(a, @enumFromInt(1024)) catch null;
        if (body) |b| {
            const parsed = std.json.parseFromSlice(std.json.Value, a, b, .{ .ignore_unknown_fields = true }) catch null;
            if (parsed) |p| {
                if (p.value.object.get("model")) |mv| {
                    if (mv == .string and mv.string.len > 0) body_model = mv.string;
                }
            }
        }
    }
    var created = try createSession(ctx, a, body_model, null);
    defer created.session.deinit();
    var buf: [256]u8 = undefined;
    const response = try std.fmt.bufPrint(&buf, "{{\"id\":\"{s}\",\"name\":\"New Session\",\"model\":\"{s}\"}}", .{ created.id, created.session.model });
    try respondJson(request, response);
}

/// GET /api/command — serialize the core command registry (drives the Web
/// slash popover; no inline duplication).
fn handleCommandList(ctx: *Context, request: *std.http.Server.Request, a: std.mem.Allocator) !void {
    _ = ctx;
    var body: AlignedU8 = .empty;
    try body.appendSlice(a, "[");
    for (&command_mod.builtin, 0..) |c, i| {
        if (i > 0) try body.appendSlice(a, ",");
        const item = try std.fmt.allocPrint(a, "{{\"name\":\"{s}\",\"description\":\"{s}\",\"args_hint\":\"{s}\",\"kind\":\"{s}\"}}", .{ c.name, c.description, c.args_hint, @tagName(c.kind) });
        try body.appendSlice(a, item);
    }
    try body.appendSlice(a, "]");
    try respondJson(request, body.items);
}

/// POST /api/command — execute a core action command. Non-streaming JSON
/// envelope {status:ok|error, data?}. Session-bound commands require session_id.
fn handleCommandExec(ctx: *Context, request: *std.http.Server.Request, a: std.mem.Allocator) !void {
    var transfer_buf: [512]u8 = undefined;
    var body_reader = request.readerExpectNone(&transfer_buf);
    const body = try body_reader.allocRemaining(a, @enumFromInt(2048));
    const parsed = std.json.parseFromSlice(std.json.Value, a, body, .{ .ignore_unknown_fields = true }) catch
        return err_mod.respondError(request, .bad_request, "invalid JSON body", a);
    const obj = parsed.value.object;
    const name = if (obj.get("name")) |nv| nv.string else return err_mod.respondError(request, .bad_request, "missing name", a);
    const cmd = command_mod.find(name) orelse return err_mod.respondError(request, .bad_request, "unknown command", a);
    if (cmd.kind != .action) return err_mod.respondError(request, .bad_request, "prompt command not supported yet", a);
    const args = if (obj.get("args")) |av| (if (av == .string) av.string else "") else "";
    const session_id = if (obj.get("session_id")) |sv| (if (sv == .string) sv.string else null) else null;

    if (std.mem.eql(u8, name, "new")) {
        return handleCommandNew(ctx, request, a);
    }
    if (std.mem.eql(u8, name, "list")) {
        return handleSessionList(ctx, request, a);
    }
    if (std.mem.eql(u8, name, "thinking") or std.mem.eql(u8, name, "load")) {
        return respondJson(request, "{\"status\":\"error\",\"message\":\"command not available via API yet\"}");
    }

    const sid = session_id orelse return err_mod.respondError(request, .bad_request, "missing session_id", a);
    if (std.mem.eql(u8, name, "fork") or std.mem.eql(u8, name, "reset") or std.mem.eql(u8, name, "name")) {
        if (isSessionStreaming(ctx, sid)) return err_mod.respondError(request, .agent_busy, "session is busy", a);
    }
    var session = loadSession(ctx, sid) catch |err| return respondCmdLoadError(request, err, a);
    defer session.deinit();

    if (std.mem.eql(u8, name, "fork")) {
        var fork_sess = session_ops.fork(ctx.allocator, ctx.io, &session, ctx.sessions_dir, args) catch
            return err_mod.respondError(request, .bad_request, "fork failed", a);
        defer fork_sess.deinit();
        const fork_path = fork_sess.path orelse return err_mod.respondError(request, .internal_error, "fork session has no path", a);
        const fork_id = try sessionIdFromPath(a, fork_path);
        const response = try std.fmt.allocPrint(a, "{{\"status\":\"ok\",\"data\":{{\"session_id\":\"{s}\",\"name\":\"{s}\"}}}}", .{ fork_id, fork_sess.name });
        return respondJson(request, response);
    }
    if (std.mem.eql(u8, name, "reset")) {
        session_ops.reset(&session);
        try session.flush();
        return respondJson(request, "{\"status\":\"ok\"}");
    }
    if (std.mem.eql(u8, name, "name")) {
        try session.rename(args);
        try session.flush();
        return respondJson(request, "{\"status\":\"ok\"}");
    }
    return respondJson(request, "{\"status\":\"error\",\"message\":\"unknown command\"}");
}

fn handleCommandNew(ctx: *Context, request: *std.http.Server.Request, a: std.mem.Allocator) !void {
    var created = try createSession(ctx, a, null, null);
    defer created.session.deinit();
    const response = try std.fmt.allocPrint(a, "{{\"status\":\"ok\",\"data\":{{\"session_id\":\"{s}\",\"name\":\"{s}\"}}}}", .{ created.id, created.session.name });
    try respondJson(request, response);
}

fn respondCmdLoadError(request: *std.http.Server.Request, err: anyerror, a: std.mem.Allocator) !void {
    if (err == error.InvalidSessionId) return err_mod.respondError(request, .bad_request, "invalid session id", a);
    if (err == error.FileNotFound) return err_mod.respondError(request, .session_not_found, "session not found", a);
    return err_mod.respondError(request, .internal_error, "failed to load session", a);
}

fn sessionIdFromPath(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    const base = std.fs.path.basename(path);
    const id = if (std.mem.endsWith(u8, base, ".jsonl")) base[0 .. base.len - ".jsonl".len] else base;
    return a.dupe(u8, id);
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

    // Active-session guard (canonicalized compare) BEFORE deletion: deleting the
    // default session leaves a stale in-memory Session whose next flush would
    // recreate an empty file.
    const def_session: *session_mod.Session = @ptrCast(@alignCast(ctx.default_session));
    if (def_session.path) |cur_path| {
        const cur_res = std.fs.path.resolve(a, &.{cur_path}) catch null;
        defer if (cur_res) |r| a.free(r);
        const tgt_res = std.fs.path.resolve(a, &.{path}) catch null;
        defer if (tgt_res) |r| a.free(r);
        if (cur_res != null and tgt_res != null and std.mem.eql(u8, cur_res.?, tgt_res.?)) {
            return err_mod.respondError(request, .bad_request, "cannot delete the active session", a);
        }
    }

    session_mod.Session.deleteFile(ctx.io, path) catch |err| {
        if (err == error.FileNotFound) return err_mod.respondError(request, .session_not_found, "session not found", a);
        return err_mod.respondError(request, .internal_error, "failed to delete session", a);
    };
    try respondJson(request, "{\"status\":\"deleted\"}");
}

fn handleMessageDelete(ctx: *Context, request: *std.http.Server.Request, session_id: []const u8, msg_id_str: []const u8, a: std.mem.Allocator) !void {
    if (!isValidSessionId(session_id)) return err_mod.respondError(request, .bad_request, "invalid session id", a);
    if (isSessionStreaming(ctx, session_id)) return err_mod.respondError(request, .agent_busy, "session is busy", a);

    const msg_id = std.fmt.parseUnsigned(u64, msg_id_str, 10) catch
        return err_mod.respondError(request, .bad_request, "invalid message id", a);

    var session = loadSession(ctx, session_id) catch |err| {
        if (err == error.InvalidSessionId) return err_mod.respondError(request, .bad_request, "invalid session id", a);
        if (err == error.FileNotFound) return err_mod.respondError(request, .session_not_found, "session not found", a);
        return err_mod.respondError(request, .internal_error, "failed to load session", a);
    };
    defer session.deinit();

    const index = session.indexOfId(msg_id) orelse
        return err_mod.respondError(request, .message_not_found, "message not found", a);
    if (index == 0) return err_mod.respondError(request, .bad_request, "cannot delete system message", a);

    try pushUndo(ctx, session_id, .{ .delete = .{ .index = index, .message = try dupMessage(ctx.undo_allocator, session.messages()[index]) } });

    session.removeMessage(index) catch |err| {
        if (err == error.IndexOutOfBounds) return err_mod.respondError(request, .bad_request, "message index out of bounds", a);
        return err_mod.respondError(request, .internal_error, "failed to remove message", a);
    };

    try respondJson(request, "{\"status\":\"deleted\"}");
}

/// POST /api/session/:id/truncate {"message_id":N} — keep messages before the
/// message with id N (position-based, system prompt at index 0 preserved).
fn handleTruncate(ctx: *Context, request: *std.http.Server.Request, session_id: []const u8, a: std.mem.Allocator) !void {
    if (!isValidSessionId(session_id)) return err_mod.respondError(request, .bad_request, "invalid session id", a);
    if (isSessionStreaming(ctx, session_id)) return err_mod.respondError(request, .agent_busy, "session is busy", a);

    const msg_id = readMessageIdBody(request, a) catch |err| switch (err) {
        error.InvalidBody => return err_mod.respondError(request, .bad_request, "invalid JSON body", a),
        error.InvalidMessageId => return err_mod.respondError(request, .bad_request, "missing or invalid message_id", a)
    };

    var session = loadSession(ctx, session_id) catch |err| {
        if (err == error.InvalidSessionId) return err_mod.respondError(request, .bad_request, "invalid session id", a);
        if (err == error.FileNotFound) return err_mod.respondError(request, .session_not_found, "session not found", a);
        return err_mod.respondError(request, .internal_error, "failed to load session", a);
    };
    defer session.deinit();

    const index = session.indexOfId(msg_id) orelse
        return err_mod.respondError(request, .message_not_found, "message not found", a);
    if (index == 0) return err_mod.respondError(request, .bad_request, "cannot truncate at system message", a);

    // Record the removed messages (deep-copied) for undo.
    {
        const removed_msgs = session.messages()[index..];
        const removed = try ctx.undo_allocator.alloc(types.Message, removed_msgs.len);
        for (removed_msgs, 0..) |m, i| removed[i] = try dupMessage(ctx.undo_allocator, m);
        try pushUndo(ctx, session_id, .{ .truncate = .{ .removed = removed } });
    }

    session.truncateTo(index);
    try session.flush();
    try respondJson(request, "{\"status\":\"ok\"}");
}

/// POST /api/session/:id/branch {"message_id":N} — fork a new session containing
/// messages up to and including the message with id N. Auto-named `(fork #N)`.
fn handleBranch(ctx: *Context, request: *std.http.Server.Request, session_id: []const u8, a: std.mem.Allocator) !void {
    if (!isValidSessionId(session_id)) return err_mod.respondError(request, .bad_request, "invalid session id", a);
    if (isSessionStreaming(ctx, session_id)) return err_mod.respondError(request, .agent_busy, "session is busy", a);

    const msg_id = readMessageIdBody(request, a) catch |err| switch (err) {
        error.InvalidBody => return err_mod.respondError(request, .bad_request, "invalid JSON body", a),
        error.InvalidMessageId => return err_mod.respondError(request, .bad_request, "missing or invalid message_id", a)
    };

    var session = loadSession(ctx, session_id) catch |err| {
        if (err == error.InvalidSessionId) return err_mod.respondError(request, .bad_request, "invalid session id", a);
        if (err == error.FileNotFound) return err_mod.respondError(request, .session_not_found, "session not found", a);
        return err_mod.respondError(request, .internal_error, "failed to load session", a);
    };
    defer session.deinit();

    const boundary_idx = session.indexOfId(msg_id) orelse
        return err_mod.respondError(request, .message_not_found, "message not found", a);
    if (boundary_idx == 0) return err_mod.respondError(request, .bad_request, "cannot branch at system message", a);
    const boundary_content = session.messages()[boundary_idx].content;

    var fork_sess = session_ops.forkAt(ctx.allocator, ctx.io, &session, ctx.sessions_dir, msg_id, session_id) catch |err| {
        if (err == error.MessageNotFound) return err_mod.respondError(request, .message_not_found, "message not found", a);
        if (err == error.SessionAlreadyExists) return err_mod.respondError(request, .bad_request, "fork name already exists", a);
        return err_mod.respondError(request, .internal_error, "branch failed", a);
    };
    defer fork_sess.deinit();
    const fork_path = fork_sess.path orelse return err_mod.respondError(request, .internal_error, "fork session has no path", a);
    const fork_id = try sessionIdFromPath(a, fork_path);
    try pushUndo(ctx, session_id, .{ .branch = .{ .fork_id = try ctx.undo_allocator.dupe(u8, fork_id) } });
    const esc_content = try escapeJsonDynamic(a, boundary_content);
    defer a.free(esc_content);
    const response = try std.fmt.allocPrint(a, "{{\"status\":\"ok\",\"data\":{{\"session_id\":\"{s}\",\"name\":\"{s}\",\"boundary_content\":\"{s}\"}}}}", .{ fork_id, fork_sess.name, esc_content });
    return respondJson(request, response);
}

/// POST /api/session/:id/compact — LLM-summarize older messages, keep the recent
/// tail (token-budget + MIN_KEEP, tool-boundary safe), persist as a compaction
/// system message. Thin wrapper over `compact_mod.compactSession`. Blocking (the
/// summarization request round-trips); guarded against streaming sessions.
fn handleCompact(ctx: *Context, request: *std.http.Server.Request, session_id: []const u8, a: std.mem.Allocator) !void {
    if (!isValidSessionId(session_id)) return err_mod.respondError(request, .bad_request, "invalid session id", a);
    if (isSessionStreaming(ctx, session_id)) return err_mod.respondError(request, .agent_busy, "session is busy", a);

    var session = loadSession(ctx, session_id) catch |err| {
        if (err == error.InvalidSessionId) return err_mod.respondError(request, .bad_request, "invalid session id", a);
        if (err == error.FileNotFound) return err_mod.respondError(request, .session_not_found, "session not found", a);
        return err_mod.respondError(request, .internal_error, "failed to load session", a);
    };
    defer session.deinit();

    const agent: *agent_mod.AgentLoop = @ptrCast(@alignCast(ctx.agent));
    if (session.model.len > 0) {
        applySessionModel(ctx, agent, session.model, ctx.allocator) catch |err| {
            log.biz_error(ctx.thread_id, ctx.request_id, "compact_model_apply_failed", "err={s}", .{@errorName(err)});
            return err_mod.respondError(request, .internal_error, "failed to configure model", a);
        };
    }

    const compacted = compact_mod.compactSession(agent.provider_ref, &session, ctx.allocator, ctx.io, compact_mod.DEFAULT_KEEP_RECENT_TOKENS) catch |err| {
        log.biz_error(ctx.thread_id, ctx.request_id, "compact_llm_failed", "err={s}", .{@errorName(err)});
        return err_mod.respondError(request, .internal_error, "summarization failed", a);
    };

    var buf: [64]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\"status\":\"ok\",\"data\":{{\"compacted\":{d}}}}}", .{@as(u32, @intFromBool(compacted))}) catch "{}";
    try respondJson(request, body);
}

/// POST /api/session/:id/undo — reverse the most recent recorded operation
/// (delete → re-insert message; truncate → re-append removed messages; branch →
/// delete the created fork). LIFO, in-memory (lost on server restart).
fn handleUndo(ctx: *Context, request: *std.http.Server.Request, session_id: []const u8, a: std.mem.Allocator) !void {
    if (!isValidSessionId(session_id)) return err_mod.respondError(request, .bad_request, "invalid session id", a);
    if (isSessionStreaming(ctx, session_id)) return err_mod.respondError(request, .agent_busy, "session is busy", a);

    const op = popUndo(ctx, session_id) orelse
        return err_mod.respondError(request, .bad_request, "nothing to undo", a);

    switch (op) {
        .delete => |d| {
            var session = loadSession(ctx, session_id) catch |err| {
                if (err == error.FileNotFound) return err_mod.respondError(request, .session_not_found, "session not found", a);
                return err_mod.respondError(request, .internal_error, "failed to load session", a);
            };
            defer session.deinit();
            try session.insertMessageAt(d.index, d.message);
            try session.flush();
        },
        .truncate => |t| {
            var session = loadSession(ctx, session_id) catch |err| {
                if (err == error.FileNotFound) return err_mod.respondError(request, .session_not_found, "session not found", a);
                return err_mod.respondError(request, .internal_error, "failed to load session", a);
            };
            defer session.deinit();
            for (t.removed) |m| try session.insertMessageAt(session.messages().len, m);
            try session.flush();
        },
        .branch => |b| {
            const filename = try std.fmt.allocPrint(a, "{s}.jsonl", .{b.fork_id});
            defer a.free(filename);
            const path = try std.fs.path.join(a, &.{ ctx.sessions_dir, filename });
            defer a.free(path);
            session_mod.Session.deleteFile(ctx.io, path) catch {};
        },
    }
    try respondJson(request, "{\"status\":\"ok\"}");
}

/// GET /api/session/:id/history — recent undoable operations (kind + detail).
fn handleHistory(ctx: *Context, request: *std.http.Server.Request, session_id: []const u8, a: std.mem.Allocator) !void {
    var buf: AlignedU8 = .empty;
    try buf.appendSlice(a, "[");
    const list = ctx.undo_map.get(session_id);
    var first = true;
    if (list) |l| {
        for (l.items) |op| {
            if (!first) try buf.appendSlice(a, ",");
            first = false;
            switch (op) {
                .delete => |d| {
                    const s = try std.fmt.allocPrint(a, "{{\"kind\":\"delete\",\"index\":{d},\"id\":{d}}}", .{ d.index, d.message.id });
                    defer a.free(s);
                    try buf.appendSlice(a, s);
                },
                .truncate => |t| {
                    const s = try std.fmt.allocPrint(a, "{{\"kind\":\"truncate\",\"removed\":{d}}}", .{t.removed.len});
                    defer a.free(s);
                    try buf.appendSlice(a, s);
                },
                .branch => |b| {
                    const s = try std.fmt.allocPrint(a, "{{\"kind\":\"branch\",\"fork_id\":\"{s}\"}}", .{b.fork_id});
                    defer a.free(s);
                    try buf.appendSlice(a, s);
                },
            }
        }
    }
    try buf.appendSlice(a, "]");
    try respondJson(request, buf.items);
}

/// Parse {"message_id":N} from a JSON request body. Returns a plain error set;
/// callers map to HTTP responses.
fn readMessageIdBody(request: *std.http.Server.Request, a: std.mem.Allocator) !u64 {
    var transfer_buf: [512]u8 = undefined;
    var body_reader = request.readerExpectNone(&transfer_buf);
    const body = body_reader.allocRemaining(a, @enumFromInt(2048)) catch return error.InvalidBody;
    const parsed = std.json.parseFromSlice(std.json.Value, a, body, .{ .ignore_unknown_fields = true }) catch
        return error.InvalidBody;
    const obj = parsed.value.object;
    const mid_val = obj.get("message_id") orelse return error.InvalidMessageId;
    if (mid_val != .integer) return error.InvalidMessageId;
    return @intCast(mid_val.integer);
}

/// True while a prompt stream is active for this session (populated by handlePrompt,
/// cleared on stream end). Session-mutating endpoints must reject busy sessions.
fn isSessionStreaming(ctx: *Context, session_id: []const u8) bool {
    return ctx.abort_map.contains(session_id);
}

/// Deep-copy a message into `al` (persistent allocator) for the undo stack.
fn dupMessage(al: std.mem.Allocator, src: types.Message) !types.Message {
    var d = src;
    d.content = try al.dupe(u8, src.content);
    if (src.reasoning_content) |rc| d.reasoning_content = try al.dupe(u8, rc);
    if (src.model) |m| d.model = try al.dupe(u8, m);
    if (src.tool_call_id) |tci| d.tool_call_id = try al.dupe(u8, tci);
    if (src.tool_calls) |tcs| {
        const dtcs = try al.alloc(types.ToolCall, tcs.len);
        for (tcs, dtcs) |s, *dst| {
            dst.* = .{
                .id = try al.dupe(u8, s.id),
                .name = try al.dupe(u8, s.name),
                .arguments = try al.dupe(u8, s.arguments),
            };
        }
        d.tool_calls = dtcs;
    }
    return d;
}

/// Record a session operation for undo (LIFO, cap 20 per session).
fn pushUndo(ctx: *Context, session_id: []const u8, op: UndoOp) !void {
    const al = ctx.undo_allocator;
    var list = ctx.undo_map.get(session_id);
    if (list == null) {
        const new_list = try al.create(std.ArrayListAligned(UndoOp, null));
        new_list.* = .empty;
        try ctx.undo_map.put(try al.dupe(u8, session_id), new_list);
        list = new_list;
    }
    try list.?.append(al, op);
    if (list.?.items.len > 20) _ = list.?.orderedRemove(0);
}

fn popUndo(ctx: *Context, session_id: []const u8) ?UndoOp {
    const list = ctx.undo_map.get(session_id) orelse return null;
    if (list.items.len == 0) return null;
    return list.pop();
}

fn applySessionModel(ctx: *Context, agent: *agent_mod.AgentLoop, spec: []const u8, a: std.mem.Allocator) !void {
    const resolved = try resolveSessionModel(ctx.config, spec);
    const api_key = try config_mod.resolveApiKey(ctx.env_snapshot, ctx.dotenv, resolved.entry.api_key_env);
    try agent.provider_ref.setModel(a, resolved.entry.*, resolved.model, api_key);
    agent.context_window = resolved.model.context_window;
}

fn handlePrompt(ctx: *Context, request: *std.http.Server.Request, session_id: []const u8) !void {
    const target = request.head.target;
    const prompt = extractPrompt(target, ctx.allocator) orelse return err_mod.respondError(request, .bad_request, "missing ?prompt= parameter", ctx.allocator);
    const url_model = extractModel(target, ctx.allocator);

    var is_new: bool = false;
    var session = loadSession(ctx, session_id) catch |err| blk: {
        var tbuf: [256]u8 = undefined;
        const tdata = std.fmt.bufPrint(&tbuf, "{{\"method\":\"prompt\",\"session\":\"{s}\"}}", .{session_id}) catch "";
        trace.write("request", ctx.thread_id, ctx.request_id, tdata);
        if (err == error.InvalidSessionId) return err_mod.respondError(request, .bad_request, "invalid session id", ctx.allocator);
        if (err != error.FileNotFound) return err_mod.respondError(request, .internal_error, "failed to load session", ctx.allocator);

        const spec = resolveModelSpec(ctx.config, url_model);
        if (url_model != null) {
            _ = resolveSessionModel(ctx.config, spec) catch {
                return respondModelUnavailable(request, ctx, spec, ctx.allocator);
            };
        }

        const created = try createSession(ctx, ctx.allocator, url_model, session_id);
        var s = created.session;
        defer s.deinit();
        try s.append(.{ .role = .user, .content = prompt });
        const title_len = @min(prompt.len, 30);
        s.name = try ctx.allocator.dupe(u8, prompt[0..title_len]);
        try s.flush();
        is_new = true;

        log.biz_info(ctx.thread_id, ctx.request_id, "session_new", "path={s}", .{s.path orelse "?"});

        const filename = try std.fmt.allocPrint(ctx.allocator, "{s}.jsonl", .{session_id});
        const path2 = try std.fs.path.join(ctx.allocator, &.{ ctx.sessions_dir, filename });
        break :blk try session_mod.Session.load(ctx.allocator, ctx.io, path2);
    };
    defer session.deinit();
    log.dbg(ctx.thread_id, ctx.request_id, "sse_load", "session={s} msgs={d}", .{ session_id, session.messages().len });
    timing.mark("sse_load", ctx.thread_id, ctx.request_id);

    if (!is_new) {
        if (session.messages().len == 0) is_new = true; // 空会话标记为新（session_ready 用）；不 rename（rename 会改文件名破坏 UUID 映射）
        try session.append(.{ .role = .user, .content = prompt });
    }
    log.dbg(ctx.thread_id, ctx.request_id, "sse_append", "msgs={d}", .{session.messages().len});

    const agent: *agent_mod.AgentLoop = @ptrCast(@alignCast(ctx.agent));
    agent.setSession(&session);

    if (session.model.len > 0) {
        applySessionModel(ctx, agent, session.model, ctx.allocator) catch {
            log.biz_error(ctx.thread_id, ctx.request_id, "model_apply_failed", "model={s}", .{session.model});
        };
    }
    log.dbg(ctx.thread_id, ctx.request_id, "sse_apply_model", "model={s}", .{session.model});

    const sw: *sse.SseWriter = @ptrCast(@alignCast(ctx.sse_writer orelse return err_mod.respondError(request, .internal_error, "SSE writer not available", ctx.allocator)));
    try sw.writeAll("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: keep-alive\r\nCache-Control: no-cache\r\n\r\n");
    try sw.flush();
    log.dbg(ctx.thread_id, ctx.request_id, "sse_header", "session={s}", .{session_id});

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
    log.dbg(ctx.thread_id, ctx.request_id, "sse_abort_reg", "session={s}", .{session_id});

    defer {
        ctx.abort_mutex.lock(ctx.io) catch unreachable;
        defer ctx.abort_mutex.unlock(ctx.io);
        _ = ctx.abort_map.remove(session_id);
        ctx.current_abort_session = null;
        log.dbg(ctx.thread_id, ctx.request_id, "sse_abort_remove", "session={s}", .{session_id});
    }

    {
        // Always announce the session and the freshly appended user message id
        // (binds the frontend's revert/branch/delete buttons to the stable id).
        const esc_name = try escapeJsonDynamic(ctx.allocator, session.name);
        defer ctx.allocator.free(esc_name);
        const msgs = session.messages();
        const user_msg_id = if (msgs.len > 0) msgs[msgs.len - 1].id else @as(u64, 0);
        var sid_buf: [320]u8 = undefined;
        const sid_payload = try std.fmt.bufPrint(&sid_buf, "{{\"id\":\"{s}\",\"name\":\"{s}\",\"message_id\":{d}}}", .{ session_id, esc_name, user_msg_id });
        try sse_state.writeFrame("session_ready", sid_payload);
        log.dbg(ctx.thread_id, ctx.request_id, "sse_session_ready", "message_id={d}", .{user_msg_id});
    }

    const compacted = agent.maybeAutoCompact();
    log.biz_info(ctx.thread_id, ctx.request_id, "sse_compact", "compacted={d}", .{@as(u32, @intFromBool(compacted))});

    log.biz_info(ctx.thread_id, ctx.request_id, "sse_run_turn_start", "session={s}", .{session_id});
    timing.mark("sse_run_turn", ctx.thread_id, ctx.request_id);
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
    timing.mark("sse_done", ctx.thread_id, ctx.request_id);
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
    const id_str = try std.fmt.allocPrint(allocator, "{{\"id\":{d},\"role\":\"", .{msg.id});
    defer allocator.free(id_str);
    try buf.appendSlice(allocator, id_str);
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
    return extractQueryValue(target, "prompt", a);
}

fn extractModel(target: []const u8, a: std.mem.Allocator) ?[]const u8 {
    return extractQueryValue(target, "model", a);
}

fn extractQueryValue(target: []const u8, comptime key: []const u8, a: std.mem.Allocator) ?[]const u8 {
    const qm = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    const query = target[qm + 1 ..];
    var it = std.mem.splitScalar(u8, query, '&');
    const prefix = key ++ "=";
    while (it.next()) |pair| {
        if (std.mem.startsWith(u8, pair, prefix)) {
            const value = pair[prefix.len..];
            if (value.len == 0) return null;
            return percentDecode(a, value) catch null;
        }
    }
    return null;
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

test "handler: resolveModelSpec falls back to default" {
    const cfg = config_mod.Config{
        .default_model = "deepseek/deepseek-v4-pro",
        .max_tokens = 1000,
        .max_tool_rounds = 8,
        .providers = &.{},
        ._arena = undefined,
    };
    try std.testing.expectEqualStrings("deepseek/deepseek-v4-pro", resolveModelSpec(&cfg, null));
    try std.testing.expectEqualStrings("deepseek/deepseek-v4-pro", resolveModelSpec(&cfg, ""));
    try std.testing.expectEqualStrings("deepseek/deepseek-v4-flash", resolveModelSpec(&cfg, "deepseek/deepseek-v4-flash"));
}

test "handler: resolveSessionModel finds entry and errors" {
    const provider = types.ProviderEntry{
        .name = "deepseek",
        .api = .openai_compat,
        .base_url = "https://api.deepseek.com",
        .api_key_env = "DEEPSEEK_API_KEY",
        .models = &.{
            .{ .id = "deepseek-v4-pro", .name = "V4 Pro", .provider = "deepseek", .context_window = 128000, .max_tokens = 4000, .input = &.{} },
        },
    };
    const cfg = config_mod.Config{
        .default_model = "deepseek/deepseek-v4-pro",
        .max_tokens = 1000,
        .max_tool_rounds = 8,
        .providers = &.{provider},
        ._arena = undefined,
    };

    const resolved = try resolveSessionModel(&cfg, "deepseek/deepseek-v4-pro");
    try std.testing.expectEqualStrings("deepseek", resolved.entry.name);
    try std.testing.expectEqualStrings("deepseek-v4-pro", resolved.model.id);

    try std.testing.expectError(error.InvalidModelSpec, resolveSessionModel(&cfg, "no-slash"));
    try std.testing.expectError(error.ProviderNotFound, resolveSessionModel(&cfg, "nobody/ghost"));
    try std.testing.expectError(error.ModelNotFound, resolveSessionModel(&cfg, "deepseek/nonexistent"));
}

test "handler: writeModelIds emits provider/model_id list" {
    const p1 = types.ProviderEntry{
        .name = "deepseek",
        .api = .openai_compat,
        .base_url = "https://api.deepseek.com",
        .api_key_env = "DEEPSEEK_API_KEY",
        .models = &.{
            .{ .id = "deepseek-v4-pro", .name = "V4 Pro", .provider = "deepseek", .context_window = 128000, .max_tokens = 4000, .input = &.{} },
            .{ .id = "deepseek-v4-flash", .name = "V4 Flash", .provider = "deepseek", .context_window = 64000, .max_tokens = 2000, .input = &.{} },
        },
    };
    const p2 = types.ProviderEntry{
        .name = "openai",
        .api = .openai_compat,
        .base_url = "https://api.openai.com",
        .api_key_env = "OPENAI_API_KEY",
        .models = &.{
            .{ .id = "gpt-4o", .name = "GPT-4o", .provider = "openai", .context_window = 128000, .max_tokens = 4096, .input = &.{} },
        },
    };
    const cfg = config_mod.Config{
        .default_model = "deepseek/deepseek-v4-pro",
        .max_tokens = 1000,
        .max_tool_rounds = 8,
        .providers = &.{ p1, p2 },
        ._arena = undefined,
    };

    var buf: AlignedU8 = .empty;
    var tmp = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer tmp.deinit();
    const a = tmp.allocator();
    try writeModelIds(a, &cfg, &buf);
    try std.testing.expectEqualStrings("\"deepseek/deepseek-v4-pro\",\"deepseek/deepseek-v4-flash\",\"openai/gpt-4o\"", buf.items);
}
