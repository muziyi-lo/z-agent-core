# Step 1: config.zig + toml.zig — 配置系统

> 详细实施计划。A~G 维度全部覆盖。

## A. 源码依据

| 源文件 | 行号 | 用途 |
|--------|------|------|
| `projects/z-agent/src/config.zig` | 1-80, 100-200 | Config struct + findZagentRoot + loadDotEnv + 模板生成 |
| `projects/z-agent/src/config.zig` | 250-350 | parseConfigContent, loadProviderEntries |
| `projects/z-agent/src/toml.zig` | 1-577 | 轻量 TOML 解析器（完整迁移） |
| `zig/zig/lib/std/Io/Dir.zig` | — | `realPath`, `openFile`, `writeFile` API（0.16.0 都需要 Io 参数） |
| `.opencode/learnings/LEARNINGS.md` | ZIG-CFG-TOUCH | 配置字段修改需改 4+ 处的踩坑（用 comptime 自动序列化规避） |
| `projects/z-agent/.zagent/config.toml` | — | 默认配置模板参考 |

## B. 模块设计

### B1. 文件职责

```
src/
├── config.zig         # Config struct + findZagentRoot + loadDotEnv + 模板生成
├── toml.zig           # TOML 解析器（从 z-agent 迁移，独立于 config）
└── types.zig          # 已有，需新增 ProviderEntry + Config 相关类型
```

### B2. Config 结构体 + Arena 所有权

> **实现偏差**: toml.zig (Zig 标准库外依赖) 不支持嵌套表数组 `[[providers.models]]` 和点语法 `[a.b]`。改用平铺格式：`[[providers]]` 只存模型 ID 字符串数组，`[[models]]` 独立表数组通过 `provider` 字段关联。`Model.provider` 空值时匹配所有 provider。

```zig
pub const Config = struct {
    default_model: []const u8,
    max_tokens: u32,
    max_tool_rounds: u32,
    providers: []const ProviderEntry,
    _arena: std.heap.ArenaAllocator,    // 内部——dupe 从此分配，deinit 一次释放

    pub fn load(allocator: Allocator, project_root: []const u8, io: std.Io) !Config;
    pub fn deinit(self: *Config) void;  // 只需 self._arena.deinit()
};
```

**所有权模型**：`Config.load` 内部创建 ArenaAllocator，挂载到 `Config._arena`。所有字符串 duped 通过 `_arena.allocator()`。`deinit()` 只需 `_arena.deinit()`——无需追踪每个字段的释放顺序。消除了解析函数中的逐项 `defer` 地狱。对外接口不变：调用方仍拿 `Config` 实例，用完 `deinit()`。

```zig
pub fn load(allocator: Allocator, project_root: []const u8, io: std.Io) !Config {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();    // 解析中途失败时清理

    const path = try std.fs.path.join(allocator, &.{ project_root, ".zagent", "config.toml" });
    defer allocator.free(path);

    const content = readFile(allocator, path, io) catch |err| switch (err) {
        error.FileNotFound => {
            // 创建默认配置——直接解析模板字符串，不回读磁盘
            var result = try parseConfigContent(arena.allocator(), DEFAULT_TEMPLATE);
            try writeDefaultConfig(arena.allocator(), project_root, io);
            // 启动提示——通过 io 获取 stderr writer，而非 std.debug.print
            {
                var stderr_buf: [256]u8 = undefined;
                var stderr_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buf);
                try stderr_writer.interface.print("z-agent-core: config created at .zagent/config.toml\n", .{});
            }
            {
                const model = try resolveModel(&result, result.default_model);
                var stderr_buf2: [256]u8 = undefined;
                var stderr_writer2: std.Io.File.Writer = .init(.stderr(), io, &stderr_buf2);
                try stderr_writer2.interface.print("z-agent-core: {s}/{s} ({d}M ctx, {d}K max_tokens)\n", .{
                    result.default_model,
                    model.name,
                    @divTrunc(model.context_window, 1_000_000),
                    @divTrunc(model.max_tokens, 1000),
                });
            }
            result._arena = arena;    // ← 所有权转移
            return result;
        },
        else => return err,
    };
    defer allocator.free(content);

    var result = try parseConfigContent(arena.allocator(), content);
    try validateConfig(&result);
    {
        const model = try resolveModel(&result, result.default_model);
        var stderr_buf: [256]u8 = undefined;
        var stderr_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buf);
        try stderr_writer.interface.print("z-agent-core: {s} ({d}M ctx, {d}K max_tokens)\n", .{
            result.default_model,
            model.name,
            @divTrunc(model.context_window, 1_000_000),
            @divTrunc(model.max_tokens, 1000),
        });
    }
    result._arena = arena;    // ← 所有权转移
    return result;
}
```

