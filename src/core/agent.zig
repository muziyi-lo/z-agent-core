const std = @import("std");
const builtin = @import("builtin");
const types = @import("../types.zig");
const provider = @import("../io/provider.zig");
const registry_mod = @import("../tool/registry.zig");
const session_mod = @import("session.zig");
const signal = @import("../util/signal.zig");
const frontmatter = @import("../util/frontmatter.zig");
const skill_tool = @import("../tool/skill.zig");
const compact_mod = @import("compact.zig");
const log = @import("../util/log.zig");

/// Turn-level termination reason. Distinct from types.FinishReason (per-request LLM status).
pub const TurnFinish = enum {
    stop,
    max_rounds,
    interrupted,
    api_error,
    render_error,
};

/// Result of a single runTurn call: new_message_count + finish (stop/max_rounds/interrupted/api_error/render_error).
pub const RoundResult = struct {
    new_message_count: usize,
    finish: TurnFinish,
    error_msg: ?[]const u8 = null,
};

/// Mock-injectable chat function. ctx: opaque test state; returns arena-backed ProviderResponse.
pub const ChatFn = *const fn (
    ctx: ?*anyopaque,
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    messages: []const types.Message,
    tools: ?[]const types.Tool,
) anyerror!types.ProviderResponse;

/// Callback for tool result display. {context, render} struct avoids agent importing render module.
pub const ToolDisplayCb = struct {
    context: ?*anyopaque,
    begin_tool: ?*const fn (ctx: ?*anyopaque, tool_name: []const u8) void = null,
    render: *const fn (
        ctx: ?*anyopaque,
        tool_name: []const u8,
        tool_args: []const u8,
        had_error: bool,
        err_msg: ?[]const u8,
        user_output: ?[]const u8,
        meta: types.ToolMeta,
    ) anyerror!void,
};

/// Hooks for intercepting tool execution. before returns non-null to block; after fires before result deinit.
/// Returned slice from before must be valid until runTurn returns (immediately duped into session arena).
pub const ToolHooks = struct {
    context: ?*anyopaque = null,
    before: ?*const fn (ctx: ?*anyopaque, name: []const u8, args: []const u8) ?[]const u8 = null,
    after: ?*const fn (ctx: ?*anyopaque, result: *types.ToolResult) void = null,
};

/// Optional lifecycle notifications. Called at turn start and every exit point.
pub const LifecycleCb = struct {
    context: ?*anyopaque = null,
    on_turn_start: ?*const fn (ctx: ?*anyopaque) void = null,
    on_turn_end: ?*const fn (ctx: ?*anyopaque, finish: TurnFinish) void = null,
};

/// Callback to rebuild the system prompt at the start of each turn.
/// Frontend injects this; agent calls it before the first LLM request.
/// Responsible for updating the session's system message (replace or prepend).
pub const SystemPromptCb = struct {
    context: ?*anyopaque = null,
    rebuild: *const fn (ctx: ?*anyopaque) anyerror!void,
};

pub const ToolCallRecord = struct {
    name: []const u8,
    args_hash: u64,
};

