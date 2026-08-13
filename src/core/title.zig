const std = @import("std");
const types = @import("../types.zig");
const provider_mod = @import("../io/provider.zig");
const session_mod = @import("session.zig");
const log = @import("../util/log.zig");

const Io = std.Io;

/// Title length cap from the title prompt (title.txt: `<=50 characters`).
pub const TITLE_MAX_CHARS: usize = 50;
/// Hard truncation cap for cleaned LLM titles (opencode truncates >100 → 97+"...").
pub const TITLE_HARD_CAP: usize = 100;
/// Static fallback prefix length (L3). MUST equal Web is_new prompt-prefix
/// (handler.zig:958 `@min(prompt.len, 30)`) — shared via this constant.
pub const TITLE_PREFIX_LEN: usize = 30;
/// Keyword extraction token range (L2): keep the first 3-5 non-stopword tokens.
pub const KEYWORD_MIN: usize = 3;
pub const KEYWORD_MAX: usize = 5;
/// Stopwords filtered by L2 keyword extraction. Conservative core — only
/// words that are stopwords in EVERY domain (pronouns/particles/English
/// function words). Domain-specific words (e.g. "修"/"修复" in tech chats)
/// must NOT be here — they belong in the user's `title_stop_words` config.
pub const STOPWORDS = [_][]const u8{
    "的", "了", "是", "我", "你", "他", "帮", "请", "一个", "在", "用",
    "the", "a", "an", "to", "of", "and", "or", "for", "with", "please",
};

const TITLE_PROMPT =
    \\You are a title generator. You output ONLY a thread title. Nothing else.
    \\Generate a brief title that would help the user find this conversation later.
    \\- A single line, <=50 characters, no explanations
    \\- Use the same language as the user message
    \\- Never include tool names
    \\- Focus on the main topic or question the user needs to retrieve
    \\- Keep exact: technical terms, numbers, filenames, HTTP codes
    \\- If the message is short or conversational (e.g. "hello"), reflect its tone
    \\  (such as Greeting, Quick check-in, Light chat)
    \\- NEVER respond to questions, just generate a title
;

/// Guard: should the session auto-title run? All conditions must hold:
/// 0. switch enabled (D5)
/// 1. no parent_id (fork children keep `(fork #N)`)
/// 2. title is still default ("New Session" / UUID / the Web prompt-prefix)
/// 3. exactly 2 real user messages (second turn, D1)
pub fn shouldAutoTitle(session: *session_mod.Session, auto_title: bool) bool {
    if (!auto_title) return false;
    if (session.parent_id != null) return false;
    if (!isDefaultTitle(session)) return false;

    var user_count: usize = 0;
    for (session.messages()) |m| {
        if (m.role == .user) user_count += 1;
    }
    return user_count == 2;
}

fn isDefaultTitle(session: *session_mod.Session) bool {
    if (std.mem.eql(u8, session.name, session_mod.DEFAULT_SESSION_NAME)) return true;

    // Web empty sessions carry a UUID name shown as "New Session".
    if (isUuid(session.name)) return true;

    // Web is_new heuristic: name == first user message's TITLE_PREFIX_LEN prefix.
    for (session.messages()) |m| {
        if (m.role == .user) {
            const prefix_len = @min(m.content.len, TITLE_PREFIX_LEN);
            if (std.mem.eql(u8, session.name, m.content[0..prefix_len])) return true;
        }
    }
    return false;
}

/// UUID v4 shape: 8-4-4-4-12 hex digits with hyphens.
fn isUuid(name: []const u8) bool {
    if (name.len != 36) return false;
    for (name, 0..) |c, i| {
        const is_hyphen = (i == 8 or i == 13 or i == 18 or i == 23);
        if (is_hyphen) {
            if (c != '-') return false;
        } else {
            if (!std.ascii.isHex(c)) return false;
        }
    }
    return true;
}

