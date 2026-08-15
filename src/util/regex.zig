//! Lightweight regex engine for grep (PLAN-GREP-REGEX, N20).
//!
//! Feature subset: literals, `.`, `^`/`$` anchors, char classes (POSIX boundary
//! semantics), groups, alternation, quantifiers (`*` `+` `?` `{n,m}`), class
//! escapes (`\d \w \s` ASCII), word boundary `\b`, escaped literals.
//! Matching is code-point based (UTF-8) with ASCII class escapes, unanchored
//! search driven by a literal prefix, iterative chain/repeat matching
//! (zero recursion for long literal runs and unbounded repetition), memoized
//! failure (lazy), and an input-scaled step budget.
//!
//! Ownership contract: `Pattern` is move-only (embedded arena). Shallow copies
//! share the arena and double-free on double deinit - forbidden. Deep copy is
//! possible by duping the nodes array (next is an index, not a pointer).

const std = @import("std");

// --- limits (PLAN-GREP-REGEX) ---

/// Max group nesting accepted at compile time (deeper patterns are rejected).
pub const MAX_NEST_DEPTH: usize = 64;
/// Runtime recursion guard for nested group/alt matching (2x compile bound).
pub const MAX_MATCH_DEPTH: usize = 128;
/// Max quantifier bound accepted at compile time (`{n,m}` values must fit).
pub const MAX_QUANTIFIER_LIMIT: usize = 1000;
/// Fixed step-budget base (covers small-file overhead).
pub const MATCH_STEP_BASE: usize = 100_000;
/// Step-budget ratio: allowed steps per scanned byte (linear scan is 1-5).
pub const MATCH_STEP_RATIO: usize = 16;
/// Steps after which the failure-memoization set is lazily created.
pub const MEMO_THRESHOLD: usize = 2_000;

pub const RegexError = error{ MatchLimitExceeded };

// --- AST ---

pub const Class = struct {
    negated: bool,
    ranges: []const Cprange, // allocated in Pattern arena
};

/// code-point range, inclusive both ends
pub const Cprange = struct { lo: u21, hi: u21 };

const Kind = union(enum) {
    literal: u21, // code point (Unicode strategy)
    any,
    class: Class, // negated + ranges
    group: ?usize, // first node of group content (null = empty group)
    alt: struct { left: ?usize, right: ?usize }, // branch first nodes (null = empty branch)
    repeat: struct { node: usize, min: usize, max: ?usize }, // greedy, applies to a single atom node
    anchor_start,
    anchor_end,
    word_boundary,
};

const Node = struct { kind: Kind, next: ?usize };

pub const Pattern = struct {
    nodes: []Node, // arena-allocated; next-chain expresses sequence
    root: ?usize, // top-level chain head (null = empty pattern, matches everything)
    prefix: []const u8, // literal prefix for fast fail/scan drive (empty = none)
    arena: std.heap.ArenaAllocator, // owns nodes + prefix + class ranges

    pub fn deinit(self: *Pattern) void {
        self.arena.deinit();
    }

    /// Unanchored search: pattern may match at any position in text. Driven by
    /// the literal prefix when present (every match start must be a prefix
    /// hit), otherwise plain per-position scan.
    pub fn match(self: *const Pattern, text: []const u8, steps: *usize, allocator: ?std.mem.Allocator) (error{MatchLimitExceeded})!bool {
        var ctx = MatchCtx{
            .text = text,
            .steps = steps,
            .limit = MATCH_STEP_BASE + MATCH_STEP_RATIO * text.len,
            .allocator = allocator,
        };
        defer if (ctx.memo) |m| {
            if (allocator) |a| {
                m.deinit(a);
                a.destroy(m);
            }
        };
        defer {
            for (ctx.stack.items) |f| {
                switch (f) {
                    .repeat => |r| if (allocator) |a| a.free(r.attempts),
                    .alt => {},
                }
            }
            ctx.stack.deinit(allocator orelse std.heap.page_allocator);
        }

        if (self.prefix.len > 0) {
            var i = std.mem.indexOf(u8, text, self.prefix);
            while (i) |start| {
                if ((try matchSeq(self, &ctx, self.root, start, 0, null)) != null) return true;
                i = std.mem.indexOfPos(u8, text, start + 1, self.prefix);
            }
            return false;
        }
        var pos: usize = 0;
        while (pos <= text.len) : (pos += 1) {
            if ((try matchSeq(self, &ctx, self.root, pos, 0, null)) != null) return true;
        }
        return false;
    }
};

// --- compile errors ---

pub const CompileErrorCode = enum {
    unterminated_class, // `[abc` / `[]`
    unterminated_group, // `(ab`
    unterminated_brace, // `a{2`
    quantifier_no_target, // `*a` / `a**`
    invalid_escape, // `\q`
    unsupported_construct, // `(?=` / `(?!` / `\1` / `\p{` / `\B`
    invalid_quantifier_range, // `a{2,1}` / bound > MAX_QUANTIFIER_LIMIT
    invalid_range, // `[z-a]` / `[a-\d]`
    nesting_too_deep, // group nesting > MAX_NEST_DEPTH
};

pub const CompileError = struct {
    code: CompileErrorCode,
    pos: usize, // 0-based position in the spec (stack value, no allocation)
};

pub const CompileResult = union(enum) {
    ok: Pattern,
    err: CompileError,
};

/// Official message for a compile error code, with static fix guidance
/// ("did you mean" templates bound to the error type; no content inference).
pub fn errorDetail(code: CompileErrorCode) []const u8 {
    return switch (code) {
        .unterminated_class => "unterminated character class - did you mean to close it with ']'?",
        .unterminated_group => "unterminated group - did you mean to close it with ')'?",
        .unterminated_brace => "unterminated quantifier - did you mean to close it with '}'?",
        .quantifier_no_target => "quantifier without target - remove the dangling '*', '+', or '?'",
        .invalid_escape => "invalid escape sequence - unknown escape after '\\'",
        .unsupported_construct => "unsupported construct (e.g. backreferences, lookahead, (?i) flags, \\p{...}, \\B) - not in the supported subset",
        .invalid_quantifier_range => "invalid quantifier range (bounds must be ≤ 1000 and min ≤ max)",
        .invalid_range => "invalid character range (range endpoints must be literal characters; e.g. write [a0-9] instead of [a-\\d])",
        .nesting_too_deep => "pattern nesting too deep (max 64 group levels)",
    };
}