/// Single-turn LLM execution engine. V1 synchronous — no TUI, compact, permission, or async.
pub const AgentLoop = struct {
    /// Parent allocator, used for ToolContext and freeing tool results. Not arena.
    allocator: std.mem.Allocator,
    io: std.Io,
    provider_ref: *provider.Provider,
    tool_registry: registry_mod.Registry,
    session_ref: *session_mod.Session,
    max_tool_rounds: u32,
    project_root: []const u8,
    context_window: u32,
    chat_fn: ?ChatFn = null,
    chat_ctx: ?*anyopaque = null,
    tool_hooks: ?ToolHooks = null,
    lifecycle: ?LifecycleCb = null,
    system_prompt: ?SystemPromptCb = null,
    skills_dir: []const u8 = ".zagent/skills",
    _aborted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    _aborted_bool: bool = false,
    _tool_call_history: [5]ToolCallRecord = undefined,
    _tool_call_history_len: usize = 0,
    _tool_call_history_pos: usize = 0,
    _loop_warning_injected: bool = false,
    _context_warning_injected: bool = false,

    /// Signal the next runTurn to abort at the earliest safe point.
    /// Sets the per-agent abort flag and the global interrupt flag so the provider's
    /// SSE loop will detect the abort and kill the curl subprocess.
    pub fn abort(self: *AgentLoop) void {
        self._aborted.store(true, .release);
        self._aborted_bool = true;
        signal.setInterrupted();
    }

    /// Swap the session reference — used by web frontend for per-request session isolation.
    pub fn setSession(self: *AgentLoop, session: *session_mod.Session) void {
        self.session_ref = session;
    }

    /// Estimate current context token usage: the last assistant message's
    /// usage.total when available (it reflects the full context sent to the
    /// model), otherwise a length-based estimate across all messages. Never
    /// sums per-message usage — each total is a per-request value and summing
    /// over-approximates the real context badly.
    fn estimateContextTokens(self: *AgentLoop) u32 {
        const msgs = self.session_ref.messages();
        var i: usize = msgs.len;
        while (i > 0) {
            i -= 1;
            const m = msgs[i];
            if (m.role == .assistant) {
                if (m.usage) |u| return u.total;
                break;
            }
        }
        var total: u32 = 0;
        for (msgs) |m| {
            total += @as(u32, @intCast(m.content.len / 4));
            if (m.reasoning_content) |rc| {
                total += @as(u32, @intCast(rc.len / 4));
            }
        }
        return total;
    }

    /// Auto-compact at a turn boundary when the estimated context exceeds the
    /// window budget (context_window - reserved). Returns true when a
    /// compaction happened. Never fails the turn: summarization errors are
    /// swallowed and the in-runTurn context warning stays as the fallback.
    /// Frontends call this before capturing pre_count / invoking runTurn.
    pub fn maybeAutoCompact(self: *AgentLoop) bool {
        if (self.context_window == 0) return false;

        const context_tokens = self.estimateContextTokens();
        const reserved: u32 = @max(@as(u32, 20000), self.context_window / 10);
        const usable = if (self.context_window > reserved) self.context_window - reserved else self.context_window;
        if (context_tokens <= usable) return false;

        // Stale-usage guard: a last assistant message written before the latest
        // compaction carries pre-compaction usage and would re-trigger
        // immediately. A null bound (never compacted in-process) skips this.
        if (self.session_ref.last_compact_id) |bound| {
            const msgs = self.session_ref.messages();
            var i: usize = msgs.len;
            while (i > 0) {
                i -= 1;
                if (msgs[i].role == .assistant) {
                    if (msgs[i].id <= bound) return false;
                    break;
                }
            }
        }

        _ = compact_mod.compactSession(self.provider_ref, self.session_ref, self.allocator, self.io, compact_mod.DEFAULT_KEEP_RECENT_TOKENS) catch {
            return false;
        };
        return true;
    }

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        provider_ref: *provider.Provider,
        tool_registry: registry_mod.Registry,
        session_ref: *session_mod.Session,
        max_tool_rounds: u32,
        project_root: []const u8,
        context_window: u32,
        opts: struct {
            tool_hooks: ?ToolHooks = null,
            lifecycle: ?LifecycleCb = null,
            system_prompt: ?SystemPromptCb = null,
            skills_dir: []const u8 = ".zagent/skills",
        },
    ) AgentLoop {
        return .{
            .allocator = allocator,
            .io = io,
            .provider_ref = provider_ref,
            .tool_registry = tool_registry,
            .session_ref = session_ref,
            .max_tool_rounds = max_tool_rounds,
            .project_root = project_root,
            .context_window = context_window,
            .tool_hooks = opts.tool_hooks,
            .lifecycle = opts.lifecycle,
            .system_prompt = opts.system_prompt,
            .skills_dir = opts.skills_dir,
        };
    }

    /// Fire on_turn_end callback then construct RoundResult. Called at every exit point.
    fn finishTurn(self: *AgentLoop, new_msgs: usize, finish: TurnFinish, error_msg: ?[]const u8) RoundResult {
        if (finish == .interrupted) {
            self._aborted.store(false, .release);
            self._aborted_bool = false;
            // Clear the global interrupt flag too: abort() set it to kill the
            // provider's curl subprocess, and every interrupted exit path must
            // consume it. Otherwise a stale flag makes later bash tool calls
            // report "Command aborted by user." (leak between turns/tests).
            signal.reset();
        }
        if (self.lifecycle) |lc| {
            if (lc.on_turn_end) |cb| cb(lc.context, finish);
        }
        return .{ .new_message_count = new_msgs, .finish = finish, .error_msg = error_msg };
    }

    /// Execute one LLM turn. User message must already be in session.
    /// tool_display: callback struct for tool result rendering (null = headless).
    /// phase_writer: callback struct for streaming phase events (null = silent).
    pub fn runTurn(
        self: *AgentLoop,
        tool_display: ?ToolDisplayCb,
        phase_writer: ?provider.PhaseWriterCb,
    ) !RoundResult {
        if (self.lifecycle) |lc| {
            if (lc.on_turn_start) |cb| cb(lc.context);
        }
        errdefer {
            if (self.lifecycle) |lc| {
                if (lc.on_turn_end) |cb| cb(lc.context, .api_error);
            }
        }

        {
            const msgs = self.session_ref.messages();
            if (msgs.len == 0 or msgs[0].role != .system) {
                const sp = try buildPromptString(self);
                defer self.allocator.free(sp);
                try self.session_ref.updateFirstSystem(sp);
            }
        }

        if (self.system_prompt) |sp| {
            try sp.rebuild(sp.context);
        }

        self._tool_call_history_len = 0;
        self._tool_call_history_pos = 0;
        self._loop_warning_injected = false;
        self._context_warning_injected = false;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const tools = try self.tool_registry.toTools(arena_alloc);

        var tool_rounds: u32 = 0;
        var new_msgs: usize = 0;

        while (true) {
            if (self._aborted.load(.acquire)) {
                self._aborted_bool = true;
                return finishTurn(self, new_msgs, .interrupted, null);
            }
            if (tool_rounds >= self.max_tool_rounds) {
                new_msgs += 1;
                const rounds_msg = try std.fmt.allocPrint(self.allocator, "[Notice: tool call limit reached ({d} rounds this turn). Stop calling tools now. Report your completed work and any remaining questions to the user.]", .{self.max_tool_rounds});
                defer self.allocator.free(rounds_msg);
                try self.session_ref.append(.{
                    .role = .system,
                    .content = rounds_msg,
                    // max_tool_rounds 上限已到，注入当前回合的强制指令（对齐 StormBreaker
                    // [Notice: ...] 措辞——明确"现在做什么"而非陈述历史，模型才不会忽略）
                });
                return finishTurn(self, new_msgs, .max_rounds, null);
            }

            if (self.context_window > 0) {
                // Estimate total context usage — prefer actual usage stats, fall back to length-based estimate
                var total_used: u32 = 0;
                var usage_based = false;
                for (self.session_ref.messages()) |msg| {
                    if (msg.usage) |u| {
                        total_used += u.total;
                        usage_based = true;
                    }
                }
                // If no usage data available (e.g. loaded session), estimate from content length
                if (!usage_based) {
                    for (self.session_ref.messages()) |msg| {
                        total_used += @as(u32, @intCast(msg.content.len / 4));
                        if (msg.reasoning_content) |rc| {
                            total_used += @as(u32, @intCast(rc.len / 4));
                        }
                    }
                }
                const reserved: u32 = @max(@as(u32, 20000), self.context_window / 10);
                const usable = if (self.context_window > reserved) self.context_window - reserved else self.context_window;
                if (total_used > usable and !self._context_warning_injected) {
                    self._context_warning_injected = true;
                    try self.session_ref.append(.{
                        .role = .system,
                        .content = "[Notice: Context window nearly full. Consider summarizing earlier discussion or asking the user for guidance.]",
                    });
                    new_msgs += 1;
                }
            }

            const msgs = self.session_ref.messages();

        const raw_resp = blk: {
            const result = if (self.chat_fn) |cf|
                cf(self.chat_ctx, &arena, self.io, msgs, tools)
            else
                self.provider_ref.chatCompletionStreaming(&arena, self.io, msgs, tools, phase_writer);
            break :blk result;
        };
            const resp = raw_resp catch |err| {
                const err_name = @errorName(err);
                return switch (err) {
                    error.Interrupted => {
                        signal.reset();
                        return finishTurn(self, new_msgs, .interrupted, err_name);
                    },
                    else => finishTurn(self, new_msgs, .api_error, err_name),
                };
            };

            try self.session_ref.append(.{
                .role = .assistant,
                .content = resp.content orelse "",
                .reasoning_content = resp.reasoning_content,
                .tool_calls = resp.tool_calls,
                .usage = resp.usage,
            });
            new_msgs += 1;

            if (resp.finish_reason == .stop) {
                return finishTurn(self, new_msgs, .stop, null);
            }

            if (resp.finish_reason == .tool_calls) {
                if (resp.tool_calls) |tcs| {
                    for (tcs) |tc| {
                        if (self._aborted.load(.acquire)) {
                            return finishTurn(self, new_msgs, .interrupted, null);
                        }

                        if (self.tool_hooks) |h| {
                            if (h.before) |beforeFn| {
                                if (beforeFn(h.context, tc.name, tc.arguments)) |block_msg| {
                                    try self.session_ref.append(.{
                                        .role = .tool,
                                        .content = block_msg,
                                        .tool_call_id = tc.id,
                                    });
                                    new_msgs += 1;
                                    continue;
                                }
                            }
                        }

                        const ctx = types.ToolContext{
                            .allocator = self.allocator,
                            .io = self.io,
                            .project_root = self.project_root,
                            .api_endpoint = .{
                                .base_url = self.provider_ref.config.base_url,
                                .api_key = self.provider_ref.config.api_key,
                                .model = self.provider_ref.config.model,
                            },
                            .abort_target = &self._aborted_bool,
                            .messages = self.session_ref.messages(),
                            .session_ref = self.session_ref,
                            .provider_ref = self.provider_ref,
                            .skills_dir = self.skills_dir,
                        };
                        if (tool_display) |cb| {
                            if (cb.begin_tool) |bt| bt(cb.context, tc.name);
                        }

                        if (!self._loop_warning_injected) {
                            const args_hash: u64 = std.hash.Wyhash.hash(0, tc.arguments);
                            if (self._tool_call_history_len >= 3) {
                                var all_same = true;
                                const start_pos: usize = (self._tool_call_history_pos + 5 - 3) % 5;
                                for (0..3) |i| {
                                    const idx = (start_pos + i) % 5;
                                    if (!std.mem.eql(u8, self._tool_call_history[idx].name, tc.name) or
                                        self._tool_call_history[idx].args_hash != args_hash)
                                    {
                                        all_same = false;
                                        break;
                                    }
                                }
                                if (all_same) {
                                    self._loop_warning_injected = true;
                                    log.dbg(0, 0, "stormbreaker_trigger", "tool={s}", .{tc.name});
                                    try self.session_ref.append(.{
                                        .role = .system,
                                        .content = "[Notice: You appear to be repeating the same tool call. Consider adjusting your strategy or asking the user for guidance.]",
                                    });
                                    new_msgs += 1;
                                }
                            }
                            self._tool_call_history[self._tool_call_history_pos] = .{ .name = tc.name, .args_hash = args_hash };
                            self._tool_call_history_pos = (self._tool_call_history_pos + 1) % 5;
                            if (self._tool_call_history_len < 5) self._tool_call_history_len += 1;
                        }

                        var exec_result = self.tool_registry.execute(ctx, tc.name, tc.arguments);

                        if (exec_result) |*ok| {
                            if (self.tool_hooks) |h| {
                                if (h.after) |afterFn| afterFn(h.context, ok);
                            }
                            defer ok.deinit(self.allocator);
                            if (tool_display) |cb| {
                                cb.render(cb.context, tc.name, tc.arguments, ok.err_msg != null, ok.err_msg, ok.user_output, ok.meta) catch {};
                            }
                            try self.session_ref.append(.{
                                .role = .tool,
                                .content = ok.session_content,
                                .tool_call_id = tc.id,
                                .meta = ok.meta,
                            });
                            new_msgs += 1;
                        } else |exec_err| {
                            if (tool_display) |cb| {
                                cb.render(cb.context, tc.name, tc.arguments, true, @errorName(exec_err), null, .none) catch {};
                            }
                            const err_msg = try std.fmt.allocPrint(self.allocator, "Error executing {s}: {s}", .{ tc.name, @errorName(exec_err) });
                            defer self.allocator.free(err_msg);
                            try self.session_ref.append(.{
                                .role = .tool,
                                .content = err_msg,
                                .tool_call_id = tc.id,
                            });
                            new_msgs += 1;
                        }
                    }
                }
                tool_rounds += 1;
                log.dbg(0, 0, "tool_round", "round={d} max={d}", .{ tool_rounds, self.max_tool_rounds });
                continue;
            }

            return finishTurn(self, new_msgs, .stop, null);
        }
    }
};

