const std = @import("std");
const init_mod = @import("../init.zig");
const config_mod = @import("../../config.zig");
const agent_mod = @import("../../core/agent.zig");
const signal = @import("../../util/signal.zig");
const log = @import("../../util/log.zig");
const handler = @import("handler.zig");
const sse = @import("sse.zig");

const Io = std.Io;
const builtin = @import("builtin");

const default_port: u16 = 8090;

var abort_map: std.StringHashMap(*agent_mod.AgentLoop) = undefined;
var abort_mutex: std.Io.Mutex = .init;
var undo_map: std.StringHashMap(*std.ArrayListAligned(handler.UndoOp, null)) = undefined;
/// Long-lived allocator for undo ops (survives per-request arenas).
var persistent_alloc: std.mem.Allocator = undefined;
var active_threads: u32 = 0;
var next_thread_id: u32 = 0;
var next_request_id: u32 = 0;

var lan_url_buf: [128]u8 = undefined;

fn resolveLocalIp(io: Io, port: u16) ?[]const u8 {
    _ = io;
    if (builtin.os.tag == .windows) {
        const sockaddr_in = extern struct {
            sin_family: i16,
            sin_port: u16,
            sin_addr: [4]u8,
            sin_zero: [8]u8,
        };
        const WSADATA = extern struct {
            wVersion: u16,
            wHighVersion: u16,
            iMaxSockets: u16,
            iMaxUdpDg: u16,
            lpVendorInfo: ?[*:0]u8,
            szDescription: [257]u8,
            szSystemStatus: [129]u8,
        };
        const ws2 = struct {
            extern "ws2_32" fn WSAStartup(wVersionRequested: u16, lpWSAData: *WSADATA) callconv(.c) i32;
            extern "ws2_32" fn socket(af: i32, type_: i32, protocol: i32) callconv(.c) isize;
            extern "ws2_32" fn connect(s: isize, name: *const sockaddr_in, namelen: i32) callconv(.c) i32;
            extern "ws2_32" fn getsockname(s: isize, name: *sockaddr_in, namelen: *i32) callconv(.c) i32;
            extern "ws2_32" fn closesocket(s: isize) callconv(.c) i32;
            extern "ws2_32" fn htons(hostshort: u16) callconv(.c) u16;
        };
        const AF_INET: i32 = 2;
        const SOCK_DGRAM: i32 = 2;
        const INVALID_SOCKET: isize = ~@as(isize, 0);
        const SOCKET_ERROR: i32 = -1;

        var wsa_data: WSADATA = undefined;
        _ = ws2.WSAStartup(0x0202, &wsa_data);

        const sock = ws2.socket(AF_INET, SOCK_DGRAM, 0);
        if (sock == INVALID_SOCKET) return null;
        defer _ = ws2.closesocket(sock);

        var remote: sockaddr_in = .{
            .sin_family = AF_INET,
            .sin_port = ws2.htons(53),
            .sin_addr = .{ 8, 8, 8, 8 },
            .sin_zero = [_]u8{0} ** 8,
        };
        if (ws2.connect(sock, &remote, @sizeOf(sockaddr_in)) == SOCKET_ERROR) return null;

        var local: sockaddr_in = undefined;
        var local_len: i32 = @sizeOf(sockaddr_in);
        if (ws2.getsockname(sock, &local, &local_len) == SOCKET_ERROR) return null;

        return std.fmt.bufPrint(&lan_url_buf, "http://{d}.{d}.{d}.{d}:{d}", .{ local.sin_addr[0], local.sin_addr[1], local.sin_addr[2], local.sin_addr[3], port }) catch null;
    }
    return null;
}

fn threadStarted() void {
    _ = @atomicRmw(u32, &active_threads, .Add, 1, .seq_cst);
}

fn threadFinished() void {
    _ = @atomicRmw(u32, &active_threads, .Sub, 1, .seq_cst);
}

