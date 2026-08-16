const std = @import("std");
const Io = std.Io;
const toml = @import("toml.zig");
const types = @import("types.zig");

const ConfigToml = std.StringArrayHashMapUnmanaged(toml.Value);

/// Known top-level config keys (parseConfigContent consumers). Unknown keys
/// trigger a warning so typos surface instead of silently doing nothing.
const top_level_keys = [_][]const u8{
    "default_model", "max_tokens", "max_tool_rounds", "base_prompt", "skills_dir",
    "auto_title", "title_stop_words", "approval_mode", "approval_allow", "approval_cache",
    "thinking_level", "providers", "models", "models.compat",
};
/// Known per-model keys (parseAllModels consumers).
const model_keys = [_][]const u8{ "id", "name", "provider", "context_window", "max_tokens", "params_json", "input", "compat", "thinking_level" };
/// Known per-provider keys (parseProviders consumers).
const provider_keys = [_][]const u8{ "name", "api", "base_url", "api_key_env", "models" };

/// Warn about keys in `table` that are not in `known`. This catches
/// misspelled keys (`imput = [...]`) and misplaced keys before they silently
/// degrade to defaults.
fn warnUnknownKeys(io: Io, table: *const ConfigToml, known: []const []const u8, context: []const u8) void {
    var it = table.iterator();
    while (it.next()) |entry| {
        var matched = false;
        for (known) |k| {
            if (std.mem.eql(u8, entry.key_ptr.*, k)) {
                matched = true;
                break;
            }
        }
        if (!matched) {
            var warn_buf: [512]u8 = undefined;
            var warn_w: Io.File.Writer = .init(.stderr(), io, &warn_buf);
            warn_w.interface.print("z-agent-core: warning: unknown config key \"{s}\" in {s} — check the spelling (it was ignored)\n", .{ entry.key_ptr.*, context }) catch {};
            warn_w.interface.flush() catch {};
        }
    }
}

/// Configuration loaded from .zagent/config.toml.
/// Caller must call deinit() to release all owned memory.
pub const Config = struct {
    default_model: []const u8,
    max_tokens: u32,
    max_tool_rounds: u32,
    providers: []const types.ProviderEntry,
    base_prompt: ?[]const u8 = null,
    /// Skill root directory relative to project_root. Configurable so users can
    /// point at another tool's skills dir (e.g. .opencode/skills).
    skills_dir: []const u8 = ".zagent/skills",
    /// Auto-generate a conversational title with the LLM after the second turn.
    /// Set false to keep static naming (Web prompt-prefix, CLI "New Session").
    auto_title: bool = true,
    /// Extra stopwords appended to the built-in conservative STOPWORDS set for
    /// the L2 keyword fallback title. User domain-specific noise words.
    title_stop_words: []const []const u8 = &.{},
    /// Tool approval policy: "never" / "risky" / "always" (see src/approval.zig
    /// Mode). risky = only enumerated destructive bash commands (L1 rules).
    approval_mode: []const u8 = "risky",
    /// Exact normalized command whitelist exempt from approval. A command is
    /// exempt when `args.command` trimmed with whitespace collapsed to single
    /// spaces equals an entry exactly (case-sensitive). Coverage list: see
    /// docs/0.2.8/PLAN-N16-APPROVAL-PREVIEW.md category table (grows per version).
    approval_allow: []const []const u8 = &.{},
    /// Skip the approval prompt when the exact name+args pair was already
    /// approved in this round (SSE connection). Set false to prompt every time.
    approval_cache: bool = true,

    _arena: std.heap.ArenaAllocator,

    /// Load config from project_root/.zagent/config.toml.
    /// If the file does not exist, creates default template and returns it.
    /// Uses internal ArenaAllocator: caller only needs to call deinit().
    pub fn load(allocator: std.mem.Allocator, project_root: []const u8, io: std.Io) !Config {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const path = try std.fs.path.join(arena.allocator(), &.{ project_root, ".zagent", "config.toml" });

        const content = readFile(arena.allocator(), path, io) catch |err| switch (err) {
            error.FileNotFound => {
                var result = try parseConfigContent(arena.allocator(), io, DEFAULT_TEMPLATE);
                try writeDefaultConfig(arena.allocator(), project_root, io);
                {
                    var stderr_buf: [256]u8 = undefined;
                    var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
                    try stderr_writer.interface.print("z-agent-core: config created at .zagent/config.toml\n", .{});
                }
                result._arena = arena;
                return result;
            },
            else => return err,
        };

        var result = try parseConfigContent(arena.allocator(), io, content);
        try validateConfig(&result, io);

        result._arena = arena;
        return result;
    }

    /// Release all config-owned memory. Safe to call on zero-value Config.
    pub fn deinit(self: *Config) void {
        self._arena.deinit();
    }
};

/// Walk up from CWD to find .zagent/config.toml.
/// Caller owns returned string, must free with allocator.
pub fn findZagentRoot(allocator: std.mem.Allocator, io: std.Io) ?[]const u8 {
    var buf: [4096]u8 = undefined;
    const len = Io.Dir.cwd().realPath(io, &buf) catch {
        var dbuf: [256]u8 = undefined;
        var dw: Io.File.Writer = .init(.stderr(), io, &dbuf);
        _ = dw.interface.writeAll("z-agent-core: error: cannot resolve working directory\n") catch {};
        _ = dw.interface.flush() catch {};
        return null;
    };
    const start_path = allocator.dupe(u8, buf[0..len]) catch return null;
    defer allocator.free(start_path);
    var current: []const u8 = start_path;

    while (true) {
        const cfg_path = std.fs.path.join(allocator, &.{ current, ".zagent", "config.toml" }) catch return null;
        defer allocator.free(cfg_path);

        if (Io.Dir.cwd().openFile(io, cfg_path, .{ .mode = .read_only })) |file| {
            file.close(io);
            return allocator.dupe(u8, current) catch return null;
        } else |_| {}

        const parent = std.fs.path.dirname(current) orelse return null;
        if (std.mem.eql(u8, parent, current)) return null;
        current = parent;
    }
}

/// Write a best-effort .env warning to stderr. comptime fmt keeps the prefix
/// string concatenated at compile time. config.zig runs before log.init, so
/// util/log.zig's global io is unavailable here.
fn warnEnv(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    var w: Io.File.Writer = .init(.stderr(), io, &buf);
    w.interface.print("z-agent-core: warning: .env: " ++ fmt ++ "\n", args) catch {};
    w.interface.flush() catch {};
}