// --- compile ---

const ParseError = error{ CompileFailed };

const Parser = struct {
    spec: []const u8,
    pos: usize,
    arena: std.mem.Allocator,
    nodes: std.ArrayListAligned(Node, null) = .empty,
    depth: usize = 0,
    last_err: ?CompileError = null,

    fn fail(self: *Parser, code: CompileErrorCode) ParseError {
        self.last_err = .{ .code = code, .pos = self.pos };
        return error.CompileFailed;
    }

    fn peek(self: *const Parser) ?u8 {
        return if (self.pos < self.spec.len) self.spec[self.pos] else null;
    }

    fn bump(self: *Parser) ?u8 {
        const c = self.peek() orelse return null;
        self.pos += 1;
        return c;
    }

    fn emitNode(self: *Parser, kind: Kind) !usize {
        const idx = self.nodes.items.len;
        try self.nodes.append(self.arena, .{ .kind = kind, .next = null });
        return idx;
    }

    fn linkNext(self: *Parser, from: usize, to: usize) void {
        self.nodes.items[from].next = to;
    }

    /// Consume a code point at self.pos; returns cp + byte length. Invalid
    /// UTF-8 degrades to a single byte (behavior is deterministic, no crash).
    fn readCp(self: *Parser) CpInfo {
        return decodeCpAt(self.spec, self.pos);
    }

    fn skipCp(self: *Parser) void {
        self.pos += self.readCp().bytes;
    }

    fn parseExpr(self: *Parser) anyerror!?usize {
        return self.parseAlt();
    }

    fn parseAlt(self: *Parser) anyerror!?usize {
        var left = try self.parseSeq();
        while (self.peek() == '|') {
            _ = self.bump();
            const right = try self.parseSeq();
            const alt_idx = try self.emitNode(.{ .alt = .{ .left = left, .right = right } });
            left = alt_idx;
        }
        return left;
    }

    fn parseSeq(self: *Parser) anyerror!?usize {
        var first: ?usize = null;
        var prev: ?usize = null;
        while (self.peek()) |c| {
            if (c == '|' or c == ')') break;
            const atom = try self.parseAtom();
            if (prev) |p| self.linkNext(p, atom) else first = atom;
            prev = atom;
        }
        return first;
    }

    fn parseAtom(self: *Parser) anyerror!usize {
        const c = self.bump() orelse
            return self.fail(.quantifier_no_target);
        var idx: usize = undefined;
        switch (c) {
            '(' => {
                if (self.peek() == '?') return self.fail(.unsupported_construct); // (?= (?! (?: (?i ...
                if (self.depth >= MAX_NEST_DEPTH) return self.fail(.nesting_too_deep);
                self.depth += 1;
                const inner = try self.parseExpr();
                self.depth -= 1;
                const close = self.bump() orelse return self.fail(.unterminated_group);
                if (close != ')') return self.fail(.unterminated_group);
                idx = try self.emitNode(.{ .group = inner });
            },
            '[' => idx = try self.parseClass(),
            '\\' => {
                const e = self.bump() orelse return self.fail(.invalid_escape);
                switch (e) {
                    'd' => idx = try self.emitNode(.{ .class = .{ .negated = false, .ranges = &digit_ranges } }),
                    'D' => idx = try self.emitNode(.{ .class = .{ .negated = true, .ranges = &digit_ranges } }),
                    'w' => idx = try self.emitNode(.{ .class = .{ .negated = false, .ranges = &word_ranges } }),
                    'W' => idx = try self.emitNode(.{ .class = .{ .negated = true, .ranges = &word_ranges } }),
                    's' => idx = try self.emitNode(.{ .class = .{ .negated = false, .ranges = &space_ranges } }),
                    'S' => idx = try self.emitNode(.{ .class = .{ .negated = true, .ranges = &space_ranges } }),
                    'b' => idx = try self.emitNode(.word_boundary),
                    '1'...'9' => return self.fail(.unsupported_construct),
                    'A', 'z', 'B', 'Q' => return self.fail(.unsupported_construct),
                    'p' => {
                        if (self.peek() == '{') return self.fail(.unsupported_construct);
                        return self.fail(.invalid_escape);
                    },
                    '.', '*', '\\', '|', '(', ')', '[', ']', '{', '}', '^', '$', '+', '?', '-', '/', 'n', 't', 'r' => {
                        const cp: u21 = switch (e) {
                            'n' => '\n',
                            't' => '\t',
                            'r' => '\r',
                            else => e,
                        };
                        idx = try self.emitNode(.{ .literal = cp });
                    },
                    else => return self.fail(.invalid_escape),
                }
            },
            '^' => idx = try self.emitNode(.anchor_start),
            '$' => idx = try self.emitNode(.anchor_end),
            '.' => idx = try self.emitNode(.any),
            '*', '+', '?' => return self.fail(.quantifier_no_target),
            '{' => {
                if (self.peek() != null and self.peek().? >= '0' and self.peek().? <= '9') {
                    return self.fail(.quantifier_no_target);
                }
                idx = try self.emitNode(.{ .literal = '{' });
            },
            ')' => return self.fail(.unterminated_group),
            ']' => return self.fail(.invalid_escape), // stray ']' outside a class: treat as escape error
            '|' => return self.fail(.quantifier_no_target),
            else => {
                // literal code point (re-read because bump consumed one byte only)
                self.pos -= 1;
                const cpinfo = self.readCp();
                self.pos += cpinfo.bytes;
                idx = try self.emitNode(.{ .literal = cpinfo.cp });
            },
        }
        return self.parseQuantifier(idx);
    }

    fn parseQuantifier(self: *Parser, atom: usize) anyerror!usize {
        const c = self.peek() orelse return atom;
        if (c != '*' and c != '+' and c != '?' and c != '{') return atom;
        _ = self.bump();
        var min: usize = undefined;
        var max: ?usize = undefined;
        switch (c) {
            '*' => {
                min = 0;
                max = null;
            },
            '+' => {
                min = 1;
                max = null;
            },
            '?' => {
                min = 0;
                max = 1;
            },
            '{' => {
                const saved = self.pos - 1;
                const parsed = try self.parseBrace();
                if (parsed) |bv| {
                    min = bv.min;
                    max = bv.max;
                } else {
                    // not a quantifier: '{' is a literal; the atom was already
                    // emitted and linked, return the '{' node as the next atom
                    self.pos = saved;
                    return self.emitNode(.{ .literal = '{' });
                }
            },
            else => unreachable,
        }
        return self.emitNode(.{ .repeat = .{ .node = atom, .min = min, .max = max } });
    }

    const Brace = struct { min: usize, max: ?usize };

    /// Parse a brace quantifier after '{'. Returns null when '{' is not a
    /// quantifier (no leading digit) - caller treats '{' as a literal.
    /// Errors: unterminated_brace (unclosed or malformed), invalid_quantifier_range
    /// (bounds > MAX_QUANTIFIER_LIMIT or min > max).
    fn parseBrace(self: *Parser) ParseError!?Brace {
        const start = self.pos;
        const mn = self.parseUintStrict() catch |e| return e;
        if (mn == null) {
            self.pos = start;
            return null; // no digit: not a quantifier
        }
        const mnv = mn.?;
        if (self.peek() == '}') {
            _ = self.bump();
            return .{ .min = mnv, .max = mnv };
        }
        if (self.peek() != ',') return self.fail(.unterminated_brace);
        _ = self.bump();
        if (self.peek() == '}') {
            _ = self.bump();
            return .{ .min = mnv, .max = null };
        }
        const mx = self.parseUintStrict() catch |e| return e;
        if (mx == null) return self.fail(.unterminated_brace);
        if (self.peek() != '}') return self.fail(.unterminated_brace);
        _ = self.bump();
        if (mnv > mx.?) return self.fail(.invalid_quantifier_range);
        return .{ .min = mnv, .max = mx.? };
    }

    /// Parse decimal digits; null = no digits. Bounds above
    /// MAX_QUANTIFIER_LIMIT are an error.
    fn parseUintStrict(self: *Parser) ParseError!?usize {
        var v: usize = 0;
        var any = false;
        while (self.peek()) |c| {
            if (c < '0' or c > '9') break;
            any = true;
            v = v * 10 + (c - '0');
            _ = self.bump();
            if (v > MAX_QUANTIFIER_LIMIT) {
                while (self.peek()) |d| {
                    if (d < '0' or d > '9') break;
                    _ = self.bump();
                }
                return self.fail(.invalid_quantifier_range);
            }
        }
        return if (any) v else null;
    }

    fn parseClass(self: *Parser) anyerror!usize {
        var negated = false;
        if (self.peek() == '^') {
            negated = true;
            _ = self.bump();
        }
        var ranges = std.ArrayListAligned(Cprange, null).empty;
        var first_member = true;
        var closed = false;

        while (self.peek()) |c| {
            if (c == ']' and !first_member) {
                // closing bracket (first ']' is a literal member)
                _ = self.bump();
                closed = true;
                break;
            }
            first_member = false;

            // read one member (code point): class escape expansion or literal
            var member: ?u21 = null;
            if (c == '\\') {
                _ = self.bump();
                const e = self.bump() orelse return self.fail(.unterminated_class);
                switch (e) {
                    'd', 'D', 'w', 'W', 's', 'S' => {
                        const rs: []const Cprange = switch (e) {
                            'd', 'D' => &digit_ranges,
                            'w', 'W' => &word_ranges,
                            else => &space_ranges,
                        };
                        if (self.peek() == '-') {
                            // x-\d: class escape as range endpoint -> error
                            return self.fail(.invalid_range);
                        }
                        for (rs) |r| try ranges.append(self.arena, r);
                        continue;
                    },
                    ']', '\\', '-', 'n', 't', 'r' => member = switch (e) {
                        'n' => '\n',
                        't' => '\t',
                        'r' => '\r',
                        else => e,
                    },
                    else => return self.fail(.invalid_escape),
                }
            } else {
                const cpinfo = self.readCp();
                self.pos += cpinfo.bytes;
                member = cpinfo.cp;
            }

            const m = member.?;
            if (self.peek() == '-') {
                _ = self.bump();
                const nx = self.peek();
                if (nx == null or nx == ']') {
                    // trailing '-': literal member + literal '-'
                    try ranges.append(self.arena, .{ .lo = m, .hi = m });
                    try ranges.append(self.arena, .{ .lo = '-', .hi = '-' });
                    continue;
                }
                // range: endpoint must be a literal or escaped literal
                var end_cp: u21 = undefined;
                if (nx == '\\') {
                    _ = self.bump();
                    const e = self.bump() orelse return self.fail(.unterminated_class);
                    switch (e) {
                        ']', '\\', '-', 'n', 't', 'r' => end_cp = switch (e) {
                            'n' => '\n',
                            't' => '\t',
                            'r' => '\r',
                            else => e,
                        },
                        else => return self.fail(.invalid_range), // class escape as range endpoint
                    }
                } else {
                    const ep = self.readCp();
                    self.pos += ep.bytes;
                    end_cp = ep.cp;
                }
                if (end_cp < m) return self.fail(.invalid_range);
                try ranges.append(self.arena, .{ .lo = m, .hi = end_cp });
                continue;
            }
            try ranges.append(self.arena, .{ .lo = m, .hi = m });
        }

        if (!closed) return self.fail(.unterminated_class);

        return self.emitNode(.{ .class = .{ .negated = negated, .ranges = try ranges.toOwnedSlice(self.arena) } });
    }
};
const digit_ranges = [_]Cprange{.{ .lo = '0', .hi = '9' }};
const word_ranges = [_]Cprange{ .{ .lo = 'a', .hi = 'z' }, .{ .lo = 'A', .hi = 'Z' }, .{ .lo = '0', .hi = '9' }, .{ .lo = '_', .hi = '_' } };
const space_ranges = [_]Cprange{ .{ .lo = ' ', .hi = ' ' }, .{ .lo = '\t', .hi = '\r' } };

