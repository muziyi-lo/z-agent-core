const std = @import("std");

/// Lightweight TOML parser supporting the config subset:
/// - Key-value pairs: key = "string", key = 123, key = true/false
/// - [table] and [[table_array]] headers
/// - Inline comments (#)
/// - String arrays: key = ["a", "b"]
/// - Empty lines and whitespace ignored
pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    boolean: bool,
    array: []const Value,
    table: std.StringArrayHashMapUnmanaged(Value),
};

pub const ParseError = error{
    InvalidToml,
};

/// Parse a TOML source string into a flat table.
/// `[[providers]]` becomes an array under the key "providers".
/// `[permissions]` becomes a table under the key "permissions".
pub fn parse(allocator: std.mem.Allocator, source: []const u8) !std.StringArrayHashMapUnmanaged(Value) {
    var root = std.StringArrayHashMapUnmanaged(Value){};
    errdefer freeTable(allocator, &root);

    // Track table arrays as Managed lists to avoid pointer invalidation
    var arr_list = std.StringArrayHashMapUnmanaged(ManagedValueList){};
    defer {
        var it = arr_list.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        arr_list.deinit(allocator);
    }

    // Current context tracking (resolved on each key-value assignment)
    var ctx_table_name: []const u8 = ""; // "" = root, else key in root
    var ctx_array_name: []const u8 = ""; // "" = not in array, else key in arr_list
    var ctx_array_index: usize = 0;

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r') raw_line[0 .. raw_line.len - 1] else raw_line;
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        const effective = stripInlineComment(line);
        const e_trimmed = std.mem.trim(u8, effective, " \t");
        if (e_trimmed.len == 0) continue;

        // Table header: [table] or [[table_array]]
        if (e_trimmed[0] == '[') {
            if (e_trimmed.len > 1 and e_trimmed[1] == '[') {
                // [[table_array]]
                const close = std.mem.indexOfPos(u8, e_trimmed, 2, "]]") orelse {
                    return error.InvalidToml;
                };
                const name = std.mem.trim(u8, e_trimmed[2..close], " \t");
                if (name.len == 0) return error.InvalidToml;

                const name_dup = try allocator.dupe(u8, name);
                errdefer allocator.free(name_dup);

                const gop = try arr_list.getOrPut(allocator, name_dup);
                if (!gop.found_existing) {
                    gop.key_ptr.* = name_dup;
                    gop.value_ptr.* = ManagedValueList.init(allocator);
                } else {
                    allocator.free(name_dup);
                }

                // Append new empty table
                const new_table = std.StringArrayHashMapUnmanaged(Value){};
                try gop.value_ptr.*.append(Value{ .table = new_table });

                // Update context
                ctx_array_name = gop.key_ptr.*;
                ctx_array_index = gop.value_ptr.*.items.len - 1;
                ctx_table_name = "";
            } else {
                // [table]
                const close = std.mem.indexOfScalar(u8, e_trimmed[1..], ']') orelse {
                    return error.InvalidToml;
                };
                const name = std.mem.trim(u8, e_trimmed[1 .. 1 + close], " \t");
                if (name.len == 0) return error.InvalidToml;

                const entry = try root.getOrPut(allocator, name);
                if (!entry.found_existing) {
                    entry.key_ptr.* = try allocator.dupe(u8, name);
                    const t = std.StringArrayHashMapUnmanaged(Value){};
                    entry.value_ptr.* = Value{ .table = t };
                }
                if (entry.value_ptr.* != .table) return error.InvalidToml;

                ctx_table_name = entry.key_ptr.*;
                ctx_array_name = "";
            }
            continue;
        }

        // key = value
        const eq_pos = findEquals(e_trimmed) orelse {
            return error.InvalidToml;
        };
        const key = std.mem.trim(u8, e_trimmed[0..eq_pos], " \t");
        if (key.len == 0) return error.InvalidToml;

        const val_raw = std.mem.trim(u8, e_trimmed[eq_pos + 1 ..], " \t");
        if (val_raw.len == 0) return error.InvalidToml;

        var val = try parseValue(allocator, val_raw);
        errdefer freeValue(allocator, &val);

        // Assign to current context
        const target = if (ctx_array_name.len > 0) ctx: {
            const arr = arr_list.getPtr(ctx_array_name).?;
            break :ctx &arr.items[ctx_array_index].table;
        } else if (ctx_table_name.len > 0) ctx: {
            break :ctx &root.getPtr(ctx_table_name).?.table;
        } else
            &root;

        const entry = try target.getOrPut(allocator, key);
        if (entry.found_existing) {
            freeValue(allocator, entry.value_ptr);
        } else {
            entry.key_ptr.* = try allocator.dupe(u8, key);
        }
        entry.value_ptr.* = val;
    }

    // Convert arr_list to root entries
    var arr_it = arr_list.iterator();
    while (arr_it.next()) |entry| {
        const slice = try entry.value_ptr.toOwnedSlice();

        const key_owned = try allocator.dupe(u8, entry.key_ptr.*);
        const root_entry = try root.getOrPut(allocator, key_owned);
        if (root_entry.found_existing) {
            allocator.free(key_owned);
            freeValue(allocator, root_entry.value_ptr);
        } else {
            root_entry.key_ptr.* = key_owned;
        }
        root_entry.value_ptr.* = Value{ .array = slice };
    }

    return root;
}


