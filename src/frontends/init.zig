const std = @import("std");
const types = @import("../types.zig");
const config_mod = @import("../config.zig");
const session_mod = @import("../core/session.zig");
const agent_mod = @import("../core/agent.zig");
const provider_mod = @import("../io/provider.zig");
const registry_mod = @import("../tool/registry.zig");
const log = @import("../util/log.zig");

const Io = std.Io;

pub const init_error_max_len = 256;

pub const InitError = error{
    NoProjectRoot,
    ConfigLoadFailed,
    ModelResolveFailed,
    ProviderNotFound,
    ApiKeyNotSet,
};

pub const FrontendState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    config: config_mod.Config,
    provider: provider_mod.Provider,
    registry: registry_mod.Registry,
    session: session_mod.Session,
    session_dir: []const u8,
    /// 进程级 env 快照：启动时 createMap 一次，请求期只读（Web 前端模型切换复用）。
    env_snapshot: std.process.Environ.Map,
    /// 进程级 .env 快照：启动时 loadDotEnv 一次，请求期只读。
    dotenv: std.StringArrayHashMapUnmanaged([]const u8),

    pub fn deinit(self: *FrontendState) void {
        self.config.deinit();
        self.session.deinit();
        self.env_snapshot.deinit();
        var it = self.dotenv.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.dotenv.deinit(self.allocator);
        self.allocator.free(self.session_dir);
        self.allocator.free(self.project_root);
    }
};

pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: struct {
        project_root: ?[]const u8 = null,
        api_key_override: ?[]const u8 = null,
        /// --model override (N23): applied BEFORE the startup resolveModel check
        /// so the validation uses the effective value — a broken config
        /// default_model must not be killed by the pre-override resolve.
        model_override: ?[]const u8 = null,
    },
) !FrontendState {
    const project_root = if (opts.project_root) |r|
        try allocator.dupe(u8, r)
    else if (config_mod.findZagentRoot(allocator, io)) |r|
        r
    else blk: {
        var buf: [4096]u8 = undefined;
        const len = Io.Dir.cwd().realPath(io, &buf) catch return error.NoProjectRoot;
        break :blk try allocator.dupe(u8, buf[0..len]);
    };

    var cfg = config_mod.Config.load(allocator, project_root, io) catch return error.ConfigLoadFailed;
    errdefer cfg.deinit();

    // N23: --model override applied here (pre-resolve) so the startup check
    // below validates the effective value, not the static config value.
    if (opts.model_override) |spec| {
        cfg.default_model = try allocator.dupe(u8, spec);
    }

    var dotenv = config_mod.loadDotEnv(allocator, project_root, io) catch |err| blk: {
        var dbuf: [256]u8 = undefined;
        var dw: std.Io.File.Writer = .init(.stderr(), io, &dbuf);
        dw.interface.print("z-agent-core: warning: failed to load .env ({s})\n", .{@errorName(err)}) catch {};
        dw.interface.flush() catch {};
        break :blk std.StringArrayHashMapUnmanaged([]const u8){};
    };
    errdefer dotenv.deinit(allocator);

    const env = std.process.Environ{ .block = .{ .use_global = true } };
    var env_snapshot = try env.createMap(allocator);
    errdefer env_snapshot.deinit();

    // N23: startup fail-fast with available-model suggestions. Also the single
    // place where a broken default_model (or an unresolvable --model override)
    // surfaces — web gets its own check at listen time (server.zig).
    const model = config_mod.resolveModel(&cfg, cfg.default_model) catch |err| {
        var ebuf: [512]u8 = undefined;
        var ew: std.Io.File.Writer = .init(.stderr(), io, &ebuf);
        ew.interface.print("error: default_model \"{s}\" cannot be resolved ({s})\n", .{ cfg.default_model, @errorName(err) }) catch {};
        ew.interface.flush() catch {};
        const models_text = config_mod.formatAvailableModels(allocator, &cfg) catch "?";
        defer allocator.free(models_text);
        ew.interface.print("       available models: {s}\n", .{models_text}) catch {};
        ew.interface.flush() catch {};
        return error.ModelResolveFailed;
    };

    const entry = for (cfg.providers) |p| {
        if (std.mem.eql(u8, p.name, model.provider)) break p;
    } else return error.ProviderNotFound;

    const provider = blk: {
        const api_key = try config_mod.resolveApiKey(&env_snapshot, &dotenv, entry.api_key_env);
        break :blk try provider_mod.Provider.init(allocator, entry, model, api_key, null, io);
    };

    const registry = registry_mod.buildRegistry();

    var session = try session_mod.Session.init(allocator, io, cfg.default_model);
    errdefer session.deinit();

    const session_dir = try std.fs.path.join(allocator, &.{ project_root, session_mod.sessions_subdir });

    // Crash recovery (F5/D4): delete leftover `*.jsonl.tmp` orphans from an
    // interrupted session.flush (tmp+rename atomic write). Best-effort; a missing
    // directory (first run) is fine. Cleanup runs for both CLI and Web (shared init).
    var removed_tmp: usize = 0;
    {
        var dir = Io.Dir.cwd().openDir(io, session_dir, .{ .iterate = true }) catch null;
        if (dir) |*d| {
            defer d.close(io);
            var it = d.iterate();
            while (it.next(io) catch null) |e| {
                if (e.kind != .file) continue;
                if (!std.mem.endsWith(u8, e.name, ".jsonl.tmp")) continue;
                const tmp_path = std.fs.path.join(allocator, &.{ session_dir, e.name }) catch continue;
                defer allocator.free(tmp_path);
                if (Io.Dir.cwd().deleteFile(io, tmp_path) catch null) |_| {
                    removed_tmp += 1;
                }
            }
        }
    }
    if (removed_tmp > 0) {
        log.dbg(0, 0, "session_tmp_cleanup", "removed={d}", .{removed_tmp});
    }

    return FrontendState{
        .allocator = allocator,
        .io = io,
        .project_root = project_root,
        .config = cfg,
        .provider = provider,
        .registry = registry,
        .session = session,
        .session_dir = session_dir,
        .env_snapshot = env_snapshot,
        .dotenv = dotenv,
    };
}