/// Parse .zagent/.env into KEY=VALUE map.
/// Malformed lines (no '=', empty key, unclosed quote) are warned and skipped.
/// Caller owns all entries: free each key/value, then deinit map.
pub fn loadDotEnv(allocator: std.mem.Allocator, project_root: []const u8, io: std.Io) !std.StringArrayHashMapUnmanaged([]const u8) {
    var map = std.StringArrayHashMapUnmanaged([]const u8){};
    errdefer {
        var it = map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        map.deinit(allocator);
    }

    const env_path = std.fs.path.join(allocator, &.{ project_root, ".zagent", ".env" }) catch return map;
    defer allocator.free(env_path);

    const content = readFile(allocator, env_path, io) catch return map;
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_no: usize = 0;
    while (lines.next()) |raw| {
        line_no += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            warnEnv(io, "line {d}: missing '=' ignored: '{s}'", .{ line_no, line });
            continue;
        };
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (key.len == 0) {
            warnEnv(io, "line {d}: empty key ignored", .{line_no});
            continue;
        }

        var value_raw = line[eq + 1 ..];

        var comment_pos: ?usize = null;
        var in_quotes = false;
        for (value_raw, 0..) |c, i| {
            if (c == '"') {
                in_quotes = !in_quotes;
            } else if (c == '#' and !in_quotes) {
                comment_pos = i;
                break;
            }
        }
        if (in_quotes) {
            warnEnv(io, "line {d}: unclosed quote for key '{s}'", .{ line_no, key });
            continue;
        }

        const value_before_comment = if (comment_pos) |pos| value_raw[0..pos] else value_raw;
        const value_trimmed = std.mem.trim(u8, value_before_comment, " \t");

        const value = if (value_trimmed.len >= 2 and value_trimmed[0] == '"' and value_trimmed[value_trimmed.len - 1] == '"')
            value_trimmed[1 .. value_trimmed.len - 1]
        else
            value_trimmed;

        const k_dup = try allocator.dupe(u8, key);
        errdefer allocator.free(k_dup);
        const v_dup = try allocator.dupe(u8, value);
        errdefer allocator.free(v_dup);
        try map.put(allocator, k_dup, v_dup);
    }

    return map;
}

/// Resolve API key: process env first, .env fallback. Empty = unset.
/// Returns a borrowed slice (env_map's owned copy or dotenv arena value);
/// caller must copy before env_map.deinit / arena teardown.
/// error.ApiKeyNotSet if neither source has a value.
pub fn resolveApiKey(
    env_map: *const std.process.Environ.Map,
    dotenv: ?*const std.StringArrayHashMapUnmanaged([]const u8),
    env_name: []const u8,
) ![]const u8 {
    var raw = env_map.get(env_name);
    if (raw == null or raw.?.len == 0) {
        if (dotenv) |fb| raw = fb.get(env_name);
    }
    if (raw == null or raw.?.len == 0) return error.ApiKeyNotSet;
    return raw.?;
}

/// Resolve "provider/model_id" to a Model pointer.
/// Returns pointer borrowed from config.providers, valid until deinit().
pub fn resolveModel(config: *const Config, spec: []const u8) !*const types.Model {
    const slash = std.mem.indexOfScalar(u8, spec, '/') orelse return error.InvalidModelSpec;
    const provider_name = spec[0..slash];
    const model_id = spec[slash + 1 ..];

    for (config.providers) |*p| {
        if (!std.mem.eql(u8, p.name, provider_name)) continue;
        for (p.models) |*m| {
            if (std.mem.eql(u8, m.id, model_id)) return m;
        }
        return error.ModelNotFound;
    }
    return error.ProviderNotFound;
}

fn validateConfig(config: *const Config, io: std.Io) !void {
    if (config.default_model.len == 0) return error.InvalidConfig_NoDefaultModel;
    for (config.providers) |p| {
        if (p.name.len == 0) return error.InvalidConfig_NameEmpty;
        if (p.base_url.len == 0) {
            var sbuf: [256]u8 = undefined;
            var sw: std.Io.File.Writer = .init(.stderr(), io, &sbuf);
            sw.interface.print("error: Provider has empty base_url.\n", .{}) catch {};
            sw.interface.flush() catch {};
            return error.InvalidConfig_BaseUrlEmpty;
        }
        if (p.api_key_env.len == 0) {
            var sbuf: [256]u8 = undefined;
            var sw: std.Io.File.Writer = .init(.stderr(), io, &sbuf);
            sw.interface.print("error: Provider has empty api_key_env.\n", .{}) catch {};
            sw.interface.flush() catch {};
            return error.InvalidConfig_ApiKeyEnvEmpty;
        }
        if (p.models.len == 0) {
            var sbuf: [256]u8 = undefined;
            var sw: std.Io.File.Writer = .init(.stderr(), io, &sbuf);
            sw.interface.print("error: Provider '{s}' has no valid models.\n", .{p.name}) catch {};
            sw.interface.print("       Each model ID in [[providers]].models needs a matching [[models]] block.\n", .{}) catch {};
            sw.interface.flush() catch {};
            return error.InvalidConfig_NoModels;
        }
        for (p.models) |m| {
            if (m.id.len == 0) return error.InvalidConfig_ModelIdEmpty;
            if (m.context_window == 0) {
                var sbuf: [256]u8 = undefined;
                var sw: std.Io.File.Writer = .init(.stderr(), io, &sbuf);
                sw.interface.print("error: Model '{s}' in provider '{s}' has context_window=0.\n", .{ m.id, p.name }) catch {};
                sw.interface.flush() catch {};
                return error.InvalidConfig_ContextWindowZero;
            }
        }
    }
}

fn parseConfigContent(a: std.mem.Allocator, io: Io, source: []const u8) !Config {
    var parsed = try toml.parse(a, source);
    defer toml.freeTable(a, &parsed);

    // N22: the lightweight TOML parser flattens nested tables — a
    // `[models.compat]` header routes subsequent keys (input,
    // thinking_format, ...) into root["models.compat"] where the model
    // parser never reads them. Warn loudly instead of silently dropping
    // (observed: input=["text","image"] written after [models.compat] was
    // ignored, leaving the model text-only).
    if (parsed.get("models.compat") != null) {
        var warn_buf: [512]u8 = undefined;
        var warn_w: Io.File.Writer = .init(.stderr(), io, &warn_buf);
        warn_w.interface.print("z-agent-core: warning: [models.compat] is not supported — its keys (input/thinking_format/...) were ignored. Move them directly into the [[models]] table, above any [models.compat] header.\n", .{}) catch {};
        warn_w.interface.flush() catch {};
    }

    // Unknown top-level keys: warn instead of silently ignoring (a typo like
    // `imput` or `max_token` would otherwise look configured but do nothing).
    warnUnknownKeys(io, &parsed, &top_level_keys, "top-level config");

    const dm_raw = getString(parsed, "default_model") orelse "deepseek/deepseek-v4-pro";
    const max_tokens_val = getInt(parsed, "max_tokens") orelse 384000;
    const max_tool_rounds_val = getInt(parsed, "max_tool_rounds") orelse 10;

    if (max_tokens_val > @as(i64, @intCast(std.math.maxInt(u32)))) return error.ValueTooLarge;
    if (max_tool_rounds_val > @as(i64, @intCast(std.math.maxInt(u32)))) return error.ValueTooLarge;

    const all_models = try parseAllModels(a, parsed, io);
    const bp_raw = getString(parsed, "base_prompt");
    const skills_dir_raw = getString(parsed, "skills_dir") orelse ".zagent/skills";
    const auto_title_val = getBool(parsed, "auto_title") orelse true;

    // title_stop_words: best-effort; type errors degrade to empty with a warning
    // (must not block app startup — it's a refinement knob, D5).
    var title_stop_words_val: []const []const u8 = &.{};
    title_stop_words_val = getStringArray(a, parsed, "title_stop_words") catch |err| blk: {
        if (err == error.InvalidType) {
            var warn_buf: [256]u8 = undefined;
            var warn_w: Io.File.Writer = .init(.stderr(), io, &warn_buf);
            warn_w.interface.print("z-agent-core: warning: title_stop_words ignored (expected a string array)\n", .{}) catch {};
            warn_w.interface.flush() catch {};
        }
        break :blk &.{};
    };

    const approval_mode_raw = getString(parsed, "approval_mode") orelse "risky";
    // approval_allow: best-effort; type errors degrade to empty with a warning
    // (a broken whitelist must not block startup — an empty list just means
    // every risky command prompts again).
    var approval_allow_val: []const []const u8 = &.{};
    approval_allow_val = getStringArray(a, parsed, "approval_allow") catch |err| blk: {
        if (err == error.InvalidType) {
            var warn_buf: [256]u8 = undefined;
            var warn_w: Io.File.Writer = .init(.stderr(), io, &warn_buf);
            warn_w.interface.print("z-agent-core: warning: approval_allow ignored (expected a string array)\n", .{}) catch {};
            warn_w.interface.flush() catch {};
        }
        break :blk &.{};
    };
    const approval_cache_val = getBool(parsed, "approval_cache") orelse true;

    return .{
        .default_model = try a.dupe(u8, dm_raw),
        .max_tokens = @intCast(@max(max_tokens_val, 0)),
        .max_tool_rounds = @intCast(@max(max_tool_rounds_val, 0)),
        .providers = try parseProviders(a, parsed, all_models, io),
        .base_prompt = if (bp_raw) |bp| try a.dupe(u8, bp) else null,
        .skills_dir = try a.dupe(u8, skills_dir_raw),
        .auto_title = auto_title_val,
        .title_stop_words = title_stop_words_val,
        .approval_mode = try a.dupe(u8, approval_mode_raw),
        .approval_allow = approval_allow_val,
        .approval_cache = approval_cache_val,
        ._arena = undefined,
    };
}