fn buildPromptString(self: *const AgentLoop) ![]const u8 {
    var buf: std.ArrayListAligned(u8, null) = .empty;
    const a = self.allocator;

    try buf.appendSlice(a, "You are z-agent-core, an interactive CLI agent that helps users with software engineering tasks.\n\n<env>\n  Workspace root: ");
    try buf.appendSlice(a, self.project_root);
    try buf.appendSlice(a, "\n  Platform: ");
    try buf.appendSlice(a, @tagName(builtin.os.tag));
    try buf.appendSlice(a, "\n  Shell: ");
    try buf.appendSlice(a, shellName());
    try buf.appendSlice(a, "\n  Arch: ");
    try buf.appendSlice(a, @tagName(builtin.cpu.arch));
    try buf.appendSlice(a, "\n  Model: ");
    try buf.appendSlice(a, self.provider_ref.config.model);
    try buf.appendSlice(a, "\n  Date: ");
    {
        var date_buf: [16]u8 = undefined;
        try buf.appendSlice(a, try formatUtcDate(self.io, &date_buf));
    }
    try buf.appendSlice(a, "\n  Git repo: ");
    try buf.appendSlice(a, if (isGitRepo(self.io, self.project_root)) "yes" else "no");
    try buf.appendSlice(a, "\n</env>");

    if (readAgentsMd(self)) |content| {
        defer a.free(content);
        try buf.appendSlice(a, "\n\n<project_context>\n");
        try buf.appendSlice(a, content);
        try buf.appendSlice(a, "\n</project_context>");
    }

    try appendSkillsList(self, &buf);

    return buf.toOwnedSlice(a);
}

/// Format current UTC date as YYYY-MM-DD. Zig 0.16 has no std date formatting
/// public API; convert manually via the epoch chain:
/// Timestamp(ns) → EpochSeconds → EpochDay → YearAndDay → MonthAndDay.
fn formatUtcDate(io: std.Io, buf: []u8) ![]const u8 {
    const ts = Io.Clock.real.now(io);
    const secs: u64 = @intCast(@divTrunc(ts.nanoseconds, 1_000_000_000));
    const epoch = std.time.epoch.EpochSeconds{ .secs = secs };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        @as(u8, @intFromEnum(month_day.month)) + 1,
        @as(u8, month_day.day_index) + 1,
    });
}

/// Detect a git repo by checking project_root/.git directory existence.
fn isGitRepo(io: std.Io, project_root: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const git_dir = std.fs.path.join(a, &.{ project_root, ".git" }) catch return false;
    var dir = Io.Dir.cwd().openDir(io, git_dir, .{ .iterate = false }) catch return false;
    dir.close(io);
    return true;
}

fn shellName() []const u8 {
    // The bash tool executes commands via this shell; the model needs to know
    // its syntax (e.g. %date% is cmd, not PowerShell).
    return switch (builtin.os.tag) {
        .windows => "pwsh (PowerShell 7)",
        else => "sh",
    };
}