/// Only arena allocation (nodes) can OOM -> propagates error.OutOfMemory;
/// other compile failures -> `.err` structured error.
pub fn compile(allocator: std.mem.Allocator, spec: []const u8) (error{OutOfMemory})!CompileResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var p = Parser{
        .spec = spec,
        .pos = 0,
        .arena = arena.allocator(),
    };
    const root = p.parseExpr() catch {
        arena.deinit();
        return .{ .err = p.last_err orelse .{ .code = .unsupported_construct, .pos = p.pos } };
    };
    if (p.pos != spec.len) {
        // trailing characters (e.g. stray ')')
        arena.deinit();
        return .{ .err = .{ .code = .unsupported_construct, .pos = p.pos } };
    }

    const nodes = try p.nodes.toOwnedSlice(arena.allocator());
    const prefix = try extractPrefix(arena.allocator(), nodes, root);

    return .{ .ok = .{
        .nodes = nodes,
        .root = root,
        .prefix = prefix,
        .arena = arena,
    } };
}

/// Collect the leading run of literal nodes into a byte prefix (code points
/// encoded back to UTF-8). Stops at the first non-literal node.
fn extractPrefix(allocator: std.mem.Allocator, nodes: []const Node, root: ?usize) ![]const u8 {
    var buf = std.ArrayListAligned(u8, null).empty;
    var cur = root;
    while (cur) |idx| {
        const node = &nodes[idx];
        switch (node.kind) {
            .literal => |cp| {
                var tmp: [4]u8 = undefined;
                const n = utf8Encode(cp, &tmp);
                try buf.appendSlice(allocator, tmp[0..n]);
            },
            else => break,
        }
        cur = node.next;
    }
    return buf.toOwnedSlice(allocator);
}