fn testParseConfig(allocator: std.mem.Allocator, source: []const u8) !Config {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var config = try parseConfigContent(arena.allocator(), std.testing.io, source);
    config._arena = arena;
    return config;
}

fn parseProviders(a: std.mem.Allocator, root: ConfigToml, all_models: []const types.Model, io: Io) ![]const types.ProviderEntry {
    const arr = root.get("providers") orelse return &.{};
    if (arr != .array) return error.InvalidConfig_ProvidersNotArray;
    var list = std.ArrayListAligned(types.ProviderEntry, null).empty;
    for (arr.array) |provider_table| {
        if (provider_table != .table) continue;
        const pt = provider_table.table;
        warnUnknownKeys(io, &pt, &provider_keys, "[[providers]] table");
        const name_raw = getString(pt, "name") orelse "";
        const base_url_raw = getString(pt, "base_url") orelse "";
        const key_env_raw = getString(pt, "api_key_env") orelse "";

        var models_list = std.ArrayListAligned(types.Model, null).empty;
        if (pt.get("models")) |models_val| {
            if (models_val == .array) {
                for (models_val.array) |m| {
                    if (m == .string) {
                        const model_id = m.string;
                        if (lookupModel(all_models, name_raw, model_id)) |found| {
                            try models_list.append(a, found);
                        }
                    }
                }
            }
        }

        try list.append(a, .{
            .name = try a.dupe(u8, name_raw),
            .api = parseApi(getString(pt, "api") orelse "openai_compat"),
            .base_url = try a.dupe(u8, base_url_raw),
            .models = try models_list.toOwnedSlice(a),
            .api_key_env = try a.dupe(u8, key_env_raw),
        });
    }
    return list.toOwnedSlice(a);
}

fn lookupModel(all_models: []const types.Model, provider_name: []const u8, model_id: []const u8) ?types.Model {
    var i: usize = all_models.len;
    while (i > 0) {
        i -= 1;
        const m = all_models[i];
        if ((m.provider.len == 0 or std.mem.eql(u8, m.provider, provider_name)) and
            std.mem.eql(u8, m.id, model_id))
        {
            return m;
        }
    }
    return null;
}

fn parseAllModels(a: std.mem.Allocator, root: ConfigToml, io: Io) ![]const types.Model {
    const arr = root.get("models") orelse return &.{};
    if (arr != .array) return &.{};
    var list = std.ArrayListAligned(types.Model, null).empty;
    for (arr.array) |model_table| {
        if (model_table != .table) continue;
        const mt = model_table.table;
        warnUnknownKeys(io, &mt, &model_keys, "[[models]] table");
        const id_raw = getString(mt, "id") orelse "";
        const name_raw = getString(mt, "name") orelse "";
        const provider_raw = getString(mt, "provider") orelse "";
        const cw_val = getInt(mt, "context_window") orelse 0;
        const mt_val = getInt(mt, "max_tokens") orelse 0;
        if (cw_val > @as(i64, @intCast(std.math.maxInt(u32)))) return error.ValueTooLarge;
        if (mt_val > @as(i64, @intCast(std.math.maxInt(u32)))) return error.ValueTooLarge;

        var model_compat: ?types.ModelCompatOverride = null;
        if (mt.get("compat")) |compat_val| {
            if (compat_val == .table) {
                var ov = types.ModelCompatOverride{};
                if (compat_val.table.get("thinking_format")) |v| {
                    if (v == .string) ov.thinking_format = parseThinkingFormat(v.string);
                }
                if (compat_val.table.get("max_tokens_field")) |v| {
                    if (v == .string) ov.max_tokens_field = parseMaxTokensField(v.string);
                }
                if (compat_val.table.get("supports_stream_options")) |v| {
                    if (v == .boolean) ov.supports_stream_options = v.boolean;
                }
                if (compat_val.table.get("supports_usage_in_streaming")) |v| {
                    if (v == .boolean) ov.supports_usage_in_streaming = v.boolean;
                }
                if (compat_val.table.get("require_reasoning_on_tool_calls")) |v| {
                    if (v == .boolean) ov.require_reasoning_on_tool_calls = v.boolean;
                }
                model_compat = ov;
            }
        }
        if (mt.get("thinking_level")) |tl_val| {
            if (tl_val == .string) {
                if (types.ThinkingLevel.fromString(tl_val.string)) |tl| {
                    if (model_compat == null) model_compat = types.ModelCompatOverride{};
                    model_compat.?.thinking_level = tl;
                }
            }
        }

        try list.append(a, .{
            .id = try a.dupe(u8, id_raw),
            .name = try a.dupe(u8, name_raw),
            .provider = try a.dupe(u8, provider_raw),
            .context_window = @intCast(cw_val),
            .max_tokens = @intCast(mt_val),
            .params_json = getString(mt, "params_json"),
            .compat = model_compat,
            .input = try parseInputModality(a, mt, io),
        });
    }
    return list.toOwnedSlice(a);
}

fn parseInputModality(a: std.mem.Allocator, mt: ConfigToml, io: Io) ![]const types.InputModality {
    const arr = mt.get("input") orelse {
        const duped = try a.dupe(types.InputModality, &.{.text});
        return duped;
    };
    if (arr != .array) {
        const duped = try a.dupe(types.InputModality, &.{.text});
        return duped;
    }
    var list = std.ArrayListAligned(types.InputModality, null).empty;
    for (arr.array) |v| {
        if (v == .string) {
            var matched = false;
            inline for (@typeInfo(types.InputModality).@"enum".fields) |field| {
                if (std.mem.eql(u8, v.string, field.name)) {
                    try list.append(a, @field(types.InputModality, field.name));
                    matched = true;
                }
            }
            // Unknown modality values are silently ignored today; warn so the
            // user notices a typo (e.g. input=["text","video"]) instead of
            // believing the modality is declared (N22 vision gating).
            if (!matched) {
                var warn_buf: [256]u8 = undefined;
                var warn_w: Io.File.Writer = .init(.stderr(), io, &warn_buf);
                warn_w.interface.print("z-agent-core: warning: input modality \"{s}\" ignored (expected text|image)\n", .{v.string}) catch {};
                warn_w.interface.flush() catch {};
            }
        }
    }
    if (list.items.len == 0) {
        const duped = try a.dupe(types.InputModality, &.{.text});
        return duped;
    }
    return list.toOwnedSlice(a);
}