fn readAgentsMd(self: *const AgentLoop) ?[]const u8 {
    const ap = std.fs.path.join(self.allocator, &.{ self.project_root, "AGENTS.md" }) catch return null;
    defer self.allocator.free(ap);
    const f = Io.Dir.cwd().openFile(self.io, ap, .{ .mode = .read_only }) catch return null;
    defer f.close(self.io);
    const s = f.stat(self.io) catch return null;
    if (s.size <= 0 or s.size > 65536) return null;
    const sz = @as(usize, @intCast(s.size));
    const content = self.allocator.alloc(u8, sz) catch return null;
    const n = f.readPositionalAll(self.io, content, 0) catch {
        self.allocator.free(content);
        return null;
    };
    return content[0..n];
}

fn appendSkillsList(self: *const AgentLoop, buf: *std.ArrayListAligned(u8, null)) !void {
    const skills_path = std.fs.path.join(self.allocator, &.{ self.project_root, self.skills_dir }) catch return;
    defer self.allocator.free(skills_path);
    var dir = Io.Dir.cwd().openDir(self.io, skills_path, .{ .iterate = true }) catch return;
    defer dir.close(self.io);

    var list = std.ArrayListAligned(skill_tool.SkillInfo, null).empty;
    var iter = dir.iterate();
    while (iter.next(self.io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const skill_md = std.fs.path.join(self.allocator, &.{ skills_path, entry.name, "SKILL.md" }) catch continue;
        defer self.allocator.free(skill_md);
        const sk = Io.Dir.cwd().openFile(self.io, skill_md, .{ .mode = .read_only }) catch continue;
        defer sk.close(self.io);
        const ss = sk.stat(self.io) catch continue;
        if (ss.size <= 0 or ss.size > 65536) continue;
        const sz = @as(usize, @intCast(ss.size));
        const skill_content = self.allocator.alloc(u8, sz) catch continue;
        const nn = sk.readPositionalAll(self.io, skill_content, 0) catch {
            self.allocator.free(skill_content);
            continue;
        };
        const skill_text = skill_content[0..nn];

        const desc = frontmatter.parseField(skill_text, "description") orelse {
            self.allocator.free(skill_content);
            continue;
        };

        const duped_name = self.allocator.dupe(u8, entry.name) catch {
            self.allocator.free(skill_content);
            continue;
        };
        const duped_desc = self.allocator.dupe(u8, desc) catch {
            self.allocator.free(skill_content);
            continue;
        };
        // desc 借用 skill_content，dupe 完成后再释放
        self.allocator.free(skill_content);

        list.append(self.allocator, .{ .name = duped_name, .description = duped_desc }) catch continue;
    }

    if (list.items.len == 0) {
        try buf.appendSlice(self.allocator, "\n\nNo skills are currently available.\n");
        return;
    }

    std.mem.sort(skill_tool.SkillInfo, list.items, {}, struct {
        fn lt(_: void, a: skill_tool.SkillInfo, b: skill_tool.SkillInfo) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);

    try buf.appendSlice(self.allocator, "\n\n<available_skills>\n");
    for (list.items) |s| {
        try buf.appendSlice(self.allocator, "  ");
        try buf.appendSlice(self.allocator, s.name);
        try buf.appendSlice(self.allocator, ": ");
        try buf.appendSlice(self.allocator, s.description);
        try buf.appendSlice(self.allocator, "\n");
    }
    try buf.appendSlice(self.allocator, "</available_skills>");
    // buf.appendSlice copies the bytes, so the duped strings are no longer
    // referenced; free each, then release the items array.
    for (list.items) |s| {
        self.allocator.free(s.name);
        self.allocator.free(s.description);
    }
    list.deinit(self.allocator);
}

const Io = std.Io;

const MockChatter = struct {
    responses: []const types.ProviderResponse,
    index: usize,
    error_on_call: ?usize = null,
};

fn mockChat(
    ctx: ?*anyopaque,
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    messages: []const types.Message,
    tools: ?[]const types.Tool,
) anyerror!types.ProviderResponse {
    _ = io;
    _ = messages;
    _ = tools;
    const self: *MockChatter = @ptrCast(@alignCast(ctx.?));
    defer self.index += 1;

    if (self.error_on_call) |eoc| {
        if (self.index == eoc) return error.ApiError;
    }

    if (self.index >= self.responses.len) return error.ApiError;

    const src = self.responses[self.index];
    const alloc = arena.allocator();

    var duped_tool_calls: ?[]types.ToolCall = null;
    if (src.tool_calls) |tcs| {
        const duped = try alloc.alloc(types.ToolCall, tcs.len);
        for (tcs, duped) |s, *d| {
            d.* = .{
                .id = try alloc.dupe(u8, s.id),
                .name = try alloc.dupe(u8, s.name),
                .arguments = try alloc.dupe(u8, s.arguments),
            };
        }
        duped_tool_calls = duped;
    }

    return types.ProviderResponse{
        .content = if (src.content) |c| try alloc.dupe(u8, c) else null,
        .tool_calls = duped_tool_calls,
        .finish_reason = src.finish_reason,
    };
}

test "agent: init stores fields" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var sess = try session_mod.Session.init(allocator, io, "test-model");
    defer sess.deinit();

    var p = provider.Provider{
        .config = .{
            .base_url = "https://api.test.com",
            .api_key = "",
            .model = "test-model",
            .max_tokens = 1000,
            .vendor = .standard,
            .compat = .{},
        },
    };

    const reg = registry_mod.buildRegistry();

    const agent = AgentLoop.init(allocator, io, &p, reg, &sess, 10, "/tmp/project", 0, .{});

    try std.testing.expectEqual(allocator, agent.allocator);
    try std.testing.expectEqual(io, agent.io);
    try std.testing.expectEqual(&p, agent.provider_ref);
    try std.testing.expectEqual(@as(u32, 10), agent.max_tool_rounds);
    try std.testing.expectEqualStrings("/tmp/project", agent.project_root);
    try std.testing.expect(agent.chat_fn == null);
}

test "agent: estimateContextTokens prefers last assistant usage" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var sess = try session_mod.Session.init(allocator, io, "test-model");
    defer sess.deinit();
    try sess.append(.{ .role = .system, .content = "sys" });
    try sess.append(.{ .role = .user, .content = "abcdefgh" });
    try sess.append(.{ .role = .assistant, .content = "hi", .usage = .{ .input = 100, .output = 50, .total = 150 } });

    var p = provider.Provider{
        .config = .{
            .base_url = "https://api.test.com",
            .api_key = "",
            .model = "test-model",
            .max_tokens = 1000,
            .vendor = .standard,
            .compat = .{},
        },
    };
    const reg = registry_mod.buildRegistry();
    var agent = AgentLoop.init(allocator, io, &p, reg, &sess, 10, ".", 0, .{});
    try std.testing.expectEqual(@as(u32, 150), agent.estimateContextTokens());
}