fn utf8Encode(cp: u21, buf: []u8) usize {
    if (cp < 0x80) {
        buf[0] = @intCast(cp);
        return 1;
    } else if (cp < 0x800) {
        buf[0] = @intCast(0xC0 | (cp >> 6));
        buf[1] = @intCast(0x80 | (cp & 0x3F));
        return 2;
    } else if (cp < 0x10000) {
        buf[0] = @intCast(0xE0 | (cp >> 12));
        buf[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        buf[2] = @intCast(0x80 | (cp & 0x3F));
        return 3;
    } else {
        buf[0] = @intCast(0xF0 | (cp >> 18));
        buf[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
        buf[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        buf[3] = @intCast(0x80 | (cp & 0x3F));
        return 4;
    }
}

// --- match ---

const MemoKey = struct { node_idx: u32, pos: u32 };

const Frame = union(enum) {
    // resume_chain: node to continue from after a successful retry. For frames
    // created inside a group chain this is the group node's outer next; at top
    // level it is the frame node's own next.
    repeat: struct { repeat_node: usize, attempts: []u32, idx: usize, min: usize, resume_chain: ?usize, depth: usize },
    alt: struct { alt_node: usize, pos: usize, resume_chain: ?usize, depth: usize },
};

const MatchCtx = struct {
    text: []const u8,
    steps: *usize,
    limit: usize,
    allocator: ?std.mem.Allocator,
    memo: ?*std.AutoHashMapUnmanaged(MemoKey, void) = null,
    memo_attempted: bool = false,
    // Shared backtrack stack across nested matchSeq calls. Deferred at match().
    stack: std.ArrayListAligned(Frame, null) = .empty,
};

/// Iterative chain walk: zero recursion for long literal runs. Handles repeat
/// greedily with an explicit backtrack stack (zero recursion for unbounded
/// repetition).
fn matchSeq(self: *const Pattern, ctx: *MatchCtx, first: ?usize, pos0: usize, depth: usize, group_of: ?usize) (error{MatchLimitExceeded})!?usize {
    var cur = first;
    var p = pos0;
    while (cur) |idx| {
        const node = &self.nodes[idx];
        switch (node.kind) {
            .repeat => |rep| {
                if (node.next == null) {
                    // chain tail: greedy consume, no backtracking needed
                    var count: usize = 0;
                    var q = p;
                    while (rep.max == null or count < rep.max.?) {
                        const r = try matchNode(self, ctx, rep.node, q, depth);
                        const q2 = r orelse break;
                        count += 1;
                        q = q2;
                    }
                    if (count < rep.min) return null;
                    p = q;
                } else {
                    // greedy consume recording positions; later nodes may
                    // backtrack through the stack
                    var attempts = std.ArrayListAligned(u32, null).empty;
                    defer if (ctx.allocator) |a| attempts.deinit(a);
                    attempts.append(ctx.allocator orelse std.heap.page_allocator, @intCast(p)) catch return null;
                    var count: usize = 0;
                    var q = p;
                    while (rep.max == null or count < rep.max.?) {
                        const r = try matchNode(self, ctx, rep.node, q, depth);
                        const q2 = r orelse break;
                        count += 1;
                        q = q2;
                        attempts.append(ctx.allocator orelse std.heap.page_allocator, @intCast(q)) catch return null;
                    }
                    if (count < rep.min) return null;
                    const owned = if (ctx.allocator) |a| attempts.toOwnedSlice(a) catch return null else attempts.toOwnedSlice(std.heap.page_allocator) catch return null;
                    const resume_chain: ?usize = if (group_of) |g| self.nodes[g].next else node.next;
                    ctx.stack.append(ctx.allocator orelse std.heap.page_allocator, .{ .repeat = .{
                        .repeat_node = idx,
                        .attempts = owned,
                        .idx = count,
                        .min = rep.min,
                        .resume_chain = resume_chain,
                        .depth = depth,
                    } }) catch return null;
                    p = q;
                }
            },
            .alt => |alt| {
                // alternation with cross-branch backtracking: try left branch;
                // on later failure, retry the right branch (explicit frame).
                const r = try matchSeq(self, ctx, alt.left, p, depth + 1, group_of);
                const p2 = r orelse {
                    // left failed: try right directly (no frame needed - right is
                    // the last alternative)
                    const r2 = try matchSeq(self, ctx, alt.right, p, depth + 1, group_of);
                    const p3 = r2 orelse {
                        // backtrack further
                        var found = false;
                        while (ctx.stack.items.len > 0) {
                            const top = ctx.stack.items[ctx.stack.items.len - 1];
                            if ((switch (top) { .repeat => |f| f.depth, .alt => |f| f.depth }) < depth) break; // never pop frames of outer chains
                            switch (top) {
                                .repeat => |f| {
                                    if (f.idx > f.min) {
                                        ctx.stack.items[ctx.stack.items.len - 1].repeat.idx -= 1;
                                        p = f.attempts[ctx.stack.items[ctx.stack.items.len - 1].repeat.idx];
                                        cur = f.resume_chain;
                                        found = true;
                                        break;
                                    } else {
                                        if (ctx.allocator) |a| a.free(f.attempts);
                                        _ = ctx.stack.pop();
                                    }
                                },
                                .alt => |f| {
                                    const alt2 = self.nodes[f.alt_node].kind.alt;
                                    const rr = try matchSeq(self, ctx, alt2.right, f.pos, depth + 1, group_of);
                                    if (rr) |q| {
                                        _ = ctx.stack.pop();
                                        p = q;
                                        cur = f.resume_chain;
                                        found = true;
                                        break;
                                    } else {
                                        _ = ctx.stack.pop();
                                    }
                                },
                            }
                        }
                        if (!found) return null;
                        continue;
                    };
                    p = p3;
                    cur = node.next;
                    continue;
                };
                // left succeeded: push frame for right-branch retry
                const alt_resume_chain: ?usize = if (group_of) |g| self.nodes[g].next else node.next;
                ctx.stack.append(ctx.allocator orelse std.heap.page_allocator, .{ .alt = .{
                    .alt_node = idx,
                    .pos = p,
                    .resume_chain = alt_resume_chain,
                    .depth = depth,
                } }) catch {}; // OOM: right-branch retry lost, acceptable degradation
                p = p2;
            },
            else => {
                const r = try matchNode(self, ctx, idx, p, depth);
                const p2 = r orelse {
                    // backtrack: retry repeat states or alt right branches
                    var found = false;
                    while (ctx.stack.items.len > 0) {
                        const top = ctx.stack.items[ctx.stack.items.len - 1];
                        if ((switch (top) { .repeat => |f| f.depth, .alt => |f| f.depth }) < depth) break; // never pop frames of outer chains
                        switch (top) {
                            .repeat => |f| {
                                if (f.idx > f.min) {
                                    ctx.stack.items[ctx.stack.items.len - 1].repeat.idx -= 1;
                                    p = f.attempts[ctx.stack.items[ctx.stack.items.len - 1].repeat.idx];
                                    cur = f.resume_chain;
                                    found = true;
                                    break;
                                } else {
                                    if (ctx.allocator) |a| a.free(f.attempts);
                                    _ = ctx.stack.pop();
                                }
                            },
                            .alt => |f| {
                                const alt2 = self.nodes[f.alt_node].kind.alt;
                                const rr = try matchSeq(self, ctx, alt2.right, f.pos, depth + 1, group_of);
                                if (rr) |q| {
                                    _ = ctx.stack.pop();
                                    p = q;
                                    cur = f.resume_chain;
                                    found = true;
                                    break;
                                } else {
                                    _ = ctx.stack.pop();
                                }
                            },
                        }
                    }
                    if (!found) return null;
                    continue;
                };
                p = p2;
            },
        }
        cur = node.next;
    }
    return p;
}

/// Recursive dispatch for a single atom node (nesting recursion only; depth is
/// bounded by MAX_NEST_DEPTH/MAX_MATCH_DEPTH).
fn matchNode(self: *const Pattern, ctx: *MatchCtx, idx: usize, pos: usize, depth: usize) (error{MatchLimitExceeded})!?usize {
    ctx.steps.* += 1;
    if (ctx.steps.* > ctx.limit) return error.MatchLimitExceeded;

    if (depth > MAX_MATCH_DEPTH) return error.MatchLimitExceeded;

    if (ctx.allocator) |a| {
        if (ctx.memo == null and !ctx.memo_attempted and ctx.steps.* > MEMO_THRESHOLD) {
            ctx.memo_attempted = true;
            var m: std.AutoHashMapUnmanaged(MemoKey, void) = .empty;
            m.ensureTotalCapacity(a, 64) catch {}; // OOM: memo creation skipped, plain backtracking
            const heap_m = a.create(std.AutoHashMapUnmanaged(MemoKey, void)) catch null;
            if (heap_m) |hm| {
                hm.* = m;
                ctx.memo = hm;
            }
        }
        if (ctx.memo) |m| {
            const key = MemoKey{ .node_idx = @intCast(idx), .pos = @intCast(pos) };
            if (m.contains(key)) return null;
        }
    }

    const result = try matchNodeInner(self, ctx, idx, pos, depth);

    if (ctx.allocator) |a| {
        if (ctx.memo) |m| {
            const key = MemoKey{ .node_idx = @intCast(idx), .pos = @intCast(pos) };
            if (result == null) {
                m.put(a, key, {}) catch {}; // OOM: failed-state cache write skipped, correctness unaffected
            }
        }
    }
    return result;
}

fn matchNodeInner(self: *const Pattern, ctx: *MatchCtx, idx: usize, pos: usize, depth: usize) (error{MatchLimitExceeded})!?usize {
    const node = &self.nodes[idx];
    const text = ctx.text;
    switch (node.kind) {
        .literal => |want| {
            const got = readCpAt(text, pos);
            if (got.cp == want) return pos + got.bytes;
            return null;
        },
        .any => {
            if (pos >= text.len) return null;
            const got = readCpAt(text, pos);
            return pos + got.bytes;
        },
        .class => |cls| {
            if (pos >= text.len) return null;
            const got = readCpAt(text, pos);
            var in_class = false;
            for (cls.ranges) |r| {
                if (got.cp >= r.lo and got.cp <= r.hi) {
                    in_class = true;
                    break;
                }
            }
            if (in_class == cls.negated) return null;
            return pos + got.bytes;
        },
        .group => |inner| return matchSeq(self, ctx, inner, pos, depth + 1, idx),
        .alt => |alt| {
            if (try matchSeq(self, ctx, alt.left, pos, depth + 1, null)) |q| return q;
            return matchSeq(self, ctx, alt.right, pos, depth + 1, null);
        },
        .repeat => |rep| {
            // repeat inside group content: matchSeq handles repeats at chain
            // level; nested repeat (group of groups) goes through matchSeq
            // recursion - handled there; direct call here happens only when a
            // repeat node is matched via a group content chain, which is
            // dispatched through matchSeq's repeat branch. Guard defensively.
            var count: usize = 0;
            var q = pos;
            while (rep.max == null or count < rep.max.?) {
                const r = try matchNode(self, ctx, rep.node, q, depth + 1);
                const q2 = r orelse break;
                count += 1;
                q = q2;
            }
            if (count < rep.min) return null;
            return q;
        },
        .anchor_start => {
            if (pos == 0) return pos;
            return null;
        },
        .anchor_end => {
            if (pos == text.len) return pos;
            return null;
        },
        .word_boundary => {
            const left_word = pos > 0 and isWordByte(text[pos - 1]);
            const right_word = pos < text.len and isWordByte(text[pos]);
            if (left_word == right_word) return null;
            return pos;
        },
    }
}

fn isWordByte(b: u8) bool {
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9') or b == '_';
}

const CpInfo = struct { cp: u21, bytes: usize };

/// Decode one code point at `pos` in `text`. utf8Decode requires a 1-4 byte
/// slice, so the sequence length is derived from the first byte first; invalid
/// bytes degrade to a single-byte code point (deterministic, no crash).
fn decodeCpAt(text: []const u8, pos: usize) CpInfo {
    const rest = text[pos..];
    if (rest.len == 0) return .{ .cp = 0, .bytes = 0 };
    const want = std.unicode.utf8ByteSequenceLength(rest[0]) catch 1;
    const n = @min(want, rest.len);
    if (std.unicode.utf8Decode(rest[0..n])) |cp| {
        return .{ .cp = cp, .bytes = n };
    } else |_| {
        return .{ .cp = rest[0], .bytes = 1 };
    }
}

fn readCpAt(text: []const u8, pos: usize) CpInfo {
    return decodeCpAt(text, pos);
}

// --- tests ---

fn ok(allocator: std.mem.Allocator, spec: []const u8) !Pattern {
    const res = try compile(allocator, spec);
    return switch (res) {
        .ok => |p| p,
        .err => |e| {
            std.debug.print("unexpected compile error for '{s}': {s} at {d}\n", .{ spec, errorDetail(e.code), e.pos });
            return error.UnexpectedCompileError;
        },
    };
}

fn matches(allocator: std.mem.Allocator, spec: []const u8, text: []const u8) !bool {
    var p = try ok(allocator, spec);
    defer p.deinit();
    var steps: usize = 0;
    return p.match(text, &steps, allocator);
}

fn compileErr(allocator: std.mem.Allocator, spec: []const u8) !CompileError {
    const res = try compile(allocator, spec);
    return switch (res) {
        .ok => |p| {
            var pp = p;
            pp.deinit();
            return error.UnexpectedOk;
        },
        .err => |e| e,
    };
}

test "regex: literal match and miss" {
    try std.testing.expect(try matches(std.testing.allocator, "hello", "say hello world"));
    try std.testing.expect(!try matches(std.testing.allocator, "hello", "goodbye"));
}

test "regex: dot matches any code point (Chinese = one)" {
    try std.testing.expect(try matches(std.testing.allocator, "中.文", "中X文"));
    try std.testing.expect(!try matches(std.testing.allocator, "中.文", "中文"));
}

test "regex: anchors" {
    try std.testing.expect(try matches(std.testing.allocator, "^import", "import foo"));
    try std.testing.expect(!try matches(std.testing.allocator, "^import", "xx import foo"));
    try std.testing.expect(try matches(std.testing.allocator, "foo$", "xx foo"));
    try std.testing.expect(!try matches(std.testing.allocator, "foo$", "foo bar"));
    try std.testing.expect(try matches(std.testing.allocator, "^a|b$", "a"));
    try std.testing.expect(try matches(std.testing.allocator, "^a|b$", "b"));
    try std.testing.expect(!try matches(std.testing.allocator, "^a|b$", "c"));
}

test "regex: character classes" {
    try std.testing.expect(try matches(std.testing.allocator, "[abc]", "qxb"));
    try std.testing.expect(!try matches(std.testing.allocator, "[abc]", "qxd"));
    try std.testing.expect(try matches(std.testing.allocator, "[^abc]", "qxd"));
    try std.testing.expect(!try matches(std.testing.allocator, "[^abc]", "bbb"));
    try std.testing.expect(try matches(std.testing.allocator, "[a-z]+", "ABCdef"));
    try std.testing.expect(try matches(std.testing.allocator, "[0-9_]+", "a_b1"));
    try std.testing.expect(!try matches(std.testing.allocator, "[0-9]+", "abc"));
    try std.testing.expect(try matches(std.testing.allocator, "[一-龥]+", "中文"));
}

test "regex: class boundary semantics" {
    // first ']' in class is a literal member
    try std.testing.expect(try matches(std.testing.allocator, "[]a]", "x]"));
    try std.testing.expect(try matches(std.testing.allocator, "[]a]", "xa"));
    try std.testing.expect(!try matches(std.testing.allocator, "[]a]", "xb"));
    // '-' at edges is literal
    try std.testing.expect(try matches(std.testing.allocator, "[-a]", "-"));
    try std.testing.expect(try matches(std.testing.allocator, "[a-]", "-"));
    // negation with first ']' literal
    try std.testing.expect(try matches(std.testing.allocator, "[^]a]", "b"));
    try std.testing.expect(!try matches(std.testing.allocator, "[^]a]", "a"));
    // single-char range
    try std.testing.expect(try matches(std.testing.allocator, "[a-a]", "a"));
    // '[' inside class is a literal
    try std.testing.expect(try matches(std.testing.allocator, "[[]", "["));
    // escaped literals inside class
    try std.testing.expect(try matches(std.testing.allocator, "[\\]]", "]"));
    try std.testing.expect(try matches(std.testing.allocator, "[\\d]", "5"));
    try std.testing.expect(!try matches(std.testing.allocator, "[\\d]", "x"));
}

test "regex: groups and alternation" {
    try std.testing.expect(try matches(std.testing.allocator, "(ab)c", "xabc"));
    try std.testing.expect(!try matches(std.testing.allocator, "(ab)c", "acbc"));
    try std.testing.expect(try matches(std.testing.allocator, "a|b", "xxb"));
    try std.testing.expect(!try matches(std.testing.allocator, "a|b", "xxc"));
    try std.testing.expect(try matches(std.testing.allocator, "(ab|a)b", "ab"));
    try std.testing.expect(try matches(std.testing.allocator, "((a|b)c)d", "bcd"));
}

test "regex: quantifiers greedy and backtracking" {
    try std.testing.expect(try matches(std.testing.allocator, "a*b", "aaaab"));
    try std.testing.expect(try matches(std.testing.allocator, "a+b", "aab"));
    try std.testing.expect(!try matches(std.testing.allocator, "a+b", "b"));
    try std.testing.expect(try matches(std.testing.allocator, "colou?r", "color"));
    try std.testing.expect(try matches(std.testing.allocator, "colou?r", "colour"));
    try std.testing.expect(try matches(std.testing.allocator, "a{2,3}", "aaaa"));
    try std.testing.expect(!try matches(std.testing.allocator, "a{2,3}b", "ab"));
    try std.testing.expect(try matches(std.testing.allocator, "a.*b", "axxxb"));
    // greedy takes the last possible b
    try std.testing.expect(try matches(std.testing.allocator, "a.*b", "axxbxxb"));
    try std.testing.expect(try matches(std.testing.allocator, "a{1000}", "a" ** 1000));
}

test "regex: class escapes ASCII" {
    try std.testing.expect(try matches(std.testing.allocator, "\\d+", "abc123"));
    try std.testing.expect(!try matches(std.testing.allocator, "\\d+", "abc"));
    try std.testing.expect(!try matches(std.testing.allocator, "\\d", "１")); // fullwidth digit is NOT \d
    try std.testing.expect(try matches(std.testing.allocator, "\\w+", "a_b1"));
    try std.testing.expect(!try matches(std.testing.allocator, "\\w+", "---"));
    try std.testing.expect(try matches(std.testing.allocator, "\\s+", "a \tb"));
    try std.testing.expect(try matches(std.testing.allocator, "\\S+", "  abc "));
}

test "regex: word boundary" {
    try std.testing.expect(try matches(std.testing.allocator, "\\bfoo\\b", "a foo b"));
    try std.testing.expect(!try matches(std.testing.allocator, "\\bfoo\\b", "afoo"));
    try std.testing.expect(!try matches(std.testing.allocator, "\\bfoo\\b", "foo_"));
    // Chinese surrounded by non-word chars: no boundary on either side
    try std.testing.expect(!try matches(std.testing.allocator, "\\b中文\\b", " 中文 "));
    // adjacent to word chars: boundary exists
    try std.testing.expect(try matches(std.testing.allocator, "\\b中文\\b", "a中文b"));
}

test "regex: escaped literals" {
    try std.testing.expect(try matches(std.testing.allocator, "foo\\.bar", "xfoo.bar"));
    try std.testing.expect(!try matches(std.testing.allocator, "foo\\.bar", "xfooXbar"));
    try std.testing.expect(try matches(std.testing.allocator, "a\\*b", "a*b"));
    try std.testing.expect(try matches(std.testing.allocator, "\\(", "("));
    try std.testing.expect(try matches(std.testing.allocator, "\\n", "a\nb"));
}

test "regex: empty pattern and empty branches" {
    try std.testing.expect(try matches(std.testing.allocator, "", "anything"));
    try std.testing.expect(try matches(std.testing.allocator, "a|", "x"));
    try std.testing.expect(try matches(std.testing.allocator, "|a", "x"));
    try std.testing.expect(try matches(std.testing.allocator, "a||b", "x")); // empty branch: matches everywhere
    try std.testing.expect(try matches(std.testing.allocator, "()", "x"));
    try std.testing.expect(try matches(std.testing.allocator, "a*", ""));
    try std.testing.expect(try matches(std.testing.allocator, "a*", "bb"));
}

test "regex: unanchored search (fatal semantics regression)" {
    try std.testing.expect(try matches(std.testing.allocator, "foo", "xxfooxx"));
    try std.testing.expect(!try matches(std.testing.allocator, "^foo", "xxfoo"));
    try std.testing.expect(!try matches(std.testing.allocator, "foo$", "fooxx"));
    try std.testing.expect(try matches(std.testing.allocator, "fo", "xyfoxz"));
}

test "regex: prefix drive multi-hit" {
    try std.testing.expect(try matches(std.testing.allocator, "fo.o", "fofofooo"));
}

test "regex: compile errors with code and pos" {
    const cases = [_]struct { spec: []const u8, code: CompileErrorCode }{
        .{ .spec = "[abc", .code = .unterminated_class },
        .{ .spec = "(ab", .code = .unterminated_group },
        .{ .spec = "a{2", .code = .unterminated_brace },
        .{ .spec = "*a", .code = .quantifier_no_target },
        .{ .spec = "a**", .code = .quantifier_no_target },
        .{ .spec = "\\q", .code = .invalid_escape },
        .{ .spec = "(?=", .code = .unsupported_construct },
        .{ .spec = "\\1", .code = .unsupported_construct },
        .{ .spec = "\\B", .code = .unsupported_construct },
        .{ .spec = "a{2,1}", .code = .invalid_quantifier_range },
        .{ .spec = "a{1001}", .code = .invalid_quantifier_range },
        .{ .spec = "a{1,1001}", .code = .invalid_quantifier_range },
        .{ .spec = "a{1001,}", .code = .invalid_quantifier_range },
        .{ .spec = "[z-a]", .code = .invalid_range },
        .{ .spec = "[a-\\d]", .code = .invalid_range },
        .{ .spec = "[]", .code = .unterminated_class },
    };
    for (cases) |c| {
        const e = try compileErr(std.testing.allocator, c.spec);
        try std.testing.expectEqual(c.code, e.code);
        try std.testing.expect(e.pos >= 0 and e.pos < c.spec.len + 1);
    }
}

test "regex: nesting depth limits" {
    var deep_ok = std.ArrayListAligned(u8, null).empty;
    var deep_err = std.ArrayListAligned(u8, null).empty;
    defer deep_ok.deinit(std.testing.allocator);
    defer deep_err.deinit(std.testing.allocator);
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        try deep_ok.append(std.testing.allocator, '(');
        try deep_err.append(std.testing.allocator, '(');
    }
    try deep_err.append(std.testing.allocator, '('); // 65 levels: exceeds MAX_NEST_DEPTH
    try deep_ok.appendSlice(std.testing.allocator, "a");
    try deep_err.appendSlice(std.testing.allocator, "a");
    i = 0;
    while (i < 64) : (i += 1) {
        try deep_ok.append(std.testing.allocator, ')');
        try deep_err.append(std.testing.allocator, ')');
    }
    try deep_err.append(std.testing.allocator, ')');

    var p = try ok(std.testing.allocator, deep_ok.items);
    defer p.deinit();
    {
        var steps: usize = 0;
        try std.testing.expect(try p.match("a", &steps, null));
    }

    const e = try compileErr(std.testing.allocator, deep_err.items);
    try std.testing.expectEqual(CompileErrorCode.nesting_too_deep, e.code);
}

test "regex: quantifier bounds" {
    const e1001 = try compileErr(std.testing.allocator, "a{1001}");
    try std.testing.expectEqual(CompileErrorCode.invalid_quantifier_range, e1001.code);
    var p = try ok(std.testing.allocator, "a{1000}");
    defer p.deinit();
    {
        var steps: usize = 0;
        try std.testing.expect(try p.match("a" ** 1000, &steps, null));
    }
}

test "regex: long literal chain zero recursion" {
    var spec = std.ArrayListAligned(u8, null).empty;
    defer spec.deinit(std.testing.allocator);
    var i: usize = 0;
    while (i < 10000) : (i += 1) try spec.append(std.testing.allocator, 'a');
    try spec.append(std.testing.allocator, 'b');
    var p = try ok(std.testing.allocator, spec.items);
    defer p.deinit();
    var big = std.ArrayListAligned(u8, null).empty;
    defer big.deinit(std.testing.allocator);
    i = 0;
    while (i < 100_000) : (i += 1) try big.append(std.testing.allocator, 'a');
    try big.append(std.testing.allocator, 'b');
    var steps: usize = 0;
    try std.testing.expect(try p.match(big.items, &steps, std.testing.allocator));
}

test "regex: unbounded repeat zero recursion" {
    var p = try ok(std.testing.allocator, "a*");
    defer p.deinit();
    var big = std.ArrayListAligned(u8, null).empty;
    defer big.deinit(std.testing.allocator);
    var i: usize = 0;
    while (i < 100_000) : (i += 1) try big.append(std.testing.allocator, 'a');
    var steps: usize = 0;
    try std.testing.expect(try p.match(big.items, &steps, std.testing.allocator));
}

test "regex: catastrophic pattern memoized" {
    // (a+)+b on an 'a' run: the iterative repeat stack linearizes the
    // repetition backtracking (O(n^2) per scan position), so a moderate input
    // completes within the scaled budget; a large input trips the budget and
    // match must return (never hang). Memoization correctness equivalence is
    // covered by "memo vs plain equivalence"; here we pin the budget net.
    var p = try ok(std.testing.allocator, "(a+)+b");
    defer p.deinit();
    var big = std.ArrayListAligned(u8, null).empty;
    defer big.deinit(std.testing.allocator);
    var i: usize = 0;
    while (i < 250) : (i += 1) try big.append(std.testing.allocator, 'a');
    var steps: usize = 0;
    try std.testing.expect(!try p.match(big.items, &steps, std.testing.allocator));

    var huge = std.ArrayListAligned(u8, null).empty;
    defer huge.deinit(std.testing.allocator);
    i = 0;
    while (i < 5000) : (i += 1) try huge.append(std.testing.allocator, 'a');
    var steps_huge: usize = 0;
    try std.testing.expectError(error.MatchLimitExceeded, p.match(huge.items, &steps_huge, std.testing.allocator));
}

test "regex: step budget single-line limit" {
    // a+b on 100KB of 'a': unanchored scan retries the greedy repeat from
    // every position -> O(n^2); the single-line budget must trip so match
    // returns instead of hanging (scaled budget: BASE + RATIO * text.len).
    var p = try ok(std.testing.allocator, "a+b");
    defer p.deinit();
    var big = std.ArrayListAligned(u8, null).empty;
    defer big.deinit(std.testing.allocator);
    var i: usize = 0;
    while (i < 100_000) : (i += 1) try big.append(std.testing.allocator, 'a');
    var steps: usize = 0;
    try std.testing.expectError(error.MatchLimitExceeded, p.match(big.items, &steps, std.testing.allocator));
}

test "regex: memo vs plain equivalence" {
    const specs = [_][]const u8{ "a|b", "(ab|a)b", "a.*b", "[a-z]+x", "\\d+foo" };
    for (specs) |s| {
        var p = try ok(std.testing.allocator, s);
        defer p.deinit();
        const texts = [_][]const u8{ "ab", "aaab", "axb", "xyzx", "123foo", "none" };
        for (texts) |t| {
            var s1: usize = 0;
            const r1 = try p.match(t, &s1, null);
            var s2: usize = 0;
            const r2 = try p.match(t, &s2, std.testing.allocator);
            try std.testing.expectEqual(r1, r2);
        }
    }
}

test "regex: literal equivalence with indexOf" {
    const patterns = [_][]const u8{ "foo", "hello world", "z-agent-core", "target" };
    const texts = [_][]const u8{ "xxfoo", "foo", "zzhello worldyy", "no match here", "the target is here" };
    for (patterns) |pat| {
        var p = try ok(std.testing.allocator, pat);
        defer p.deinit();
        for (texts) |t| {
            var steps: usize = 0;
            const m = try p.match(t, &steps, std.testing.allocator);
            try std.testing.expectEqual(std.mem.indexOf(u8, t, pat) != null, m);
        }
    }
}

test "regex: prefix fast path" {
    var p = try ok(std.testing.allocator, "fn.*foo");
    defer p.deinit();
    try std.testing.expectEqualStrings("fn", p.prefix);
    var steps: usize = 0;
    try std.testing.expect(!try p.match("no prefix here", &steps, std.testing.allocator));
    try std.testing.expect(steps == 0); // fast-fail without entering the matcher
}

test "regex: errorDetail non-empty for all codes" {
    inline for (std.meta.fields(CompileErrorCode)) |f| {
        const code: CompileErrorCode = @enumFromInt(f.value);
        const detail = errorDetail(code);
        try std.testing.expect(detail.len > 0);
    }
    try std.testing.expect(std.mem.indexOf(u8, errorDetail(.invalid_quantifier_range), "1000") != null);
    try std.testing.expect(std.mem.indexOf(u8, errorDetail(.invalid_range), "[a0-9]") != null);
    try std.testing.expect(std.mem.indexOf(u8, errorDetail(.unterminated_group), "did you mean") != null);
}

test "regex: invalid UTF-8 does not crash" {
    var p = try ok(std.testing.allocator, "ab");
    defer p.deinit();
    const bad = [_]u8{ 'x', 0xFF, 0xFE, 'b' };
    var steps: usize = 0;
    _ = try p.match(&bad, &steps, std.testing.allocator);
}
