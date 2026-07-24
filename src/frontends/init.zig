const std = @import("std");
const types = @import("../types.zig");
const config_mod = @import("../config.zig");
const session_mod = @import("../core/session.zig");
const agent_mod = @import("../core/agent.zig");
const provider_mod = @import("../io/provider.zig");
const registry_mod = @import("../tool/registry.zig");

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

    pub fn deinit(self: *FrontendState) void {
        self.config.deinit();
        self.session.deinit();
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
    },
) !FrontendState {
    var tmp = std.heap.ArenaAllocator.init(allocator);
    defer tmp.deinit();
    const ta = tmp.allocator();

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

    _ = config_mod.loadDotEnv(ta, project_root, io) catch {};

    const model = config_mod.resolveModel(&cfg, cfg.default_model) catch return error.ModelResolveFailed;

    const entry = for (cfg.providers) |p| {
        if (std.mem.eql(u8, p.name, model.provider)) break p;
    } else return error.ProviderNotFound;

    const provider = provider_mod.Provider.init(allocator, entry, model, null, io) catch |err| {
        if (err == error.ApiKeyNotSet) return error.ApiKeyNotSet;
        return err;
    };

    const registry = registry_mod.buildRegistry();

    var session = try session_mod.Session.init(allocator, io, cfg.default_model);
    errdefer session.deinit();

    const session_dir = try std.fs.path.join(allocator, &.{ project_root, ".zagent", "sessions" });

    return FrontendState{
        .allocator = allocator,
        .io = io,
        .project_root = project_root,
        .config = cfg,
        .provider = provider,
        .registry = registry,
        .session = session,
        .session_dir = session_dir,
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