pub fn loadSessionList(state: *const FrontendState) ![]types.SessionInfo {
    return session_mod.list(state.allocator, state.io, state.session_dir);
}

pub fn formatInitError(
    buf: []u8,
    err: anyerror,
    api_key_env: ?[]const u8,
    model_spec: ?[]const u8,
) ![]const u8 {
    const name = @errorName(err);
    if (std.mem.eql(u8, name, "NoProjectRoot")) return std.fmt.bufPrint(buf, "z-agent-core: error: cannot resolve project root", .{});
    if (std.mem.eql(u8, name, "ConfigLoadFailed")) return std.fmt.bufPrint(buf, "z-agent-core: error: cannot load config", .{});
    if (std.mem.eql(u8, name, "ModelResolveFailed")) {
        if (model_spec) |s| return std.fmt.bufPrint(buf, "z-agent-core: error: cannot resolve model '{s}'", .{s});
        return std.fmt.bufPrint(buf, "z-agent-core: error: cannot resolve default model", .{});
    }
    if (std.mem.eql(u8, name, "ProviderNotFound")) {
        if (model_spec) |s| return std.fmt.bufPrint(buf, "z-agent-core: error: provider for '{s}' not found", .{s});
        return std.fmt.bufPrint(buf, "z-agent-core: error: provider not found", .{});
    }
    if (std.mem.eql(u8, name, "ApiKeyNotSet")) {
        if (api_key_env) |env| return std.fmt.bufPrint(buf, "z-agent-core: Error: {s} environment variable not set", .{env});
        return std.fmt.bufPrint(buf, "z-agent-core: Error: API key not set", .{});
    }
    return std.fmt.bufPrint(buf, "z-agent-core: fatal init error: {s}", .{name});
}

pub fn reportInitError(io: Io, err: anyerror, api_key_env: ?[]const u8, model_spec: ?[]const u8) void {
    var buf: [init_error_max_len]u8 = undefined;
    const msg = formatInitError(&buf, err, api_key_env, model_spec) catch "z-agent-core: fatal init error";
    var sw_buf: [256]u8 = undefined;
    var sw: Io.File.Writer = .init(.stderr(), io, &sw_buf);
    sw.interface.writeAll(msg) catch {};
    sw.interface.writeAll("\n") catch {};
    sw.interface.flush() catch {};
}