/// Strip `<think>` blocks, take the first non-empty trimmed line, then cap to
/// TITLE_HARD_CAP (100 → 97+"..."). Mirrors opencode's title cleaning.
pub fn cleanTitle(raw: []const u8, allocator: std.mem.Allocator) !?[]const u8 {
    // Strip <think>...</think> blocks (non-greedy across lines).
    var cleaned = std.ArrayListAligned(u8, null).empty;
    defer cleaned.deinit(allocator);
    var rest = raw;
    while (std.mem.indexOf(u8, rest, "<think>")) |open_pos| {
        const end_pos = std.mem.indexOf(u8, rest[open_pos..], "</think>") orelse break;
        try cleaned.appendSlice(allocator, rest[0..open_pos]);
        rest = rest[open_pos + end_pos + "</think>".len ..];
    }
    if (cleaned.items.len == 0 and std.mem.indexOf(u8, raw, "<think>") == null) {
        try cleaned.appendSlice(allocator, raw);
    } else if (cleaned.items.len == 0) {
        // Raw was entirely think blocks with no trailing content.
        try cleaned.appendSlice(allocator, rest);
    }

    var lines = std.mem.splitScalar(u8, cleaned.items, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (trimmed.len > TITLE_HARD_CAP) {
            const capped = std.fmt.allocPrint(allocator, "{s}...", .{trimmed[0 .. TITLE_HARD_CAP - 3]}) catch return null;
            return @as(?[]const u8, capped);
        }
        const duped = allocator.dupe(u8, trimmed) catch return null;
        return @as(?[]const u8, duped);
    }
    return null;
}

fn isStopword(word: []const u8, extra: []const []const u8) bool {
    for (STOPWORDS) |s| {
        if (std.mem.eql(u8, s, word)) return true;
    }
    for (extra) |s| {
        if (std.mem.eql(u8, s, word)) return true;
    }
    // CJK imperative/particle prefix: a token like "帮我修" starts with the
    // stopword char "帮"/"我" → filter it. Compare the full first UTF-8
    // character (3 bytes) — byte-prefix comparison is WRONG because many CJK
    // chars share a leading byte (e.g. 是 0xE6.. vs 模 0xE6..).
    if (word.len >= 3 and isCjk(word[0]) and word[1] >= 0x80 and word[2] >= 0x80) {
        const first_char = word[0..3];
        for (STOPWORDS) |s| {
            if (isCjk(s[0]) and std.mem.eql(u8, s, first_char)) return true;
        }
        for (extra) |s| {
            if (isCjk(s[0]) and std.mem.eql(u8, s, first_char)) return true;
        }
    }
    return false;
}

fn isCjk(c: u8) bool {
    return c >= 0x80; // UTF-8 lead byte (CJK multibyte); ASCII content never matches.
}

/// L2 fallback: extract the first KEYWORD_MIN..KEYWORD_MAX non-stopword tokens
/// from the most recent user message and join them. Null when no tokens survive
/// (all stopwords / message too short) → caller falls to L3.
pub fn keywordTitle(user_msg: []const u8, extra_stopwords: []const []const u8, allocator: std.mem.Allocator) !?[]const u8 {
    var tokens: [KEYWORD_MAX][]const u8 = undefined;
    var count: usize = 0;

    var rest = user_msg;
    while (count < KEYWORD_MAX) {
        // Tokenize on whitespace/punctuation.
        var i: usize = 0;
        while (i < rest.len and !isSeparator(rest[i])) i += 1;
        if (i == 0) {
            if (rest.len == 0) break;
            rest = rest[i + 1 ..];
            continue;
        }
        const tok = rest[0..i];
        rest = rest[i..];
        if (isStopword(tok, extra_stopwords)) {
            // Skip separator following the token.
            var j: usize = 0;
            while (j < rest.len and isSeparator(rest[j])) j += 1;
            rest = rest[j..];
            continue;
        }
        tokens[count] = tok;
        count += 1;
        var j: usize = 0;
        while (j < rest.len and isSeparator(rest[j])) j += 1;
        rest = rest[j..];
    }

    if (count < KEYWORD_MIN) return null;

    var buf = std.ArrayListAligned(u8, null).empty;
    defer buf.deinit(allocator);
    for (tokens[0..count], 0..) |tok, idx| {
        if (idx > 0) {
            // Use a comma-space or space join; TITLE_MAX_CHARS caps the result.
            try buf.appendSlice(allocator, " ");
        }
        try buf.appendSlice(allocator, tok);
    }
    if (buf.items.len > TITLE_MAX_CHARS) {
        const capped = buf.items[0..TITLE_MAX_CHARS];
        const out = std.fmt.allocPrint(allocator, "{s}...", .{capped[0 .. TITLE_MAX_CHARS - 3]}) catch return null;
        return @as(?[]const u8, out);
    }
    const duped = allocator.dupe(u8, buf.items) catch return null;
    return @as(?[]const u8, duped);
}

