const std = @import("std");
const builtin = @import("builtin");
const log = @import("util/log.zig");

const Io = std.Io;

/// Approval mode, from config `approval_mode`. `risky` is the default.
pub const Mode = enum {
    never,
    risky,
    always,

    pub fn fromString(s: []const u8) ?Mode {
        if (std.mem.eql(u8, s, "never")) return .never;
        if (std.mem.eql(u8, s, "risky")) return .risky;
        if (std.mem.eql(u8, s, "always")) return .always;
        return null;
    }

    pub fn toString(self: Mode) []const u8 {
        return switch (self) {
            .never => "never",
            .risky => "risky",
            .always => "always",
        };
    }
};

/// Gate state machine. `timeout` is not a distinct state: a timed-out wait
/// transitions pending → denied with `timed_out=true` so callers can tell an
/// auto-denial from an explicit user denial (messageFor wording differs).
pub const GateState = enum {
    pending,
    approved,
    denied,
    aborted,
};

/// Decision category for messageFor (hook-level semantics, not Gate states).
pub const Decision = enum {
    denied,
    timeout,
    aborted,
};

/// Rule text used in `approval_required.rule` / Modal display / messageFor.
pub const ALWAYS_RULE = "all tool calls require approval (approval_mode=always)";
pub const L0_RULE = "suspicious dynamic execution (command substitution, backticks, or variable indirection)";
pub const RM_RULE = "recursive delete";
pub const GIT_PUSH_RULE = "git force push";
pub const GIT_RESET_RULE = "git hard reset";
pub const GIT_CLEAN_RULE = "git clean with force";
pub const PIPE_RULE = "pipe to shell (sh/bash/dash)";
pub const STORAGE_RULE = "storage/device destruction";
pub const SYSTEM_RULE = "system mutation";
pub const DD_RULE = "device write (dd of= to /dev/)";
pub const CRYPTSETUP_RULE = "cryptographic volume operation";

/// Per-approval gate. Owned by the web handler; the waiting thread polls
/// `state` every 100ms. Not tied to the io event loop (web request threads are
/// plain threads), matching the abort-flag pattern in agent.zig.
pub const Gate = struct {
    io: Io,
    /// Stored as u8: std.atomic.Value wraps an extern struct, which cannot
    /// contain enum fields (Zig 0.16 restriction).
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(GateState.pending)),
    /// Set by wait() only when the wait itself performed the pending→denied
    /// transition at the deadline (i.e. the denial was a timeout, not a user
    /// decision). Written by the wait thread, read by the hook on the same
    /// thread after wait returns — no cross-thread sharing.
    timed_out: bool = false,
    id: []const u8,
    session_id: []const u8,
    /// Real clock (project-wide convention, see subcall.zig) at registration;
    /// used for lazy sweep of stale entries.
    registered_at_ms: i64,

    pub fn init(io: Io, id: []const u8, session_id: []const u8, registered_at_ms: i64) Gate {
        return .{
            .io = io,
            .id = id,
            .session_id = session_id,
            .registered_at_ms = registered_at_ms,
        };
    }

    pub fn current(self: *Gate) GateState {
        return @enumFromInt(self.state.load(.acquire));
    }

    /// Block until the gate is resolved. Returns the final state.
    /// - check_abort: polled every cycle; true → aborted
    /// - keepalive: called roughly every second (or timeout/4 when the timeout
    ///   is sub-second, for testability); false → aborted (SSE write failed)
    /// - reminder: called once at timeout/2; false → aborted
    pub fn wait(
        self: *Gate,
        timeout_ms: u32,
        check_abort: *const fn () bool,
        keepalive: ?*const fn () bool,
        reminder: ?*const fn () bool,
    ) GateState {
        const poll_ms: u32 = 100;
        const keepalive_every_ms: u32 = if (timeout_ms < 1000) timeout_ms / 4 else 1000;
        const start_ms = nowRealMs(self.io);
        const deadline_ms = start_ms + @as(i64, @intCast(timeout_ms));
        var last_keepalive_ms = start_ms;
        var reminder_done = false;

        while (true) {
            const st: GateState = self.current();
            if (st != .pending) return st;

            if (check_abort()) {
                log.req_warn(0, 0, "approval_aborted", "id={s} reason=abort_flag", .{self.id});
                return self.transitionOrState(.aborted);
            }

            const now_ms = nowRealMs(self.io);
            if (now_ms >= deadline_ms) {
                if (self.transition(.denied)) {
                    self.timed_out = true;
                    log.req_warn(0, 0, "approval_timeout", "id={s} session={s}", .{ self.id, self.session_id });
                }
                return self.current();
            }

            if (keepalive) |ka| {
                if (now_ms - last_keepalive_ms >= @as(i64, @intCast(keepalive_every_ms))) {
                    if (!ka()) {
                        log.req_warn(0, 0, "approval_aborted", "id={s} reason=keepalive_write_failed", .{self.id});
                        return self.transitionOrState(.aborted);
                    }
                    last_keepalive_ms = now_ms;
                }
            }

            if (reminder) |rm| {
                if (!reminder_done and timeout_ms > 0 and now_ms - start_ms >= @as(i64, @intCast(timeout_ms / 2))) {
                    if (!rm()) {
                        log.req_warn(0, 0, "approval_aborted", "id={s} reason=reminder_write_failed", .{self.id});
                        return self.transitionOrState(.aborted);
                    }
                    reminder_done = true;
                }
            }

            sleepMs(poll_ms);
        }
    }

    /// User decision. Returns true only when this call performed the
    /// pending → approved/denied transition (i.e. the gate was still pending).
    /// Idempotent: repeated calls after resolution return false.
    pub fn resolve(self: *Gate, allow: bool) bool {
        const target: GateState = if (allow) .approved else .denied;
        const changed = self.transition(target);
        log.biz_info(0, 0, "approval_resolved", "id={s} allow={d} changed={d}", .{ self.id, @intFromBool(allow), @intFromBool(changed) });
        return changed;
    }

    /// pending → target CAS; false when already terminal.
    fn transition(self: *Gate, target: GateState) bool {
        const target_raw: u8 = @intFromEnum(target);
        var cur = self.state.load(.acquire);
        while (cur == @intFromEnum(GateState.pending)) {
            if (self.state.cmpxchgWeak(cur, target_raw, .acq_rel, .acquire)) |actual| {
                cur = actual;
            } else {
                return true;
            }
        }
        return false;
    }

    /// Try to mark aborted; return the actual state (aborted if we transitioned,
    /// whatever the other party set otherwise).
    fn transitionOrState(self: *Gate, target: GateState) GateState {
        _ = self.transition(target);
        return self.current();
    }
};

