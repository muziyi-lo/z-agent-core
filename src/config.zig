const std = @import("std");
const Io = std.Io;
const toml = @import("toml.zig");
const types = @import("types.zig");

const ConfigToml = std.StringArrayHashMapUnmanaged(toml.Value);

/// Configuration loaded from .zagent/config.toml.
/// Caller must call deinit() to release all owned memory.
pub const Config = struct {
    default_model: []const u8,
    max_tokens: u32,
    max_tool_rounds: u32,
    providers: []const types.ProviderEntry,
    base_prompt: ?[]const u8 = null,

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
                var result = try parseConfigContent(arena.allocator(), DEFAULT_TEMPLATE);
                try writeDefaultConfig(arena.allocator(), project_root, io);
                {
                    var stderr_buf: [256]u8 = undefined;
                    var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
                    try stderr_writer.interface.print("z-agent-core: config created at .zagent/config.toml\n", .{});
                }
                const model = try resolveModel(&result, result.default_model);
                {
                    var stderr_buf: [512]u8 = undefined;
                    var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
                    var model_dbuf: [128]u8 = undefined;
                    var prov_dbuf: [64]u8 = undefined;
                    const model_display = formatModelDisplay(model.name, &model_dbuf);
                    const provider_display = formatProviderDisplay(model.provider, &prov_dbuf);
                    try stderr_writer.interface.print("z-agent-core v{s} | {s} | {s}\n", .{
                        types.VERSION, model_display, provider_display,
                    });
                    try stderr_writer.interface.flush();
                }
                result._arena = arena;
                return result;
            },
            else => return err,
        };

        var result = try parseConfigContent(arena.allocator(), content);
        try validateConfig(&result);

        const model = try resolveModel(&result, result.default_model);
        {
            var stderr_buf: [512]u8 = undefined;
            var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
            var model_dbuf: [128]u8 = undefined;
            var prov_dbuf: [64]u8 = undefined;
            const model_display = formatModelDisplay(model.name, &model_dbuf);
            const provider_display = formatProviderDisplay(model.provider, &prov_dbuf);
            try stderr_writer.interface.print("z-agent-core v{s} | {s} | {s}\n", .{
                types.VERSION, model_display, provider_display,
            });
            try stderr_writer.interface.flush();
        }

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
    const len = Io.Dir.cwd().realPath(io, &buf) catch return null;
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

/// Parse .zagent/.env into KEY=VALUE map.
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
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (key.len == 0) continue;

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

fn validateConfig(config: *const Config) !void {
    if (config.default_model.len == 0) return error.InvalidConfig_NoDefaultModel;
    for (config.providers) |p| {
        if (p.name.len == 0) return error.InvalidConfig_NameEmpty;
        if (p.base_url.len == 0) return error.InvalidConfig_BaseUrlEmpty;
        if (p.api_key_env.len == 0) return error.InvalidConfig_ApiKeyEnvEmpty;
        if (p.models.len == 0) return error.InvalidConfig_NoModels;
        for (p.models) |m| {
            if (m.id.len == 0) return error.InvalidConfig_ModelIdEmpty;
            if (m.context_window == 0) return error.InvalidConfig_ContextWindowZero;
        }
    }
}

fn parseConfigContent(a: std.mem.Allocator, source: []const u8) !Config {
    var parsed = try toml.parse(a, source);
    defer toml.freeTable(a, &parsed);

    const dm_raw = getString(parsed, "default_model") orelse "deepseek/deepseek-v4-pro";
    const max_tokens_val = getInt(parsed, "max_tokens") orelse 384000;
    const max_tool_rounds_val = getInt(parsed, "max_tool_rounds") orelse 10;

    if (max_tokens_val > @as(i64, @intCast(std.math.maxInt(u32)))) return error.ValueTooLarge;
    if (max_tool_rounds_val > @as(i64, @intCast(std.math.maxInt(u32)))) return error.ValueTooLarge;

    const all_models = try parseAllModels(a, parsed);
    const bp_raw = getString(parsed, "base_prompt");

    return .{
        .default_model = try a.dupe(u8, dm_raw),
        .max_tokens = @intCast(@max(max_tokens_val, 0)),
        .max_tool_rounds = @intCast(@max(max_tool_rounds_val, 0)),
        .providers = try parseProviders(a, parsed, all_models),
        .base_prompt = if (bp_raw) |bp| try a.dupe(u8, bp) else null,
        ._arena = undefined,
    };
}

fn testParseConfig(allocator: std.mem.Allocator, source: []const u8) !Config {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var config = try parseConfigContent(arena.allocator(), source);
    config._arena = arena;
    return config;
}

