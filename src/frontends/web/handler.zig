const std = @import("std");
const types = @import("../../types.zig");
const config_mod = @import("../../config.zig");
const session_mod = @import("../../core/session.zig");
const err_mod = @import("error.zig");

const AlignedU8 = std.ArrayListAligned(u8, null);

pub const Context = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    project_root: []const u8,
    config: *config_mod.Config,
    agent: *anyopaque,
    provider: *anyopaque,
    session_list: []const types.SessionInfo,
};

pub fn handleRequest(ctx: *Context, method: std.http.Method, path: []const u8, request: *std.http.Server.Request) !void {
    var req_arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer req_arena.deinit();
    const a = req_arena.allocator();

    if (method == .GET) {
        if (std.mem.eql(u8, path, "/")) return serveIndex(ctx, request);
        if (std.mem.eql(u8, path, "/api/health")) return respondJson(request, "{\"status\":\"ok\"}");
        if (std.mem.eql(u8, path, "/api/model")) return handleModelList(ctx, request, a);
        if (std.mem.eql(u8, path, "/api/provider")) return handleProviderList(ctx, request, a);
        if (std.mem.eql(u8, path, "/api/session")) return handleSessionList(ctx, request, a);
        if (std.mem.startsWith(u8, path, "/api/session/")) {
            const rest = path["/api/session/".len..];
            if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
                const id = rest[0..slash];
                const sub = rest[slash + 1 ..];
                if (std.mem.eql(u8, sub, "message")) return handleSessionMessages(ctx, request, id, a);
            } else {
                return handleSessionGet(ctx, request, rest, a);
            }
        }
    } else if (method == .POST) {
        if (std.mem.eql(u8, path, "/api/session")) return handleSessionCreate(ctx, request, a);
    }

    return err_mod.respondError(request, .not_found, "endpoint not found", a);
}

fn serveIndex(_: *Context, request: *std.http.Server.Request) !void {
    try request.respond(@embedFile("index.html"), .{
        .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
    });
}

fn respondJson(request: *std.http.Server.Request, body: []const u8) !void {
    try request.respond(body, .{
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
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
    var buf: AlignedU8 = .empty;
    try buf.appendSlice(a, "[");
    var first = true;
    for (ctx.session_list) |s| {
        if (!first) try buf.appendSlice(a, ",");
        first = false;
        var item: [256]u8 = undefined;
        const ss = try std.fmt.bufPrint(&item, "{{\"id\":\"{s}\",\"name\":\"{s}\",\"model\":\"{s}\",\"message_count\":{d}}}", .{ s.id, s.name, s.model, s.msg_count });
        try buf.appendSlice(a, ss);
    }
    try buf.appendSlice(a, "]");
    try respondJson(request, buf.items);
}

fn handleSessionGet(ctx: *Context, request: *std.http.Server.Request, id: []const u8, a: std.mem.Allocator) !void {
    var session = loadSession(ctx, id) catch |err| {
        if (err == error.SessionNotFound) return err_mod.respondError(request, .session_not_found, "session not found", a);
        return err;
    };
    defer session.deinit();

    var buf: AlignedU8 = .empty;
    var hdr: [512]u8 = undefined;
    const h = try std.fmt.bufPrint(&hdr, "{{\"name\":\"{s}\",\"model\":\"{s}\",\"messages\":[", .{ session.name, session.model });
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
        if (err == error.SessionNotFound) return err_mod.respondError(request, .session_not_found, "session not found", a);
        return err;
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
    var session = try session_mod.Session.init(ctx.allocator, ctx.io, ctx.config.default_model);
    defer session.deinit();
    try session.flush();
    try respondJson(request, "{\"status\":\"created\"}");
    _ = a;
}

fn loadSession(ctx: *Context, id: []const u8) !session_mod.Session {
    const sessions_dir = try std.fs.path.join(ctx.allocator, &.{ ctx.project_root, ".zagent", "sessions" });
    defer ctx.allocator.free(sessions_dir);
    const path = try std.fs.path.join(ctx.allocator, &.{ sessions_dir, id });
    defer ctx.allocator.free(path);
    return session_mod.Session.load(ctx.allocator, ctx.io, path);
}

fn formatMessageJson(allocator: std.mem.Allocator, buf: *AlignedU8, msg: types.Message) !void {
    var item: [1024]u8 = undefined;
    const role = @tagName(msg.role);
    const escaped = try escapeJson(msg.content, &item);
    var out: [2048]u8 = undefined;
    const s = try std.fmt.bufPrint(&out, "{{\"role\":\"{s}\",\"content\":\"{s}\"}}", .{ role, escaped });
    try buf.appendSlice(allocator, s);
}

fn escapeJson(src: []const u8, buf: []u8) ![]const u8 {
    var pos: usize = 0;
    for (src) |c| {
        if (pos + 2 >= buf.len) return error.BufferTooSmall;
        switch (c) {
            '"' => {
                buf[pos] = '\\'; pos += 1;
                buf[pos] = '"'; pos += 1;
            },
            '\\' => {
                buf[pos] = '\\'; pos += 1;
                buf[pos] = '\\'; pos += 1;
            },
            '\n' => {
                buf[pos] = '\\'; pos += 1;
                buf[pos] = 'n'; pos += 1;
            },
            '\r' => {
                buf[pos] = '\\'; pos += 1;
                buf[pos] = 'r'; pos += 1;
            },
            '\t' => {
                buf[pos] = '\\'; pos += 1;
                buf[pos] = 't'; pos += 1;
            },
            else => {
                buf[pos] = c; pos += 1;
            },
        }
    }
    return buf[0..pos];
}
