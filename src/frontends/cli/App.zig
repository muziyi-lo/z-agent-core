const std = @import("std");
const builtin = @import("builtin");
const types = @import("../../types.zig");
const config_mod = @import("../../config.zig");
const provider_mod = @import("../../io/provider.zig");
const registry_mod = @import("../../tool/registry.zig");
const skill_tool = @import("../../tool/skill.zig");
const session_mod = @import("../../core/session.zig");
const agent_mod = @import("../../core/agent.zig");
const approval_mod = @import("../../approval.zig");
const render = @import("render.zig");
const signal = @import("../../util/signal.zig");
const session_ops = @import("../../session_ops.zig");
const command_mod = @import("../../command.zig");
const log = @import("../../util/log.zig");
const trace = @import("../../util/trace.zig");
const timing = @import("../../util/timing.zig");
const title_mod = @import("../../core/title.zig");
const subcall_mod = @import("../../core/subcall.zig");

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
    pipe_mode: bool = false,
    _env_changed: bool = true,

    subcall_runner: subcall_mod.SubcallRunner,

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
        thinking_level: ?types.ThinkingLevel,
    ) !App {
        render.init();
        signal.init(io);

        const init_mod = @import("../init.zig");
        var state = try init_mod.init(allocator, io, .{
            .api_key_override = null,
            .model_override = model_override,
        });
        errdefer state.deinit();

        log.init(allocator, io, state.project_root);
        trace.init(allocator, io, state.project_root);
        timing.init(io);

        {
            var sbuf: [256]u8 = undefined;
            var sw: Io.File.Writer = .init(.stderr(), io, &sbuf);
            var md: [128]u8 = undefined;
            var pd: [64]u8 = undefined;
            const model = try config_mod.resolveModel(&state.config, state.config.default_model);
            sw.interface.print("z-agent-core v{s} | {s} | {s}\n", .{
                types.VERSION,
                config_mod.formatModelDisplay(model.name, &md),
                config_mod.formatProviderDisplay(model.provider, &pd),
            }) catch {};
            sw.interface.flush() catch {};
        }

        if (thinking_level) |tl| {
            state.provider.config.compat.thinking_level = tl;
        }

        const tools = try state.registry.toTools(allocator);
        errdefer allocator.free(tools);

        var project_context: ?[]const u8 = null;
        readAgents: {
            const ap = std.fs.path.join(allocator, &.{ state.project_root, "AGENTS.md" }) catch break :readAgents;
            defer allocator.free(ap);
            const f = Io.Dir.cwd().openFile(io, ap, .{ .mode = .read_only }) catch break :readAgents;
            defer f.close(io);
            const s = f.stat(io) catch break :readAgents;
            if (s.size <= 0 or s.size > types.FILE_READ_LIMIT) break :readAgents;
            const sz = @as(usize, @intCast(s.size));
            const content = allocator.alloc(u8, sz) catch break :readAgents;
            const n = f.readPositionalAll(io, content, 0) catch {
                allocator.free(content);
                break :readAgents;
            };
            project_context = content[0..n];
        }

        const model_ctx = try config_mod.resolveModel(&state.config, state.config.default_model);
        return App{
            .allocator = allocator,
            .io = io,
            .cfg = state.config,
            .provider = state.provider,
            .registry = state.registry,
            .tools = tools,
            .session = state.session,
            .agent = undefined,
            .project_root = state.project_root,
            .project_context = project_context,
            .single_prompt = single_prompt,
            .session_dir = state.session_dir,
            .base_prompt = state.config.base_prompt,
            .render_ctx = render.RenderContext{ .colorize = render.isColorized() },
            .tool_display = render.ToolDisplay{ .ctx = undefined, .writer = undefined },
            .line_buffer = undefined,
            .model_context = model_ctx.context_window,
            .subcall_runner = subcall_mod.SubcallRunner.init(allocator, io),
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
                // N16 fail-closed: no interactive answerer exists on the CLI
                // (REPL and --prompt single-shot), so risky/always commands are
                // deterministically denied instead of silently executed.
                .tool_hooks = .{ .context = self, .before = approvalCliHook },
                .skills_dir = self.cfg.skills_dir,
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
        var stdout_w: Io.File.Writer = .init(.stdout(), self.io, &obuf);

        var ebuf: [4096]u8 = undefined;
        var stderr_w: Io.File.Writer = .init(.stderr(), self.io, &ebuf);

        const display_w: *Io.Writer = if (self.pipe_mode) &stderr_w.interface else &stdout_w.interface;

        var pw = render.PhaseWriter.init(display_w);
        var wc = WriterCtx{ .pw = &pw, .lb = &self.line_buffer, .writer = display_w };

        const phase_cb = provider_mod.PhaseWriterCb{
            .context = @ptrCast(@alignCast(&wc)),
            .begin_phase = pwBeginPhase,
            .write_raw = pwWriteRaw,
            .write_rendered = pwWriteRendered,
            .end_phase = pwEndPhase,
        };

        try render.writeLabeled(display_w, .user, prompt);
        try display_w.flush();

        _ = self.agent.maybeAutoCompact();
        const pre_count = self.session.messages().len;
        try self.session.append(.{ .role = .user, .content = prompt });
        _ = display_w.write("\n") catch {};

        const tool_cb = agent_mod.ToolDisplayCb{
            .context = &self.tool_display,
            .begin_tool = render.ToolDisplay.beginCb,
            .render = render.ToolDisplay.renderCb,
        };
        self.tool_display.writer = display_w;
        const result = self.agent.runTurn(tool_cb, phase_cb) catch |err| {
            if (err != error.OutOfMemory) {
                self.rollbackTurn(pre_count);
            }
            return err;
        };
        _ = display_w.write("\n") catch {};
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
                try render.writeLabeled(display_w, .usage, label);
                _ = display_w.write("\n") catch {};
            }
        }

        if (result.finish == .interrupted) {
            try render.writeLabeled(display_w, .warning, "interrupted");
        }
        if (result.finish == .max_rounds) {
            try render.writeLabeled(display_w, .warning, "max tool rounds reached");
        }
        if (result.finish == .api_error or result.finish == .interrupted) {
            if (result.error_msg) |e| {
                try render.writeLabeled(display_w, .err, e);
            }
            self.rollbackTurn(pre_count);
            try self.session.flush();
            std.process.exit(1);
        } else {
            try self.session.flush();
        }

        if (self.pipe_mode and result.finish == .stop) {
            const msgs = self.session.messages();
            for (msgs) |msg| {
                if (msg.role == .assistant and msg.tool_calls == null) {
                    _ = stdout_w.interface.write(msg.content) catch {};
                    _ = stdout_w.interface.write("\n") catch {};
                }
            }
            try stdout_w.interface.flush();
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
        if (line[0] == '/') {
            try self.dispatchCommand(stdout, line);
            return;
        }

        _ = self.agent.maybeAutoCompact();
        const pre_count = self.session.messages().len;
        try self.session.append(.{ .role = .user, .content = line });
        _ = stdout.interface.write("\n") catch {};

        const phase_cb = provider_mod.PhaseWriterCb{
            .context = @ptrCast(@alignCast(wc)),
            .begin_phase = pwBeginPhase,
            .write_raw = pwWriteRaw,
            .write_rendered = pwWriteRendered,
            .end_phase = pwEndPhase,
        };
        const tool_cb = agent_mod.ToolDisplayCb{
            .context = &self.tool_display,
            .begin_tool = render.ToolDisplay.beginCb,
            .render = render.ToolDisplay.renderCb,
        };
        self.tool_display.writer = &stdout.interface;
        const result = self.agent.runTurn(tool_cb, phase_cb) catch |err| {
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

        // Second-turn title generation (background, best-effort). Fire only on
        // non-error finishes so a rolled-back turn never gets a title.
        if (result.finish == .stop or result.finish == .max_rounds) {
            self.maybeAutoTitle();
        }
    }

    /// After a successful turn, fire a background title sub-call when the
    /// session qualifies (second user message, default title, switch on).
    /// Non-blocking: spawns a detached thread (D6). Skipped in pipe mode.
    fn maybeAutoTitle(self: *App) void {
        if (self.pipe_mode) return;
        if (!title_mod.shouldAutoTitle(&self.session, self.cfg.auto_title)) return;
        if (self.session.path == null) return;

        // The runner dups all borrowed strings, so session/cfg slices are safe
        // to hand off here.
        const task = subcall_mod.TitleTask{
            .provider = self.provider,
            .session_path = self.session.path.?,
            .extra_stopwords = self.cfg.title_stop_words,
            .auto_title = self.cfg.auto_title,
        };
        self.subcall_runner.spawnTitle(task);
    }

    /// Dispatch a "/command" line. CLI-local commands first (exit/quit/help),
    /// then the shared core registry; unknown commands show a /help hint.
    fn dispatchCommand(self: *App, stdout: *Io.File.Writer, line: []const u8) !void {
        const rest = line[1..];
        const arg_start = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
        const name = rest[0..arg_start];
        const args = std.mem.trim(u8, rest[arg_start..], " \t");

        // CLI-local commands
        if (std.mem.eql(u8, name, "exit") or std.mem.eql(u8, name, "quit")) return error.ExitRepl;
        if (std.mem.eql(u8, name, "help")) return self.showHelp(stdout);

        // Shared core registry
        _ = command_mod.find(name) orelse {
            const msg = try std.fmt.allocPrint(self.allocator, "unknown command '/{s}' (try /help)", .{name});
            defer self.allocator.free(msg);
            try render.writeLabeled(&stdout.interface, .err, msg);
            return;
        };

        if (std.mem.eql(u8, name, "new")) return self.resetSession(stdout);
        if (std.mem.eql(u8, name, "reset")) return self.clearSession(stdout);
        if (std.mem.eql(u8, name, "name")) return self.renameSession(args);
        if (std.mem.eql(u8, name, "list")) return self.listSessions(stdout);
        if (std.mem.eql(u8, name, "load")) return self.loadSession(stdout, args);
        if (std.mem.eql(u8, name, "fork")) return self.forkSession(stdout, args);
        if (std.mem.eql(u8, name, "delete")) return self.deleteSession(stdout, args);
        if (std.mem.eql(u8, name, "thinking")) {
            if (types.ThinkingLevel.fromString(args)) |tl| {
                self.provider.config.compat.thinking_level = tl;
                const msg = try std.fmt.allocPrint(self.allocator, "thinking level: {s}", .{args});
                defer self.allocator.free(msg);
                try render.writeLabeled(&stdout.interface, .success, msg);
            } else {
                const hint = command_mod.enumHint(types.ThinkingLevel);
                const msg = try std.fmt.allocPrint(self.allocator, "Usage: /thinking {s}", .{hint});
                defer self.allocator.free(msg);
                try render.writeLabeled(&stdout.interface, .warning, msg);
            }
            return;
        }
        unreachable;
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

    fn resetSession(self: *App, stdout: *Io.File.Writer) !void {
        self.session.deinit();
        self.session = try session_ops.new(self.allocator, self.io, self.cfg.default_model);
        self._env_changed = true;
        self.initAgent();
        try render.writeLabeled(&stdout.interface, .success, "New session started.");
    }

    fn clearSession(self: *App, stdout: *Io.File.Writer) !void {
        session_ops.reset(&self.session);
        try self.session.flush();
        self._env_changed = true;
        self.initAgent();
        try render.writeLabeled(&stdout.interface, .success, "Session cleared.");
    }

    fn renameSession(self: *App, new_name: []const u8) !void {
        const trimmed = std.mem.trim(u8, new_name, " \t");
        if (trimmed.len == 0) {
            var ebuf: [256]u8 = undefined;
            var ew: Io.File.Writer = .init(.stderr(), self.io, &ebuf);
            try render.writeLabeled(&ew.interface, .warning, "Usage: /name <new-name>");
            return;
        }
        try self.session.rename(trimmed);
        try self.session.flush();
        const msg = try std.fmt.allocPrint(self.allocator, "Session renamed to: {s}", .{trimmed});
        defer self.allocator.free(msg);
        var ebuf: [256]u8 = undefined;
        var ew: Io.File.Writer = .init(.stderr(), self.io, &ebuf);
        try render.writeLabeled(&ew.interface, .success, msg);
    }

    fn listSessions(self: *App, stdout: *Io.File.Writer) !void {
        const sessions = try session_mod.list(self.allocator, self.io, self.session_dir);
        defer session_mod.freeSessionInfoList(self.allocator, sessions);

        if (sessions.len == 0) {
            try render.writeLabeled(&stdout.interface, .success, "No saved sessions.");
            return;
        }

        const header = try std.fmt.allocPrint(self.allocator, "Saved sessions ({d}):", .{sessions.len});
        defer self.allocator.free(header);
        try render.writeLabeled(&stdout.interface, .success, header);
        for (sessions) |s| {
            try stdout.interface.print("  {s}  \"{s}\"  {s}  ~{d} msgs\n", .{ s.id, s.name, s.model, s.msg_count });
        }
    }

    fn showHelp(self: *App, stdout: *Io.File.Writer) !void {
        _ = self;
        try render.writeLabeled(&stdout.interface, .success, "z-agent-core commands:");
        try stdout.interface.print("  /exit, /quit    Exit the REPL\n", .{});
        for (&command_mod.builtin) |c| {
            if (c.args_hint.len > 0) {
                try stdout.interface.print("  /{s} <{s}>    {s}\n", .{ c.name, c.args_hint, c.description });
            } else {
                try stdout.interface.print("  /{s}        {s}\n", .{ c.name, c.description });
            }
        }
        try stdout.interface.print("  /help           Show this help\n", .{});
    }

    fn loadSession(self: *App, stdout: *Io.File.Writer, name: []const u8) !void {
        const trimmed = std.mem.trim(u8, name, " \t");
        if (trimmed.len == 0) {
            try render.writeLabeled(&stdout.interface, .err, "Usage: /load <id> (use /list to see IDs)");
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
        self._env_changed = true;
        self.initAgent();
        self.render_ctx.reset();
        try render.writeLabeled(&stdout.interface, .success, "Loaded session");

        // Display all messages using the rendering pipeline
        var pw = render.PhaseWriter.init(&stdout.interface);
        var wc = WriterCtx{ .pw = &pw, .lb = &self.line_buffer, .writer = &stdout.interface };
        const msgs = self.session.messages();
        var last_usage: ?types.TokenUsage = null;
        for (msgs) |msg| {
            if (msg.role == .system) continue;
            if (msg.usage) |u| last_usage = u;

            if (msg.role == .assistant) {
                // Reasoning phase
                if (msg.reasoning_content) |rc| {
                    if (std.mem.trim(u8, rc, " \t\r\n").len > 0) {
                        pwBeginPhase(@ptrCast(@alignCast(&wc)), .thinking);
                        pwWriteRaw(@ptrCast(@alignCast(&wc)), rc);
                        pwEndPhase(@ptrCast(@alignCast(&wc)));
                    }
                }
                // Content phase with Markdown rendering
                pwBeginPhase(@ptrCast(@alignCast(&wc)), .content);
                var line_iter = std.mem.splitScalar(u8, msg.content, '\n');
                while (line_iter.next()) |raw_line| {
                    const line = std.mem.trimEnd(u8, raw_line, "\r");
                    const rendered = try render.renderLine(&self.render_ctx, self.allocator, line);
                    defer self.allocator.free(rendered);
                    pwWriteRendered(@ptrCast(@alignCast(&wc)), rendered);
                }
                pwEndPhase(@ptrCast(@alignCast(&wc)));
                // Tool calls
                if (msg.tool_calls) |tcs| {
                    for (tcs) |tc| {
                        var buf: [512]u8 = undefined;
                        const label = std.fmt.bufPrint(&buf, "{s}({s})", .{ tc.name, tc.arguments }) catch tc.name;
                        try render.writeLabeled(&stdout.interface, .tool, label);
                    }
                }
            } else {
                const mt: render.MessageType = switch (msg.role) {
                    .user => .user,
                    .assistant => unreachable,
                    .tool => .tool,
                    .system => unreachable,
                };
                try render.writeLabeled(&stdout.interface, mt, msg.content);
            }
        }

        // Show final usage if available
        if (last_usage) |u| {
            var t1: [16]u8 = undefined;
            var t2: [16]u8 = undefined;
            const label = try std.fmt.allocPrint(self.allocator, "输入 {s} | 输出 {s}", .{
                try formatToken(u.input, &t1),
                try formatToken(u.output, &t2),
            });
            defer self.allocator.free(label);
            try render.writeLabeled(&stdout.interface, .usage, label);
        }
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
        self._env_changed = true;
        self.initAgent();
        self.render_ctx.reset();

        const msg = try std.fmt.allocPrint(self.allocator, "Forked to '{s}' (switched)", .{fork_name_raw});
        defer self.allocator.free(msg);
        try render.writeLabeled(&stdout.interface, .success, msg);
    }

    /// /delete <id> — confirm, guard the active session, then delete the file.
    fn deleteSession(self: *App, stdout: *Io.File.Writer, id_raw: []const u8) !void {
        const id = std.mem.trim(u8, id_raw, " \t");
        if (id.len == 0) {
            try render.writeLabeled(&stdout.interface, .err, "Usage: /delete <id> (use /list to see IDs)");
            return;
        }
        if (!session_mod.Session.isValidId(id)) {
            try render.writeLabeled(&stdout.interface, .err, "Invalid session id");
            return;
        }

        // Active-session guard (canonicalized compare) BEFORE any deletion.
        if (self.session.path) |cur_path| {
            const target = try std.fs.path.join(self.allocator, &.{ self.session_dir, id });
            defer self.allocator.free(target);
            const target_file = try std.fmt.allocPrint(self.allocator, "{s}.jsonl", .{target});
            defer self.allocator.free(target_file);
            const cur_res = std.fs.path.resolve(self.allocator, &.{cur_path}) catch null;
            defer if (cur_res) |r| self.allocator.free(r);
            const tgt_res = std.fs.path.resolve(self.allocator, &.{target_file}) catch null;
            defer if (tgt_res) |r| self.allocator.free(r);
            if (cur_res != null and tgt_res != null and std.mem.eql(u8, cur_res.?, tgt_res.?)) {
                try render.writeLabeled(&stdout.interface, .err, "Cannot delete the active session (use /new first)");
                return;
            }
        }

        // y/N confirmation.
        try stdout.interface.print("Delete session {s}? (y/N) ", .{id});
        _ = stdout.interface.flush() catch {};
        var rbuf: [128]u8 = undefined;
        var stdin_file = Io.File.stdin();
        var stdin_reader = stdin_file.reader(self.io, rbuf[0..]);
        var confirm_buf: std.ArrayListAligned(u8, null) = .empty;
        const ans = readLine(&stdin_reader.interface, &confirm_buf, self.allocator) catch null;
        const answer = if (ans) |a| a else "";
        if (answer.len > 0) self.allocator.free(answer);
        _ = stdout.interface.write("\n") catch {};
        if (answer.len == 0 or !(answer[0] == 'y' or answer[0] == 'Y')) {
            try render.writeLabeled(&stdout.interface, .success, "Cancelled.");
            return;
        }

        const deleted = session_ops.deleteById(self.allocator, self.io, self.session_dir, id) catch |err| {
            const msg = switch (err) {
                error.InvalidSessionId => "Invalid session id",
                error.FileNotFound => "Session not found",
                else => blk: {
                    var ebuf: [128]u8 = undefined;
                    break :blk std.fmt.bufPrint(&ebuf, "Cannot delete: {s}", .{@errorName(err)}) catch "Cannot delete";
                },
            };
            try render.writeLabeled(&stdout.interface, .err, msg);
            return;
        };
        defer self.allocator.free(deleted);

        try render.writeLabeled(&stdout.interface, .success, "Session deleted");
    }

    /// Free session, config, and all heap-allocated fields. Safe to call on zero-value App.
    pub fn deinit(self: *App) void {
        // Wait for any in-flight background title sub-calls so their write-back
        // completes before session/config memory is freed (D6).
        self.subcall_runner.waitIdle(30_000);
        if (self.project_context) |ctx| self.allocator.free(@constCast(ctx));
        self.allocator.free(self.tools);
        self.allocator.free(self.session_dir);
        self.session.deinit();
        self.cfg.deinit();
        log.deinit();
    }
};

fn spRebuild(ctx: ?*anyopaque) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    if (self.single_prompt != null) {
        try self.session.append(.{
            .role = .system,
            .content = "Interaction mode: single-shot, no user interaction possible. Produce complete final output.",
        });
    }
    // N16: model-visible approval policy notice (idempotent by prefix scan —
    // the rebuild runs before every turn).
    const mode = approval_mod.Mode.fromString(self.cfg.approval_mode) orelse .risky;
    const notice = approval_mod.policyNotice(mode) orelse return;
    for (self.session.messages()) |m| {
        if (m.role == .system and std.mem.startsWith(u8, m.content, approval_mod.POLICY_PREFIX)) return;
    }
    try self.session.append(.{ .role = .system, .content = notice });
}

/// N16 fail-closed CLI hook: no interactive answerer on the CLI, so any
/// command that would require approval is denied with the unified wording
/// (denied = final for that command). `approval_mode = "never"` explicitly
/// opts out.
fn approvalCliHook(ctx: ?*anyopaque, name: []const u8, args: []const u8) ?[]const u8 {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    const mode = approval_mod.Mode.fromString(self.cfg.approval_mode) orelse .risky;
    const rule = approval_mod.isRisky(mode, name, args) orelse return null;
    log.biz_info(0, 0, "approval_denied", "reason=no_interactive tool={s} rule={s}", .{ name, rule });
    return approval_mod.messageFor(self.allocator, .denied, rule) catch null;
}

fn shellName() []const u8 {
    // The bash tool executes commands via this shell; the model needs to know
    // its syntax (e.g. %date% is cmd, not PowerShell).
    return switch (builtin.os.tag) {
        .windows => "pwsh (PowerShell 7)",
        else => "sh",
    };
}

fn buildPromptString(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    project_context: ?[]const u8,
    base_prompt: ?[]const u8,
    single_shot: bool,
) ![]const u8 {
    const os_tag = @tagName(builtin.os.tag);

    const interactive_hint: []const u8 = if (single_shot)
        \\  Interaction mode: single-shot, no user interaction possible. Produce complete final output.
        \\
    else
        "";

    const effective_prompt = base_prompt orelse BASE_PROMPT;

    const prompt = try std.fmt.allocPrint(allocator,
        \\{s}
        \\
        \\<env>
        \\  Workspace root: {s}
        \\  Platform: {s}
        \\  Shell: {s}
        \\  Arch: {s}
        \\{s}\\</env>
        \\
    , .{ effective_prompt, project_root, os_tag, shellName(), @tagName(builtin.cpu.arch), interactive_hint });
    defer allocator.free(prompt);

    const skills = skill_tool.listAvailableSkills(allocator, io, project_root, ".zagent/skills") catch &.{};
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

test "buildPromptString: single_shot adds interaction mode" {
    const allocator = std.testing.allocator;
    const result = try buildPromptString(allocator, std.testing.io, "/root", null, null, true);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "Interaction mode: single-shot") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "no user interaction possible") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Shell: ") != null);
}

test "buildPromptString: REPL mode omits interaction hint" {
    const allocator = std.testing.allocator;
    const result = try buildPromptString(allocator, std.testing.io, "/root", null, null, false);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "Interaction mode") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "single-shot") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Shell: ") != null);
}
