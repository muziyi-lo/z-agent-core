const std = @import("std");
const builtin = @import("builtin");
const types = @import("../../types.zig");
const config_mod = @import("../../config.zig");
const provider_mod = @import("../../io/provider.zig");
const registry_mod = @import("../../tool/registry.zig");
const skill_tool = @import("../../tool/skill.zig");
const session_mod = @import("../../core/session.zig");
const agent_mod = @import("../../core/agent.zig");
const render = @import("render.zig");
const signal = @import("../../util/signal.zig");
const session_ops = @import("../../session_ops.zig");

const Io = std.Io;

const BASE_PROMPT =
    "You are z-agent-core, an interactive CLI agent that helps users with software engineering tasks.";

const WriterCtx = struct {
    pw: *render.PhaseWriter,
    lb: *render.LineBuffer,
    writer: *Io.Writer,
};

fn pwBeginPhase(ctx: ?*anyopaque, mtype: provider_mod.PhaseType) void {
    const wc: *WriterCtx = @ptrCast(@alignCast(ctx.?));
    wc.lb.flush(wc.writer) catch {};
    switch (mtype) {
        .thinking => wc.lb.setRawMode(true),
        .content => wc.lb.setRawMode(false),
        .none => {},
    }
    const mt: render.MessageType = switch (mtype) {
        .thinking => .think,
        .content => .output,
        .none => return,
    };
    wc.pw.beginPhase(mt) catch {};
}

fn pwWriteRaw(ctx: ?*anyopaque, bytes: []const u8) void {
    const wc: *WriterCtx = @ptrCast(@alignCast(ctx.?));
    wc.lb.feed(bytes, wc.writer) catch {};
}

fn pwWriteRendered(ctx: ?*anyopaque, line: []const u8) void {
    const wc: *WriterCtx = @ptrCast(@alignCast(ctx.?));
    wc.writer.print("{s}", .{line}) catch {};
}

fn pwEndPhase(ctx: ?*anyopaque) void {
    const wc: *WriterCtx = @ptrCast(@alignCast(ctx.?));
    wc.lb.flush(wc.writer) catch {};
    wc.pw.endPhase() catch {};
}

