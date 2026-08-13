const std = @import("std");
const types = @import("../types.zig");
const provider_mod = @import("../io/provider.zig");
const session_mod = @import("session.zig");
const log = @import("../util/log.zig");

const Io = std.Io;

/// Default recent-context token budget kept after compaction.
pub const DEFAULT_KEEP_RECENT_TOKENS: u32 = 20000;
/// Minimum number of real messages (excluding the system prompt) kept after
/// compaction — the token budget may keep more, never fewer.
pub const MIN_KEEP_MESSAGES: usize = 20;
/// Prefix of the compaction summary system message written to the session.
pub const COMPACTION_PREFIX = "[Compaction] ";

/// Estimate tokens for a message with a chars/4 heuristic (content + reasoning).
/// Conservative overestimate; used for the token-budget keep cut point only.
pub fn estimateTokens(msg: types.Message) u32 {
    var total: u32 = @intCast(msg.content.len / 4);
    if (msg.reasoning_content) |rc| total += @intCast(rc.len / 4);
    return total;
}

/// Compute the first message index to keep after compaction.
///
/// Keeps the tail until its accumulated estimated tokens reach
/// `keep_recent_tokens` (walking newest→oldest), but never keeps fewer than
/// `MIN_KEEP_MESSAGES` real messages. The cut never lands on a tool message
/// (a tool result must stay with its assistant turn); walking back over tools
/// keeps them with the preceding message. Returns 1 when nothing is
/// compressible (messages ≤ MIN_KEEP + system prompt).
pub fn computeKeepStart(msgs: []const types.Message, keep_recent_tokens: u32) usize {
    if (msgs.len <= MIN_KEEP_MESSAGES + 1) return 1;

    var keep_start: usize = msgs.len;
    var acc: u32 = 0;
    var i: usize = msgs.len;
    while (i > 1 and acc < keep_recent_tokens) {
        i -= 1;
        acc += estimateTokens(msgs[i]);
        keep_start = i;
    }

    const min_start = msgs.len - MIN_KEEP_MESSAGES;
    if (keep_start > min_start) keep_start = min_start;

    while (keep_start > 1 and msgs[keep_start].role == .tool) keep_start -= 1;
    return keep_start;
}

/// Find the summary text of the last `[Compaction]` system message (the
/// previous compaction), if any. Used for iterative summary updates.
pub fn findPreviousSummary(msgs: []const types.Message) ?[]const u8 {
    var i: usize = msgs.len;
    while (i > 0) {
        i -= 1;
        const m = msgs[i];
        if (m.role == .system and std.mem.startsWith(u8, m.content, COMPACTION_PREFIX)) {
            return m.content[COMPACTION_PREFIX.len..];
        }
    }
    return null;
}

const SUMMARIZATION_PROMPT =
    \\Summarize the conversation history before the most recent messages. Preserve:
    \\- the user's goals and any explicit constraints or preferences
    \\- key decisions and their rationale
    \\- exact file paths, function names, and error messages
    \\- open questions and next steps
    \\Use this EXACT structure:
    \\## Goal
    \\[What is the user trying to accomplish?]
    \\
    \\## Progress
    \\### Done / ### In Progress / ### Blocked
    \\
    \\## Key Decisions
    \\- **[Decision]**: [rationale]
    \\
    \\## Next Steps
    \\1. [ordered list]
    \\
    \\## Critical Context
    \\- [data/examples/references needed to continue]
    \\Keep each section concise. This summary will replace the summarized messages.
;

const UPDATE_SUMMARIZATION_PROMPT =
    \\The messages above are NEW conversation messages to incorporate into the
    \\existing summary provided in <previous-summary> tags. RULES:
    \\- PRESERVE all existing information from the previous summary
    \\- ADD new progress, decisions, and context from the new messages
    \\- MOVE "In Progress" items to "Done" when completed
    \\- UPDATE "Next Steps" based on what was accomplished
    \\- PRESERVE exact file paths, function names, and error messages
    \\Keep the EXACT structure: ## Goal / ## Progress / ## Key Decisions /
    \\## Next Steps / ## Critical Context. This merged summary will replace
    \\both the previous summary and the new messages.
;

