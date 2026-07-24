const std = @import("std");
const config_mod = @import("../../config.zig");
const session_mod = @import("../../core/session.zig");
const agent_mod = @import("../../core/agent.zig");
const provider_mod = @import("../../io/provider.zig");
const registry_mod = @import("../../tool/registry.zig");
const types = @import("../../types.zig");
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

    var root_arg: ?[]const u8 = null;
    while (arg_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--root")) {
            if (arg_iter.next()) |val| {
                root_arg = val;
            }
        }
    }

    const project_root = if (root_arg) |r| try findRootExplicit(gpa, r, io)
        else if (process.environ_map.get("ZAGENT_ROOT")) |r| try findRootExplicit(gpa, r, io)
    else config_mod.findZagentRoot(allocator, io) orelse blk: {
        var buf: [4096]u8 = undefined;
        const len = Io.Dir.cwd().realPath(io, &buf) catch {
            printStderr(io, "z-agent-core: error: cannot resolve working directory\n");
            return error.NoProjectRoot;
        };
        break :blk try allocator.dupe(u8, buf[0..len]);
    };

    var cfg = config_mod.Config.load(gpa, project_root, io) catch {
        printStderr(io, "z-agent-core: error: cannot load config\n");
        return;
    };
    defer cfg.deinit();

    _ = config_mod.loadDotEnv(allocator, project_root, io) catch {};

    const model = config_mod.resolveModel(&cfg, cfg.default_model) catch {
        printStderr(io, "z-agent-core: error: cannot resolve default model\n");
        return;
    };

    const entry = for (cfg.providers) |p| {
        if (std.mem.eql(u8, p.name, model.provider)) break p;
    } else {
        printStderr(io, "z-agent-core: error: provider not found\n");
        return;
    };

    var provider = provider_mod.Provider.init(gpa, entry, model, null, io) catch |err| {
        if (err == error.ApiKeyNotSet) {
            printStderrFmt(io, "z-agent-core: Error: {s} environment variable not set\n", .{entry.api_key_env});
        } else {
            printStderr(io, "z-agent-core: error: cannot create provider\n");
        }
        return;
    };

    const registry = registry_mod.buildRegistry();

    const sessions_dir = try std.fs.path.join(allocator, &.{ project_root, ".zagent", "sessions" });
    const session_list = session_mod.list(allocator, io, sessions_dir) catch blk: {
        break :blk &[_]types.SessionInfo{};
    };

    var session = try session_mod.Session.init(gpa, io, cfg.default_model);
    defer session.deinit();

    var agent = agent_mod.AgentLoop.init(gpa, io, &provider, registry, &session, cfg.max_tool_rounds, project_root, model.context_window, .{});

    var ctx = handler.Context{
        .io = io,
        .allocator = gpa,
        .project_root = project_root,
        .config = &cfg,
        .agent = &agent,
        .provider = &provider,
        .session_list = session_list,
    };

    const addr = try Io.net.IpAddress.resolve(io, "127.0.0.1", default_port);
    var tcp_server = try addr.listen(io, .{ .reuse_address = true });

    printStderrFmt(io, "z-agent-core web server\n  -> http://localhost:{d}\n  -> Project root: {s}\n  -> Sessions: {d} found\n", .{ default_port, project_root, session_list.len });

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

        handler.handleRequest(&ctx, method, path, &request) catch {
            _ = request.respond("500 Internal Server Error", .{}) catch {};
        };
    }
}

fn findRootExplicit(allocator: std.mem.Allocator, path: []const u8, io: Io) ![]const u8 {
    _ = io;
    return allocator.dupe(u8, path);
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
