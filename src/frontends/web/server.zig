const std = @import("std");
const init_mod = @import("../init.zig");
const agent_mod = @import("../../core/agent.zig");
const signal = @import("../../util/signal.zig");
const handler = @import("handler.zig");
const sse = @import("sse.zig");

const Io = std.Io;

const default_port: u16 = 8090;

pub fn main(process: std.process.Init) !void {
    const allocator = process.arena.allocator();
    const io = process.io;

    var gpa_alloc = std.heap.ArenaAllocator.init(allocator);
    defer gpa_alloc.deinit();
    const gpa = gpa_alloc.allocator();

    var arg_iter = try std.process.Args.Iterator.initAllocator(process.minimal.args, process.gpa);
    defer arg_iter.deinit();
    _ = arg_iter.next();

    var root_override: ?[]const u8 = null;
    while (arg_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--root")) {
            if (arg_iter.next()) |val| {
                root_override = val;
            }
        }
    }
    if (root_override == null) {
        root_override = process.environ_map.get("ZAGENT_ROOT");
    }

    var state = init_mod.init(gpa, io, .{ .project_root = root_override }) catch |err| {
        var buf: [init_mod.init_error_max_len]u8 = undefined;
        const msg = init_mod.formatInitError(&buf, err, null, null) catch "z-agent-core: fatal init error";
        printStderr(io, msg);
        return;
    };
    defer state.deinit();

    var agent = agent_mod.AgentLoop.init(gpa, io, &state.provider, state.registry, &state.session, state.config.max_tool_rounds, state.project_root, 0, .{});

    printStderrFmt(io, "z-agent-core web server\n  -> http://localhost:{d}\n  -> Project root: {s}\n", .{ default_port, state.project_root });

    var ctx = handler.Context{
        .io = io,
        .allocator = gpa,
        .project_root = state.project_root,
        .config = &state.config,
        .agent = &agent,
        .provider = &state.provider,
    };

    const addr = try Io.net.IpAddress.resolve(io, "127.0.0.1", default_port);
    var tcp_server = try addr.listen(io, .{ .reuse_address = true });

    printStderrFmt(io, "z-agent-core web server\n  -> http://localhost:{d}\n  -> Project root: {s}\n", .{ default_port, state.project_root });

    while (true) {
        if (signal.isInterrupted()) break;
        const stream = tcp_server.accept(io) catch continue;
        defer stream.close(io);

        var recv_buf: [4096]u8 = undefined;
        var send_buf: [4096]u8 = undefined;
        var reader = stream.reader(io, &recv_buf);
        var writer = stream.writer(io, &send_buf);
        var server = std.http.Server.init(&reader.interface, &writer.interface);

        var request = server.receiveHead() catch continue;
        const method = request.head.method;
        const target = request.head.target;
        const path = if (target.len > 0 and target[0] == '/') target else "/";

        var sse_w = sse.sseWriterFrom(&writer.interface);
        ctx.sse_writer = &sse_w;

        handler.handleRequest(&ctx, method, path, &request) catch {
            _ = request.respond("500 Internal Server Error", .{}) catch {};
        };
    }
}

fn printStderr(io: Io, msg: []const u8) void {
    var buf: [256]u8 = undefined;
    var sw: Io.File.Writer = .init(.stderr(), io, &buf);
    sw.interface.writeAll(msg) catch {};
    sw.interface.flush() catch {};
}

fn printStderrFmt(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    printStderr(io, msg);
}
