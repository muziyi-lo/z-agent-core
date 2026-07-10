const std = @import("std");
const types = @import("../types.zig");
const provider = @import("../io/provider.zig");
const registry_mod = @import("../tool/registry.zig");
const session_mod = @import("session.zig");
const signal = @import("../util/signal.zig");
const render = @import("../render/cli.zig");

/// Turn-level termination reason. Distinct from types.FinishReason (per-request LLM status).
pub const TurnFinish = enum {
    stop,
    max_rounds,
    interrupted,
    api_error,
};

/// Result of a single runTurn call.
/// new_message_count: messages appended to session this turn.
/// finish: why the turn ended (stop/max_rounds/interrupted/api_error).
pub const RoundResult = struct {
    new_message_count: usize,
    finish: TurnFinish,
};

/// Mock-injectable chat function. ctx: opaque test state; returns arena-backed ProviderResponse.
pub const ChatFn = *const fn (
    ctx: ?*anyopaque,
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    messages: []const types.Message,
    tools: ?[]const types.Tool,
    out_writer: *std.Io.Writer,
) anyerror!types.ProviderResponse;

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
    chat_fn: ?ChatFn = null,
    chat_ctx: ?*anyopaque = null,

    /// No failure path — all params guaranteed valid by caller.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        provider_ref: *provider.Provider,
        tool_registry: registry_mod.Registry,
        session_ref: *session_mod.Session,
        max_tool_rounds: u32,
        project_root: []const u8,
    ) AgentLoop {
        return .{
            .allocator = allocator,
            .io = io,
            .provider_ref = provider_ref,
            .tool_registry = tool_registry,
            .session_ref = session_ref,
            .max_tool_rounds = max_tool_rounds,
            .project_root = project_root,
        };
    }

    /// Execute one LLM turn. User message must already be in session.
    /// writer: raw stdout writer for general output + tool labels (via render.writeLabeled).
    /// phase_writer: opaque PhaseWriter pointer passed through to provider for streaming phase labels.
    /// V1 pragmatic: agent imports render/cli.zig for writeLabeled tool labels. V2 should use callback injection.
    /// Returns error.OutOfMemory on arena OOM.
    pub fn runTurn(
        self: *AgentLoop,
        writer: *std.Io.Writer,
        phase_writer: ?*anyopaque,
    ) !RoundResult {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const tools = try self.tool_registry.toTools(arena_alloc);

        var tool_rounds: u32 = 0;
        var new_msgs: usize = 0;

        while (true) {
            // Interrupted: no flush — V1 accepts partial stdout and no session save.
            if (signal.isInterrupted()) {
                return RoundResult{ .new_message_count = new_msgs, .finish = .interrupted };
            }
            if (tool_rounds >= self.max_tool_rounds) {
                return RoundResult{ .new_message_count = new_msgs, .finish = .max_rounds };
            }

            const msgs = self.session_ref.messages();

            const raw_resp = blk: {
                const result = if (self.chat_fn) |cf|
                    cf(self.chat_ctx, &arena, self.io, msgs, tools, writer)
                else
                    self.provider_ref.chatCompletionStreaming(&arena, self.io, msgs, tools, phase_writer);
                break :blk result;
            };
            const resp = raw_resp catch |err| {
                return switch (err) {
                    error.Interrupted => RoundResult{ .new_message_count = new_msgs, .finish = .interrupted },
                    else => {
                        return RoundResult{ .new_message_count = new_msgs, .finish = .api_error };
                    },
                };
            };

            try self.session_ref.append(.{
                .role = .assistant,
                .content = resp.content orelse "",
                .tool_calls = resp.tool_calls,
            });
            new_msgs += 1;

            if (resp.finish_reason == .stop) {
                return RoundResult{ .new_message_count = new_msgs, .finish = .stop };
            }

            if (resp.finish_reason == .tool_calls) {
                // Defensive: API may return finish_reason=tool_calls with null tool_calls array.
                if (resp.tool_calls) |tcs| {
                    for (tcs) |tc| {
                        if (signal.isInterrupted()) {
                            return RoundResult{ .new_message_count = new_msgs, .finish = .interrupted };
                        }
                        const tool_label = if (tc.arguments.len > 0)
                            try std.fmt.allocPrint(arena_alloc, "{s} {s}", .{ tc.name, tc.arguments })
                        else
                            try std.fmt.allocPrint(arena_alloc, "{s}", .{tc.name});
                        try render.writeLabeled(writer, .tool, tool_label);
                        const ctx = types.ToolContext{
                            // Parent allocator, not arena - tools allocate via ctx.allocator.
                            // Agent frees with same allocator below.
                            .allocator = self.allocator,
                            .io = self.io,
                            .project_root = self.project_root,
                            .display_writer = writer,
                        };
                        // Tool execution errors captured as error string, not propagated
                        // to agent - failed tool still yields a tool message.
                        const exec_result = self.tool_registry.execute(ctx, tc.name, tc.arguments);
                        const result = if (exec_result) |ok|
                            ok
                        else |exec_err|
                            try std.fmt.allocPrint(self.allocator, "Error executing {s}: {s}", .{ tc.name, @errorName(exec_err) });
                        defer self.allocator.free(result);
                        try self.session_ref.append(.{
                            .role = .tool,
                            .content = result,
                            .tool_call_id = tc.id,
                        });
                        new_msgs += 1;
                    }
                }
                tool_rounds += 1;
                continue;
            }

            return RoundResult{ .new_message_count = new_msgs, .finish = .stop };
        }
    }
};