test "agent: estimateContextTokens falls back to length estimate" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var sess = try session_mod.Session.init(allocator, io, "test-model");
    defer sess.deinit();
    try sess.append(.{ .role = .system, .content = "sys" });
    try sess.append(.{ .role = .user, .content = "abcdefghijklmnop" });
    try sess.append(.{ .role = .assistant, .content = "abcdefghijklmnop" });

    var p = provider.Provider{
        .config = .{
            .base_url = "https://api.test.com",
            .api_key = "",
            .model = "test-model",
            .max_tokens = 1000,
            .vendor = .standard,
            .compat = .{},
        },
    };
    const reg = registry_mod.buildRegistry();
    var agent = AgentLoop.init(allocator, io, &p, reg, &sess, 10, ".", 0, .{});
    try std.testing.expectEqual(@as(u32, 8), agent.estimateContextTokens());
}

test "agent: maybeAutoCompact no-op when context_window zero" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var sess = try session_mod.Session.init(allocator, io, "test-model");
    defer sess.deinit();
    try sess.append(.{ .role = .system, .content = "sys" });
    try sess.append(.{ .role = .assistant, .content = "hi", .usage = .{ .input = 1, .output = 1, .total = 2 } });

    var p = provider.Provider{
        .config = .{
            .base_url = "https://api.test.com",
            .api_key = "",
            .model = "test-model",
            .max_tokens = 1000,
            .vendor = .standard,
            .compat = .{},
        },
    };
    const reg = registry_mod.buildRegistry();
    var agent = AgentLoop.init(allocator, io, &p, reg, &sess, 10, ".", 0, .{});
    try std.testing.expect(!agent.maybeAutoCompact());
}

test "agent: maybeAutoCompact no-op under threshold" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var sess = try session_mod.Session.init(allocator, io, "test-model");
    defer sess.deinit();
    try sess.append(.{ .role = .system, .content = "sys" });
    try sess.append(.{ .role = .assistant, .content = "hi", .usage = .{ .input = 100, .output = 100, .total = 200 } });

    var p = provider.Provider{
        .config = .{
            .base_url = "https://api.test.com",
            .api_key = "",
            .model = "test-model",
            .max_tokens = 1000,
            .vendor = .standard,
            .compat = .{},
        },
    };
    const reg = registry_mod.buildRegistry();
    var agent = AgentLoop.init(allocator, io, &p, reg, &sess, 10, ".", 100000, .{});
    try std.testing.expect(!agent.maybeAutoCompact());
}

test "agent: maybeAutoCompact stale usage blocked by compaction boundary" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var sess = try session_mod.Session.init(allocator, io, "test-model");
    defer sess.deinit();
    try sess.append(.{ .role = .system, .content = "sys" });
    try sess.append(.{ .role = .assistant, .content = "hi", .usage = .{ .input = 5000, .output = 0, .total = 5000 } });
    // Over-threshold for a tiny window, but the last assistant predates the
    // compaction boundary → must not trigger (and must not call the LLM).
    sess.last_compact_id = 9999;

    var p = provider.Provider{
        .config = .{
            .base_url = "https://api.test.com",
            .api_key = "",
            .model = "test-model",
            .max_tokens = 1000,
            .vendor = .standard,
            .compat = .{},
        },
    };
    const reg = registry_mod.buildRegistry();
    var agent = AgentLoop.init(allocator, io, &p, reg, &sess, 10, ".", 100, .{});
    try std.testing.expect(!agent.maybeAutoCompact());
}

test "agent: runTurn stop" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var sess = try session_mod.Session.init(allocator, io, "test-model");
    defer sess.deinit();

    var p = provider.Provider{
        .config = .{
            .base_url = "https://api.test.com",
            .api_key = "",
            .model = "test-model",
            .max_tokens = 1000,
            .vendor = .standard,
            .compat = .{},
        },
    };
    const reg = registry_mod.buildRegistry();

    var agent = AgentLoop.init(allocator, io, &p, reg, &sess, 10, ".", 0, .{});

    var mock = MockChatter{
        .responses = &.{
            .{ .content = "Hello!", .tool_calls = null, .finish_reason = .stop },
        },
        .index = 0,
    };
    agent.chat_fn = mockChat;
    agent.chat_ctx = &mock;

    try sess.append(.{ .role = .user, .content = "hi" });

    const result = try agent.runTurn(null, null);

    try std.testing.expectEqual(TurnFinish.stop, result.finish);
    try std.testing.expectEqual(@as(usize, 1), result.new_message_count);

    const msgs = sess.messages();
    try std.testing.expectEqual(@as(usize, 3), msgs.len);
    try std.testing.expectEqual(types.Role.system, msgs[0].role);
    try std.testing.expectEqual(types.Role.user, msgs[1].role);
    try std.testing.expectEqual(types.Role.assistant, msgs[2].role);
    try std.testing.expectEqualStrings("Hello!", msgs[2].content);
}

test "agent: runTurn tool_calls" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var sess = try session_mod.Session.init(allocator, io, "test-model");
    defer sess.deinit();

    var p = provider.Provider{
        .config = .{
            .base_url = "https://api.test.com",
            .api_key = "",
            .model = "test-model",
            .max_tokens = 1000,
            .vendor = .standard,
            .compat = .{},
        },
    };
    const reg = registry_mod.buildRegistry();

    var agent = AgentLoop.init(allocator, io, &p, reg, &sess, 10, ".", 0, .{});

    var tool_calls = [_]types.ToolCall{
        .{ .id = "call_1", .name = "glob", .arguments = "{\"pattern\":\"*.zig\"}" },
    };
    var mock = MockChatter{
        .responses = &.{
            .{ .content = null, .tool_calls = tool_calls[0..], .finish_reason = .tool_calls },
            .{ .content = "Found 1 file.", .tool_calls = null, .finish_reason = .stop },
        },
        .index = 0,
    };
    agent.chat_fn = mockChat;
    agent.chat_ctx = &mock;

    try sess.append(.{ .role = .user, .content = "find zig files" });

    const result = try agent.runTurn(null, null);

    try std.testing.expectEqual(TurnFinish.stop, result.finish);
    try std.testing.expectEqual(@as(usize, 3), result.new_message_count);

    const msgs = sess.messages();
    try std.testing.expectEqual(@as(usize, 5), msgs.len);
    try std.testing.expectEqual(types.Role.system, msgs[0].role);
    try std.testing.expectEqual(types.Role.user, msgs[1].role);
    try std.testing.expectEqual(types.Role.assistant, msgs[2].role);
    try std.testing.expect(msgs[2].tool_calls != null);
    try std.testing.expectEqual(types.Role.tool, msgs[3].role);
    try std.testing.expectEqualStrings("call_1", msgs[3].tool_call_id orelse "");
    try std.testing.expectEqual(types.Role.assistant, msgs[4].role);
    try std.testing.expectEqualStrings("Found 1 file.", msgs[4].content);
}