`_arena` 转移时机：`parseConfigContent` 返回的 `result` 中 `_arena = undefined`。调用方 `load()` 在所有初始化完成后将 `result._arena = arena`——此后 arena 的释放由 Config.deinit 负责，`errdefer` 不再生效。

### B2½. parseConfigContent — 签名修正（最终实现）

```zig
fn parseConfigContent(a: Allocator, source: []const u8) !Config {
    var parsed = try toml.parse(a, source);
    defer toml.freeTable(a, &parsed);

    const dm_raw = getString(parsed, "default_model") orelse "deepseek/deepseek-v4-pro";
    const max_tokens_val = getInt(parsed, "max_tokens") orelse 384000;
    const max_tool_rounds_val = getInt(parsed, "max_tool_rounds") orelse 10;

    if (max_tokens_val > @as(i64, @intCast(std.math.maxInt(u32)))) return error.ValueTooLarge;
    if (max_tool_rounds_val > @as(i64, @intCast(std.math.maxInt(u32)))) return error.ValueTooLarge;

    const all_models = try parseAllModels(a, parsed);

    return .{
        .default_model = try a.dupe(u8, dm_raw),
        .max_tokens = @intCast(@max(max_tokens_val, 0)),
        .max_tool_rounds = @intCast(@max(max_tool_rounds_val, 0)),
        .providers = try parseProviders(a, parsed, all_models),
        ._arena = undefined,
    };
}
```

**`_arena` 字段约定**：`parseConfigContent` 返回的 Config 中 `_arena` 为 undefined 状态。调用方 `load()` 在返回前将 arena 所有权移入 `result._arena`。这是 Zig 中常见的"构造器返回不完整对象，调用方完成最终组装"模式。

### B3. types.zig 新增类型（对照 DeepSeek pi 接入配置）

```zig
/// 输入模态——V1 只用 text，枚举预留给 V2 多模态
pub const InputModality = enum { text, image };

/// API 协议类型——V1 只有一种，预留给 V2 多协议
pub const Api = enum { openai_compat };

/// 模型配置——自描述值对象，含调用所需全部元信息
pub const Model = struct {
    id: []const u8,                     // "deepseek-v4-pro"
    name: []const u8,                   // "DeepSeek V4 Pro"
    provider: []const u8,               // "deepseek" — 关联 [[providers]]（空值匹配所有）
    context_window: u32,                // 1000000
    max_tokens: u32,                    // 384000
    reasoning: bool,                    // 是否支持 thinking mode
    input: []const InputModality,       // arena-allocated，统一所有权
};

/// Provider 定义——一个厂商 + 协议 + 模型列表
pub const ProviderEntry = struct {
    name: []const u8,           // "deepseek"
    api: Api,                   // .openai_compat
    base_url: []const u8,       // "https://api.deepseek.com"
    models: []const Model,      // 结构化，非字符串数组
    api_key_env: []const u8,    // "DEEPSEEK_API_KEY"
};

/// 工具执行上下文——由 Agent 传入，避免 tool/ 层 import config
/// 各工具通过 ctx.project_root 获取 .zagent/ 路径
pub const ToolContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
};
```

### B4. config.toml 模板（对照 DeepSeek 官方 pi 接入配置）

```toml
# z-agent-core config
# Provider and models. API key goes in .zagent/.env or environment.

default_model = "deepseek/deepseek-v4-pro"
max_tokens = 384000
max_tool_rounds = 10

[[providers]]
name = "deepseek"
api = "openai_compat"
base_url = "https://api.deepseek.com"
api_key_env = "DEEPSEEK_API_KEY"
models = ["deepseek-v4-pro", "deepseek-v4-flash"]

[[models]]
id = "deepseek-v4-pro"
name = "DeepSeek V4 Pro"
provider = "deepseek"
context_window = 1000000
max_tokens = 384000
reasoning = true
input = ["text"]

[[models]]
id = "deepseek-v4-flash"
name = "DeepSeek V4 Flash"
provider = "deepseek"
context_window = 1000000
max_tokens = 384000
reasoning = true
input = ["text"]
```