/// Decide whether a tool call requires approval.
/// - never: no
/// - always: yes, fixed rule text (no rule matching)
/// - risky: only the bash tool, only when an L0/L1 rule matches
/// Returns the rule text or null. Static strings, no allocation.
pub fn isRisky(mode: Mode, name: []const u8, args: []const u8) ?[]const u8 {
    switch (mode) {
        .never => return null,
        .always => return ALWAYS_RULE,
        .risky => {},
    }
    if (!std.mem.eql(u8, name, "bash")) return null;

    var buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, fba.allocator(), args, .{ .ignore_unknown_fields = true }) catch return L0_RULE;
    const command: []const u8 = if (parsed == .object) blk: {
        if (parsed.object.get("command")) |c| {
            if (c == .string) break :blk c.string;
        }
        break :blk "";
    } else "";

    if (command.len == 0) return null;
    if (hasDynamicSignal(command)) return L0_RULE;
    return matchL1(command);
}

/// L0: dynamic-execution signals (fail-closed — upgrade to approval when the
/// lexical scan cannot prove safety). `$(` / backticks / `${` anywhere, or a
/// `$`-prefixed token in command position after `;` / `&&` / `||`.
fn hasDynamicSignal(command: []const u8) bool {
    if (std.mem.indexOf(u8, command, "$(") != null) return true;
    if (std.mem.indexOf(u8, command, "`") != null) return true;
    if (std.mem.indexOf(u8, command, "${") != null) return true;

    var i: usize = 0;
    while (i < command.len) {
        const rest = command[i..];
        if (std.mem.startsWith(u8, rest, ";")) {
            i += 1;
            while (i < command.len and isSpace(command[i])) i += 1;
            if (i < command.len and command[i] == '$') return true;
            continue;
        }
        if (std.mem.startsWith(u8, rest, "&&") or std.mem.startsWith(u8, rest, "||")) {
            i += 2;
            while (i < command.len and isSpace(command[i])) i += 1;
            if (i < command.len and command[i] == '$') return true;
            continue;
        }
        i += 1;
    }
    return false;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// L1: enumerated destructive classes. Command name matching is case-insensitive.
fn matchL1(command: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, command, " \t");
    const first = firstCommand(&it) orelse return null;

    if (isRmFamily(first)) {
        if (hasRecursiveFlag(&it)) return RM_RULE;
        return null;
    }
    if (isStorageCommand(first, &it)) return STORAGE_RULE;
    if (isSystemCommand(first, &it)) return SYSTEM_RULE;
    if (gitRule(first, &it)) |r| return r;
    if (hasPipeToShell(command)) return PIPE_RULE;
    return null;
}