test "agent: runTurn max_rounds" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var sess = try session_mod.Session.init(allocator, io, "test-model");
    defer sess.deinit();

    var p = provider.Provider{
        .config = .{
            .base_url = "https://api.test.com",
            .api_key = "",
            .model = "test-model",
            .max_tokens = 1000,
            .vendor = .standard,
            .compat = .{},
        },
    };
    const reg = registry_mod.buildRegistry();

    var agent = AgentLoop.init(allocator, io, &p, reg, &sess, 1, ".", 0, .{});

    var tool_calls_mr = [_]types.ToolCall{
        .{ .id = "call_1", .name = "glob", .arguments = "{\"pattern\":\"*.zig\"}" },
    };
    var mock = MockChatter{
        .responses = &.{
            .{ .content = null, .tool_calls = tool_calls_mr[0..], .finish_reason = .tool_calls },
            .{ .content = "Done", .tool_calls = null, .finish_reason = .stop },
        },
        .index = 0,
    };
    agent.chat_fn = mockChat;
    agent.chat_ctx = &mock;

    try sess.append(.{ .role = .user, .content = "task" });

    const result = try agent.runTurn(null, null);

    try std.testing.expectEqual(TurnFinish.max_rounds, result.finish);
    try std.testing.expectEqual(@as(usize, 3), result.new_message_count);

    const msgs = sess.messages();
    try std.testing.expectEqual(@as(usize, 5), msgs.len);
    try std.testing.expectEqual(types.Role.system, msgs[0].role);
    try std.testing.expectEqual(types.Role.user, msgs[1].role);
    try std.testing.expectEqual(types.Role.assistant, msgs[2].role);
    try std.testing.expectEqual(types.Role.tool, msgs[3].role);
    try std.testing.expectEqual(types.Role.system, msgs[4].role);
}

test "agent: runTurn interrupted" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var sess = try session_mod.Session.init(allocator, io, "test-model");
    defer sess.deinit();

    var p = provider.Provider{
        .config = .{
            .base_url = "https://api.test.com",
            .api_key = "",
            .model = "test-model",
            .max_tokens = 1000,
            .vendor = .standard,
            .compat = .{},
        },
    };
    const reg = registry_mod.buildRegistry();

    var agent = AgentLoop.init(allocator, io, &p, reg, &sess, 10, ".", 0, .{});

    var mock = MockChatter{
        .responses = &.{
            .{ .content = "Start...", .tool_calls = null, .finish_reason = .stop },
        },
        .index = 0,
    };
    agent.chat_fn = mockChat;
    agent.chat_ctx = &mock;

    try sess.append(.{ .role = .user, .content = "hi" });

    agent.abort();

    const result = try agent.runTurn(null, null);

    try std.testing.expectEqual(TurnFinish.interrupted, result.finish);
    try std.testing.expectEqual(@as(usize, 0), result.new_message_count);
}

test "agent: runTurn api_error" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var sess = try session_mod.Session.init(allocator, io, "test-model");
    defer sess.deinit();

    var p = provider.Provider{
        .config = .{
            .base_url = "https://api.test.com",
            .api_key = "",
            .model = "test-model",
            .max_tokens = 1000,
            .vendor = .standard,
            .compat = .{},
        },
    };
    const reg = registry_mod.buildRegistry();

    var agent = AgentLoop.init(allocator, io, &p, reg, &sess, 10, ".", 0, .{});

    var mock = MockChatter{
        .responses = &.{},
        .index = 0,
        .error_on_call = 0,
    };
    agent.chat_fn = mockChat;
    agent.chat_ctx = &mock;

    try sess.append(.{ .role = .user, .content = "hi" });

    const result = try agent.runTurn(null, null);

    try std.testing.expectEqual(TurnFinish.api_error, result.finish);
    try std.testing.expectEqual(@as(usize, 0), result.new_message_count);
}

test "agent: runTurn appends to session" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var sess = try session_mod.Session.init(allocator, io, "test-model");
    defer sess.deinit();

    var p = provider.Provider{
        .config = .{
            .base_url = "https://api.test.com",
            .api_key = "",
            .model = "test-model",
            .max_tokens = 1000,
            .vendor = .standard,
            .compat = .{},
        },
    };
    const reg = registry_mod.buildRegistry();

    var agent = AgentLoop.init(allocator, io, &p, reg, &sess, 10, ".", 0, .{});

    var tool_calls_app = [_]types.ToolCall{
        .{ .id = "c1", .name = "glob", .arguments = "{\"pattern\":\"*\"}" },
    };
    var mock = MockChatter{
        .responses = &.{
            .{ .content = null, .tool_calls = tool_calls_app[0..], .finish_reason = .tool_calls },
            .{ .content = "Result: done", .tool_calls = null, .finish_reason = .stop },
        },
        .index = 0,
    };
    agent.chat_fn = mockChat;
    agent.chat_ctx = &mock;

    const pre_len = sess.messages().len;
    try sess.append(.{ .role = .user, .content = "task" });

    _ = try agent.runTurn(null, null);

    const msgs = sess.messages();
    const new_msgs = msgs[pre_len + 1 ..];
    try std.testing.expectEqual(@as(usize, 4), new_msgs.len);
    try std.testing.expectEqual(types.Role.user, new_msgs[0].role);
    try std.testing.expectEqual(types.Role.assistant, new_msgs[1].role);
    try std.testing.expectEqual(types.Role.tool, new_msgs[2].role);
    try std.testing.expectEqual(types.Role.assistant, new_msgs[3].role);
}

// ── Test helpers for hooks/lifecycle/abort tests ──

const TestCallbacks = struct {
    before_called: bool = false,
    before_block: bool = false,
    after_called: bool = false,
    start_called: bool = false,
    end_called: bool = false,
    end_finish: TurnFinish = .stop,
};

fn testBeforeHook(ctx: ?*anyopaque, name: []const u8, args: []const u8) ?[]const u8 {
    _ = name;
    _ = args;
    const tc: *TestCallbacks = @ptrCast(@alignCast(ctx.?));
    tc.before_called = true;
    if (tc.before_block) return "blocked by test hook";
    return null;
}

fn testAfterHook(ctx: ?*anyopaque, result: *types.ToolResult) void {
    _ = result;
    const tc: *TestCallbacks = @ptrCast(@alignCast(ctx.?));
    tc.after_called = true;
}

fn testStartCb(ctx: ?*anyopaque) void {
    const tc: *TestCallbacks = @ptrCast(@alignCast(ctx.?));
    tc.start_called = true;
}

fn testEndCb(ctx: ?*anyopaque, finish: TurnFinish) void {
    const tc: *TestCallbacks = @ptrCast(@alignCast(ctx.?));
    tc.end_called = true;
    tc.end_finish = finish;
}

// ── Hooks tests ──