fn parseThinkingFormat(s: []const u8) types.ThinkingFormat {
    inline for (@typeInfo(types.ThinkingFormat).@"enum".fields) |field| {
        if (std.mem.eql(u8, s, field.name)) return @field(types.ThinkingFormat, field.name);
    }
    return .none;
}

fn parseMaxTokensField(s: []const u8) types.MaxTokensField {
    inline for (@typeInfo(types.MaxTokensField).@"enum".fields) |field| {
        if (std.mem.eql(u8, s, field.name)) return @field(types.MaxTokensField, field.name);
    }
    return .max_tokens;
}

/// Merge TOML ModelCompatOverride into detectCompat result.
/// Only non-null override fields replace detected values.
pub fn resolveCompat(base_url: []const u8, model: *const types.Model) types.ModelCompat {
    var c = types.detectCompat(base_url);
    if (model.compat) |ov| {
        if (ov.thinking_format) |v| c.thinking_format = v;
        if (ov.thinking_level) |v| c.thinking_level = v;
        if (ov.max_tokens_field) |v| c.max_tokens_field = v;
        if (ov.supports_stream_options) |v| c.supports_stream_options = v;
        if (ov.supports_usage_in_streaming) |v| c.supports_usage_in_streaming = v;
        if (ov.require_reasoning_on_tool_calls) |v| c.require_reasoning_on_tool_calls = v;
    }
    return c;
}

fn parseApi(raw: []const u8) types.Api {
    inline for (@typeInfo(types.Api).@"enum".fields) |field| {
        if (std.mem.eql(u8, raw, field.name)) return @field(types.Api, field.name);
    }
    return .openai_compat;
}

fn getString(t: ConfigToml, key: []const u8) ?[]const u8 {
    const val = t.get(key) orelse return null;
    if (val != .string) return null;
    return val.string;
}

fn getInt(t: ConfigToml, key: []const u8) ?i64 {
    const val = t.get(key) orelse return null;
    if (val != .integer) return null;
    return val.integer;
}

fn getBool(t: ConfigToml, key: []const u8) ?bool {
    const val = t.get(key) orelse return null;
    if (val != .boolean) return null;
    return val.boolean;
}

/// Parse a TOML string array value into an owned []const []const u8. Returns
/// error.InvalidType when the value is absent-but-typed-wrong, not a string
/// array, or contains a non-string element. Callers degrade to defaults on error.
fn getStringArray(a: std.mem.Allocator, t: ConfigToml, key: []const u8) ![]const []const u8 {
    const val = t.get(key) orelse return &.{};
    if (val != .array) return error.InvalidType;
    const out = try a.alloc([]const u8, val.array.len);
    errdefer a.free(out);
    for (val.array, 0..) |item, i| {
        if (item != .string) return error.InvalidType;
        out[i] = try a.dupe(u8, item.string);
    }
    return out;
}

fn readFile(allocator: std.mem.Allocator, path: []const u8, io: std.Io) ![]u8 {
    const file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);

    const size = (try file.stat(io)).size;
    var buf = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(buf);

    const n = try file.readPositionalAll(io, buf, 0);
    return buf[0..n];
}

/// Format model name for display: replace spaces with hyphens.
/// Returns slice of buf (caller owns nothing).
pub fn formatModelDisplay(name: []const u8, buf: *[128]u8) []const u8 {
    var i: usize = 0;
    for (name) |ch| {
        if (i >= 126) break;
        if (ch == ' ') {
            buf[i] = '-';
        } else {
            buf[i] = ch;
        }
        i += 1;
    }
    buf[i] = 0;
    return buf[0..i];
}

/// Capitalize first letter of provider name for display.
/// Special-cases known provider names for correct casing (e.g. "deepseek" → "DeepSeek").
/// Returns a compile-time known slice or a slice of buf.
pub fn formatProviderDisplay(name: []const u8, buf: *[64]u8) []const u8 {
    if (name.len == 0) return name;
    if (std.mem.eql(u8, name, "deepseek")) return "DeepSeek";
    buf[0] = if (name[0] >= 'a' and name[0] <= 'z') @as(u8, name[0] - 32) else name[0];
    var i: usize = 1;
    while (i < name.len and i < 62) : (i += 1) {
        buf[i] = name[i];
    }
    buf[i] = 0;
    return buf[0..i];
}

fn writeDefaultConfig(allocator: std.mem.Allocator, project_root: []const u8, io: std.Io) !void {
    const dir_path = try std.fs.path.join(allocator, &.{ project_root, ".zagent" });
    defer allocator.free(dir_path);
    Io.Dir.cwd().createDirPath(io, dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const path = try std.fs.path.join(allocator, &.{ dir_path, "config.toml" });
    defer allocator.free(path);

    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, DEFAULT_TEMPLATE);
}

