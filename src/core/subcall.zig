const std = @import("std");
const types = @import("../types.zig");
const provider_mod = @import("../io/provider.zig");
const session_mod = @import("session.zig");
const title_mod = @import("title.zig");
const log = @import("../util/log.zig");

const Io = std.Io;

/// A background sub-call (子代理) task: one-shot, tool-less, silent LLM call
/// with a dedicated system prompt, executed on its own detached thread with a
/// fully independent lifecycle (arena + provider copy + session load + write-back).
/// This is the title consumer today; F4 branch-summary reuses the same runner.
pub const TitleTask = struct {
    provider: provider_mod.Provider,
    session_path: []const u8,
    extra_stopwords: []const []const u8,
    auto_title: bool,
};

/// Fire-and-forget runner for one-shot sub-agent LLM calls. Owns a process-level
/// allocator used to persist task data across thread lifetime. Tracks active
/// threads so callers can wait for completion before process exit.
pub const SubcallRunner = struct {
    allocator: std.mem.Allocator,
    io: Io,
    active: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, io: Io) SubcallRunner {
        return .{ .allocator = allocator, .io = io };
    }

    /// Spawn a detached background thread to run the title task. Returns
    /// immediately. Data is dup'd into this runner's allocator; the thread
    /// builds its own arena and frees everything it owns on completion.
    /// `self` must outlive the thread (process-level lifetime: CLI App member /
    /// Web global). active is decremented by the thread on completion.
    pub fn spawnTitle(self: *SubcallRunner, task: TitleTask) void {
        const duped = self.dupTask(task) catch {
            log.dbg(0, 0, "subcall_spawn_oom", "cannot dup task", .{});
            return;
        };
        _ = @atomicRmw(u32, &self.active, .Add, 1, .seq_cst);
        const thread = std.Thread.spawn(.{}, runTitle, .{ self.allocator, self.io, self, duped }) catch {
            _ = @atomicRmw(u32, &self.active, .Sub, 1, .seq_cst);
            freeTask(self.allocator, duped);
            log.dbg(0, 0, "subcall_spawn_failed", "thread spawn error", .{});
            return;
        };
        thread.detach();
        log.dbg(0, 0, "subcall_spawned", "path={s}", .{duped.session_path});
    }

    /// Wait until no background sub-calls are running (bounded by timeout_ms).
    pub fn waitIdle(self: *SubcallRunner, timeout_ms: u32) void {
        const deadline_ms = Io.Timestamp.toMilliseconds(Io.Clock.Timestamp.now(self.io, .real).raw) + timeout_ms;
        while (@atomicLoad(u32, &self.active, .seq_cst) > 0) {
            if (Io.Timestamp.toMilliseconds(Io.Clock.Timestamp.now(self.io, .real).raw) > deadline_ms) {
                log.dbg(0, 0, "subcall_wait_timeout", "active={d}", .{@atomicLoad(u32, &self.active, .seq_cst)});
                return;
            }
            const kernel32 = struct {
                extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.c) void;
            };
            kernel32.Sleep(20);
        }
    }

    fn dupTask(self: *SubcallRunner, task: TitleTask) !*TitleTask {
        const a = self.allocator;
        const t = try a.create(TitleTask);
        errdefer a.destroy(t);

        var cfg = task.provider.config;
        cfg.base_url = try a.dupe(u8, task.provider.config.base_url);
        errdefer a.free(cfg.base_url);
        cfg.api_key = try a.dupe(u8, task.provider.config.api_key);
        errdefer a.free(cfg.api_key);
        cfg.model = try a.dupe(u8, task.provider.config.model);
        errdefer a.free(cfg.model);
        if (task.provider.config.model_params) |mp| {
            cfg.model_params = try a.dupe(u8, mp);
            errdefer a.free(cfg.model_params);
        } else {
            cfg.model_params = null;
        }

        t.* = .{
            .provider = .{ .config = cfg },
            .session_path = try a.dupe(u8, task.session_path),
            .extra_stopwords = try dupStrings(a, task.extra_stopwords),
            .auto_title = task.auto_title,
        };
        return t;
    }
};

fn dupStrings(a: std.mem.Allocator, strs: []const []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, strs.len);
    for (strs, 0..) |s, i| out[i] = try a.dupe(u8, s);
    return out;
}

fn freeTask(a: std.mem.Allocator, t: *TitleTask) void {
    a.free(t.provider.config.base_url);
    a.free(t.provider.config.api_key);
    a.free(t.provider.config.model);
    if (t.provider.config.model_params) |mp| a.free(mp);
    a.free(t.session_path);
    for (t.extra_stopwords) |s| a.free(s);
    a.free(t.extra_stopwords);
    a.destroy(t);
}

fn runTitle(allocator: std.mem.Allocator, io: Io, runner: *SubcallRunner, task: *TitleTask) void {
    defer {
        freeTask(allocator, task);
        _ = @atomicRmw(u32, &runner.active, .Sub, 1, .seq_cst);
    }

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Load the latest session from disk into a thread-local copy.
    const path_dup = arena.dupe(u8, task.session_path) catch return;
    var session = session_mod.Session.load(arena, io, path_dup) catch return;
    defer session.deinit();

    // Defensive re-check: the session may have been renamed/deleted since spawn.
    if (!title_mod.shouldAutoTitle(&session, task.auto_title)) return;

    _ = title_mod.ensureTitle(&task.provider, &session, allocator, io, task.extra_stopwords);
}

test "subcall: spawn with missing session path completes and waitIdle returns" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var runner = SubcallRunner.init(allocator, io);

    const task = TitleTask{
        .provider = .{ .config = .{
            .base_url = "https://api.test.invalid",
            .api_key = "",
            .model = "test",
            .max_tokens = 10,
            .vendor = .standard,
            .compat = .{},
        } },
        .session_path = ".zig-test-subcall/nonexistent.jsonl",
        .extra_stopwords = &.{},
        .auto_title = true,
    };

    runner.spawnTitle(task);
    runner.waitIdle(5000);
    try std.testing.expectEqual(@as(u32, 0), @atomicLoad(u32, &runner.active, .seq_cst));
}