test "agent: hooks before blocks execution" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var sess = try session_mod.Session.init(allocator, io, "test-model");
    defer sess.deinit();

    var p = provider.Provider{
        .config = .{ .base_url = "https://api.test.com", .api_key = "", .model = "test-model", .max_tokens = 1000, .vendor = .standard, .compat = .{} },
    };
    const reg = registry_mod.buildRegistry();

    var tc = TestCallbacks{ .before_block = true };
    var agent = AgentLoop.init(allocator, io, &p, reg, &sess, 10, ".", 0, .{
        .tool_hooks = .{ .context = &tc, .before = testBeforeHook },
    });

    var tool_calls = [_]types.ToolCall{.{ .id = "c1", .name = "glob", .arguments = "{\"pattern\":\"*\"}" }};
    var mock = MockChatter{
        .responses = &.{
            .{ .content = null, .tool_calls = tool_calls[0..], .finish_reason = .tool_calls },
            .{ .content = "Done", .tool_calls = null, .finish_reason = .stop },
        },
        .index = 0,
    };
    agent.chat_fn = mockChat;
    agent.chat_ctx = &mock;

    try sess.append(.{ .role = .user, .content = "task" });
    const result = try agent.runTurn(null, null);

    try std.testing.expect(tc.before_called);
    try std.testing.expectEqual(TurnFinish.stop, result.finish);
    try std.testing.expect(result.new_message_count >= 3); // assistant + tool(blocked) + assistant
}

test "agent: hooks before allows execution" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var sess = try session_mod.Session.init(allocator, io, "test-model");
    defer sess.deinit();

    var p = provider.Provider{
        .config = .{ .base_url = "https://api.test.com", .api_key = "", .model = "test-model", .max_tokens = 1000, .vendor = .standard, .compat = .{} },
    };
    const reg = registry_mod.buildRegistry();

    var tc = TestCallbacks{ .before_block = false };
    var agent = AgentLoop.init(allocator, io, &p, reg, &sess, 10, ".", 0, .{
        .tool_hooks = .{ .context = &tc, .before = testBeforeHook },
    });

    var tool_calls = [_]types.ToolCall{.{ .id = "c1", .name = "glob", .arguments = "{\"pattern\":\"*\"}" }};
    var mock = MockChatter{
        .responses = &.{
            .{ .content = null, .tool_calls = tool_calls[0..], .finish_reason = .tool_calls },
            .{ .content = "Done", .tool_calls = null, .finish_reason = .stop },
        },
        .index = 0,
    };
    agent.chat_fn = mockChat;
    agent.chat_ctx = &mock;

    try sess.append(.{ .role = .user, .content = "task" });
    const result = try agent.runTurn(null, null);

    try std.testing.expect(tc.before_called);
    try std.testing.expectEqual(TurnFinish.stop, result.finish);
}

test "agent: hooks after fires on success" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var sess = try session_mod.Session.init(allocator, io, "test-model");
    defer sess.deinit();

    var p = provider.Provider{
        .config = .{ .base_url = "https://api.test.com", .api_key = "", .model = "test-model", .max_tokens = 1000, .vendor = .standard, .compat = .{} },
    };
    const reg = registry_mod.buildRegistry();

    var tc = TestCallbacks{};
    var agent = AgentLoop.init(allocator, io, &p, reg, &sess, 10, ".", 0, .{
        .tool_hooks = .{ .context = &tc, .after = testAfterHook },
    });

    var tool_calls = [_]types.ToolCall{.{ .id = "c1", .name = "glob", .arguments = "{\"pattern\":\"*\"}" }};
    var mock = MockChatter{
        .responses = &.{
            .{ .content = null, .tool_calls = tool_calls[0..], .finish_reason = .tool_calls },
            .{ .content = "Done", .tool_calls = null, .finish_reason = .stop },
        },
        .index = 0,
    };
    agent.chat_fn = mockChat;
    agent.chat_ctx = &mock;

    try sess.append(.{ .role = .user, .content = "task" });
    _ = try agent.runTurn(null, null);

    try std.testing.expect(tc.after_called);
}

// ── Abort tests ──

test "agent: abort before runTurn returns interrupted" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var sess = try session_mod.Session.init(allocator, io, "test-model");
    defer sess.deinit();

    var p = provider.Provider{
        .config = .{ .base_url = "https://api.test.com", .api_key = "", .model = "test-model", .max_tokens = 1000, .vendor = .standard, .compat = .{} },
    };
    const reg = registry_mod.buildRegistry();

    var agent = AgentLoop.init(allocator, io, &p, reg, &sess, 10, ".", 0, .{});

    var mock = MockChatter{
        .responses = &.{.{ .content = "Hello!", .tool_calls = null, .finish_reason = .stop }},
        .index = 0,
    };
    agent.chat_fn = mockChat;
    agent.chat_ctx = &mock;

    try sess.append(.{ .role = .user, .content = "hi" });

    agent.abort();
    const result = try agent.runTurn(null, null);

    try std.testing.expectEqual(TurnFinish.interrupted, result.finish);
    try std.testing.expectEqual(@as(usize, 0), result.new_message_count);
}

test "agent: abort resets on next runTurn" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var sess = try session_mod.Session.init(allocator, io, "test-model");
    defer sess.deinit();

    var p = provider.Provider{
        .config = .{ .base_url = "https://api.test.com", .api_key = "", .model = "test-model", .max_tokens = 1000, .vendor = .standard, .compat = .{} },
    };
    const reg = registry_mod.buildRegistry();

    var agent = AgentLoop.init(allocator, io, &p, reg, &sess, 10, ".", 0, .{});

    var mock = MockChatter{
        .responses = &.{
            .{ .content = "Hello!", .tool_calls = null, .finish_reason = .stop },
            .{ .content = "Hi again!", .tool_calls = null, .finish_reason = .stop },
        },
        .index = 0,
    };
    agent.chat_fn = mockChat;
    agent.chat_ctx = &mock;

    try sess.append(.{ .role = .user, .content = "hi" });
    agent.abort();
    const r1 = try agent.runTurn(null, null);
    try std.testing.expectEqual(TurnFinish.interrupted, r1.finish);

    try sess.append(.{ .role = .user, .content = "hi again" });
    const r2 = try agent.runTurn(null, null);
    try std.testing.expectEqual(TurnFinish.stop, r2.finish);
}

// ── Lifecycle tests ──