const ManagedValueList = std.array_list.Managed(Value);

/// Free all owned memory in a Value recursively.
pub fn freeValue(allocator: std.mem.Allocator, val: *Value) void {
    switch (val.*) {
        .string => |s| allocator.free(s),
        .integer => {},
        .boolean => {},
        .array => |arr| {
            const mut_arr: []Value = @constCast(arr);
            for (mut_arr) |*item| freeValue(allocator, item);
            allocator.free(mut_arr);
        },
        .table => |*t| freeTable(allocator, t),
    }
}

pub fn freeTable(allocator: std.mem.Allocator, t: *std.StringArrayHashMapUnmanaged(Value)) void {
    var it = t.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        freeValue(allocator, entry.value_ptr);
    }
    t.deinit(allocator);
}

/// Find '=' that is not inside a string.
fn findEquals(s: []const u8) ?usize {
    var in_string = false;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\') {
            i += 2;
            continue;
        }
        if (s[i] == '"') {
            in_string = !in_string;
            i += 1;
            continue;
        }
        if (!in_string and s[i] == '=') return i;
        i += 1;
    }
    return null;
}

/// Strip inline comment (# not in string, preceded by space or at line start after trim).
fn stripInlineComment(line: []const u8) []const u8 {
    var in_string = false;
    var i: usize = 0;
    while (i < line.len) {
        switch (line[i]) {
            '\\' => {
                i += 2;
            },
            '"' => {
                in_string = !in_string;
                i += 1;
            },
            '#' => {
                if (!in_string) {
                    if (i == 0 or line[i - 1] == ' ' or line[i - 1] == '\t') {
                        var end = i;
                        while (end > 0 and (line[end - 1] == ' ' or line[end - 1] == '\t')) {
                            end -= 1;
                        }
                        return line[0..end];
                    }
                }
                i += 1;
            },
            else => {
                i += 1;
            },
        }
    }
    return line;
}

/// Parse a string value with escape sequences.
fn parseString(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\') {
            i += 1;
            if (i >= s.len) return error.InvalidToml;
            switch (s[i]) {
                '"' => try result.append('"'),
                '\\' => try result.append('\\'),
                'n' => try result.append('\n'),
                't' => try result.append('\t'),
                'r' => try result.append('\r'),
                else => return error.InvalidToml,
            }
        } else {
            try result.append(s[i]);
        }
        i += 1;
    }
    return result.toOwnedSlice();
}