/// CLI application orchestrator. init() loads config + tools + session,
/// initAgent() binds agent to session, run() enters single-turn or REPL.
pub const App = struct {
    allocator: std.mem.Allocator,
    io: Io,

    cfg: config_mod.Config,
    provider: provider_mod.Provider,
    registry: registry_mod.Registry,
    tools: []types.Tool,
    session: session_mod.Session,
    agent: agent_mod.AgentLoop,
    model_context: u32,

    project_root: []const u8,
    project_context: ?[]const u8,
    single_prompt: ?[]const u8,
    session_dir: []const u8,
    base_prompt: ?[]const u8,

    render_ctx: render.RenderContext,
    tool_display: render.ToolDisplay,
    line_buffer: render.LineBuffer,

    /// Initialize App: render.init, signal.init, findZagentRoot, load config/dotenv,
    /// create Provider/Tools/Session, inject system prompt. Agent created separately
    /// via initAgent() to avoid self-referential pointer issues.
    /// Returns error.NoProjectRoot or error.ProviderNotFound on fatal config issues.
    pub fn init(
        allocator: std.mem.Allocator,
        io: Io,
        single_prompt: ?[]const u8,
        model_override: ?[]const u8,
    ) !App {
        render.init();
        signal.init(io);

        const project_root = config_mod.findZagentRoot(allocator, io) orelse blk: {
            var pr_buf: [4096]u8 = undefined;
            const len = Io.Dir.cwd().realPath(io, &pr_buf) catch return error.NoProjectRoot;
            break :blk try allocator.dupe(u8, pr_buf[0..len]);
        };

        var project_context: ?[]const u8 = null;
        readAgents: {
            const ap = std.fs.path.join(allocator, &.{ project_root, "AGENTS.md" }) catch break :readAgents;
            defer allocator.free(ap);
            const f = Io.Dir.cwd().openFile(io, ap, .{ .mode = .read_only }) catch break :readAgents;
            defer f.close(io);
            const s = f.stat(io) catch break :readAgents;
            if (s.size <= 0 or s.size > 65536) break :readAgents;
            const sz = @as(usize, @intCast(s.size));
            const content = allocator.alloc(u8, sz) catch break :readAgents;
            const n = f.readPositionalAll(io, content, 0) catch {
                allocator.free(content);
                break :readAgents;
            };
            project_context = content[0..n];
        }

        var cfg = try config_mod.Config.load(allocator, project_root, io);
        if (model_override) |spec| {
            const duped = try allocator.dupe(u8, spec);
            cfg.default_model = duped;
        }

        _ = config_mod.loadDotEnv(allocator, project_root, io) catch {}; // .env is optional

        const model = try config_mod.resolveModel(&cfg, cfg.default_model);
        const entry = findProviderEntry(cfg.providers, cfg.default_model) orelse {
            var sbuf: [256]u8 = undefined;
            var sw: Io.File.Writer = .init(.stderr(), io, &sbuf);
            sw.interface.print("z-agent-core: Error: provider for '{s}' not found\n", .{cfg.default_model}) catch {}; // stderr gone
            sw.interface.flush() catch {};
            return error.ProviderNotFound;
        };

        const phase_writer_cb = provider_mod.PhaseWriterCb{
            .context = null,
            .begin_phase = pwBeginPhase,
            .write_raw = pwWriteRaw,
            .write_rendered = pwWriteRendered,
            .end_phase = pwEndPhase,
        };
        const provider = provider_mod.Provider.init(allocator, entry, model, null, io, phase_writer_cb) catch |err| {
            if (err == error.ApiKeyNotSet) {
                var sbuf: [256]u8 = undefined;
                var sw: Io.File.Writer = .init(.stderr(), io, &sbuf);
                sw.interface.print("z-agent-core: Error: {s} environment variable not set\n", .{entry.api_key_env}) catch {};
                sw.interface.flush() catch {};
            }
            return err;
        };
        const registry = registry_mod.buildRegistry();
        const tools = try registry.toTools(allocator);
        errdefer allocator.free(tools);

        var session = try session_mod.Session.init(allocator, io, cfg.default_model);
        errdefer session.deinit();

        const session_dir = try std.fs.path.join(allocator, &.{ project_root, ".zagent", "sessions" });

        return App{
            .allocator = allocator,
            .io = io,
            .cfg = cfg,
            .provider = provider,
            .registry = registry,
            .tools = tools,
            .session = session,
            .agent = undefined,
            .project_root = project_root,
            .project_context = project_context,
            .single_prompt = single_prompt,
            .session_dir = session_dir,
            .base_prompt = cfg.base_prompt,
            .render_ctx = render.RenderContext{ .colorize = render.isColorized() },
            .tool_display = render.ToolDisplay{ .ctx = undefined, .writer = undefined },
            .line_buffer = undefined,
            .model_context = model.context_window,
        };
    }

    /// Bind agent loop to session for tool-execution. Must call after init(), before run().
    pub fn initAgent(self: *App) void {
        self.line_buffer = render.LineBuffer.init(self.allocator, &self.render_ctx);
        self.tool_display.ctx = &self.render_ctx;
        self.agent = agent_mod.AgentLoop.init(
            self.allocator, self.io,
            &self.provider, self.registry, &self.session,
            self.cfg.max_tool_rounds, self.project_root, self.model_context,
            .{
                .system_prompt = .{ .context = self, .rebuild = spRebuild },
            },
        );
    }

    pub fn rollbackTurn(self: *App, pre_count: usize) void {
        self.session.truncateTo(pre_count);
        self.render_ctx.reset();
        self.line_buffer.reset();
    }

    /// Dispatch: singleTurn() if --prompt given, otherwise enter REPL loop.
    pub fn run(self: *App) !void {
        if (self.single_prompt) |prompt| {
            try self.singleTurn(prompt);
            return;
        }
        try self.replLoop();
    }

    fn singleTurn(self: *App, prompt: []const u8) !void {
        var obuf: [4096]u8 = undefined;
        var stdout: Io.File.Writer = .init(.stdout(), self.io, &obuf);

        var pw = render.PhaseWriter.init(&stdout.interface);
        var wc = WriterCtx{ .pw = &pw, .lb = &self.line_buffer, .writer = &stdout.interface };
        if (self.provider.phase_writer) |*cb| {
            cb.context = @ptrCast(@alignCast(&wc));
        }

        try render.writeLabeled(&stdout.interface, .user, prompt);
        try stdout.interface.flush();

        const pre_count = self.session.messages().len;
        try self.session.append(.{ .role = .user, .content = prompt });
        _ = stdout.interface.write("\n") catch {};

        const tool_cb = agent_mod.ToolDisplayCb{
            .context = &self.tool_display,
            .begin_tool = render.ToolDisplay.beginCb,
            .render = render.ToolDisplay.renderCb,
        };
        self.tool_display.writer = &stdout.interface;
        const result = self.agent.runTurn(tool_cb) catch |err| {
            if (err != error.OutOfMemory) {
                self.rollbackTurn(pre_count);
            }
            return err;
        };
        _ = stdout.interface.write("\n") catch {};
        if (signal.isInterrupted()) {
            self.agent.abort();
            signal.reset();
        }

        if (result.finish != .interrupted) {
            var last_usage: ?types.TokenUsage = null;
            for (self.session.messages()) |msg| {
                if (msg.usage) |u| last_usage = u;
            }
            if (last_usage) |u| {
                var t1: [16]u8 = undefined;
                var t2: [16]u8 = undefined;
                var t3: [16]u8 = undefined;
                var t4: [16]u8 = undefined;
                var cb: [32]u8 = undefined;
                const cache_str: []const u8 = if (u.cache_hit) |ch| blk: {
                    if (u.input > 0) {
                        break :blk try std.fmt.bufPrint(&cb, "命中 {d}%", .{(ch * 100) / u.input});
                    }
                    break :blk try std.fmt.bufPrint(&cb, "命中 ?", .{});
                } else "(缓存 N/A)";
                const ctx_pct = (u.total * 100) / @as(u32, @intCast(self.model_context));
                const label = try std.fmt.allocPrint(self.allocator, "输入 {s} ({s}) | 输出 {s} | 上下文 {s} / {s} ({d}%)", .{
                    try formatToken(u.input, &t1),
                    cache_str,
                    try formatToken(u.output, &t2),
                    try formatToken(u.total, &t3),
                    try formatToken(@as(u32, @intCast(self.model_context)), &t4),
                    ctx_pct,
                });
                defer self.allocator.free(label);
                try render.writeLabeled(&stdout.interface, .usage, label);
                _ = stdout.interface.write("\n") catch {};
            }
        }

        if (result.finish == .interrupted) {
            try render.writeLabeled(&stdout.interface, .warning, "interrupted");
        }
        if (result.finish == .max_rounds) {
            try render.writeLabeled(&stdout.interface, .warning, "max tool rounds reached");
        }
        if (result.finish == .api_error or result.finish == .interrupted) {
            if (result.error_msg) |e| {
                try render.writeLabeled(&stdout.interface, .err, e);
            }
            self.rollbackTurn(pre_count);
            try self.session.flush();
        } else {
            try self.session.flush();
        }
    }

    fn replLoop(self: *App) !void {
        var obuf: [4096]u8 = undefined;
        var stdout: Io.File.Writer = .init(.stdout(), self.io, &obuf);
        var pw = render.PhaseWriter.init(&stdout.interface);
        var wc = WriterCtx{ .pw = &pw, .lb = &self.line_buffer, .writer = &stdout.interface };

        var line_buf: std.ArrayListAligned(u8, null) = .empty;
        defer line_buf.deinit(self.allocator);

        if (builtin.os.tag == .windows) {
            const con_in = wincon.GetStdHandle(STD_INPUT_HANDLE) orelse return;
            while (true) {
                render.writePrompt(&stdout.interface) catch continue;
                _ = stdout.interface.flush() catch {};

                const line_opt = winReadLine(con_in, &line_buf, self.allocator) catch |err| switch (err) {
                    error.EndOfStream => break,
                    error.Interrupted => {
                        _ = stdout.interface.write("^C\n") catch {};
                        try render.writeLabeled(&stdout.interface, .warning, "interrupted");
                        signal.reset();
                        continue;
                    },
                    else => continue,
                };
                const line = line_opt orelse break;
                defer self.allocator.free(line);
                self.processLine(&stdout, line, &wc) catch |err| {
                    if (err == error.ExitRepl) break;
                    return err;
                };
            }
        } else {
            var rbuf: [4096]u8 = undefined;
            var stdin_file = Io.File.stdin();
            var stdin_reader = stdin_file.reader(self.io, rbuf[0..]);

            while (true) {
                render.writePrompt(&stdout.interface) catch continue;
                _ = stdout.interface.flush() catch {};

                const line_opt = readLine(&stdin_reader.interface, &line_buf, self.allocator) catch |err| switch (err) {
                    error.EndOfStream => break,
                    error.Interrupted => {
                        _ = stdout.interface.write("^C\n") catch {};
                        try render.writeLabeled(&stdout.interface, .warning, "interrupted");
                        signal.reset();
                        continue;
                    },
                    else => continue,
                };
                const line = line_opt orelse break;
                defer self.allocator.free(line);
                self.processLine(&stdout, line, &wc) catch |err| {
                    if (err == error.ExitRepl) break;
                    return err;
                };
            }
        }
    }

    fn processLine(self: *App, stdout: *Io.File.Writer, line: []const u8, wc: *WriterCtx) !void {
        if (line.len == 0) return;
        if (std.mem.eql(u8, line, "/exit") or std.mem.eql(u8, line, "/quit")) return error.ExitRepl;
        if (std.mem.eql(u8, line, "/new")) {
            try self.resetSession();
            return;
        }
        if (std.mem.startsWith(u8, line, "/name ")) {
            try self.renameSession(line["/name ".len..]);
            return;
        }
        if (std.mem.eql(u8, line, "/list")) {
            try self.listSessions(stdout);
            return;
        }
        if (std.mem.eql(u8, line, "/help")) {
            try self.showHelp(stdout);
            return;
        }
        if (std.mem.startsWith(u8, line, "/load ")) {
            try self.loadSession(stdout, line["/load ".len..]);
            return;
        }
        if (std.mem.startsWith(u8, line, "/fork ")) {
            try self.forkSession(stdout, line["/fork ".len..]);
            return;
        }

        const pre_count = self.session.messages().len;
        try self.session.append(.{ .role = .user, .content = line });
        _ = stdout.interface.write("\n") catch {};

        if (self.provider.phase_writer) |*cb| {
            cb.context = @ptrCast(@alignCast(wc));
        }
        const tool_cb = agent_mod.ToolDisplayCb{
            .context = &self.tool_display,
            .begin_tool = render.ToolDisplay.beginCb,
            .render = render.ToolDisplay.renderCb,
        };
        self.tool_display.writer = &stdout.interface;
        const result = self.agent.runTurn(tool_cb) catch |err| {
            if (err != error.OutOfMemory) {
                self.rollbackTurn(pre_count);
            }
            return err;
        };

        _ = stdout.interface.write("\n") catch {};
        if (signal.isInterrupted()) {
            self.agent.abort();
            signal.reset();
        }

        if (result.finish != .interrupted) {
            var last_usage: ?types.TokenUsage = null;
            for (self.session.messages()) |msg| {
                if (msg.usage) |u| last_usage = u;
            }
            if (last_usage) |u| {
                var t1: [16]u8 = undefined;
                var t2: [16]u8 = undefined;
                var t3: [16]u8 = undefined;
                var t4: [16]u8 = undefined;
                var cb: [32]u8 = undefined;
                const cache_str: []const u8 = if (u.cache_hit) |ch| blk: {
                    if (u.input > 0) {
                        break :blk try std.fmt.bufPrint(&cb, "命中 {d}%", .{(ch * 100) / u.input});
                    }
                    break :blk try std.fmt.bufPrint(&cb, "命中 ?", .{});
                } else "(缓存 N/A)";
                const ctx_pct = (u.total * 100) / @as(u32, @intCast(self.model_context));
                const label = try std.fmt.allocPrint(self.allocator, "输入 {s} ({s}) | 输出 {s} | 上下文 {s} / {s} ({d}%)", .{
                    try formatToken(u.input, &t1),
                    cache_str,
                    try formatToken(u.output, &t2),
                    try formatToken(u.total, &t3),
                    try formatToken(@as(u32, @intCast(self.model_context)), &t4),
                    ctx_pct,
                });
                defer self.allocator.free(label);
                try render.writeLabeled(&stdout.interface, .usage, label);
                _ = stdout.interface.write("\n") catch {};
            }
        }

        switch (result.finish) {
            .api_error => {
                const msg = if (result.error_msg) |e| e else "API error";
                try render.writeLabeled(&stdout.interface, .err, msg);
                self.rollbackTurn(pre_count);
                try self.session.flush();
            },
            .interrupted => {
                try render.writeLabeled(&stdout.interface, .warning, "interrupted");
                self.rollbackTurn(pre_count);
                try self.session.flush();
            },
            .max_rounds => {
                try render.writeLabeled(&stdout.interface, .warning, "max tool rounds reached");
                try self.session.flush();
            },
            else => try self.session.flush(),
        }
    }

    fn winReadLine(
        con_in: ?*anyopaque,
        buf: *std.ArrayListAligned(u8, null),
        allocator: std.mem.Allocator,
    ) !?[]const u8 {
        _ = buf;
        var utf16_buf: [4096]u16 = undefined;
        var chars_read: u32 = 0;
        if (wincon.ReadConsoleW(con_in, &utf16_buf, @intCast(utf16_buf.len), &chars_read, null) == 0) {
            if (signal.isInterrupted()) return error.Interrupted;
            return error.EndOfStream;
        }
        if (chars_read == 0) return null;
        const trimmed = std.mem.trimEnd(u16, utf16_buf[0..chars_read], &[_]u16{ '\r', '\n' });
        return @as(?[]const u8, try std.unicode.utf16LeToUtf8Alloc(allocator, trimmed));
    }

    const STD_INPUT_HANDLE: u32 = @bitCast(@as(i32, -10));

    const wincon = if (builtin.os.tag == .windows)
        struct {
            extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(.winapi) ?*anyopaque;
            extern "kernel32" fn ReadConsoleW(
                hConsoleInput: ?*anyopaque,
                lpBuffer: [*]u16,
                nNumberOfCharsToRead: u32,
                lpNumberOfCharsRead: *u32,
                pInputControl: ?*anyopaque,
            ) callconv(.winapi) i32;
        }
    else
        struct {};

    fn sanitizeForkName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
        return session_ops.sanitizeForkName(allocator, name);
    }

    fn resetSession(self: *App) !void {
        self.session.deinit();
        self.session = try session_ops.new(self.allocator, self.io, self.cfg.default_model);
        self.initAgent();
    }

    fn renameSession(self: *App, new_name: []const u8) !void {
        const trimmed = std.mem.trim(u8, new_name, " \t");
        if (trimmed.len == 0) {
            var ebuf: [256]u8 = undefined;
            var ew: Io.File.Writer = .init(.stderr(), self.io, &ebuf);
            try ew.interface.print("Usage: /name <new-name>\n", .{});
            return;
        }
        try self.session.rename(trimmed);
        try self.session.flush();
        var ebuf: [256]u8 = undefined;
        var ew: Io.File.Writer = .init(.stderr(), self.io, &ebuf);
        try ew.interface.print("Session renamed to: {s}\n", .{trimmed});
    }

    fn listSessions(self: *App, stdout: *Io.File.Writer) !void {
        const sessions = try session_mod.list(self.allocator, self.io, self.session_dir);
        defer session_mod.freeSessionInfoList(self.allocator, sessions);

        if (sessions.len == 0) {
            try stdout.interface.print("No saved sessions.\n", .{});
            return;
        }

        try stdout.interface.print("Saved sessions ({d}):\n", .{sessions.len});
        for (sessions) |s| {
            try stdout.interface.print("  {s}  {s}  ~{d} msgs\n", .{ s.name, s.model, s.msg_count });
        }
    }

    fn showHelp(self: *App, stdout: *Io.File.Writer) !void {
        _ = self;
        try stdout.interface.print(
            \\z-agent-core commands:
            \\  /exit, /quit    Exit the REPL
            \\  /new            Start a new session
            \\  /load <name>    Load a saved session
            \\  /name <name>    Rename current session
            \\  /list           List saved sessions
            \\  /fork <name>    Fork current session to new file
            \\  /help           Show this help
            \\
        , .{});
    }

    fn loadSession(self: *App, stdout: *Io.File.Writer, name: []const u8) !void {
        const trimmed = std.mem.trim(u8, name, " \t");
        if (trimmed.len == 0) {
            try render.writeLabeled(&stdout.interface, .err, "Usage: /load <session-name>");
            return;
        }
        const new_session = session_ops.loadById(self.allocator, self.io, self.session_dir, trimmed) catch |err| {
            var ebuf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&ebuf, "Cannot load '{s}': {s}", .{ trimmed, @errorName(err) }) catch "Cannot load session";
            try render.writeLabeled(&stdout.interface, .err, msg);
            return;
        };
        self.session.deinit();
        self.session = new_session;
        self.initAgent();
        self.render_ctx.reset();
        try render.writeLabeled(&stdout.interface, .success, "Loaded session");
    }

    fn forkSession(self: *App, stdout: *Io.File.Writer, fork_name_raw: []const u8) !void {
        const fork_name = std.mem.trim(u8, fork_name_raw, " \t");
        if (fork_name.len == 0) {
            try render.writeLabeled(&stdout.interface, .err, "Usage: /fork <name>");
            return;
        }
        if (std.mem.indexOfAny(u8, fork_name, "/\\") != null) {
            try render.writeLabeled(&stdout.interface, .err, "Fork name must not contain path separators");
            return;
        }

        const new_session = session_ops.fork(self.allocator, self.io, &self.session, self.session_dir, fork_name_raw) catch |err| {
            const msg = switch (err) {
                error.InvalidForkName => "Fork name must not be empty",
                error.PathSeparatorInName => "Fork name must not contain path separators",
                error.SessionAlreadyExists => "Session already exists",
                else => blk: {
                    var ebuf: [128]u8 = undefined;
                    break :blk std.fmt.bufPrint(&ebuf, "Cannot fork: {s}", .{@errorName(err)}) catch "Cannot fork";
                },
            };
            try render.writeLabeled(&stdout.interface, .err, msg);
            return;
        };
        self.session.deinit();
        self.session = new_session;
        self.initAgent();
        self.render_ctx.reset();

        const msg = try std.fmt.allocPrint(self.allocator, "Forked to '{s}' (switched)", .{fork_name_raw});
        defer self.allocator.free(msg);
        try render.writeLabeled(&stdout.interface, .success, msg);
    }

    /// Free session, config, and all heap-allocated fields. Safe to call on zero-value App.
    pub fn deinit(self: *App) void {
        if (self.project_context) |ctx| self.allocator.free(@constCast(ctx));
        self.allocator.free(self.tools);
        self.allocator.free(self.session_dir);
        self.session.deinit();
        self.cfg.deinit();
    }
};