const DEFAULT_TEMPLATE =
    \\# z-agent-core configuration
    \\# Set API key via environment or .zagent/.env: DEEPSEEK_API_KEY=sk-...
    \\# If this file is corrupted, delete it and restart — a fresh copy will be regenerated.
    \\
    \\# Default model: format is "provider/model_id". Used when --model is not specified.
    \\default_model = "deepseek/deepseek-v4-flash"
    \\# Maximum tokens per LLM response. Models have their own limits; this caps the request.
    \\max_tokens = 384000
    \\# Maximum tool execution rounds per turn. Prevents infinite loops.
    \\max_tool_rounds = 10
    \\# Skill root directory relative to project_root. Default .zagent/skills.
    \\# Point at another tool's skills dir (e.g. .opencode/skills) to reuse its skills.
    \\# skills_dir = ".zagent/skills"
    \\# Auto-generate a conversational title with the LLM after the second turn.
    \\# Set false to keep static naming (Web prompt-prefix, CLI "New Session").
    \\auto_title = true
    \\# Extra stopwords appended to the built-in conservative STOPWORDS set for the
    \\# L2 keyword fallback title. Use for domain-specific noise words.
    \\# title_stop_words = ["修", "修复", "TODO"]
    \\
    \\# Tool approval: dangerous commands ask for confirmation before running.
    \\#   never  = no prompts (risky commands run silently — not recommended)
    \\#   risky  = only enumerated destructive bash commands prompt (default)
    \\#   always = every tool call prompts
    \\# approval_mode = "risky"
    \\# Exact command whitelist exempt from approval. Matches `args.command`
    \\# exactly (trimmed, whitespace collapsed, case-sensitive):
    \\# approval_allow = ["rm -rf .zig-cache", "git push --force origin dev"]
    \\# Covered destructive categories (grows per version): recursive delete,
    \\# storage/device wipe, system mutation, git force ops, pipe to shell.
    \\# Full list: docs/0.2.8/PLAN-N16-APPROVAL-PREVIEW.md category table.
    \\# Skip the prompt for an exact command already approved in this round.
    \\# approval_cache = true
    \\
    \\# Provider: defines an API endpoint with auth and available models.
    \\# Add multiple [[providers]] blocks for different services (openai, ollama, etc).
    \\[[providers]]
    \\name = "deepseek"
    \\api = "openai_compat"           # openai_compat format (supports DeepSeek, OpenAI, Ollama)
    \\base_url = "https://api.deepseek.com"
    \\api_key_env = "DEEPSEEK_API_KEY"  # environment variable holding the API key
    \\models = ["deepseek-v4-pro", "deepseek-v4-flash"]  # model IDs available for this provider
    \\
    \\# Model: defines an LLM model and its capabilities. One [[models]] block
    \\# per (provider, id) pair. Model ids are namespaced per provider: the SAME
    \\# id may appear under different providers without conflict (each resolves
    \\# via "provider/model_id"; ids are looked up inside the provider only).
    \\# provider = "" makes the definition available to ANY provider (shared
    \\# pool — only here does an id collide across providers).
    \\# Duplicate (id, provider) pairs: last entry wins (override).
    \\[[models]]
    \\id = "deepseek-v4-pro"          # used in "provider/model_id" format
    \\name = "DeepSeek V4 Pro"        # display name (shown in banner)
    \\provider = "deepseek"           # owner [[providers]].name; "" = any provider
    \\context_window = 1000000          # model's context window in tokens (informational)
    \\max_tokens = 384000             # max tokens the model can generate per response
    \\# thinking: auto-detected from base_url. Override via [models.compat] sub-table.
    \\# thinking_level = "high"         # none|minimal|low|medium|high|xhigh|max (default: high)
    \\# NOTE: [models.compat] as a table header is NOT supported (flattened by the
    \\# TOML parser) — put overrides (thinking_format/max_tokens_field/...) directly
    \\# in the [[models]] table above this line.
    \\# params_json: vendor-specific JSON fragment for non-thinking params (e.g. top_p).
    \\# params_json = ""
    \\input = ["text"]               # supported input modalities: ["text"] or ["text", "image"]
    \\                                # ["text","image"] = vision model — image attachments are
    \\                                # injected into the model request (N22); text-only models
    \\                                # receive plain summaries + a capability notice instead.
    \\                                # Unknown values are ignored with a warning.
    \\                                # !! MUST be written in the [[models]] table directly —
    \\                                # a later [models.compat] header would swallow it.
    \\# Compat quirks: NOT supported as a nested table. Put compat keys
    \\# (thinking_format / max_tokens_field / ...) directly in the [[models]]
    \\# table above this line, e.g. thinking_format = "openai".
    \\
    \\[[models]]
    \\id = "deepseek-v4-flash"
    \\name = "DeepSeek V4 Flash"
    \\provider = "deepseek"
    \\context_window = 1000000
    \\max_tokens = 384000
    \\params_json = ""
    \\input = ["text"]
    \\
    \\# To add another provider (e.g. local Ollama), append:
    \\# [[providers]]
    \\# name = "ollama"
    \\# api = "openai_compat"
    \\# base_url = "http://localhost:11434"
    \\# api_key_env = "OLLAMA_API_KEY"
    \\# models = ["llama4"]
    \\#
    \\# Model ids are scoped per provider — a "qwen3.7-max" under "dashscope"
    \\# and another under "ollama" coexist without renaming either.
    \\# [[models]]
    \\# id = "llama4"
    \\# name = "Llama 4"
    \\# provider = "ollama"            # must match the [[providers]] name above
    \\#
    \\# [[models]]
    \\# id = "llama4"
    \\# name = "Llama 4"
    \\# provider = "ollama"
    \\# context_window = 1000000
    \\# max_tokens = 4096
    \\# params_json = ""
    \\# input = ["text"]
;

test "config: parse default template" {
    const allocator = std.testing.allocator;

    var config = try testParseConfig(allocator, DEFAULT_TEMPLATE);
    defer config.deinit();

    try std.testing.expectEqualStrings("deepseek/deepseek-v4-flash", config.default_model);
    try std.testing.expectEqual(@as(u32, 384000), config.max_tokens);
    try std.testing.expectEqual(@as(u32, 10), config.max_tool_rounds);
    try std.testing.expect(config.providers.len >= 1);

    const deepseek = &config.providers[0];
    try std.testing.expectEqualStrings("deepseek", deepseek.name);
    try std.testing.expectEqualStrings("https://api.deepseek.com", deepseek.base_url);
    try std.testing.expectEqualStrings("DEEPSEEK_API_KEY", deepseek.api_key_env);
    try std.testing.expect(deepseek.api == .openai_compat);
    try std.testing.expectEqual(@as(usize, 2), deepseek.models.len);
    try std.testing.expectEqualStrings("deepseek-v4-pro", deepseek.models[0].id);
    try std.testing.expect(deepseek.models[0].params_json == null);
    try std.testing.expectEqual(@as(usize, 1), deepseek.models[0].input.len);
    try std.testing.expect(deepseek.models[0].input[0] == .text);
}

test "config: skills_dir defaults to .zagent/skills" {
    const allocator = std.testing.allocator;
    var config = try testParseConfig(allocator, DEFAULT_TEMPLATE);
    defer config.deinit();
    try std.testing.expectEqualStrings(".zagent/skills", config.skills_dir);
}

test "config: skills_dir override parsed" {
    const allocator = std.testing.allocator;
    var config = try testParseConfig(allocator,
        \\skills_dir = ".opencode/skills"
        \\default_model = "deepseek/deepseek-v4-pro"
        \\max_tokens = 1000
        \\max_tool_rounds = 8
    );
    defer config.deinit();
    try std.testing.expectEqualStrings(".opencode/skills", config.skills_dir);
}

test "config: auto_title defaults true" {
    const allocator = std.testing.allocator;
    var config = try testParseConfig(allocator, DEFAULT_TEMPLATE);
    defer config.deinit();
    try std.testing.expect(config.auto_title);
}

test "config: auto_title false parsed" {
    const allocator = std.testing.allocator;
    var config = try testParseConfig(allocator,
        \\auto_title = false
        \\default_model = "deepseek/deepseek-v4-pro"
        \\max_tokens = 1000
        \\max_tool_rounds = 8
    );
    defer config.deinit();
    try std.testing.expect(!config.auto_title);
}

test "config: title_stop_words defaults empty" {
    const allocator = std.testing.allocator;
    var config = try testParseConfig(allocator, DEFAULT_TEMPLATE);
    defer config.deinit();
    try std.testing.expectEqual(@as(usize, 0), config.title_stop_words.len);
}

test "config: title_stop_words parsed" {
    const allocator = std.testing.allocator;
    var config = try testParseConfig(allocator,
        \\title_stop_words = ["修", "修复", "TODO"]
        \\default_model = "deepseek/deepseek-v4-pro"
        \\max_tokens = 1000
        \\max_tool_rounds = 8
    );
    defer config.deinit();
    try std.testing.expectEqual(@as(usize, 3), config.title_stop_words.len);
    try std.testing.expectEqualStrings("修", config.title_stop_words[0]);
    try std.testing.expectEqualStrings("TODO", config.title_stop_words[2]);
}

test "config: title_stop_words type error degrades to empty with warning" {
    const allocator = std.testing.allocator;
    var config = try testParseConfig(allocator,
        \\title_stop_words = "not-an-array"
        \\default_model = "deepseek/deepseek-v4-pro"
        \\max_tokens = 1000
        \\max_tool_rounds = 8
    );
    defer config.deinit();
    try std.testing.expectEqual(@as(usize, 0), config.title_stop_words.len);
    try std.testing.expect(config.auto_title);
}