### B5. API Key 设计——config 只存变量名，不存密钥值

```
config.toml          api_key_env = "DEEPSEEK_API_KEY"    ← 只声明名字
                          │
                          ▼
io/provider.zig       init(allocator, provider_entry) {
                          // Step 2 实现——provider 自己读取
                          const key = process.getEnvVarOwned(
                              allocator, entry.api_key_env
                          ) catch |err| {
                              stderr: "DEEPSEEK_API_KEY not set\n";
                              return err;
                          };
                      }
```

原则：
- config.zig 不读密钥、不存密钥、不检查密钥是否存在
- `api_key_env` 只是一条 string 配置，跟 `base_url` 同级
- Step 1 只负责把 `"DEEPSEEK_API_KEY"` 这个字符串从 TOML 解析到 `ProviderEntry.apikey_env`
- 密钥的实际读取是 Step 2 provider.init() 的职责

### B6. Model 解析——`"deepseek/deepseek-v4-pro"` → `Model`

```zig
/// 从 "provider/model_id" 字符串解析出 Model 对象。
/// 遍历所有 provider → models，匹配 name/id 组合。
/// 返回指针指向 providers 切片中的元素。仅在 Config 存活期间有效——Config.deinit() 后指针悬垂。
pub fn resolveModel(config: *const Config, spec: []const u8) ?*const Model;
```

放在 config.zig 而非 types.zig——因为需要访问 providers 数组做双循环查找。

### B7. 解析校验——非法配置不静默通过

```zig
fn validateConfig(config: *const Config) !void {
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
```

`Config.load()` 在 `return config` 前调用 `validateConfig`。校验失败 → 返回错误，不创建 Config。

### B8. 启动反馈——通过 `io` 获取 stderr writer

```zig
var stderr_buf: [256]u8 = undefined;
var stderr_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buf);
try stderr_writer.interface.print("z-agent-core: {s}/{s} ({d}M ctx, {d}K max_tokens)\n", .{...});
```

使用 `io` 参数获取 stderr writer（`std.Io.File.Writer`），而非 `std.debug.print`——保持一致 I/O 契约，日志输出可被单元测试重定向。

## C. 接口设计

### C1. findZagentRoot

```zig
/// Walk up from CWD to find `.zagent/config.toml`. Returns duped path, caller frees.
pub fn findZagentRoot(allocator: Allocator, io: std.Io) ?[]const u8;
```

- 从 z-agent 迁移，去掉文件存在性检查后直接 return 的逻辑（原版有分支差异）
- 返回调用方的 `allocator` 分配的内存

### C2. loadDotEnv

```zig
/// Load .zagent/.env into StringArrayHashMap. Caller must deinit.
pub fn loadDotEnv(allocator: Allocator, project_root: []const u8, io: std.Io) !std.StringArrayHashMapUnmanaged([]const u8);
```

- 支持 `KEY=VALUE`、`KEY="value"`、`#` 注释
- 从 z-agent 迁移，函数体基本不变

### C3. Config.load

```zig
pub fn load(allocator: Allocator, project_root: []const u8, io: std.Io) !Config {
    // 1. join path → .zagent/config.toml
    // 2. readFile → FileNotFound? → write default → retry
    // 3. toml.parse(content)
    // 4. parseConfigContent(toml_root) → Config
    //     - getString("default_model")
    //     - getInt("max_tokens")
    //     - getInt("max_tool_rounds")
    //     - parseProviders(providers_table_array) → []ProviderEntry
    // 5. return Config
}
```

### C4. 与 z-agent 的差异

| z-agent（不迁移） | z-agent-core（替代） |
|---|---|
| `permissions` 表解析 | 暂不需要权限系统 |
| `proxy` 配置 | V2 |
| `warnIfNotOwnerOnly` 文件权限检查 | Windows 不需要 |
| `ProviderEntry` 中 `context_limit` 扁平的 | 拆到 `Model.context_window`，每个模型自己声明 |
| `models: []const []const u8` 字符串数组 | `models: []const Model` 结构化值对象 |
| `kind: []const u8` 字符串协议类型 | `api: Api` 编译期枚举 |
| `ProviderEntry` 从 `provider/registry.zig` 导入 | `types.zig` 统一定义，避免 config → provider 循环 |
| `Config.deinit` 中 permission 清理 | 不需要 |