fn isSeparator(c: u8) bool {
    return std.ascii.isWhitespace(c) or c == ',' or c == ';' or c == ':' or
        c == '、' or c == '，' or c == '。' or c == '；' or c == '：';
}

/// L3 fallback: static prefix truncation of the most recent user message.
pub fn fallbackTitle(user_msg: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const trimmed = std.mem.trim(u8, user_msg, " \t\r\n");
    const prefix_len = @min(trimmed.len, TITLE_PREFIX_LEN);
    return allocator.dupe(u8, trimmed[0..prefix_len]);
}

/// Generate a conversation title (sub-agent call, executed on a background
/// thread by SubcallRunner). Caller must have run shouldAutoTitle first.
/// LLM success → LLM title; LLM failure/empty → keywordTitle (L2) → empty then
/// fallbackTitle (L3). Writes back via session_mod.renameTitle (atomic, D6).
/// Returns true when a title was written.
pub fn ensureTitle(
    provider: *provider_mod.Provider,
    session: *session_mod.Session,
    allocator: std.mem.Allocator,
    io: Io,
    extra_stopwords: []const []const u8,
) bool {
    const msgs = session.messages();

    // Collect the first two real user messages (skip system prompt index 0,
    // compaction summaries are system role).
    var user_msgs: [2][]const u8 = undefined;
    var user_count: usize = 0;
    for (msgs) |m| {
        if (m.role == .user and user_count < 2) {
            user_msgs[user_count] = m.content;
            user_count += 1;
        }
    }
    if (user_count < 2) return false;

    // Most recent user message feeds L2/L3 fallbacks.
    const last_user = user_msgs[user_count - 1];

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Build the title request: [system: TITLE_PROMPT, user: first-two-user joined].
    var prompt_msgs: std.ArrayListAligned(types.Message, null) = .empty;
    defer prompt_msgs.deinit(arena);
    prompt_msgs.append(arena, .{ .role = .system, .content = TITLE_PROMPT }) catch return false;
    const joined = std.mem.join(arena, "\n", user_msgs[0..user_count]) catch return false;
    prompt_msgs.append(arena, .{ .role = .user, .content = joined }) catch return false;

    var title: ?[]const u8 = null;
    const resp = provider.chatCompletionStreaming(&arena_state, io, prompt_msgs.items, null, null) catch null;
    if (resp) |r| {
        if (r.content) |c| {
            title = cleanTitle(c, allocator) catch null;
        }
    }

    if (title == null) {
        title = keywordTitle(last_user, extra_stopwords, allocator) catch null;
    }
    if (title == null) {
        title = fallbackTitle(last_user, allocator) catch null;
    }
    if (title == null) return false;

    session_mod.renameTitle(allocator, io, session.path, title.?) catch return false;
    log.dbg(0, 0, "title_updated", "len={d}", .{title.?.len});
    allocator.free(title.?);
    return true;
}