test "config: approval defaults risky, cache on, empty allow" {
    const allocator = std.testing.allocator;
    var config = try testParseConfig(allocator, DEFAULT_TEMPLATE);
    defer config.deinit();
    try std.testing.expectEqualStrings("risky", config.approval_mode);
    try std.testing.expect(config.approval_cache);
    try std.testing.expectEqual(@as(usize, 0), config.approval_allow.len);
}

test "config: approval fields parsed" {
    const allocator = std.testing.allocator;
    var config = try testParseConfig(allocator,
        \\approval_mode = "always"
        \\approval_cache = false
        \\approval_allow = ["rm -rf .zig-cache", "git push --force origin dev"]
        \\default_model = "deepseek/deepseek-v4-pro"
        \\max_tokens = 1000
        \\max_tool_rounds = 8
    );
    defer config.deinit();
    try std.testing.expectEqualStrings("always", config.approval_mode);
    try std.testing.expect(!config.approval_cache);
    try std.testing.expectEqual(@as(usize, 2), config.approval_allow.len);
    try std.testing.expectEqualStrings("rm -rf .zig-cache", config.approval_allow[0]);
    try std.testing.expectEqualStrings("git push --force origin dev", config.approval_allow[1]);
}

test "config: approval_allow type error degrades to empty" {
    const allocator = std.testing.allocator;
    var config = try testParseConfig(allocator,
        \\approval_allow = "not-an-array"
        \\default_model = "deepseek/deepseek-v4-pro"
        \\max_tokens = 1000
        \\max_tool_rounds = 8
    );
    defer config.deinit();
    try std.testing.expectEqual(@as(usize, 0), config.approval_allow.len);
    try std.testing.expectEqualStrings("risky", config.approval_mode);
}

test "config: model params_json present" {
    const allocator = std.testing.allocator;

    var config = try testParseConfig(allocator,
        \\[[providers]]
        \\name = "test"
        \\api = "openai_compat"
        \\base_url = "https://test.example.com"
        \\api_key_env = "TEST_KEY"
        \\models = ["test-model"]
        \\
        \\[[models]]
        \\id = "test-model"
        \\name = "Test Model"
        \\provider = "test"
        \\context_window = 100000
        \\max_tokens = 4096
        \\params_json = "\"thinking\":{\"type\":\"enabled\"}"
        \\input = ["text"]
    );
    defer config.deinit();

    try std.testing.expect(config.providers[0].models[0].params_json != null);
}

test "config: model input text" {
    const allocator = std.testing.allocator;

    var config = try testParseConfig(allocator,
        \\[[providers]]
        \\name = "test"
        \\api = "openai_compat"
        \\base_url = "https://test.example.com"
        \\api_key_env = "TEST_KEY"
        \\models = ["test-model"]
        \\
        \\[[models]]
        \\id = "test-model"
        \\name = "Test Model"
        \\provider = "test"
        \\context_window = 100000
        \\max_tokens = 4096
        \\input = ["text"]
    );
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 1), config.providers[0].models[0].input.len);
    try std.testing.expect(config.providers[0].models[0].input[0] == .text);
}

test "config: model input multimodal" {
    const allocator = std.testing.allocator;

    var config = try testParseConfig(allocator,
        \\[[providers]]
        \\name = "test"
        \\api = "openai_compat"
        \\base_url = "https://api.test.com"
        \\api_key_env = "TEST_KEY"
        \\models = ["m1"]
        \\
        \\[[models]]
        \\id = "m1"
        \\name = "M1"
        \\provider = "test"
        \\context_window = 1000
        \\max_tokens = 100
        \\input = ["text", "image"]
    );
    defer config.deinit();
    const input = config.providers[0].models[0].input;
    try std.testing.expectEqual(@as(usize, 2), input.len);
    try std.testing.expect(input[0] == .text);
    try std.testing.expect(input[1] == .image);
}

test "config: unknown input modality warns and is ignored" {
    const allocator = std.testing.allocator;

    var config = try testParseConfig(allocator,
        \\[[providers]]
        \\name = "test"
        \\api = "openai_compat"
        \\base_url = "https://api.test.com"
        \\api_key_env = "TEST_KEY"
        \\models = ["m1"]
        \\
        \\[[models]]
        \\id = "m1"
        \\name = "M1"
        \\provider = "test"
        \\context_window = 1000
        \\max_tokens = 100
        \\input = ["text", "video"]
    );
    defer config.deinit();
    const input = config.providers[0].models[0].input;
    try std.testing.expectEqual(@as(usize, 1), input.len);
    try std.testing.expect(input[0] == .text);
}

test "config: input under [models.compat] header is ignored with warning" {
    const allocator = std.testing.allocator;

    var config = try testParseConfig(allocator,
        \\[[providers]]
        \\name = "test"
        \\api = "openai_compat"
        \\base_url = "https://api.test.com"
        \\api_key_env = "TEST_KEY"
        \\models = ["m1"]
        \\
        \\[[models]]
        \\id = "m1"
        \\name = "M1"
        \\provider = "test"
        \\context_window = 1000
        \\max_tokens = 100
        \\[models.compat]
        \\thinking_format = "openai"
        \\input = ["text", "image"]
    );
    defer config.deinit();
    // Flattened [models.compat] keys are dropped: input falls back to text-only.
    const input = config.providers[0].models[0].input;
    try std.testing.expectEqual(@as(usize, 1), input.len);
    try std.testing.expect(input[0] == .text);
}

test "config: resolveModel deepseek/v4-pro" {
    const allocator = std.testing.allocator;

    var config = try testParseConfig(allocator, DEFAULT_TEMPLATE);
    defer config.deinit();

    const model = try resolveModel(&config, "deepseek/deepseek-v4-pro");
    try std.testing.expectEqualStrings("deepseek-v4-pro", model.id);
    // params_json removed from default template; thinking now auto-detected via compat
    try std.testing.expect(model.params_json == null);
}

test "config: resolveModel unknown provider" {
    const allocator = std.testing.allocator;

    var config = try testParseConfig(allocator, DEFAULT_TEMPLATE);
    defer config.deinit();

    try std.testing.expectError(error.ProviderNotFound, resolveModel(&config, "nobody/ghost"));
}

test "config: resolveModel unknown model" {
    const allocator = std.testing.allocator;

    var config = try testParseConfig(allocator, DEFAULT_TEMPLATE);
    defer config.deinit();

    try std.testing.expectError(error.ModelNotFound, resolveModel(&config, "deepseek/nonexistent"));
}

test "config: resolveModel no slash" {
    const allocator = std.testing.allocator;

    var config = try testParseConfig(allocator, DEFAULT_TEMPLATE);
    defer config.deinit();

    try std.testing.expectError(error.InvalidModelSpec, resolveModel(&config, "invalid-spec"));
}

test "config: deinit cleans all duped strings" {
    const allocator = std.testing.allocator;

    var config = try testParseConfig(allocator, DEFAULT_TEMPLATE);
    config.deinit();
}

test "config: validate no models" {
    const allocator = std.testing.allocator;

    var config = try testParseConfig(allocator,
        \\[[providers]]
        \\name = "test"
        \\api = "openai_compat"
        \\base_url = "https://test.example.com"
        \\api_key_env = "TEST_KEY"
        \\models = []
    );
    defer config.deinit();

    try std.testing.expectError(error.InvalidConfig_NoModels, validateConfig(&config, std.testing.io));
}