/// Normalized first command: skips wrappers (sudo/env/nice/exec/command, with
/// absolute paths), sudo options + their values, env var assignments, and
/// strips path prefixes from the command name. Returns the base name.
fn firstCommand(it: anytype) ?[]const u8 {
    while (it.next()) |tok| {
        const base = baseName(tok);
        if (isWrapperName(base)) continue;
        if (isVarAssign(tok)) continue;
        if (tok.len > 0 and tok[0] == '-') {
            // sudo option with a value (sudo -u user …): consume the value
            if (std.mem.eql(u8, tok, "-u") or std.mem.eql(u8, tok, "-U") or
                std.mem.eql(u8, tok, "-g") or std.mem.eql(u8, tok, "-G"))
            {
                _ = it.next();
            }
            continue;
        }
        return base;
    }
    return null;
}

fn isRmFamily(base: []const u8) bool {
    return eqlIgnoreCase(base, "rm") or eqlIgnoreCase(base, "del") or
        eqlIgnoreCase(base, "rmdir") or eqlIgnoreCase(base, "erase") or
        eqlIgnoreCase(base, "remove-item");
}

fn hasRecursiveFlag(it: anytype) bool {
    while (it.next()) |tok| {
        if (isShortFlagGroup(tok)) {
            for (tok[1..]) |c| {
                if (std.ascii.toLower(c) == 'r') return true;
            }
        } else if (std.mem.eql(u8, tok, "--recursive") or std.mem.eql(u8, tok, "-recursive")) {
            return true;
        } else if (std.mem.eql(u8, tok, "/s") or std.mem.eql(u8, tok, "/S")) {
            return true;
        }
    }
    return false;
}

fn isStorageCommand(base: []const u8, it: anytype) bool {
    const members = [_][]const u8{ "format", "diskpart", "fdisk", "sfdisk", "gdisk", "parted", "mkswap", "swapoff", "shred", "wipefs", "pvcreate", "pvremove", "vgremove", "lvremove", "lvreduce" };
    for (members) |m| {
        if (eqlIgnoreCase(base, m)) return true;
    }
    // mkfs family incl. mkfs.ext4 / mkfs.vfat / mkfs.xfs variants.
    if (eqlIgnoreCase(base, "mkfs") or (base.len > "mkfs.".len and std.ascii.eqlIgnoreCase(base[0 .. "mkfs.".len], "mkfs."))) return true;
    if (eqlIgnoreCase(base, "dd")) {
        while (it.next()) |tok| {
            if (std.mem.startsWith(u8, tok, "of=") and std.mem.startsWith(u8, tok["of=".len..], "/dev/")) return true;
        }
        return false;
    }
    if (eqlIgnoreCase(base, "cryptsetup")) {
        const sub = it.next() orelse return false;
        return std.mem.eql(u8, sub, "luksFormat") or std.mem.eql(u8, sub, "luksErase") or std.mem.eql(u8, sub, "erase");
    }
    return false;
}

fn isSystemCommand(base: []const u8, it: anytype) bool {
    if (eqlIgnoreCase(base, "chkdsk")) {
        while (it.next()) |tok| {
            if (std.mem.eql(u8, tok, "/f") or std.mem.eql(u8, tok, "/F")) return true;
        }
        return false;
    }
    // Only consume the subcommand for the reg/sc/net families (other commands
    // must not advance the iterator — later rules read the same token stream).
    if (eqlIgnoreCase(base, "reg") or eqlIgnoreCase(base, "sc") or eqlIgnoreCase(base, "net")) {
        const sub = it.next() orelse return false;
        if (eqlIgnoreCase(base, "reg")) {
            return eqlIgnoreCase(sub, "delete") or eqlIgnoreCase(sub, "del");
        }
        if (eqlIgnoreCase(base, "sc")) {
            return eqlIgnoreCase(sub, "delete") or eqlIgnoreCase(sub, "config");
        }
        return eqlIgnoreCase(sub, "user") or eqlIgnoreCase(sub, "localgroup");
    }
    return false;
}