test "title: shouldAutoTitle requires switch, no parent, default name, 2 users" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var sess = try session_mod.Session.init(allocator, io, "m");
    defer sess.deinit();
    try sess.append(.{ .role = .system, .content = "sys" });
    try sess.append(.{ .role = .user, .content = "u1" });
    try sess.append(.{ .role = .assistant, .content = "a1" });
    try sess.append(.{ .role = .user, .content = "u2" });

    // Exactly 2 users → trigger.
    try std.testing.expect(shouldAutoTitle(&sess, true));
    // Switch off → no.
    try std.testing.expect(!shouldAutoTitle(&sess, false));
    // parent_id set → no.
    sess.parent_id = "p";
    try std.testing.expect(!shouldAutoTitle(&sess, true));
    sess.parent_id = null;
    try std.testing.expect(shouldAutoTitle(&sess, true));
}

test "title: shouldAutoTitle false with !=2 users" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var sess = try session_mod.Session.init(allocator, io, "m");
    defer sess.deinit();
    try sess.append(.{ .role = .user, .content = "only one" });
    try std.testing.expect(!shouldAutoTitle(&sess, true));
}

test "title: shouldAutoTitle renamed session no" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var sess = try session_mod.Session.init(allocator, io, "m");
    defer sess.deinit();
    try sess.rename("My Custom Title");
    try sess.append(.{ .role = .user, .content = "u1" });
    try sess.append(.{ .role = .user, .content = "u2" });
    try std.testing.expect(!shouldAutoTitle(&sess, true));
}

test "title: cleanTitle strips think and takes first non-empty line" {
    const allocator = std.testing.allocator;
    const out = try cleanTitle("<think>deep reasoning</think>\n  Fix the bug  ", allocator);
    defer allocator.free(out.?);
    try std.testing.expectEqualStrings("Fix the bug", out.?);
}

test "title: cleanTitle empty returns null" {
    const allocator = std.testing.allocator;
    const out = try cleanTitle("   \n  ", allocator);
    try std.testing.expect(out == null);
}

test "title: cleanTitle caps at TITLE_HARD_CAP" {
    const allocator = std.testing.allocator;
    const long = "x" ** (TITLE_HARD_CAP + 10);
    const out = try cleanTitle(long, allocator);
    defer allocator.free(out.?);
    try std.testing.expect(out.?.len <= TITLE_HARD_CAP);
    try std.testing.expect(std.mem.endsWith(u8, out.?, "..."));
}

test "title: keywordTitle filters stopwords and respects KEYWORD_MIN/MAX" {
    const allocator = std.testing.allocator;
    const out = try keywordTitle("帮我修 src/app.js 的 500 错误", &.{}, allocator);
    defer allocator.free(out.?);
    try std.testing.expectEqualStrings("src/app.js 500 错误", out.?);
}

test "title: keywordTitle all-stopwords returns null" {
    const allocator = std.testing.allocator;
    const out = try keywordTitle("帮我 请你 的了 一个 在 用 the", &.{}, allocator);
    try std.testing.expect(out == null);
}

test "title: keywordTitle extra_stopwords filter" {
    const allocator = std.testing.allocator;
    const out = try keywordTitle("修复 bug 模块 处理 完成", &.{ "修复", "bug" }, allocator);
    defer allocator.free(out.?);
    try std.testing.expectEqualStrings("模块 处理 完成", out.?);
}

test "title: keywordTitle caps at KEYWORD_MAX tokens" {
    const allocator = std.testing.allocator;
    const out = try keywordTitle("fix config path render debug profile test", &.{}, allocator);
    defer allocator.free(out.?);
    try std.testing.expectEqualStrings("fix config path render debug", out.?);
}

test "title: keywordTitle filters cjk imperative prefix 帮我修" {
    const allocator = std.testing.allocator;
    const out = try keywordTitle("帮我修", &.{}, allocator);
    try std.testing.expect(out == null);
}

test "title: fallbackTitle truncates to TITLE_PREFIX_LEN" {
    const allocator = std.testing.allocator;
    const out = try fallbackTitle("这是一条很长的用户消息超过了三十个字符限制需要被截断处理掉多余部分", allocator);
    defer allocator.free(out);
    try std.testing.expectEqual(TITLE_PREFIX_LEN, out.len);
}