test "config: validate zero context" {
    const allocator = std.testing.allocator;

    var config = try testParseConfig(allocator,
        \\[[providers]]
        \\name = "test"
        \\api = "openai_compat"
        \\base_url = "https://test.example.com"
        \\api_key_env = "TEST_KEY"
        \\models = ["test-model"]
        \\
        \\[[models]]
        \\id = "test-model"
        \\name = "Test"
        \\provider = "test"
        \\context_window = 0
        \\max_tokens = 4096
        \\input = ["text"]
    );
    defer config.deinit();

    try std.testing.expectError(error.InvalidConfig_ContextWindowZero, validateConfig(&config, std.testing.io));
}

test "config: validate empty provider name" {
    const allocator = std.testing.allocator;

    var config = try testParseConfig(allocator,
        \\[[providers]]
        \\name = ""
        \\api = "openai_compat"
        \\base_url = "https://test.example.com"
        \\api_key_env = "TEST_KEY"
        \\models = ["test-model"]
        \\
        \\[[models]]
        \\id = "test-model"
        \\name = "Test"
        \\provider = ""
        \\context_window = 100000
        \\max_tokens = 4096
        \\input = ["text"]
    );
    defer config.deinit();

    try std.testing.expectError(error.InvalidConfig_NameEmpty, validateConfig(&config, std.testing.io));
}

test "config: validate empty base_url" {
    const allocator = std.testing.allocator;

    var config = try testParseConfig(allocator,
        \\[[providers]]
        \\name = "test"
        \\api = "openai_compat"
        \\base_url = ""
        \\api_key_env = "TEST_KEY"
        \\models = ["test-model"]
        \\
        \\[[models]]
        \\id = "test-model"
        \\name = "Test"
        \\provider = "test"
        \\context_window = 100000
        \\max_tokens = 4096
        \\input = ["text"]
    );
    defer config.deinit();

    try std.testing.expectError(error.InvalidConfig_BaseUrlEmpty, validateConfig(&config, std.testing.io));
}

test "config: validate empty api_key_env" {
    const allocator = std.testing.allocator;

    var config = try testParseConfig(allocator,
        \\[[providers]]
        \\name = "test"
        \\api = "openai_compat"
        \\base_url = "https://test.example.com"
        \\api_key_env = ""
        \\models = ["test-model"]
        \\
        \\[[models]]
        \\id = "test-model"
        \\name = "Test"
        \\provider = "test"
        \\context_window = 100000
        \\max_tokens = 4096
        \\input = ["text"]
    );
    defer config.deinit();

    try std.testing.expectError(error.InvalidConfig_ApiKeyEnvEmpty, validateConfig(&config, std.testing.io));
}

test "config: validate empty model id" {
    const allocator = std.testing.allocator;

    var config = try testParseConfig(allocator,
        \\[[providers]]
        \\name = "test"
        \\api = "openai_compat"
        \\base_url = "https://test.example.com"
        \\api_key_env = "TEST_KEY"
        \\models = [""]
        \\
        \\[[models]]
        \\id = ""
        \\name = "Test"
        \\provider = "test"
        \\context_window = 100000
        \\max_tokens = 4096
        \\input = ["text"]
    );
    defer config.deinit();

    try std.testing.expectError(error.InvalidConfig_ModelIdEmpty, validateConfig(&config, std.testing.io));
}

test "config: validate empty default model" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var config = Config{
        .default_model = "",
        .max_tokens = 4096,
        .max_tool_rounds = 10,
        .providers = &.{},
        ._arena = undefined,
    };
    config._arena = arena;
    defer config.deinit();

    try std.testing.expectError(error.InvalidConfig_NoDefaultModel, validateConfig(&config, std.testing.io));
}

test "config: providers not array returns error" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.InvalidConfig_ProvidersNotArray, testParseConfig(allocator,
        \\providers = "not_an_array"
    ));
}

test "config: loadDotEnv handles missing file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var env_map = try loadDotEnv(allocator, "/nonexistent/path", io);
    defer {
        var it = env_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        env_map.deinit(allocator);
    }

    try std.testing.expect(env_map.count() == 0);
}

test "config: loadDotEnv basic and quoted" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-config-env-basic";
    const test_dir = try std.fs.path.join(allocator, &.{ test_root });
    defer {
        // Test cleanup: best-effort, ignore if dir doesn't exist or is locked
        Io.Dir.cwd().deleteTree(io, test_dir) catch {};
        allocator.free(test_dir);
    }
    try Io.Dir.cwd().createDirPath(io, test_dir);

    const zagent_dir = try std.fs.path.join(allocator, &.{ test_dir, ".zagent" });
    defer allocator.free(zagent_dir);
    try Io.Dir.cwd().createDirPath(io, zagent_dir);

    const env_path = try std.fs.path.join(allocator, &.{ zagent_dir, ".env" });
    defer allocator.free(env_path);

    const content =
        \\KEY1="value1"
        \\KEY2=value2
        \\KEY3="with#inside"#comment
        \\KEY4=value4#outside
        \\KEY5=
        \\
    ;
    const file = try Io.Dir.cwd().createFile(io, env_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);

    var env_map = try loadDotEnv(allocator, test_dir, io);
    defer {
        var it = env_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        env_map.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 5), env_map.count());
    try std.testing.expectEqualStrings("value1", env_map.get("KEY1").?);
    try std.testing.expectEqualStrings("value2", env_map.get("KEY2").?);
    try std.testing.expectEqualStrings("with#inside", env_map.get("KEY3").?);
    try std.testing.expectEqualStrings("value4", env_map.get("KEY4").?);
    try std.testing.expectEqualStrings("", env_map.get("KEY5").?);
}

test "config: loadDotEnv skips malformed lines" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-config-env-malformed";
    const test_dir = try std.fs.path.join(allocator, &.{ test_root });
    defer {
        Io.Dir.cwd().deleteTree(io, test_dir) catch {};
        allocator.free(test_dir);
    }
    try Io.Dir.cwd().createDirPath(io, test_dir);

    const zagent_dir = try std.fs.path.join(allocator, &.{ test_dir, ".zagent" });
    defer allocator.free(zagent_dir);
    try Io.Dir.cwd().createDirPath(io, zagent_dir);

    const env_path = try std.fs.path.join(allocator, &.{ zagent_dir, ".env" });
    defer allocator.free(env_path);

    const content =
        \\NOKEY
        \\=valueonly
        \\KEY1="value1"
        \\KEY2="unclosed
        \\KEY3=value3
    ;
    const file = try Io.Dir.cwd().createFile(io, env_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);

    var env_map = try loadDotEnv(allocator, test_dir, io);
    defer {
        var it = env_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        env_map.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 2), env_map.count());
    try std.testing.expectEqualStrings("value1", env_map.get("KEY1").?);
    try std.testing.expectEqualStrings("value3", env_map.get("KEY3").?);
}

test "resolveApiKey: empty env var treated as unset" {
    const testing = std.testing;
    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();
    try env_map.put("KEY", "");
    try testing.expectError(error.ApiKeyNotSet, resolveApiKey(&env_map, null, "KEY"));
}

test "resolveApiKey: falls back to dotenv" {
    const testing = std.testing;
    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();
    var dotenv = std.StringArrayHashMapUnmanaged([]const u8){};
    defer dotenv.deinit(testing.allocator);
    try dotenv.put(testing.allocator, "KEY", "sk-x");
    const key = try resolveApiKey(&env_map, &dotenv, "KEY");
    try testing.expectEqualStrings("sk-x", key);
}