/// Parse a TOML value from raw text (after stripping comment and whitespace).
fn parseValue(allocator: std.mem.Allocator, raw: []const u8) !Value {
    const trimmed = std.mem.trim(u8, raw, " \t");

    // String
    if (trimmed.len >= 2 and trimmed[0] == '"') {
        if (trimmed[trimmed.len - 1] != '"') return error.InvalidToml;
        const content = trimmed[1 .. trimmed.len - 1];
        return Value{ .string = try parseString(allocator, content) };
    }

    // Array
    if (trimmed.len >= 2 and trimmed[0] == '[') {
        if (trimmed[trimmed.len - 1] != ']') return error.InvalidToml;
        const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t");
        if (inner.len == 0) return Value{ .array = &.{} };

        var items = std.array_list.Managed(Value).init(allocator);
        errdefer {
            for (items.items) |*item| freeValue(allocator, item);
            items.deinit();
        }

        var pos: usize = 0;
        while (pos < inner.len) {
            while (pos < inner.len and (inner[pos] == ' ' or inner[pos] == '\t')) {
                pos += 1;
            }
            if (pos >= inner.len) break;

            var end = pos;
            var in_str = false;
            while (end < inner.len) {
                if (in_str) {
                    if (inner[end] == '\\') {
                        end += 2;
                        continue;
                    }
                    if (inner[end] == '"') in_str = false;
                    end += 1;
                } else {
                    if (inner[end] == '"') in_str = true;
                    if (inner[end] == ',') break;
                    end += 1;
                }
            }

            const item_raw = std.mem.trim(u8, inner[pos..end], " \t");
            if (item_raw.len == 0) {
                pos = end + 1;
                continue;
            }
            const item = try parseValue(allocator, item_raw);
            try items.append(item);
            pos = end + 1;
        }

        return Value{ .array = try items.toOwnedSlice() };
    }

    // Boolean
    if (std.mem.eql(u8, trimmed, "true")) return Value{ .boolean = true };
    if (std.mem.eql(u8, trimmed, "false")) return Value{ .boolean = false };

    // Integer
    if (trimmed.len > 0 and (trimmed[0] == '-' or std.ascii.isDigit(trimmed[0]))) {
        const val = std.fmt.parseInt(i64, trimmed, 10) catch return error.InvalidToml;
        return Value{ .integer = val };
    }

    return error.InvalidToml;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "toml: parses simple key-value pairs" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const toml =
        \\key = "value"
        \\num = 42
        \\flag = true
        \\no = false
    ;

    var result = try parse(allocator, toml);
    defer freeTable(allocator, &result);

    try testing.expect(result.count() == 4);

    try testing.expect(std.mem.eql(u8, result.get("key").?.string, "value"));
    try testing.expect(result.get("num").?.integer == 42);
    try testing.expect(result.get("flag").?.boolean == true);
    try testing.expect(result.get("no").?.boolean == false);
}

test "toml: handles inline comments" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const toml =
        \\key = "value" # this is a comment
        \\num = 7 # trailing
        \\# whole line comment
    ;

    var result = try parse(allocator, toml);
    defer freeTable(allocator, &result);

    try testing.expect(result.count() == 2);
    try testing.expect(std.mem.eql(u8, result.get("key").?.string, "value"));
    try testing.expect(result.get("num").?.integer == 7);
}

test "toml: parses string arrays" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const toml =
        \\models = ["a", "b", "c"]
    ;

    var result = try parse(allocator, toml);
    defer freeTable(allocator, &result);

    const arr = result.get("models").?.array;
    try testing.expect(arr.len == 3);
    try testing.expect(std.mem.eql(u8, arr[0].string, "a"));
    try testing.expect(std.mem.eql(u8, arr[1].string, "b"));
    try testing.expect(std.mem.eql(u8, arr[2].string, "c"));
}

test "toml: parses table array [[providers]]" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const toml =
        \\[[providers]]
        \\name = "deepseek"
        \\kind = "openai"
        \\
        \\[[providers]]
        \\name = "openai"
        \\kind = "openai"
    ;

    var result = try parse(allocator, toml);
    defer freeTable(allocator, &result);

    const arr = result.get("providers").?.array;
    try testing.expect(arr.len == 2);
    try testing.expect(std.mem.eql(u8, arr[0].table.get("name").?.string, "deepseek"));
    try testing.expect(std.mem.eql(u8, arr[1].table.get("name").?.string, "openai"));
    try testing.expect(std.mem.eql(u8, arr[1].table.get("kind").?.string, "openai"));
}

test "toml: parses [table] section" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const toml =
        \\mode = "confirm"
        \\
        \\[permissions]
        \\allow = ["Read", "Glob"]
    ;

    var result = try parse(allocator, toml);
    defer freeTable(allocator, &result);

    try testing.expect(std.mem.eql(u8, result.get("mode").?.string, "confirm"));
    const perm = result.get("permissions").?.table;
    const allow_arr = perm.get("allow").?.array;
    try testing.expect(allow_arr.len == 2);
    try testing.expect(std.mem.eql(u8, allow_arr[0].string, "Read"));
}