/// Build the user summarization prompt. With a previous summary present, wrap
/// it in `<previous-summary>` tags and switch to the update prompt so the LLM
/// merges instead of discarding history.
fn buildSummarizationPrompt(arena: std.mem.Allocator, previous: ?[]const u8) ![]const u8 {
    if (previous) |p| {
        return std.fmt.allocPrint(arena,
            \\<previous-summary>
            \\{s}
            \\</previous-summary>
            \\
            \\{s}
        , .{ p, UPDATE_SUMMARIZATION_PROMPT });
    }
    return arena.dupe(u8, SUMMARIZATION_PROMPT);
}

/// LLM-summarize older messages of the session and replace them with a single
/// `[Compaction]` system message, keeping the recent tail (token-budget +
/// MIN_KEEP_MESSAGES, tool-boundary safe).
///
/// On success the summary message id is recorded on `session.last_compact_id`
/// (stale-usage guard for auto-trigger) and the session is flushed.
///
/// Returns:
/// - `true`  — a compaction happened (old messages replaced by a summary)
/// - `false` — nothing to compress (messages ≤ MIN_KEEP + system prompt)
/// - LLM summarization errors propagate to the caller (auto-trigger degrades to
///   a warning; the manual endpoint surfaces them as an error response).
pub fn compactSession(
    provider: *provider_mod.Provider,
    session: *session_mod.Session,
    allocator: std.mem.Allocator,
    io: Io,
    keep_recent_tokens: u32,
) !bool {
    // Summarization is a content-comprehension task, not a deep-reasoning one.
    // Disable thinking for this call: measured 61% fewer completion tokens with
    // ~identical summary length (reasoning 727/1174 = 62% was pure overhead).
    // Save/restore because compactSession shares the main provider (unlike the
    // title sub-call which holds an independent copy).
    const saved_thinking = provider.config.compat.thinking_level;
    provider.config.compat.thinking_level = .none;
    defer provider.config.compat.thinking_level = saved_thinking;

    const msgs = session.messages();
    const keep_start = computeKeepStart(msgs, keep_recent_tokens);
    if (keep_start <= 1) return false;

    log.dbg(0, 0, "compaction_start", "msgs={d} keep_from={d}", .{ msgs.len, keep_start });

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Messages to summarize: everything before the keep cut except the system
    // prompt and any previous [Compaction] summary (it feeds the update prompt).
    var sum_msgs: std.ArrayListAligned(types.Message, null) = .empty;
    defer sum_msgs.deinit(arena);
    for (msgs[1..keep_start]) |m| {
        if (m.role == .system and std.mem.startsWith(u8, m.content, COMPACTION_PREFIX)) continue;
        try sum_msgs.append(arena, m);
    }
    const previous = findPreviousSummary(msgs[1..keep_start]);
    const prompt = try buildSummarizationPrompt(arena, previous);
    try sum_msgs.append(arena, .{ .role = .user, .content = prompt });

    const resp = try provider.chatCompletionStreaming(&arena_state, io, sum_msgs.items, null, null);
    const summary = resp.content orelse "";

    var new_msgs: std.ArrayListAligned(types.Message, null) = .empty;
    defer new_msgs.deinit(arena);
    try new_msgs.append(arena, msgs[0]); // system prompt stays
    const compact_content = try std.fmt.allocPrint(arena, "{s}{s}", .{ COMPACTION_PREFIX, summary });
    const compact_id = session.allocateMessageId();
    try new_msgs.append(arena, .{ .id = compact_id, .role = .system, .content = compact_content });
    for (msgs[keep_start..]) |m| try new_msgs.append(arena, m);

    try session.replaceMessages(new_msgs.items);
    session.last_compact_id = compact_id;
    try session.flush();
    log.biz_info(0, 0, "compaction_end", "kept={d} summary_len={d}", .{ msgs.len - keep_start + 1, summary.len });
    return true;
}

test "compact: estimateTokens sums content and reasoning" {
    const msg = types.Message{ .id = 1, .role = .assistant, .content = "abcdefgh", .reasoning_content = "ijklmnop" };
    try std.testing.expectEqual(@as(u32, 2 + 2), estimateTokens(msg));
    try std.testing.expectEqual(@as(u32, 3), estimateTokens(.{ .id = 2, .role = .user, .content = "abcdefghijkl" }));
}

test "compact: computeKeepStart returns 1 when not enough messages" {
    const msgs = [_]types.Message{.{ .id = 1, .role = .system, .content = "sys" }} ++
        [_]types.Message{.{ .id = 2, .role = .user, .content = "u" }} ** 20;
    try std.testing.expectEqual(@as(usize, 1), computeKeepStart(&msgs, 20000));
}