fn findProviderEntry(providers: []const types.ProviderEntry, spec: []const u8) ?types.ProviderEntry {
    const slash = std.mem.indexOfScalar(u8, spec, '/') orelse return null;
    const provider_name = spec[0..slash];
    for (providers) |p| {
        if (std.mem.eql(u8, p.name, provider_name)) return p;
    }
    return null;
}

fn spRebuild(ctx: ?*anyopaque) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    const prompt = try buildPromptString(self.allocator, self.io, self.project_root, self.project_context, self.base_prompt);
    defer self.allocator.free(prompt);
    try self.session.updateFirstSystem(prompt);
}

fn buildPromptString(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    project_context: ?[]const u8,
    base_prompt: ?[]const u8,
) ![]const u8 {
    const cwd_alloc = std.process.currentPathAlloc(io, allocator) catch null;
    defer if (cwd_alloc) |p| allocator.free(p);
    const cwd: []const u8 = if (cwd_alloc) |p| p else ".";

    const os_tag = @tagName(builtin.os.tag);

    const clock_ts = Io.Clock.Timestamp.now(io, .real);
    const now_secs = Io.Timestamp.toSeconds(clock_ts.raw);
    const date = try formatDate(allocator, now_secs);
    defer allocator.free(date);

    const effective_prompt = base_prompt orelse BASE_PROMPT;

    const prompt = try std.fmt.allocPrint(allocator,
        \\{s}
        \\
        \\<env>
        \\  Working directory: {s}
        \\  Workspace root: {s}
        \\  Platform: {s}
        \\  Today's date: {s}
        \\</env>
        \\
    , .{ effective_prompt, cwd, project_root, os_tag, date });
    defer allocator.free(prompt);

    const skills = skill_tool.listAvailableSkills(allocator, io, project_root) catch &.{};
    var result: []const u8 = prompt;
    if (skills.len > 0) {
        var skills_buf = std.ArrayListAligned(u8, null).empty;
        errdefer skills_buf.deinit(allocator);
        try skills_buf.appendSlice(allocator, prompt);
        try skills_buf.appendSlice(allocator, "\n<available_skills>\n");
        for (skills) |s| {
            const line = try std.fmt.allocPrint(allocator, "  {s}: {s}\n", .{ s.name, s.description });
            defer allocator.free(line);
            try skills_buf.appendSlice(allocator, line);
        }
        try skills_buf.appendSlice(allocator, "</available_skills>\n");
        result = try skills_buf.toOwnedSlice(allocator);
    }
    defer {
        for (skills) |s| {
            allocator.free(s.name);
            allocator.free(s.description);
        }
        allocator.free(skills);
    }

    if (project_context) |ctx| {
        return try std.fmt.allocPrint(allocator, "{s}\n<project_context>\n{s}\n</project_context>\n", .{ result, ctx });
    }
    return if (std.mem.eql(u8, result, prompt)) try allocator.dupe(u8, result) else result;
}

