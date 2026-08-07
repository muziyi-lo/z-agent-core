const std = @import("std");
const builtin = @import("builtin");
const types = @import("../types.zig");
const provider = @import("../io/provider.zig");
const registry_mod = @import("../tool/registry.zig");
const session_mod = @import("session.zig");
const signal = @import("../util/signal.zig");

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
        };
    }

    /// Fire on_turn_end callback then construct RoundResult. Called at every exit point.
    fn finishTurn(self: *AgentLoop, new_msgs: usize, finish: TurnFinish, error_msg: ?[]const u8) RoundResult {
        if (finish == .interrupted) {
            self._aborted.store(false, .release);
            self._aborted_bool = false;
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
                try self.session_ref.append(.{
                    .role = .system,
                    .content = "[max tool rounds reached - further tool calls prevented]",
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
    const skills_dir = std.fs.path.join(self.allocator, &.{ self.project_root, ".zagent", "skills" }) catch return;
    defer self.allocator.free(skills_dir);
    var dir = Io.Dir.cwd().openDir(self.io, skills_dir, .{ .iterate = true }) catch return;
    defer dir.close(self.io);

    var first = true;
    var iter = dir.iterate();
    while (iter.next(self.io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const skill_path = std.fs.path.join(self.allocator, &.{ skills_dir, entry.name }) catch continue;
        defer self.allocator.free(skill_path);
        const sk = Io.Dir.cwd().openFile(self.io, skill_path, .{ .mode = .read_only }) catch continue;
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

        const desc = extractSkillDescription(skill_text) orelse continue;
        self.allocator.free(skill_content);

        if (first) {
            try buf.appendSlice(self.allocator, "\n\n<available_skills>\n");
            first = false;
        }
        try buf.appendSlice(self.allocator, "  ");
        try buf.appendSlice(self.allocator, entry.name);
        try buf.appendSlice(self.allocator, ": ");
        try buf.appendSlice(self.allocator, desc);
        try buf.appendSlice(self.allocator, "\n");
    }
    if (!first) {
        try buf.appendSlice(self.allocator, "</available_skills>");
    }
}

fn extractSkillDescription(skill_text: []const u8) ?[]const u8 {
    const marker = "description:";
    const start = std.mem.indexOf(u8, skill_text, marker) orelse return null;
    const after_marker = skill_text[start + marker.len ..];
    var pos: usize = 0;
    while (pos < after_marker.len and (after_marker[pos] == ' ' or after_marker[pos] == '\t')) : (pos += 1) {}
    const trimmed = after_marker[pos..];
    const end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
    return trimmed[0..end];
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