/// Per-rule git text: force push / hard reset / clean with force.
fn gitRule(base: []const u8, it: anytype) ?[]const u8 {
    if (!eqlIgnoreCase(base, "git")) return null;
    const sub = it.next() orelse return null;
    if (eqlIgnoreCase(sub, "push")) {
        while (it.next()) |tok| {
            if (hasForce(tok)) return GIT_PUSH_RULE;
        }
        return null;
    }
    if (eqlIgnoreCase(sub, "reset")) {
        while (it.next()) |tok| {
            if (std.mem.startsWith(u8, tok, "--hard")) return GIT_RESET_RULE;
        }
        return null;
    }
    if (eqlIgnoreCase(sub, "clean")) {
        while (it.next()) |tok| {
            if (hasForce(tok)) return GIT_CLEAN_RULE;
        }
        return null;
    }
    return null;
}

/// Short flag group (`-rf` / `-R` / `-Fo`) or exact long name (`--force` /
/// `-force`), or cmd `/q` style. Long options never match by prefix
/// (`--force-with-lease` is a different, safer option).
fn hasForce(tok: []const u8) bool {
    if (isShortFlagGroup(tok)) {
        for (tok[1..]) |c| {
            if (std.ascii.toLower(c) == 'f') return true;
        }
        return false;
    }
    if (std.mem.eql(u8, tok, "--force") or std.mem.eql(u8, tok, "-force")) return true;
    if (std.mem.eql(u8, tok, "/q") or std.mem.eql(u8, tok, "/Q")) return true;
    return false;
}

/// A `-`-prefixed token that is not `--...` and longer than 1 char.
fn isShortFlagGroup(tok: []const u8) bool {
    return tok.len > 1 and tok[0] == '-' and tok[1] != '-';
}

fn isWrapperName(base: []const u8) bool {
    return eqlIgnoreCase(base, "sudo") or eqlIgnoreCase(base, "env") or
        eqlIgnoreCase(base, "nice") or eqlIgnoreCase(base, "exec") or
        eqlIgnoreCase(base, "command");
}

fn isVarAssign(tok: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, tok, '=') orelse return false;
    if (eq == 0) return false;
    for (tok[0..eq]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

fn baseName(tok: []const u8) []const u8 {
    var i: usize = tok.len;
    while (i > 0) {
        i -= 1;
        if (tok[i] == '/' or tok[i] == '\\') return tok[i + 1 ..];
    }
    return tok;
}

fn eqlIgnoreCase(x: []const u8, y: []const u8) bool {
    return std.ascii.eqlIgnoreCase(x, y);
}

/// L1 pipe rule: quote-aware byte scan; after a `|` (outside quotes), the next
/// command may be sh/bash/dash with optional wrapper words (any command piped
/// to a shell executes the script — intentional over-coverage).
fn hasPipeToShell(command: []const u8) bool {
    var i: usize = 0;
    while (i < command.len) {
        const c = command[i];
        if (c == '\'') {
            i += 1;
            while (i < command.len and command[i] != '\'') i += 1;
            if (i < command.len) i += 1;
            continue;
        }
        if (c == '"') {
            i += 1;
            while (i < command.len and command[i] != '"') i += 1;
            if (i < command.len) i += 1;
            continue;
        }
        if (c == '|') {
            var j = i + 1;
            while (j < command.len and isSpace(command[j])) j += 1;
            if (isPipeTarget(command[j..])) return true;
            i = j;
            continue;
        }
        i += 1;
    }
    return false;
}

fn isPipeTarget(rest: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, rest, " \t");
    var pending_opt_value = false;
    while (it.next()) |tok| {
        if (pending_opt_value) {
            pending_opt_value = false;
            continue;
        }
        const base = baseName(tok);
        if (isWrapperName(base)) continue;
        if (isVarAssign(tok)) continue;
        if (tok.len > 0 and tok[0] == '-') {
            if (std.mem.eql(u8, tok, "-u") or std.mem.eql(u8, tok, "-U") or
                std.mem.eql(u8, tok, "-g") or std.mem.eql(u8, tok, "-G"))
            {
                pending_opt_value = true;
            }
            continue;
        }
        return isShellToken(base);
    }
    return false;
}