test "toml: handles escape sequences in strings" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const toml =
        \\text = "line1\nline2"
        \\quote = "say \"hi\""
    ;

    var result = try parse(allocator, toml);
    defer freeTable(allocator, &result);

    const text = result.get("text").?.string;
    try testing.expect(std.mem.indexOfScalar(u8, text, '\n') != null);
    try testing.expect(std.mem.eql(u8, result.get("quote").?.string, "say \"hi\""));
}

test "toml: error on invalid syntax" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const toml = "key = noquote";
    const result = parse(allocator, toml);
    try testing.expect(result == error.InvalidToml);
}

test "toml: error on unclosed string" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const toml = "key = \"unclosed";
    const result = parse(allocator, toml);
    try testing.expect(result == error.InvalidToml);
}

test "toml: empty source returns empty table" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var result = try parse(allocator, "");
    defer freeTable(allocator, &result);
    try testing.expect(result.count() == 0);
}

test "toml: comment-only content" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var result = try parse(allocator, "# just a comment\n\n  # another\n");
    defer freeTable(allocator, &result);
    try testing.expect(result.count() == 0);
}

test "toml: parses full config example" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const toml =
        \\default_model = "deepseek/deepseek-v4-flash"
        \\max_tokens = 4096
        \\
        \\[[providers]]
        \\name = "deepseek"
        \\kind = "openai"
        \\base_url = "https://api.deepseek.com"
        \\models = ["deepseek-v4-flash", "deepseek-v4-pro"]
        \\default_model = "deepseek-v4-flash"
        \\api_key_env = "DEEPSEEK_API_KEY"
        \\context_limit = 1048576
        \\max_tokens = 8192
        \\vision = true
        \\effort = "high"
        \\
        \\[[providers]]
        \\name = "openai"
        \\kind = "openai"
        \\base_url = "https://api.openai.com"
        \\models = ["gpt-4o"]
        \\api_key_env = "OPENAI_API_KEY"
        \\context_limit = 128000
        \\
        \\[permissions]
        \\mode = "confirm"
        \\allow = []
        \\ask = []
        \\deny = ["Bash(rm -rf *)"]
    ;

    var result = try parse(allocator, toml);
    defer freeTable(allocator, &result);

    try testing.expect(std.mem.eql(u8, result.get("default_model").?.string, "deepseek/deepseek-v4-flash"));
    try testing.expect(result.get("max_tokens").?.integer == 4096);

    const providers = result.get("providers").?.array;
    try testing.expect(providers.len == 2);
    try testing.expect(std.mem.eql(u8, providers[0].table.get("name").?.string, "deepseek"));
    try testing.expect(std.mem.eql(u8, providers[1].table.get("name").?.string, "openai"));
    try testing.expect(providers[0].table.get("vision").?.boolean == true);
    try testing.expect(providers[0].table.get("context_limit").?.integer == 1048576);

    const perm = result.get("permissions").?.table;
    try testing.expect(std.mem.eql(u8, perm.get("mode").?.string, "confirm"));
    try testing.expect(perm.get("allow").?.array.len == 0);
    try testing.expect(perm.get("deny").?.array.len == 1);
    try testing.expect(std.mem.eql(u8, perm.get("deny").?.array[0].string, "Bash(rm -rf *)"));
}

test "toml: [table] context persists until next header" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const toml =
        \\top = "root"
        \\
        \\[section]
        \\sub = "value"
        \\also = "section"
        \\
        \\[other]
        \\x = "y"
        \\
        \\key = "other"
    ;

    var result = try parse(allocator, toml);
    defer freeTable(allocator, &result);

    try testing.expect(std.mem.eql(u8, result.get("top").?.string, "root"));
    const section = result.get("section").?.table;
    try testing.expect(std.mem.eql(u8, section.get("sub").?.string, "value"));
    try testing.expect(std.mem.eql(u8, section.get("also").?.string, "section"));

    const other = result.get("other").?.table;
    try testing.expect(std.mem.eql(u8, other.get("x").?.string, "y"));
    try testing.expect(std.mem.eql(u8, other.get("key").?.string, "other"));
}