test "compact: computeKeepStart floors at MIN_KEEP when budget keeps too few" {
    // 30 msgs: sys + 19 short + 10 huge (3000 tokens each). Budget cut lands at
    // index 23 (keeps 7), the MIN_KEEP floor forces keeping 20 real messages →
    // keep_start = 30 - 20 = 10.
    var msgs: [30]types.Message = undefined;
    msgs[0] = .{ .id = 0, .role = .system, .content = "sys" };
    for (1..20) |i| msgs[i] = .{ .id = @intCast(i), .role = .user, .content = "x" };
    const big = "a" ** 12000;
    for (20..30) |i| msgs[i] = .{ .id = @intCast(i), .role = .assistant, .content = big };
    try std.testing.expectEqual(@as(usize, 10), computeKeepStart(&msgs, 20000));
}

test "compact: computeKeepStart token budget keeps more than floor" {
    // 40 msgs, all medium (600 tokens each): tail accumulates 20000 at index 6,
    // keeping 34 messages — exceeds the 20-message floor, so the budget decides.
    var msgs: [40]types.Message = undefined;
    msgs[0] = .{ .id = 0, .role = .system, .content = "sys" };
    const med = "a" ** 2400;
    for (1..40) |i| msgs[i] = .{ .id = @intCast(i), .role = .user, .content = med };
    try std.testing.expectEqual(@as(usize, 6), computeKeepStart(&msgs, 20000));
}

test "compact: computeKeepStart never cuts on a tool message" {
    // Tail: assistant then tool. Token budget would cut exactly at the tool.
    var msgs: [41]types.Message = undefined;
    msgs[0] = .{ .id = 0, .role = .system, .content = "sys" };
    for (1..31) |i| msgs[i] = .{ .id = @intCast(i), .role = .user, .content = "x" };
    const big = "a" ** 100000;
    msgs[31] = .{ .id = 31, .role = .assistant, .content = "tool call lead" };
    msgs[32] = .{ .id = 32, .role = .tool, .content = big };
    for (33..41) |i| msgs[i] = .{ .id = @intCast(i), .role = .user, .content = "y" };
    // Budget cut lands on index 32 (tool) → must walk back to 31.
    const keep_start = computeKeepStart(&msgs, 20000);
    try std.testing.expect(keep_start <= 31);
    try std.testing.expect(msgs[keep_start].role != .tool);
}

test "compact: findPreviousSummary returns last compaction summary" {
    const msgs = [_]types.Message{
        .{ .id = 1, .role = .system, .content = "sys" },
        .{ .id = 2, .role = .user, .content = "u1" },
        .{ .id = 3, .role = .system, .content = "[Compaction] first summary" },
        .{ .id = 4, .role = .user, .content = "u2" },
        .{ .id = 5, .role = .system, .content = "[Compaction] second summary" },
    };
    const s = findPreviousSummary(&msgs).?;
    try std.testing.expectEqualStrings("second summary", s);
    try std.testing.expect(findPreviousSummary(msgs[0..2]) == null);
}

test "compact: buildSummarizationPrompt wraps previous summary iteratively" {
    const allocator = std.testing.allocator;
    const with_prev = try buildSummarizationPrompt(allocator, "old summary");
    defer allocator.free(with_prev);
    try std.testing.expect(std.mem.indexOf(u8, with_prev, "<previous-summary>") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_prev, "old summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_prev, UPDATE_SUMMARIZATION_PROMPT) != null);

    const no_prev = try buildSummarizationPrompt(allocator, null);
    defer allocator.free(no_prev);
    try std.testing.expectEqualStrings(SUMMARIZATION_PROMPT, no_prev);
}

test "compact: compactSession no-ops without calling the LLM when too few messages" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var sess = try session_mod.Session.init(allocator, io, "test-model");
    defer sess.deinit();
    try sess.append(.{ .role = .system, .content = "sys" });
    for (0..20) |_| try sess.append(.{ .role = .user, .content = "u" });

    var p = provider_mod.Provider{
        .config = .{
            .base_url = "https://api.test.com",
            .api_key = "",
            .model = "test-model",
            .max_tokens = 1000,
            .vendor = .standard,
            .compat = .{},
        },
    };

    // 21 messages (≤ MIN_KEEP + 1) → no compressible history; must return false
    // without touching the provider.
    try std.testing.expect(!try compactSession(&p, &sess, allocator, io, 20000));
    try std.testing.expectEqual(@as(usize, 21), sess.messages().len);
}