test "agent: lifecycle on_turn_start fires" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var sess = try session_mod.Session.init(allocator, io, "test-model");
    defer sess.deinit();

    var p = provider.Provider{
        .config = .{ .base_url = "https://api.test.com", .api_key = "", .model = "test-model", .max_tokens = 1000, .vendor = .standard, .compat = .{} },
    };
    const reg = registry_mod.buildRegistry();

    var tc = TestCallbacks{};
    var agent = AgentLoop.init(allocator, io, &p, reg, &sess, 10, ".", 0, .{
        .lifecycle = .{ .context = &tc, .on_turn_start = testStartCb },
    });

    var mock = MockChatter{
        .responses = &.{.{ .content = "Ok", .tool_calls = null, .finish_reason = .stop }},
        .index = 0,
    };
    agent.chat_fn = mockChat;
    agent.chat_ctx = &mock;

    try sess.append(.{ .role = .user, .content = "hi" });
    _ = try agent.runTurn(null, null);

    try std.testing.expect(tc.start_called);
}

test "agent: lifecycle on_turn_end fires" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var sess = try session_mod.Session.init(allocator, io, "test-model");
    defer sess.deinit();

    var p = provider.Provider{
        .config = .{ .base_url = "https://api.test.com", .api_key = "", .model = "test-model", .max_tokens = 1000, .vendor = .standard, .compat = .{} },
    };
    const reg = registry_mod.buildRegistry();

    var tc = TestCallbacks{};
    var agent = AgentLoop.init(allocator, io, &p, reg, &sess, 10, ".", 0, .{
        .lifecycle = .{ .context = &tc, .on_turn_end = testEndCb },
    });

    var mock = MockChatter{
        .responses = &.{.{ .content = "Ok", .tool_calls = null, .finish_reason = .stop }},
        .index = 0,
    };
    agent.chat_fn = mockChat;
    agent.chat_ctx = &mock;

    try sess.append(.{ .role = .user, .content = "hi" });
    _ = try agent.runTurn(null, null);

    try std.testing.expect(tc.end_called);
    try std.testing.expectEqual(TurnFinish.stop, tc.end_finish);
}

test "agent: buildPromptString includes model/date/git" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const test_root = ".zig-test-prompt-env";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {};
    try Io.Dir.cwd().createDirPath(io, test_root);

    var sess = try session_mod.Session.init(allocator, io, "test-model");
    defer sess.deinit();

    var p = provider.Provider{
        .config = .{
            .base_url = "https://api.test.com",
            .api_key = "",
            .model = "test-model",
            .max_tokens = 1000,
            .vendor = .standard,
            .compat = .{},
        },
    };
    const reg = registry_mod.buildRegistry();
    var agent = AgentLoop.init(allocator, io, &p, reg, &sess, 10, test_root, 0, .{});

    const sp = try buildPromptString(&agent);
    defer allocator.free(sp);

    try std.testing.expect(std.mem.indexOf(u8, sp, "Model: test-model") != null);
    // Date format YYYY-MM-DD (regex-free positional check)
    const date_marker = "Date: ";
    const date_pos = std.mem.indexOf(u8, sp, date_marker) orelse return error.TestUnexpectedNull;
    const date_val = sp[date_pos + date_marker.len .. date_pos + date_marker.len + 10];
    try std.testing.expect(date_val.len == 10);
    try std.testing.expect(date_val[4] == '-');
    try std.testing.expect(date_val[7] == '-');
    try std.testing.expect(date_val[0] >= '1' and date_val[0] <= '9');
    // test_root has no .git -> Git repo: no
    try std.testing.expect(std.mem.indexOf(u8, sp, "Git repo: no") != null);
}

test "agent: appendSkillsList reads and sorts SKILL.md" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const test_root = ".zig-test-skills-list";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {};
    try Io.Dir.cwd().createDirPath(io, test_root);

    const skills_dir = std.fs.path.join(allocator, &.{ test_root, ".zagent", "skills" }) catch return error.Oom;
    defer allocator.free(skills_dir);
    try Io.Dir.cwd().createDirPath(io, skills_dir);

    // Create z-skill first, a-skill second to prove sorting (reverse creation order)
    const z_skill_dir = try std.fs.path.join(allocator, &.{ skills_dir, "z-skill" });
    defer allocator.free(z_skill_dir);
    try Io.Dir.cwd().createDirPath(io, z_skill_dir);
    const z_md = try std.fs.path.join(allocator, &.{ z_skill_dir, "SKILL.md" });
    defer allocator.free(z_md);
    {
        const f = try Io.Dir.cwd().createFile(io, z_md, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "---\ndescription: Z skill\n---\n");
    }

    const a_skill_dir = try std.fs.path.join(allocator, &.{ skills_dir, "a-skill" });
    defer allocator.free(a_skill_dir);
    try Io.Dir.cwd().createDirPath(io, a_skill_dir);
    const a_md = try std.fs.path.join(allocator, &.{ a_skill_dir, "SKILL.md" });
    defer allocator.free(a_md);
    {
        const f = try Io.Dir.cwd().createFile(io, a_md, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "---\ndescription: A skill\n---\n");
    }

    var sess = try session_mod.Session.init(allocator, io, "test-model");
    defer sess.deinit();
    var p = provider.Provider{
        .config = .{ .base_url = "https://api.test.com", .api_key = "", .model = "test-model", .max_tokens = 1000, .vendor = .standard, .compat = .{} },
    };
    const reg = registry_mod.buildRegistry();
    var agent = AgentLoop.init(allocator, io, &p, reg, &sess, 10, test_root, 0, .{});

    var buf: std.ArrayListAligned(u8, null) = .empty;
    defer buf.deinit(allocator);
    try appendSkillsList(&agent, &buf);

    const out = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, out, "<available_skills>") != null);
    // a-skill must come before z-skill (sorted)
    const a_pos = std.mem.indexOf(u8, out, "a-skill") orelse return error.TestUnexpectedNull;
    const z_pos = std.mem.indexOf(u8, out, "z-skill") orelse return error.TestUnexpectedNull;
    try std.testing.expect(a_pos < z_pos);
    try std.testing.expect(std.mem.indexOf(u8, out, "A skill") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Z skill") != null);
}

test "agent: appendSkillsList empty dir outputs empty state" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const test_root = ".zig-test-skills-empty";
    defer Io.Dir.cwd().deleteTree(io, test_root) catch {};
    try Io.Dir.cwd().createDirPath(io, test_root);
    const empty_skills = try std.fs.path.join(allocator, &.{ test_root, ".zagent", "skills" });
    defer allocator.free(empty_skills);
    try Io.Dir.cwd().createDirPath(io, empty_skills);

    var sess = try session_mod.Session.init(allocator, io, "test-model");
    defer sess.deinit();
    var p = provider.Provider{
        .config = .{ .base_url = "https://api.test.com", .api_key = "", .model = "test-model", .max_tokens = 1000, .vendor = .standard, .compat = .{} },
    };
    const reg = registry_mod.buildRegistry();
    var agent = AgentLoop.init(allocator, io, &p, reg, &sess, 10, test_root, 0, .{});

    var buf: std.ArrayListAligned(u8, null) = .empty;
    defer buf.deinit(allocator);
    try appendSkillsList(&agent, &buf);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "No skills are currently available.") != null);
}