fn formatDate(allocator: std.mem.Allocator, epoch_s: i64) ![]const u8 {
    const z = @divFloor(epoch_s, 86400) + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = @as(u64, @intCast(z - era * 146097));
    const yoe = @as(u64, @intCast((doe - doe / 1460 + doe / 36524 - doe / 146096) / 365));
    const y = @as(i64, @intCast(yoe)) + @as(i64, @intCast(era * 400));
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp = (5 * doy + 2) / 153;
    const d = doy - (153 * mp + 2) / 5 + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const year = if (m <= 2) y + 1 else y;
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, m, d });
}

fn formatToken(n: u32, buf: []u8) ![]const u8 {
    if (n < 1000) return try std.fmt.bufPrint(buf, "{d}t", .{n});
    if (n < 1_000_000) {
        const k = @as(f32, @floatFromInt(n)) / 1000;
        return try std.fmt.bufPrint(buf, "{d:.1}K", .{k});
    }
    const m = @as(f32, @floatFromInt(n)) / 1_000_000;
    return try std.fmt.bufPrint(buf, "{d:.1}M", .{m});
}

fn readLine(
    reader: *Io.Reader,
    buf: *std.ArrayListAligned(u8, null),
    allocator: std.mem.Allocator,
) !?[]const u8 {
    buf.clearRetainingCapacity();
    while (true) {
        const byte = reader.takeByte() catch |err| {
            switch (err) {
                error.EndOfStream => {
                    if (buf.items.len > 0) return @as(?[]const u8, try buf.toOwnedSlice(allocator));
                    return null;
                },
                else => {
                    if (signal.isInterrupted()) return error.Interrupted;
                    return err;
                },
            }
        };
        if (byte == '\n') return @as(?[]const u8, try buf.toOwnedSlice(allocator));
        if (byte == 0x08 or byte == 0x7F) {
            if (buf.items.len > 0) _ = buf.pop();
            continue;
        }
        if (buf.items.len >= 4096) return error.LineTooLong;
        try buf.append(allocator, byte);
    }
}