/// `sh` / `bash` / `dash` with only boundary chars (`;` `&` `|` or end)
/// after the name — prevents `|shell`/`|shx` prefix false positives.
fn isShellToken(tok: []const u8) bool {
    const shells = [_][]const u8{ "sh", "bash", "dash" };
    for (shells) |s| {
        if (tok.len >= s.len and std.mem.eql(u8, tok[0..s.len], s)) {
            const after = tok[s.len..];
            if (after.len == 0) return true;
            var ok = true;
            for (after) |ch| {
                if (ch != ';' and ch != '&' and ch != '|') {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
    }
    return false;
}

/// Unified denial wording (CLI/Web shared). Caller owns the returned slice.
/// `rule` is embedded as-is (already final text, never user input).
pub fn messageFor(allocator: std.mem.Allocator, decision: Decision, rule: ?[]const u8) ![]const u8 {
    const r = rule orelse "";
    return switch (decision) {
        .denied => std.fmt.allocPrint(allocator, "User denied this tool call ({s}). This rejection is final for this command — do NOT retry it or work around it by rephrasing flags; adjust your approach.", .{r}),
        .timeout => std.fmt.allocPrint(allocator, "Tool call auto-denied: approval timed out ({s}). It was not explicitly rejected by the user — you may retry this exact command later or ask the user.", .{r}),
        .aborted => std.fmt.allocPrint(allocator, "Tool call aborted: the connection was interrupted while awaiting approval ({s}). It was NOT denied by the user.", .{r}),
    };
}

/// Prefix of the model-visible approval policy notice (system message).
/// Frontends use it to keep the notice idempotent across turns.
pub const POLICY_PREFIX = "Tool approval policy:";

/// Model-visible policy notice per mode (SystemPromptCb injection).
/// never → null (no injection). Static strings.
pub fn policyNotice(mode: Mode) ?[]const u8 {
    return switch (mode) {
        .never => null,
        .risky => POLICY_PREFIX ++ " destructive commands (recursive delete / device wipe / force git / pipe-exec / system mutation) require user approval once per exact command; a denial is final for that command. Coverage is a closed lexical rule set applying only to the bash tool. Guards are lexical — shell variable indirection / command substitution / backticks can bypass them; do not rely on them as a security boundary.",
        .always => POLICY_PREFIX ++ " all tool calls require approval. Guards are lexical — shell variable indirection / command substitution / backticks can bypass them; do not rely on them as a security boundary.",
    };
}

fn nowRealMs(io: Io) i64 {
    return @as(i64, @intCast(Io.Timestamp.toMilliseconds(Io.Clock.Timestamp.now(io, .real).raw)));
}

fn sleepMs(ms: u32) void {
    if (builtin.os.tag == .windows) {
        const kernel32 = struct {
            extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.c) void;
        };
        kernel32.Sleep(ms);
    } else {
        const timespec = extern struct {
            tv_sec: i64,
            tv_nsec: i64,
        };
        const c = struct {
            extern "c" fn nanosleep(rqtp: *const timespec, rmtp: ?*timespec) c_int;
        };
        const ts = timespec{
            .tv_sec = @intCast(ms / 1000),
            .tv_nsec = @intCast((ms % 1000) * 1_000_000),
        };
        _ = c.nanosleep(&ts, null);
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "approval: mode fromString/toString roundtrip" {
    try std.testing.expectEqual(Mode.never, Mode.fromString("never").?);
    try std.testing.expectEqual(Mode.risky, Mode.fromString("risky").?);
    try std.testing.expectEqual(Mode.always, Mode.fromString("always").?);
    try std.testing.expectEqual(@as(?Mode, null), Mode.fromString("bogus"));
    try std.testing.expectEqualStrings("risky", Mode.risky.toString());
}

/// Test args builder: runtime JSON wrapper with escaping (single-threaded tests).
var args_buf: [4096]u8 = undefined;
fn a(command: []const u8) []const u8 {
    var pos: usize = 0;
    const head = "{\"command\":\"";
    @memcpy(args_buf[0..head.len], head);
    pos = head.len;
    for (command) |c| {
        if (c == '"' or c == '\\') {
            args_buf[pos] = '\\';
            pos += 1;
        }
        args_buf[pos] = c;
        pos += 1;
    }
    const tail = "\"}";
    @memcpy(args_buf[pos .. pos + tail.len], tail);
    pos += tail.len;
    return args_buf[0..pos];
}

test "approval: never/always modes short-circuit" {
    try std.testing.expectEqual(@as(?[]const u8, null), isRisky(.never, "bash", a("rm -rf /")));
    try std.testing.expectEqualStrings(ALWAYS_RULE, isRisky(.always, "write", "{}").?);
    try std.testing.expectEqualStrings(ALWAYS_RULE, isRisky(.always, "bash", a("echo hi")).?);
}

test "approval: risky only covers bash" {
    try std.testing.expectEqual(@as(?[]const u8, null), isRisky(.risky, "write", "{}"));
    try std.testing.expectEqual(@as(?[]const u8, null), isRisky(.risky, "edit", "{}"));
    try std.testing.expectEqualStrings(RM_RULE, isRisky(.risky, "bash", a("rm -rf x")).?);
}

test "approval: recursive delete variants all hit" {
    const variants = [_][]const u8{
        "rm -rf /tmp/x",
        "rm -fr /tmp/x",
        "rm -r -f /tmp/x",
        "rm --recursive --force /tmp/x",
        "rm -rF /tmp/x",
        "rm -R -f /tmp/x",
        "RM -RF /tmp/x",
        "Remove-Item -Recurse -Force x",
        "Remove-Item -R -Fo x",
        "Remove-Item -recurse -force x",
        "rmdir /s /q x",
        "del /s /q x",
        "/bin/rm -rf /tmp/x",
        "sudo rm -rf /tmp/x",
        "sudo -u root rm -rf /tmp/x",
        "env VAR=1 rm -rf /tmp/x",
        "/usr/bin/env rm -rf /tmp/x",
        "nice rm -rf /tmp/x",
        "exec rm -rf /tmp/x",
        "command rm -rf /tmp/x",
    };
    for (variants) |v| {
        try std.testing.expectEqualStrings(RM_RULE, isRisky(.risky, "bash", a(v)).?);
    }
}

test "approval: non-recursive delete not hit (L2)" {
    const variants = [_][]const u8{
        "rm /tmp/file.txt",
        "rm -f /tmp/file.txt",
        "Remove-Item file",
        "del file.txt",
    };
    for (variants) |v| {
        try std.testing.expectEqual(@as(?[]const u8, null), isRisky(.risky, "bash", a(v)));
    }
}

test "approval: git destructive variants all hit with per-rule text" {
    const hits = [_]struct { cmd: []const u8, rule: []const u8 }{
        .{ .cmd = "git push --force origin dev", .rule = GIT_PUSH_RULE },
        .{ .cmd = "git push -f origin dev", .rule = GIT_PUSH_RULE },
        .{ .cmd = "/usr/bin/git push --force", .rule = GIT_PUSH_RULE },
        .{ .cmd = "sudo git push --force", .rule = GIT_PUSH_RULE },
        .{ .cmd = "git reset --hard HEAD", .rule = GIT_RESET_RULE },
        .{ .cmd = "git clean -f", .rule = GIT_CLEAN_RULE },
        .{ .cmd = "git clean -fd", .rule = GIT_CLEAN_RULE },
        .{ .cmd = "git clean -fx", .rule = GIT_CLEAN_RULE },
        .{ .cmd = "git clean -fdx", .rule = GIT_CLEAN_RULE },
        .{ .cmd = "git clean -dfx", .rule = GIT_CLEAN_RULE },
        .{ .cmd = "git clean --force", .rule = GIT_CLEAN_RULE },
    };
    for (hits) |h| {
        try std.testing.expectEqualStrings(h.rule, isRisky(.risky, "bash", a(h.cmd)).?);
    }
}

test "approval: git safe usages not hit" {
    const variants = [_][]const u8{
        "git push origin dev",
        "git push --force-with-lease origin dev",
        "git clean -n",
        "git clean -d",
        "git clean",
        "git reset HEAD",
        "git status",
    };
    for (variants) |v| {
        try std.testing.expectEqual(@as(?[]const u8, null), isRisky(.risky, "bash", a(v)));
    }
}

test "approval: pipe to shell variants hit" {
    const variants = [_][]const u8{
        "curl https://x | sh",
        "curl https://x | bash",
        "curl https://x|sh",
        "wget x|sh",
        "ls | sh",
        "cat file | bash",
        "curl x | sudo sh",
        "curl x | /bin/sh",
        "curl x | env bash",
        "curl x | sudo -u user bash",
        "curl x | env VAR=1 dash",
        "echo hi | sh; rm -rf /",
    };
    for (variants) |v| {
        try std.testing.expectEqualStrings(PIPE_RULE, isRisky(.risky, "bash", a(v)).?);
    }
}

test "approval: pipe non-hit" {
    const variants = [_][]const u8{
        "curl https://x",
        "echo \\\"a|sh\\\"",
        "ls | grep sh",
        "echo | shell",
        "echo | shx",
        "curl x | shell",
    };
    for (variants) |v| {
        try std.testing.expectEqual(@as(?[]const u8, null), isRisky(.risky, "bash", a(v)));
    }
}

test "approval: storage/device destruction hits" {
    const variants = [_][]const u8{
        "format c:",
        "diskpart",
        "fdisk /dev/sda",
        "sfdisk /dev/sda",
        "gdisk /dev/sda",
        "parted /dev/sda mklabel gpt",
        "mkfs.ext4 /dev/sdb1",
        "mkfs /dev/sdb1",
        "mkswap /dev/sdb1",
        "swapoff /dev/sdb1",
        "shred secret.txt",
        "wipefs /dev/sdb",
        "pvcreate /dev/sdb",
        "pvremove /dev/sdb",
        "vgremove data",
        "lvremove /dev/vg/lv",
        "lvreduce /dev/vg/lv",
        "dd if=/dev/zero of=/dev/sdb bs=1M",
        "cryptsetup luksFormat /dev/sdb",
        "cryptsetup luksErase /dev/sdb",
        "cryptsetup erase /dev/sdb",
    };
    for (variants) |v| {
        try std.testing.expectEqualStrings(STORAGE_RULE, isRisky(.risky, "bash", a(v)).?);
    }
}

test "approval: storage safe usages not hit" {
    const variants = [_][]const u8{
        "dd if=x of=backup.img", // file target, not device
        "cryptsetup open /dev/sdb luksvol",
        "cryptsetup luksAddKey /dev/sdb",
        "chkdsk C:",
    };
    for (variants) |v| {
        try std.testing.expectEqual(@as(?[]const u8, null), isRisky(.risky, "bash", a(v)));
    }
}

test "approval: system mutation hits" {
    const variants = [_][]const u8{
        "reg delete HKLM\\Software\\x",
        "reg del HKLM\\Software\\x",
        "sc delete service1",
        "sc config service1 start= disabled",
        "net user hacker /add",
        "net localgroup Administrators hacker /add",
        "chkdsk C: /f",
    };
    for (variants) |v| {
        try std.testing.expectEqualStrings(SYSTEM_RULE, isRisky(.risky, "bash", a(v)).?);
    }
}

test "approval: system safe usages not hit" {
    const variants = [_][]const u8{
        "reg query HKLM\\Software",
        "sc query service1",
        "net view",
        "chkdsk C:",
    };
    for (variants) |v| {
        try std.testing.expectEqual(@as(?[]const u8, null), isRisky(.risky, "bash", a(v)));
    }
}

test "approval: L0 dynamic signals hit (fail-closed)" {
    const variants = [_][]const u8{
        "rm -rf $(pwd)/x",
        "eval $(cat x)",
        "git clean -fdx $(list)",
        "dd if=`which dd` of=/dev/sdb",
        "ls ${DIR} && rm -rf /tmp/x",
        "cmd=rm; $cmd -rf /tmp/x",
        "x=1; $x -rf /",
        "echo a && $VAR -rf /tmp/x",
    };
    for (variants) |v| {
        try std.testing.expectEqualStrings(L0_RULE, isRisky(.risky, "bash", a(v)).?);
    }
}

test "approval: direct variable reference not L0" {
    const variants = [_][]const u8{
        "echo $HOME",
        "x=1; echo $x",
        "ls $DIR",
    };
    for (variants) |v| {
        try std.testing.expectEqual(@as(?[]const u8, null), isRisky(.risky, "bash", a(v)));
    }
}

test "approval: malformed args JSON fails closed" {
    try std.testing.expectEqualStrings(L0_RULE, isRisky(.risky, "bash", "not json").?);
}

test "approval: messageFor three-way wording" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();

    const denied = try messageFor(al, .denied, RM_RULE);
    try std.testing.expect(std.mem.indexOf(u8, denied, "User denied") != null);
    try std.testing.expect(std.mem.indexOf(u8, denied, "final for this command") != null);
    try std.testing.expect(std.mem.indexOf(u8, denied, "do NOT retry") != null);

    const timeout = try messageFor(al, .timeout, RM_RULE);
    try std.testing.expect(std.mem.indexOf(u8, timeout, "auto-denied") != null);
    try std.testing.expect(std.mem.indexOf(u8, timeout, "may retry") != null);

    const aborted = try messageFor(al, .aborted, RM_RULE);
    try std.testing.expect(std.mem.indexOf(u8, aborted, "NOT denied") != null);

    const no_rule = try messageFor(al, .denied, null);
    try std.testing.expect(std.mem.indexOf(u8, no_rule, "()") != null);
}

test "approval: policyNotice per mode" {
    try std.testing.expectEqual(@as(?[]const u8, null), policyNotice(.never));
    const risky = policyNotice(.risky).?;
    try std.testing.expect(std.mem.startsWith(u8, risky, POLICY_PREFIX));
    try std.testing.expect(std.mem.indexOf(u8, risky, "require user approval") != null);
    const always = policyNotice(.always).?;
    try std.testing.expect(std.mem.indexOf(u8, always, "all tool calls require approval") != null);
}

test "approval: Gate starts pending, resolve transitions once" {
    var gate = Gate.init(std.testing.io, "g1", "s1", 0);
    try std.testing.expectEqual(GateState.pending, gate.current());
    try std.testing.expect(gate.resolve(true));
    try std.testing.expectEqual(GateState.approved, gate.current());
    try std.testing.expect(!gate.resolve(true));
    try std.testing.expect(!gate.resolve(false));
}

var test_abort_flag = false;
fn testCheckAbort() bool {
    return test_abort_flag;
}

test "approval: Gate wait respects check_abort" {
    test_abort_flag = false;
    var gate = Gate.init(std.testing.io, "g2", "s1", 0);
    test_abort_flag = true;
    try std.testing.expectEqual(GateState.aborted, gate.wait(500, &testCheckAbort, null, null));
}

var test_ka_calls: u32 = 0;
fn testKeepaliveOk() bool {
    test_ka_calls += 1;
    return true;
}

test "approval: Gate wait returns approved on resolve" {
    test_abort_flag = false;
    var gate = Gate.init(std.testing.io, "g3", "s1", 0);
    const t = std.Thread.spawn(.{}, struct {
        fn run(g: *Gate) void {
            sleepMs(300);
            _ = g.resolve(true);
        }
    }.run, .{&gate}) catch unreachable;
    try std.testing.expectEqual(GateState.approved, gate.wait(5000, &testCheckAbort, null, null));
    t.join();
}

var test_ka_fail: bool = false;
fn testKeepaliveFail() bool {
    return !test_ka_fail;
}

test "approval: Gate wait aborts when keepalive fails" {
    test_ka_fail = true;
    test_ka_calls = 0;
    test_abort_flag = false;
    var gate = Gate.init(std.testing.io, "g4", "s1", 0);
    try std.testing.expectEqual(GateState.aborted, gate.wait(400, &testCheckAbort, &testKeepaliveFail, null));
}

test "approval: Gate keepalive called periodically" {
    test_ka_fail = false;
    test_ka_calls = 0;
    test_abort_flag = false;
    var gate = Gate.init(std.testing.io, "g5", "s1", 0);
    // resolve after ~350ms; keepalive interval = timeout/4 = 100ms → several calls
    const t = std.Thread.spawn(.{}, struct {
        fn run(g: *Gate) void {
            sleepMs(350);
            _ = g.resolve(true);
        }
    }.run, .{&gate}) catch unreachable;
    _ = gate.wait(400, &testCheckAbort, &testKeepaliveOk, null);
    t.join();
    try std.testing.expect(test_ka_calls >= 1);
}

var test_rm_calls: u32 = 0;
var test_rm_ok: bool = true;
fn testReminder() bool {
    test_rm_calls += 1;
    return test_rm_ok;
}

test "approval: Gate reminder fires once at timeout/2, timeout denies" {
    test_rm_calls = 0;
    test_rm_ok = true;
    test_abort_flag = false;
    var gate = Gate.init(std.testing.io, "g6", "s1", 0);
    try std.testing.expectEqual(GateState.denied, gate.wait(300, &testCheckAbort, null, &testReminder));
    try std.testing.expectEqual(@as(u32, 1), test_rm_calls);
    try std.testing.expect(gate.timed_out);
}

test "approval: Gate reminder failure aborts" {
    test_rm_calls = 0;
    test_rm_ok = false;
    test_abort_flag = false;
    var gate = Gate.init(std.testing.io, "g7", "s1", 0);
    try std.testing.expectEqual(GateState.aborted, gate.wait(300, &testCheckAbort, null, &testReminder));
}

test "approval: Gate wait returns existing terminal state immediately" {
    test_abort_flag = false;
    var gate = Gate.init(std.testing.io, "g8", "s1", 0);
    _ = gate.resolve(false);
    try std.testing.expectEqual(GateState.denied, gate.wait(300, &testCheckAbort, null, null));
    try std.testing.expect(!gate.timed_out);
}