fn parseProviders(a: std.mem.Allocator, root: ConfigToml, all_models: []const types.Model) ![]const types.ProviderEntry {
    const arr = root.get("providers") orelse return &.{};
    if (arr != .array) return error.InvalidConfig_ProvidersNotArray;
    var list = std.ArrayListAligned(types.ProviderEntry, null).empty;
    for (arr.array) |provider_table| {
        if (provider_table != .table) continue;
        const pt = provider_table.table;
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
    for (all_models) |m| {
        if ((m.provider.len == 0 or std.mem.eql(u8, m.provider, provider_name)) and
            std.mem.eql(u8, m.id, model_id))
        {
            return m;
        }
    }
    return null;
}

fn parseAllModels(a: std.mem.Allocator, root: ConfigToml) ![]const types.Model {
    const arr = root.get("models") orelse return &.{};
    if (arr != .array) return &.{};
    var list = std.ArrayListAligned(types.Model, null).empty;
    for (arr.array) |model_table| {
        if (model_table != .table) continue;
        const mt = model_table.table;
        const id_raw = getString(mt, "id") orelse "";
        const name_raw = getString(mt, "name") orelse "";
        const provider_raw = getString(mt, "provider") orelse "";
        const cw_val = getInt(mt, "context_window") orelse 0;
        const mt_val = getInt(mt, "max_tokens") orelse 0;
        if (cw_val > @as(i64, @intCast(std.math.maxInt(u32)))) return error.ValueTooLarge;
        if (mt_val > @as(i64, @intCast(std.math.maxInt(u32)))) return error.ValueTooLarge;
        try list.append(a, .{
            .id = try a.dupe(u8, id_raw),
            .name = try a.dupe(u8, name_raw),
            .provider = try a.dupe(u8, provider_raw),
            .context_window = @intCast(cw_val),
            .max_tokens = @intCast(mt_val),
            .params_json = getString(mt, "params_json"),
            .input = try parseInputModality(a, mt),
        });
    }
    return list.toOwnedSlice(a);
}

fn parseInputModality(a: std.mem.Allocator, mt: ConfigToml) ![]const types.InputModality {
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
            inline for (@typeInfo(types.InputModality).@"enum".fields) |field| {
                if (std.mem.eql(u8, v.string, field.name)) try list.append(a, @field(types.InputModality, field.name));
            }
        }
    }
    if (list.items.len == 0) {
        const duped = try a.dupe(types.InputModality, &.{.text});
        return duped;
    }
    return list.toOwnedSlice(a);
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
fn formatModelDisplay(name: []const u8, buf: *[128]u8) []const u8 {
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
fn formatProviderDisplay(name: []const u8, buf: *[64]u8) []const u8 {
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
    \\# Model: defines an LLM model and its capabilities.
    \\# Add one [[models]] block per model. Models are shared across providers.
    \\[[models]]
    \\id = "deepseek-v4-pro"          # used in "provider/model_id" format
    \\name = "DeepSeek V4 Pro"        # display name (shown in banner)
    \\provider = "deepseek"           # links to [[providers]].name
    \\context_window = 1000000          # model's context window in tokens (informational)
    \\max_tokens = 384000             # max tokens the model can generate per response
    \\# params_json: vendor-specific JSON fragment pasted into the API request body.
    \\# Format: key:value pairs WITHOUT outer braces. Provider blindly concatenates.
    \\# Examples: "" (none), '"thinking":{"type":"enabled"}' (DeepSeek thinking mode),
    \\#           '"reasoning_effort":"high"' (reasoning effort for supported models)
    \\params_json = "\"thinking\":{\"type\":\"enabled\"}"
    \\input = ["text"]               # supported input modalities: ["text"] or ["text", "image"]
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
    try std.testing.expect(deepseek.models[0].params_json != null);
    try std.testing.expectEqual(@as(usize, 1), deepseek.models[0].input.len);
    try std.testing.expect(deepseek.models[0].input[0] == .text);
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
        \\input = ["text", "image"]
    );
    defer config.deinit();

    const input = config.providers[0].models[0].input;
    try std.testing.expectEqual(@as(usize, 2), input.len);
    try std.testing.expect(input[0] == .text);
    try std.testing.expect(input[1] == .image);
}

test "config: resolveModel deepseek/v4-pro" {
    const allocator = std.testing.allocator;

    var config = try testParseConfig(allocator, DEFAULT_TEMPLATE);
    defer config.deinit();

    const model = try resolveModel(&config, "deepseek/deepseek-v4-pro");
    try std.testing.expectEqualStrings("deepseek-v4-pro", model.id);
    try std.testing.expect(model.params_json != null);
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

    try std.testing.expectError(error.InvalidConfig_NoModels, validateConfig(&config));
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

    try std.testing.expectError(error.InvalidConfig_ContextWindowZero, validateConfig(&config));
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

    try std.testing.expectError(error.InvalidConfig_NameEmpty, validateConfig(&config));
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

    try std.testing.expectError(error.InvalidConfig_BaseUrlEmpty, validateConfig(&config));
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

    try std.testing.expectError(error.InvalidConfig_ApiKeyEnvEmpty, validateConfig(&config));
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

    try std.testing.expectError(error.InvalidConfig_ModelIdEmpty, validateConfig(&config));
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

    try std.testing.expectError(error.InvalidConfig_NoDefaultModel, validateConfig(&config));
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