## D. toml.zig 迁移策略

- 从 `projects/z-agent/src/toml.zig` **逐行复制**，不做重构
- 删除不需要的：无（整个文件是独立解析器，零外部依赖）
- 修改 import：`const std = @import("std");` 不变
- 验证：`zig test src/toml.zig` 确认 40+ 个 test 全绿

## E. 新增/修改文件清单

| 文件 | 操作 | 内容 |
|------|------|------|
| `src/toml.zig` | 新建（迁移） | 从 z-agent 逐行复制 |
| `src/types.zig` | 修改 | 新增 `Api` 枚举、`Model` struct（6 字段）、`ProviderEntry` struct（5 字段）、`InputModality` 枚举、`ToolContext` struct |
| `src/config.zig` | 实现 | Config + findZagentRoot + loadDotEnv + 模板 + parseConfigContent |
| `src/test.zig` | 修改 | 新增 `_ = @import("config.zig");`（去掉 `io/config.zig`） |

## F. 测试计划

| 测试 | 类型 | 覆盖 |
|------|------|------|
| `toml.zig` 内置 test | 迁移 | 40+ 个 test block（迁移后自动继承） |
| `config "parse default"` | 新增 | 解析完整模板 TOML → Config + 两个 provider + 三个 model，所有字段非空/非零 |
| `config "model reasoning true"` | 新增 | DeepSeek V4 Pro 的 `reasoning = true` |
| `config "model input text"` | 新增 | `input = ["text"]` → `&.{.text}` |
| `config "model input multimodal"` | 新增 | `input = ["text", "image"]` → `&.{ .text, .image }` |
| `config "findZagentRoot from project"` | 新增 | 在 `.zagent/` 存在时返回正确路径 |
| `config "findZagentRoot rootless"` | 新增 | 无 `.zagent/` 目录时返回 null |
| `config "missing file creates default"` | 新增 | 无 config.toml 时自动创建模板 |
| `config "loadDotEnv basic"` | 新增 | KEY=VALUE 解析 |
| `config "loadDotEnv quoted"` | 新增 | `KEY="value"` 解析 |
| `config "resolveModel deepseek/v4-pro"` | 新增 | `resolveModel("deepseek/deepseek-v4-pro")` 返回正确 Model |
| `config "resolveModel unknown"` | 新增 | `resolveModel("nobody/ghost")` 返回 null |
| `config "deinit cleans all duped strings"` | 新增 | load → deinit，testing.allocator 检测无泄漏 |
| `config "validate no models"` | 新增 | provider.models = [] → error.InvalidConfig_NoModels |
| `config "validate zero context"` | 新增 | model.context_window = 0 → error.InvalidConfig_ContextWindowZero |

## G. 失败路径

| 场景 | 行为 |
|------|------|
| `.zagent/config.toml` 不存在 | 创建默认模板，stderr 提示 `Created .zagent/config.toml` |
| `.zagent/` 目录不存在 | `findZagentRoot` 返回 null → Config.load 创建 `.zagent/` + 模板 |
| TOML 解析失败 | `error.InvalidToml` + 行号信息 |
| `.env` 文件不存在 | 返回空 map，不是错误 |
| `api_key_env` 变量未设置 | 此时不检查——provider 在 Step 2 取 key 时检查 |
| 模板写入磁盘失败 | 返回 IO 错误 |

## H. 架构基线（Step 1 完成后验证）

```powershell
zig build check
# 预期：编译通过 + check-arch 0 issue 0 warning

node ../../.opencode/skills/zig-dev/scripts/check-arch.mjs .
# God Object: 0, Cycles: 0, BIDIR: 0
```

依赖方向验证：`toml.zig` 不 import 任何项目模块。`config.zig` import `toml.zig` + `types.zig`，不 import `core/` 或 `tool/`。放在 `src/` 根级，与 `types.zig` 同级——作为基础模块被 `provider`、`agent`、`tool` 等依赖。

## 预计行数

| 文件 | 行数 |
|------|------|
| `src/toml.zig` | ~578（迁移后不变） |
| `src/config.zig` | ~855（含 22 个 test block） |
| `src/types.zig` | 47（含 Tool 签名修正 + 新增类型） |
| **合计** | ~1480 |