const MockChatter = struct {
    responses: []const types.ProviderResponse,
    index: usize,
    error_on_call: ?usize = null,

    fn chat(
        ctx: ?*anyopaque,
        arena: *std.heap.ArenaAllocator,
        io: std.Io,
        messages: []const types.Message,
        tools: ?[]const types.Tool,
        out_writer: *std.Io.Writer,
    ) anyerror!types.ProviderResponse {
        _ = io;
        _ = messages;
        _ = tools;
        _ = out_writer;
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
};

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
        },
    };

    const reg = registry_mod.buildRegistry();

    const agent = AgentLoop.init(allocator, io, &p, reg, &sess, 10, "/tmp/project");

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
        },
    };
    const reg = registry_mod.buildRegistry();

    var agent = AgentLoop.init(allocator, io, &p, reg, &sess, 10, ".");

    var mock = MockChatter{
        .responses = &.{
            .{ .content = "Hello!", .tool_calls = null, .finish_reason = .stop },
        },
        .index = 0,
    };
    agent.chat_fn = MockChatter.chat;
    agent.chat_ctx = &mock;

    try sess.append(.{ .role = .user, .content = "hi" });

    var out_buf: [256]u8 = undefined;
    var out_writer: std.Io.File.Writer = .init(.stderr(), io, &out_buf);
    const result = try agent.runTurn(&out_writer.interface, null);

    try std.testing.expectEqual(TurnFinish.stop, result.finish);
    try std.testing.expectEqual(@as(usize, 1), result.new_message_count);

    const msgs = sess.messages();
    try std.testing.expectEqual(@as(usize, 2), msgs.len);
    try std.testing.expectEqual(types.Role.user, msgs[0].role);
    try std.testing.expectEqual(types.Role.assistant, msgs[1].role);
    try std.testing.expectEqualStrings("Hello!", msgs[1].content);
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
        },
    };
    const reg = registry_mod.buildRegistry();

    var agent = AgentLoop.init(allocator, io, &p, reg, &sess, 10, ".");

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
    agent.chat_fn = MockChatter.chat;
    agent.chat_ctx = &mock;

    try sess.append(.{ .role = .user, .content = "find zig files" });

    var out_buf: [256]u8 = undefined;
    var out_writer: std.Io.File.Writer = .init(.stderr(), io, &out_buf);
    const result = try agent.runTurn(&out_writer.interface, null);

    try std.testing.expectEqual(TurnFinish.stop, result.finish);
    try std.testing.expectEqual(@as(usize, 3), result.new_message_count);

    const msgs = sess.messages();
    try std.testing.expectEqual(@as(usize, 4), msgs.len);
    try std.testing.expectEqual(types.Role.user, msgs[0].role);
    try std.testing.expectEqual(types.Role.assistant, msgs[1].role);
    try std.testing.expect(msgs[1].tool_calls != null);
    try std.testing.expectEqual(types.Role.tool, msgs[2].role);
    try std.testing.expectEqualStrings("call_1", msgs[2].tool_call_id orelse "");
    try std.testing.expectEqual(types.Role.assistant, msgs[3].role);
    try std.testing.expectEqualStrings("Found 1 file.", msgs[3].content);
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
        },
    };
    const reg = registry_mod.buildRegistry();

    var agent = AgentLoop.init(allocator, io, &p, reg, &sess, 1, ".");

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
    agent.chat_fn = MockChatter.chat;
    agent.chat_ctx = &mock;

    try sess.append(.{ .role = .user, .content = "task" });

    var out_buf: [256]u8 = undefined;
    var out_writer: std.Io.File.Writer = .init(.stderr(), io, &out_buf);
    const result = try agent.runTurn(&out_writer.interface, null);

    try std.testing.expectEqual(TurnFinish.max_rounds, result.finish);
    try std.testing.expectEqual(@as(usize, 2), result.new_message_count);

    const msgs = sess.messages();
    try std.testing.expectEqual(@as(usize, 3), msgs.len);
    try std.testing.expectEqual(types.Role.user, msgs[0].role);
    try std.testing.expectEqual(types.Role.assistant, msgs[1].role);
    try std.testing.expectEqual(types.Role.tool, msgs[2].role);
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
        },
    };
    const reg = registry_mod.buildRegistry();

    var agent = AgentLoop.init(allocator, io, &p, reg, &sess, 10, ".");

    var mock = MockChatter{
        .responses = &.{
            .{ .content = "Start...", .tool_calls = null, .finish_reason = .stop },
        },
        .index = 0,
    };
    agent.chat_fn = MockChatter.chat;
    agent.chat_ctx = &mock;

    try sess.append(.{ .role = .user, .content = "hi" });

    signal.setInterrupted();
    defer signal.reset();

    var out_buf: [256]u8 = undefined;
    var out_writer: std.Io.File.Writer = .init(.stderr(), io, &out_buf);
    const result = try agent.runTurn(&out_writer.interface, null);

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
        },
    };
    const reg = registry_mod.buildRegistry();

    var agent = AgentLoop.init(allocator, io, &p, reg, &sess, 10, ".");

    var mock = MockChatter{
        .responses = &.{},
        .index = 0,
        .error_on_call = 0,
    };
    agent.chat_fn = MockChatter.chat;
    agent.chat_ctx = &mock;

    try sess.append(.{ .role = .user, .content = "hi" });

    var out_buf: [256]u8 = undefined;
    var out_writer: std.Io.File.Writer = .init(.stderr(), io, &out_buf);
    const result = try agent.runTurn(&out_writer.interface, null);

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
        },
    };
    const reg = registry_mod.buildRegistry();

    var agent = AgentLoop.init(allocator, io, &p, reg, &sess, 10, ".");

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
    agent.chat_fn = MockChatter.chat;
    agent.chat_ctx = &mock;

    const pre_len = sess.messages().len;
    try sess.append(.{ .role = .user, .content = "task" });

    var out_buf: [256]u8 = undefined;
    var out_writer: std.Io.File.Writer = .init(.stderr(), io, &out_buf);
    const result = try agent.runTurn(&out_writer.interface, null);

    const msgs = sess.messages();
    const new_msgs = msgs[pre_len + 1 ..];
    try std.testing.expectEqual(result.new_message_count, new_msgs.len);
    try std.testing.expectEqual(@as(usize, 3), new_msgs.len);
    try std.testing.expectEqual(types.Role.assistant, new_msgs[0].role);
    try std.testing.expectEqual(types.Role.tool, new_msgs[1].role);
    try std.testing.expectEqual(types.Role.assistant, new_msgs[2].role);
}