pub fn main(process: std.process.Init) !void {
    const allocator = process.arena.allocator();
    const io = process.io;

    var gpa_alloc = std.heap.ArenaAllocator.init(allocator);
    defer gpa_alloc.deinit();
    const gpa = gpa_alloc.allocator();

    abort_map = std.StringHashMap(*agent_mod.AgentLoop).init(gpa);
    undo_map = std.StringHashMap(*std.ArrayListAligned(handler.UndoOp, null)).init(gpa);
    persistent_alloc = gpa;

    var arg_iter = try std.process.Args.Iterator.initAllocator(process.minimal.args, process.gpa);
    defer arg_iter.deinit();
    _ = arg_iter.next();

    var root_override: ?[]const u8 = null;
    var bind_address: []const u8 = "127.0.0.1";
    var bind_port: u16 = default_port;
    while (arg_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--root")) {
            if (arg_iter.next()) |val| {
                root_override = val;
            }
        } else if (std.mem.eql(u8, arg, "--port")) {
            if (arg_iter.next()) |val| {
                bind_port = std.fmt.parseInt(u16, val, 10) catch default_port;
            }
        } else if (std.mem.eql(u8, arg, "--address")) {
            if (arg_iter.next()) |val| {
                bind_address = val;
            }
        }
    }
    if (root_override == null) {
        root_override = process.environ_map.get("ZAGENT_ROOT");
    }

    var state = init_mod.init(gpa, io, .{ .project_root = root_override }) catch |err| {
        init_mod.reportInitError(io, err, null, null);
        return;
    };

    const sessions_dir = try std.fs.path.join(gpa, &.{ state.project_root, ".zagent", "sessions" });

    const addr = try Io.net.IpAddress.resolve(io, bind_address, bind_port);
    var tcp_server = try addr.listen(io, .{ .reuse_address = true });

    log.init(io, .debug);
    log.info("event=server_start", "address=http://{s}:{d} root={s}", .{ bind_address, bind_port, state.project_root });

    if (std.mem.eql(u8, bind_address, "0.0.0.0")) {
        if (resolveLocalIp(io, bind_port)) |lan_url| {
            log.info("event=server_start", "lan={s}", .{lan_url});
        }
    }

    defer {
        const deadline_ms = Io.Timestamp.toMilliseconds(Io.Clock.Timestamp.now(io, .real).raw) + 30_000;
        while (@atomicLoad(u32, &active_threads, .seq_cst) > 0) {
            if (Io.Timestamp.toMilliseconds(Io.Clock.Timestamp.now(io, .real).raw) > deadline_ms) {
                log.errorLog("event=shutdown_timeout", "", .{});
                break;
            }
            const kernel32 = struct {
                extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.c) void;
            };
            kernel32.Sleep(100);
        }
        state.deinit();
    }

    while (true) {
        if (signal.isInterrupted()) break;
        const stream = tcp_server.accept(io) catch continue;

        const tid = @atomicRmw(u32, &next_thread_id, .Add, 1, .seq_cst);
        const rid = @atomicRmw(u32, &next_request_id, .Add, 1, .seq_cst);

        threadStarted();
        const thread = std.Thread.spawn(.{}, handleConnection, .{
            gpa, io, &state, sessions_dir, stream, tid, rid,
        }) catch {
            threadFinished();
            stream.close(io);
            continue;
        };
        thread.detach();
    }
}

fn handleConnection(
    parent_alloc: std.mem.Allocator,
    io: Io,
    state: *init_mod.FrontendState,
    sessions_dir: []const u8,
    stream: Io.net.Stream,
    tid: u32,
    rid: u32,
) void {
    defer threadFinished();
    defer stream.close(io);

    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var recv_buf: [4096]u8 = undefined;
    var send_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &recv_buf);
    var writer = stream.writer(io, &send_buf);
    var server = std.http.Server.init(&reader.interface, &writer.interface);

    const project_root = a.dupe(u8, state.project_root) catch return;
    const base_url = a.dupe(u8, state.provider.config.base_url) catch return;
    const model = a.dupe(u8, state.provider.config.model) catch return;
    const api_key = a.dupe(u8, state.provider.config.api_key) catch return;
    const model_params: ?[]const u8 = if (state.provider.config.model_params) |mp|
        a.dupe(u8, mp) catch return
    else
        null;

    var provider = state.provider;
    provider.config.base_url = base_url;
    provider.config.model = model;
    provider.config.api_key = api_key;
    provider.config.model_params = model_params;

    const model_info = config_mod.resolveModel(&state.config, state.config.default_model) catch return;
    var agent = agent_mod.AgentLoop.init(a, io, &provider, state.registry, &state.session, state.config.max_tool_rounds, project_root, model_info.context_window, .{ .skills_dir = state.config.skills_dir });

    var request = server.receiveHead() catch return;
    const method = request.head.method;
    const target = request.head.target;
    const path = if (target.len > 0 and target[0] == '/') target else "/";

    var sse_w = sse.sseWriterFrom(&writer.interface);

    var ctx = handler.Context{
        .io = io,
        .allocator = a,
        .project_root = project_root,
        .sessions_dir = sessions_dir,
        .config = &state.config,
        .agent = &agent,
        .provider = &provider,
        .default_session = &state.session,
        .env_snapshot = &state.env_snapshot,
        .dotenv = &state.dotenv,
        .sse_writer = &sse_w,
        .abort_map = &abort_map,
        .abort_mutex = &abort_mutex,
        .current_abort_session = null,
        .undo_allocator = persistent_alloc,
        .undo_map = &undo_map,
        .thread_id = tid,
        .request_id = rid,
    };

    defer {
        abort_mutex.lock(io) catch unreachable;
        defer abort_mutex.unlock(io);
        if (ctx.current_abort_session) |sid| {
            _ = abort_map.remove(sid);
            ctx.current_abort_session = null;
        }
    }

    handler.handleRequest(&ctx, method, path, &request) catch |err| {
        log.errorLog("event=request_error", "tid={d} rid={d} method={s} path={s} err={s}", .{ tid, rid, @tagName(method), path, @errorName(err) });
        _ = request.respond("{\"error\":{\"code\":\"internal_error\",\"message\":\"internal server error\"}}", .{
            .status = .internal_server_error,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        }) catch {};
    };
}