test "resolveApiKey: env wins over dotenv" {
    const testing = std.testing;
    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();
    try env_map.put("KEY", "sk-env");
    var dotenv = std.StringArrayHashMapUnmanaged([]const u8){};
    defer dotenv.deinit(testing.allocator);
    try dotenv.put(testing.allocator, "KEY", "sk-dotenv");
    const key = try resolveApiKey(&env_map, &dotenv, "KEY");
    try testing.expectEqualStrings("sk-env", key);
}

test "resolveApiKey: empty env falls back to dotenv" {
    const testing = std.testing;
    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();
    try env_map.put("KEY", "");
    var dotenv = std.StringArrayHashMapUnmanaged([]const u8){};
    defer dotenv.deinit(testing.allocator);
    try dotenv.put(testing.allocator, "KEY", "sk-x");
    const key = try resolveApiKey(&env_map, &dotenv, "KEY");
    try testing.expectEqualStrings("sk-x", key);
}

test "resolveApiKey: both empty returns ApiKeyNotSet" {
    const testing = std.testing;
    var env_map = std.process.Environ.Map.init(testing.allocator);
    defer env_map.deinit();
    try env_map.put("KEY", "");
    var dotenv = std.StringArrayHashMapUnmanaged([]const u8){};
    defer dotenv.deinit(testing.allocator);
    try dotenv.put(testing.allocator, "KEY", "");
    try testing.expectError(error.ApiKeyNotSet, resolveApiKey(&env_map, &dotenv, "KEY"));
}

test "config: findZagentRoot walks up to .zagent" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const root = findZagentRoot(allocator, io) orelse return error.TestUnexpectedNull;
    defer allocator.free(root);

    try std.testing.expectEqualStrings("z-agent-core", std.fs.path.basename(root));
}

test "config: findZagentRoot rootless from temp dir" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-config-find-rootless";
    const test_dir = try std.fs.path.join(allocator, &.{ test_root });
    defer {
        // Test cleanup: best-effort
        Io.Dir.cwd().deleteTree(io, test_dir) catch {};
        allocator.free(test_dir);
    }
    try Io.Dir.cwd().createDirPath(io, test_dir);

    // The temp dir is below CWD, findZagentRoot walks up from CWD and
    // will find the workspace-level .zagent. Verify the found root is NOT
    // the test dir (it should be a parent of CWD).
    const root = findZagentRoot(allocator, io);

    if (root) |r| {
        defer allocator.free(r);
        try std.testing.expect(!std.mem.eql(u8, r, test_dir));
    }
}

test "config: missing file creates default" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const test_root = ".zig-test-config-missing";
    const test_dir = try std.fs.path.join(allocator, &.{ test_root });
    defer {
        // Test cleanup: best-effort
        Io.Dir.cwd().deleteTree(io, test_dir) catch {};
        allocator.free(test_dir);
    }
    try Io.Dir.cwd().createDirPath(io, test_dir);

    var config = try Config.load(allocator, test_dir, io);
    defer config.deinit();

    try std.testing.expectEqualStrings("deepseek/deepseek-v4-flash", config.default_model);
    try std.testing.expect(config.providers.len >= 1);
    try std.testing.expect(config.max_tokens > 0);
}

test "config: model compat override via top-level thinking_level" {
    const allocator = std.testing.allocator;

    var config = try testParseConfig(allocator,
        \\[[providers]]
        \\name = "test"
        \\api = "openai_compat"
        \\base_url = "https://test.example.com"
        \\api_key_env = "TEST_KEY"
        \\models = ["test-model"]
        \\
        \\[[models]]
        \\id = "test-model"
        \\name = "Test"
        \\provider = "test"
        \\context_window = 100000
        \\max_tokens = 4096
        \\thinking_level = "max"
        \\input = ["text"]
    );
    defer config.deinit();

    const model = &config.providers[0].models[0];
    try std.testing.expect(model.compat != null);
    try std.testing.expectEqual(types.ThinkingLevel.max, model.compat.?.thinking_level.?);
    // No thinking_format set → defaults to null, resolveCompat keeps auto-detect
    try std.testing.expect(model.compat.?.thinking_format == null);
}

test "config: model thinking_level top-level" {
    const allocator = std.testing.allocator;

    var config = try testParseConfig(allocator,
        \\[[providers]]
        \\name = "test"
        \\api = "openai_compat"
        \\base_url = "https://test.example.com"
        \\api_key_env = "TEST_KEY"
        \\models = ["test-model"]
        \\
        \\[[models]]
        \\id = "test-model"
        \\name = "Test"
        \\provider = "test"
        \\context_window = 100000
        \\max_tokens = 4096
        \\thinking_level = "max"
        \\input = ["text"]
    );
    defer config.deinit();

    const model = &config.providers[0].models[0];
    try std.testing.expect(model.compat != null);
    try std.testing.expectEqual(types.ThinkingLevel.max, model.compat.?.thinking_level.?);
}

test "config: resolveCompat merges override" {
    const allocator = std.testing.allocator;

    var config = try testParseConfig(allocator,
        \\[[providers]]
        \\name = "test"
        \\api = "openai_compat"
        \\base_url = "https://api.deepseek.com"
        \\api_key_env = "TEST_KEY"
        \\models = ["test-model"]
        \\
        \\[[models]]
        \\id = "test-model"
        \\name = "Test"
        \\provider = "test"
        \\context_window = 100000
        \\max_tokens = 4096
        \\thinking_level = "max"
        \\input = ["text"]
    );
    defer config.deinit();

    const model = &config.providers[0].models[0];
    const c = resolveCompat(config.providers[0].base_url, model);
    // auto-detect: deepseek.com → thinking_object
    // TOML override: thinking_level = max
    try std.testing.expectEqual(types.ThinkingFormat.thinking_object, c.thinking_format);
    try std.testing.expectEqual(types.ThinkingLevel.max, c.thinking_level);
    try std.testing.expect(c.require_reasoning_on_tool_calls);
}

test "config: parseThinkingFormat all values" {
    try std.testing.expectEqual(types.ThinkingFormat.none, parseThinkingFormat("none"));
    try std.testing.expectEqual(types.ThinkingFormat.thinking_object, parseThinkingFormat("thinking_object"));
    try std.testing.expectEqual(types.ThinkingFormat.reasoning_effort, parseThinkingFormat("reasoning_effort"));
    try std.testing.expectEqual(types.ThinkingFormat.enable_thinking_bool, parseThinkingFormat("enable_thinking_bool"));
    try std.testing.expectEqual(types.ThinkingFormat.thinking_parameters, parseThinkingFormat("thinking_parameters"));
    try std.testing.expectEqual(types.ThinkingFormat.thinking_with_budget, parseThinkingFormat("thinking_with_budget"));
    try std.testing.expectEqual(types.ThinkingFormat.thinking_config_object, parseThinkingFormat("thinking_config_object"));
    try std.testing.expectEqual(types.ThinkingFormat.none, parseThinkingFormat("invalid"));
}

test "config: parseMaxTokensField all values" {
    try std.testing.expectEqual(types.MaxTokensField.max_tokens, parseMaxTokensField("max_tokens"));
    try std.testing.expectEqual(types.MaxTokensField.max_tokens_to_sample, parseMaxTokensField("max_tokens_to_sample"));
    try std.testing.expectEqual(types.MaxTokensField.max_output_tokens, parseMaxTokensField("max_output_tokens"));
    try std.testing.expectEqual(types.MaxTokensField.max_tokens, parseMaxTokensField("invalid"));
}

