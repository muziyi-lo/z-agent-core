# Plan PHASE-3: 协议适配层（代码对齐版）

## 状态: 计划中

## 问题

当前只有 `provider.zig:29-37` 的 `detectVendor()` 做 `api.deepseek.com → .deepseek` 的二元区分。思考参数通过 TOML `params_json` 字段盲拼到 JSON body（`provider.zig:481-486`），其他 provider 靠运气。添加 Qwen 时 SSE 闪烁（`in_content_phase` 单相位锁问题），DeepSeek V4 Pro 的 `params_json` 转义 Bug。

## 前置知识

### DeepSeek API 行为

1. **默认思考开启**：不发送 thinking 字段时，API 默认启用思考（effort=high）
2. **effort 自动提升**：复杂 Agent 类请求（Claude Code、OpenCode 模式）effort 自动设为 max
3. **effort 映射**：low/medium → high，xhigh → max（API 层兼容映射）
4. **base_url**：`https://api.deepseek.com`（无 `/v1/` 在域名层面）

### 当前架构约束

- `provider.zig` 使用 `curl --fail-with-body` 子进程 → HTTP 状态码不可直接区分（exit 22 涵盖所有 >=400）
- `callWithRetry` 是 try-catch 结构（`provider.zig:130-142`），无 `continue` 机制
- `error_body_buf` 是 `chatCompletionStreamingOnce` 局部变量（`provider.zig:218`），重试循环不可访问
- `in_content_phase` 是单布尔标志（`provider.zig:221`），不支持交错式推理
- `Provider.Config` 在 `provider.zig:25-35`
- `Provider.init()` 签名为 `init(allocator, entry, *const Model, vendor_override: ?Vendor, io, phase_writer)`
- `App.init()` 调用 `Provider.init(allocator, entry, model, null, io, phase_writer_cb)`（`App.zig:154`）
- `main.zig:94` 调用 `App.init(allocator, io, single_prompt, model_override)`
- `render.zig:28` `MessageType` 枚举：`user, think, tool, output, err, warning, success, usage`（无 `.info`）
- `agent.zig` 测试中 ~14 处直接构造 `Provider.Config{}` 字面量

## 目标

1. 新增 `ModelCompat` + `detectCompat()` — URL 启发式推断 + TOML 可选覆盖
2. 7 级思考强度（`none/minimal/low/medium/high/xhigh/max`），CLI `--thinking` + REPL `/thinking`
3. 兼容 7 种 thinking JSON 格式
4. 流式双相位标记（修复闪烁 + 支持交错式推理）
5. `stream_options` 400 自动回退

## 改动文件

| 文件 | 改动要点 |
|------|---------|
| `src/types.zig` | 新增 4 个类型 + `detectCompat()`；`Model` 新增 `compat` 字段 |
| `src/config.zig` | TOML 解析 `[models.compat]` 子表；`resolveCompat()` 合并函数；DEFAULT_TEMPLATE 改用 compat |
| `src/io/provider.zig` | `Config` 新增 `compat` + `stream_options_declined`；`buildJsonBody` compat 驱动；`buildThinkingJson()`；流式双相位；`isStreamOptions400Error()`；`chatCompletionStreamingOnce` 内回退 |
| `src/core/agent.zig` | 14 处 `Config{}` 字面量加 `.compat = .{}` |
| `src/frontends/cli/main.zig` | `--thinking` 参数 |
| `src/frontends/cli/App.zig` | `/thinking` REPL 命令；CLI thinking_level 传递给 Provider |

---

## 步骤 1: types.zig — 新增 compat 类型

### 1a. 新增 ModelCompat

```zig
/// Per-model protocol quirks, all default to safe/silent.
/// Populated by detectCompat() for known providers; TOML can override via ModelCompatOverride.
pub const ModelCompat = struct {
    thinking_format: ThinkingFormat = .none,
    thinking_level: ThinkingLevel = .high,
    max_tokens_field: MaxTokensField = .max_tokens,
    supports_stream_options: bool = false,
    supports_usage_in_streaming: bool = false,
    require_reasoning_on_tool_calls: bool = false,
};

pub const ModelCompatOverride = struct {
    thinking_format: ?ThinkingFormat = null,
    thinking_level: ?ThinkingLevel = null,
    max_tokens_field: ?MaxTokensField = null,
    supports_stream_options: ?bool = null,
    supports_usage_in_streaming: ?bool = null,
    require_reasoning_on_tool_calls: ?bool = null,
};
```

### 1b. 新增枚举

```zig
pub const ThinkingFormat = enum {
    none,                    // no thinking param sent
    thinking_object,         // DeepSeek: {"thinking":{"type":"enabled"}}
    reasoning_effort,        // OpenAI: {"reasoning_effort":"high"}
    enable_thinking_bool,    // Qwen: {"enable_thinking":true}
    thinking_parameters,     // Aliyun dashscope: {"parameters":{"enable_thinking":true}}
    thinking_with_budget,    // Anthropic: {"thinking":{"type":"enabled","budget_tokens":16000}}
    thinking_config_object,  // Gemini: {"thinkingConfig":{"thinkingBudget":-1}}
};

pub const ThinkingLevel = enum {
    none, minimal, low, medium, high, xhigh, max,

    pub fn fromString(s: []const u8) ?ThinkingLevel {
        inline for (@typeInfo(ThinkingLevel).@"enum".fields) |field| {
            if (std.mem.eql(u8, s, field.name)) return @field(ThinkingLevel, field.name);
        }
        return null;
    }
};

pub const MaxTokensField = enum {
    max_tokens,           // OpenAI standard
    max_tokens_to_sample, // Anthropic
    max_output_tokens,    // Gemini via OpenAI compat
};
```

### 1c. Model 结构体扩展

```zig
pub const Model = struct {
    id: []const u8,
    name: []const u8,
    provider: []const u8 = "",
    context_window: u32,
    max_tokens: u32,
    params_json: ?[]const u8 = null,       // retained: backward compat for non-thinking params
    input: []const InputModality,
    compat: ?ModelCompatOverride = null,    // NEW: TOML override (all fields optional → null = not set)
};
```

### 1d. detectCompat()

```zig
/// Infer protocol compat from provider base_url. Returns safe defaults for unknown hosts.
/// Path keywords checked first (case-insensitive, stack buffer ≤256 bytes).
/// Domain heuristic only runs if no path keyword matched.
pub fn detectCompat(base_url: []const u8) ModelCompat {
    var c = ModelCompat{};

    // 1. Path keyword check (handles LiteLLM/OneAPI gateways)
    if (base_url.len <= 256) {
        var lower: [256]u8 = undefined;
        for (base_url, 0..) |ch, i| lower[i] = std.ascii.toLower(ch);
        const url_lower = lower[0..base_url.len];

        if (std.mem.indexOf(u8, url_lower, "/openai/") != null) {
            c.thinking_format = .reasoning_effort;
            c.supports_stream_options = true;
            c.supports_usage_in_streaming = true;
        }
        if (std.mem.indexOf(u8, url_lower, "/deepseek/") != null) {
            c.thinking_format = .thinking_object;
            c.require_reasoning_on_tool_calls = true;
        }
        if (std.mem.indexOf(u8, url_lower, "/aliyun/") != null or
            std.mem.indexOf(u8, url_lower, "/qwen/") != null) {
            c.thinking_format = .enable_thinking_bool;
        }
        if (std.mem.indexOf(u8, url_lower, "/anthropic/") != null or
            std.mem.indexOf(u8, url_lower, "/claude/") != null) {
            c.thinking_format = .thinking_with_budget;
            c.max_tokens_field = .max_tokens_to_sample;
        }
        if (std.mem.indexOf(u8, url_lower, "/gemini/") != null) {
            c.thinking_format = .thinking_config_object;
            c.max_tokens_field = .max_output_tokens;
        }
    }
    // Note: /v1/ deliberately NOT checked — too broad (also matches api.deepseek.com/v1)

    // 2. Domain heuristic (only if no path keyword set a format)
    var url = base_url;
    if (std.mem.startsWith(u8, url, "https://")) url = url["https://".len..];
    if (std.mem.startsWith(u8, url, "http://")) url = url["http://".len..];
    const hostname = if (std.mem.indexOfAny(u8, url, "/:")) |pos| url[0..pos] else url;

    if (std.mem.endsWith(u8, hostname, ".deepseek.com") or
        std.mem.eql(u8, hostname, "api.deepseek.com")) {
        if (c.thinking_format == .none) c.thinking_format = .thinking_object;
        c.require_reasoning_on_tool_calls = true;
    }
    if (std.mem.eql(u8, hostname, "api.openai.com") or
        std.mem.endsWith(u8, hostname, ".openai.com")) {
        if (c.thinking_format == .none) c.thinking_format = .reasoning_effort;
        c.supports_stream_options = true;
        c.supports_usage_in_streaming = true;
    }
    if (std.mem.startsWith(u8, hostname, "dashscope.") or
        std.mem.endsWith(u8, hostname, ".aliyuncs.com")) {
        if (c.thinking_format == .none) c.thinking_format = .enable_thinking_bool;
    }

    return c;
}
```

### 1e. 思考强度映射表

| 通用等级 | thinking_object (DeepSeek) | reasoning_effort (OpenAI/OpenRouter) | enable_thinking_bool | thinking_with_budget | thinking_config_object |
|----------|---------------------------|-------------------------------------|---------------------|---------------------|----------------------|
| `none` | `{"type":"disabled"}` | 不发字段 | `{"enable_thinking":false}` | budget=0 | budget=0 |
| `minimal` | 同 `high` | `"reasoning_effort":"minimal"` | `true` | 2000 | 512 |
| `low` | 同 `high` | `"reasoning_effort":"low"` | `true` | 4000 | 1024 |
| `medium` | 同 `high` | `"reasoning_effort":"medium"` | `true` | 8000 | 4096 |
| `high` | `{"type":"enabled"}` | `"reasoning_effort":"high"` | `true` | 16000 | 16000 |
| `xhigh` | 同 `max` | `"reasoning_effort":"xhigh"` | `true` | 24000 | 24576 |
| `max` | `{"type":"enabled","level":"max"}` | 降级为 `"high"` | `true` | 31999 | 32768 |

关键语义（基于 DeepSeek API 实际行为）：
- `none` → **必须显式发送** `{"type":"disabled"}`。DeepSeek API 默认 thinking=enabled，不发送 ≠ 关闭
- `low`/`medium` → API 层映射为 high（无浅层档位）
- `xhigh` → API 层映射为 max（Agent 请求自动提升）
- `"level":"max"` 只在 `.max`（和 `.xhigh`，因为映射）时发送

---

## 步骤 2: config.zig — TOML compat 解析 + resolveCompat()

### 2a. TOML 格式

```toml
[[models]]
id = "my-model"
thinking_level = "high"        # 写入 model.compat.thinking_level（顶级键，非子表内）

[models.compat]                # 可选子表，覆盖 detectCompat()
thinking_format = "reasoning_effort"
max_tokens_field = "max_tokens_to_sample"
supports_stream_options = true
```

### 2b. parseAllModels() 扩展

在 `config.zig:464-489` 的 `parseAllModels` 循环中，`params_json` 解析之后、`input` 解析之前插入：

```zig
// --- NEW: parse [models.compat] sub-table ---
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
            if (v == .bool) ov.supports_stream_options = v.bool;
        }
        if (compat_val.table.get("supports_usage_in_streaming")) |v| {
            if (v == .bool) ov.supports_usage_in_streaming = v.bool;
        }
        if (compat_val.table.get("require_reasoning_on_tool_calls")) |v| {
            if (v == .bool) ov.require_reasoning_on_tool_calls = v.bool;
        }
        model_compat = ov;
    }
}
// Also parse top-level thinking_level into override
if (mt.get("thinking_level")) |tl_val| {
    if (tl_val == .string) {
        if (types.ThinkingLevel.fromString(tl_val.string)) |tl| {
            if (model_compat == null) model_compat = types.ModelCompatOverride{};
            model_compat.?.thinking_level = tl;
        }
    }
}
```

模型构造时新增字段：
```zig
try list.append(a, .{
    .id = try a.dupe(u8, id_raw),
    // ... existing fields ...
    .params_json = getString(mt, "params_json"),
    .compat = model_compat,  // NEW
    .input = try parseInputModality(a, mt),
});
```

### 2c. 辅助函数

```zig
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
```

### 2d. resolveCompat()

放在 `config.zig` 中，`resolveModel()` 附近。`Provider.init()` 调用：

```zig
/// Merge TOML ModelCompatOverride into detectCompat result.
/// Only non-null override fields replace detected values.
/// Returns: finalized ModelCompat for Provider.Config.
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
```

### 2e. DEFAULT_TEMPLATE 更新

`DEEPSEEK_V4_PRO` 的 `params_json` 行替换为：

```toml
# compat: auto-detected from base_url. Override via [models.compat] sub-table.
# thinking_level = "high"           # none|minimal|low|medium|high|xhigh|max (default: high)
[models.compat]
# thinking_format = "thinking_object"  # auto-detected; uncomment to force
```

保留 `params_json` 字段但注释说明它只用于 compat 不覆盖的非-thinking 参数。

### 2f. 测试更新

| 现有测试 | 改动 |
|---------|------|
| `parse default template` | `models[0].params_json != null` → 改为 `== null`（模板不再设 params_json） |
| `model params_json present` | 改验证 `compat.thinking_format` 被解析 |
| `resolveModel deepseek/v4-pro` | `model.params_json != null` → `model.compat != null` |

新增测试：
- `detectCompat deepseek` — `api.deepseek.com` → `.thinking_object`
- `detectCompat openai` — `api.openai.com` → `.reasoning_effort` + `supports_stream_options`
- `detectCompat aliyun` — `dashscope.aliyuncs.com` → `.enable_thinking_bool`
- `detectCompat gateway path /openai/` — 路径覆盖域名
- `detectCompat unknown` — 默认 `.none` + `supports_stream_options = false`
- `resolveCompat merges override` — TOML 单字段覆盖
- `resolveCompat override null vs default` — 显式设 `none` 不退回 detectCompat
- `ThinkingLevel fromString all 7 values`

---

## 步骤 3: provider.zig — Config 扩展 + buildJsonBody + buildThinkingJson

### 3a. Config 扩展

```zig
pub const Config = struct {
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
    max_tokens: u32,
    connect_timeout_secs: u16 = 15,
    max_timeout_secs: u16 = 300,
    vendor: Vendor,
    vendor_override: ?Vendor = null,
    model_params: ?[]const u8 = null,           // retained: non-thinking backward compat
    compat: types.ModelCompat,                  // NEW: immutable protocol quirks
    stream_options_declined: bool = false,      // NEW: runtime, set after 400 error
};
```

注意：`compat` **非可选**（Zig 0.16 struct 字面量缺失字段 = undefined，非默认值）。所有现存的 `Config{}` 字面量必须显式添加 `.compat = .{}`。

### 3b. Provider.init() 更新

当前 `provider.zig:49-82`，在构造 Provider 时调用 `resolveCompat`：

```zig
pub fn init(
    allocator: std.mem.Allocator,
    entry: types.ProviderEntry,
    model: *const types.Model,
    vendor_override: ?Vendor,
    io: std.Io,
    phase_writer: ?PhaseWriterCb,
) !Provider {
    // ... existing env lookup ...
    const compat = config_mod.resolveCompat(entry.base_url, model);  // NEW

    return Provider{
        .config = .{
            .base_url = entry.base_url,
            .api_key = key_owned,
            .model = model.id,
            .max_tokens = model.max_tokens,
            .vendor = vendor,
            .vendor_override = vendor_override,
            .model_params = model.params_json,
            .compat = compat,                   // NEW
            .stream_options_declined = false,   // NEW
        },
        .phase_writer = phase_writer,
    };
}
```

注意：`provider.zig` 需要新增 `const config_mod = @import("../config.zig");` 来调用 `resolveCompat`。这不会创建循环依赖——config.zig 不 import provider.zig。

### 3c. Vendor 处理

`Vendor` enum 保留但降级：不再驱动 buildJsonBody 协议决策（compat 替代）。`detectVendor()` 保留作为 domain 快速判断（可被 compat 层调用或保留用）。

### 3d. buildThinkingJson()

```zig
fn buildThinkingJson(
    buf: *std.ArrayListAligned(u8, null),
    allocator: std.mem.Allocator,
    format: types.ThinkingFormat,
    level: types.ThinkingLevel,
) !void {
    if (level == .none) {
        // Must explicitly disable for providers that default to thinking=enabled (DeepSeek)
        switch (format) {
            .thinking_object => try buf.appendSlice(allocator, "\"thinking\":{\"type\":\"disabled\"}"),
            .enable_thinking_bool => try buf.appendSlice(allocator, "\"enable_thinking\":false"),
            .thinking_with_budget => try buf.appendSlice(allocator, "\"thinking\":{\"type\":\"disabled\",\"budget_tokens\":0}"),
            else => return, // no field = disabled for reasoning_effort, none, etc.
        }
        return;
    }
    switch (format) {
        .none => {},
        .thinking_object => {
            switch (level) {
                .none => unreachable,
                .minimal, .low, .medium, .high => try buf.appendSlice(allocator, "\"thinking\":{\"type\":\"enabled\"}"),
                .xhigh, .max => try buf.appendSlice(allocator, "\"thinking\":{\"type\":\"enabled\",\"level\":\"max\"}"),
            }
        },
        .reasoning_effort => {
            const s = switch (level) {
                .none => unreachable,
                .minimal => "minimal", .low => "low", .medium => "medium",
                .high => "high", .xhigh => "xhigh", .max => "high",
            };
            try buf.appendSlice(allocator, "\"reasoning_effort\":\"");
            try buf.appendSlice(allocator, s);
            try buf.appendSlice(allocator, "\"");
        },
        .enable_thinking_bool => try buf.appendSlice(allocator, "\"enable_thinking\":true"),
        .thinking_parameters => try buf.appendSlice(allocator, "\"parameters\":{\"enable_thinking\":true}"),
        .thinking_with_budget => {
            const budget: u32 = switch (level) {
                .none => 0, .minimal => 2000, .low => 4000, .medium => 8000,
                .high => 16000, .xhigh => 24000, .max => 31999,
            };
            var b: [16]u8 = undefined;
            const bs = try std.fmt.bufPrint(&b, "{d}", .{budget});
            if (budget == 0) {
                try buf.appendSlice(allocator, "\"thinking\":{\"type\":\"disabled\",\"budget_tokens\":0}");
            } else {
                try buf.appendSlice(allocator, "\"thinking\":{\"type\":\"enabled\",\"budget_tokens\":");
                try buf.appendSlice(allocator, bs);
                try buf.appendSlice(allocator, "}");
            }
        },
        .thinking_config_object => {
            const budget: i32 = switch (level) {
                .none => 0, .minimal => 512, .low => 1024, .medium => 4096,
                .high => 16000, .xhigh => 24576, .max => 32768,
            };
            var b: [16]u8 = undefined;
            const bs = try std.fmt.bufPrint(&b, "{d}", .{budget});
            try buf.appendSlice(allocator, "\"thinkingConfig\":{\"thinkingBudget\":");
            try buf.appendSlice(allocator, bs);
            try buf.appendSlice(allocator, "}");
        },
    }
}
```

### 3e. buildJsonBody 替换 model_params 分支

当前 `provider.zig:481-486`（model_params 拼接）替换为 compat 驱动 + model_params 保留：

```zig
// NEW: compat-driven thinking JSON
if (self.config.compat.thinking_format != .none and
    self.config.compat.thinking_level != .none) {
    try buf.appendSlice(allocator, ",");
    try buildThinkingJson(&buf, allocator,
        self.config.compat.thinking_format,
        self.config.compat.thinking_level);
}

// NEW: compat-driven max_tokens field name
try buf.appendSlice(allocator, ",\"");
try buf.appendSlice(allocator, switch (self.config.compat.max_tokens_field) {
    .max_tokens => "max_tokens",
    .max_tokens_to_sample => "max_tokens_to_sample",
    .max_output_tokens => "maxOutputTokens",
});
try buf.appendSlice(allocator, "\":");
{
    var num_buf: [16]u8 = undefined;
    const num_str = try std.fmt.bufPrint(&num_buf, "{d}", .{self.config.max_tokens});
    try buf.appendSlice(allocator, num_str);
}

if (stream) {
    try buf.appendSlice(allocator, ",\"stream\":true");
    if (self.config.compat.supports_stream_options and
        !self.config.stream_options_declined) {
        try buf.appendSlice(allocator, ",\"stream_options\":{\"include_usage\":true}");
    }
}

// KEPT: model_params for backward compat (non-thinking params)
if (self.config.model_params) |params| {
    if (params.len > 0) {
        try buf.appendSlice(allocator, ",");
        try buf.appendSlice(allocator, params);
    }
}

try buf.appendSlice(allocator, "}");
```

### 3f. stream_options 400 回退

`--fail-with-body` 在 HTTP 错误时返回 exit 22（不区分状态码），但响应体（JSON 错误）会写到 stdout —— 这正是 `chatCompletionStreamingOnce` 中 `error_body_buf` 捕获的内容。不需要解析 HTTP 状态行，直接检查错误体即可。

在 `provider.zig:381-399`（curl 退出后检测到错误体时）：

```zig
// Check if error is specifically about stream_options being unsupported
// Guard with !declined to prevent infinite retry loop: the retried request
// goes through the same error detection — if its body also happens to match,
// we must NOT trigger again.
if (!self.config.stream_options_declined and isStreamOptions400Error(error_body_str)) {
    self.config.stream_options_declined = true;
    // Rebuild body without stream_options and retry once internally
    const retry_body = try buildJsonBody(self, alloc, messages, tools, true);
    // Re-spawn curl with retry_body, re-read SSE, return result
    // (single internal retry, doesn't count against callWithRetry's budget)
    return result;
}
// Else: existing isRetryableBody / error.ApiError logic unchanged
```

`isStreamOptions400Error` 直接检查错误 JSON 体（无需 `parseHttpStatus`）：

```zig
fn isStreamOptions400Error(body: []const u8) bool {
    return std.mem.indexOf(u8, body, "stream_options") != null and
           (std.mem.indexOf(u8, body, "unknown") != null or
            std.mem.indexOf(u8, body, "unrecognized") != null or
            std.mem.indexOf(u8, body, "Invalid") != null);
}
```

### 3g. 测试更新

所有现有 `Provider.Config{}` 字面量（`provider.zig` 测试 ~15 处）加 `.compat = .{}`。

新增测试（构建 Provider 实例 + 调用 buildJsonBody）：
- `thinking_object high` → 包含 `"type":"enabled"` 不含 `"level":"max"`
- `thinking_object low` → 同样包含 `"type":"enabled"`（不意味着 disabled）
- `thinking_object max` → 包含 `"type":"enabled"` + `"level":"max"`
- `thinking_object xhigh` → 同 max（xhigh 映射为 max）
- `thinking_object none` → 包含 `"type":"disabled"`（不省略字段）
- `reasoning_effort high` → 包含 `"reasoning_effort":"high"`
- `max_tokens_to_sample` → 使用 `"max_tokens_to_sample"` 键名
- `stream_options = true` → 包含 `"stream_options":{"include_usage":true}`
- `stream_options_declined = true` → 不含 stream_options
- `thinking_level = none` → 不含 thinking/reasoning_effort 字段（格式为 `.none` 或 `.reasoning_effort`）

### 3h. 错误分类增强 — 基于响应体内容（参考 OpenCode `retry.ts` / `executor.ts`）

当前 `isRetryableBody` 仅匹配 `rate/quota/overloaded/429/503`。参考 OpenCode 的实践（不依赖 HTTP 状态码，靠体内容分类），扩增为 5 类错误检测：

```zig
/// Extend the existing isRetryableBody with auth/context-overflow/html detection.
/// Called after curl exits non-zero (error_body_buf has content).

fn classifyError(body: []const u8) ErrorClass {
    if (isStreamOptions400Error(body)) return .stream_options_unsupported;
    if (isAuthError(body)) return .authentication;
    if (isContextOverflowError(body)) return .context_overflow;
    if (isHtmlError(body)) return .gateway_html;
    if (isRetryableBody(body)) return .retryable;
    return .fatal;
}

const ErrorClass = enum {
    retryable,                  // → error.ApiRateLimited → callWithRetry 重试
    stream_options_unsupported, // → 设置 declined → 内部重试（无 stream_options）
    authentication,             // → ApiKeyNotSet 友好消息（不重试）
    context_overflow,           // → 触发压缩（PHASE-4），本次返回 error.ApiError
    gateway_html,               // → "Blocked by gateway/proxy" 友好消息
    fatal,                      // → error.ApiError（不可恢复）
};
```

**各检测函数（体内容匹配，不依赖状态码）**：

```zig
fn isAuthError(body: []const u8) bool {
    return std.mem.indexOf(u8, body, "authentication_error") != null or
           std.mem.indexOf(u8, body, "invalid_api_key") != null or
           std.mem.indexOf(u8, body, "Invalid token") != null or
           std.mem.indexOf(u8, body, "Incorrect API key") != null;
}

fn isContextOverflowError(body: []const u8) bool {
    return std.mem.indexOf(u8, body, "context_length_exceeded") != null or
           std.mem.indexOf(u8, body, "maximum context length") != null or
           (std.mem.indexOf(u8, body, "reduce the length") != null and
            std.mem.indexOf(u8, body, "messages") != null);
}

fn isHtmlError(body: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, body, " \t\r\n");
    const doctype = "<!doctype";
    const html = "<html";
    return (trimmed.len >= doctype.len and std.ascii.eqlIgnoreCase(trimmed[0..doctype.len], doctype)) or
           (trimmed.len >= html.len and std.ascii.eqlIgnoreCase(trimmed[0..html.len], html));
}
```

`chatCompletionStreamingOnce` 错误处理更新为：

```zig
switch (classifyError(error_body_str)) {
    .stream_options_unsupported => {
        if (self.config.stream_options_declined) return error.ApiError; // guard
        self.config.stream_options_declined = true;
        // internal retry without stream_options (as described in 3f)
    },
    .authentication => return error.ApiKeyNotSet,  // already handled by existing auth check
    .context_overflow => return error.ApiError,     // PHASE-4 will trigger compaction here
    .gateway_html => {
        // Log friendly message, return fatal
        var sbuf: [256]u8 = undefined;
        var sw: std.Io.File.Writer = .init(.stderr(), io, &sbuf);
        sw.interface.print("error: request blocked by gateway or proxy\n", .{}) catch {};
        return error.ApiError;
    },
    .retryable => return error.ApiRateLimited,
    .fatal => return error.ApiError,
}
```

**注意**：这些检测不需要 HTTP 状态码——`-sN --fail-with-body` 已把 JSON 错误体写入 stdout → `error_body_buf`。OpenCode 在 `retry.ts` / `executor.ts` 中同样通过体内容（非状态码）分类错误。

---

## 步骤 4: 流式相位独立双标记

### 4a. 问题

当前 `provider.zig:221` 的 `in_content_phase` 单标志在 Qwen 同时发送 `reasoning_content` + `content` 时闪烁；不支持交错式推理（DeepSeek openai-compatible 的 thinking→content→thinking→content 交替 chunk）。

### 4b. 目标

将 `in_content_phase` 替换为 `thinking_started` 和 `text_started` 两个独立标志。

### 4c. SSE 解析修改

在 `provider.zig:300-332`（delta 解析区）：

```zig
var thinking_started = false;
var text_started = false;

// reasoning_content delta
if (delta.get("reasoning_content")) |r_val| {
    if (r_val != .null and self.config.compat.thinking_level != .none) {
        const r = r_val.string;
        if (r.len > 0) {
            if (!thinking_started) {
                thinking_started = true;
                if (text_started) {           // interleaved: end content first
                    if (pw) |p| p.end_phase(p.context);
                    text_started = false;
                }
                if (pw) |p| p.begin_phase(p.context, .thinking);
            }
            try content_buf.appendSlice(alloc, r);
            if (pw) |p| p.write_raw(p.context, r);
        }
    }
}

// content delta
if (delta.get("content")) |c_val| {
    if (c_val != .null) {
        const c = c_val.string;
        if (c.len > 0) {
            if (!text_started) {
                text_started = true;
                if (thinking_started) {       // end thinking, reset flag for interleaved
                    if (pw) |p| p.end_phase(p.context);
                    thinking_started = false;
                }
                if (pw) |p| p.begin_phase(p.context, .content);
            }
            try content_buf.appendSlice(alloc, c);
            if (pw) |p| p.write_raw(p.context, c);
        }
    }
}

// tool_calls ends both (existing logic preserved)
if (delta.get("tool_calls")) |tc_array| {
    if (thinking_started) {
        if (pw) |p| p.end_phase(p.context);
        thinking_started = false;
    }
    if (text_started) {
        if (pw) |p| p.end_phase(p.context);
        text_started = false;
    }
    // ... existing tool_calls processing ...
}
```

关键差异：
- 双方在对方开始时**将自己的标志设为 false** — 支持交错式推理
- `thinking_level == .none` 时 reasoning_content 不触发显示（即使 SSE 流中包含）
- 数据捕获始终执行，不受相位标志影响

---

## 步骤 5: CLI + REPL — thinking 强度

### 5a. main.zig — `--thinking` 参数

在 `main.zig:20-36` 的 while 循环中添加：

```zig
var thinking_level: ?types.ThinkingLevel = null;

while (arg_iter.next()) |arg| {
    // ... existing arg parsing ...
    } else if (std.mem.eql(u8, arg, "--thinking")) {
        if (arg_iter.next()) |val| {
            thinking_level = types.ThinkingLevel.fromString(val);
        }
    }
    // ...
}
```

`App.init()` 调用后（`main.zig:94`）：

```zig
var app = App.init(allocator, io, single_prompt, model_override, thinking_level) catch return;
```

`App.init` 签名更新为：
```zig
pub fn init(allocator, io, single_prompt: ?[]const u8, model_override: ?[]const u8, thinking_level: ?types.ThinkingLevel) !App
```

在 Provider 创建（`App.zig:154`）之后：

```zig
const provider = provider_mod.Provider.init(...) catch |err| { ... };
if (thinking_level) |tl| {
    provider.config.compat.thinking_level = tl;  // CLI overrides TOML
}
```

### 5b. App.zig — `/thinking` REPL 命令

在 `processLine()` 中（`App.zig:384`，`/fork` 处理之后）添加：

```zig
if (std.mem.startsWith(u8, line, "/thinking ")) {
    const level_str = std.mem.trim(u8, line["/thinking ".len..], " \t");
    if (types.ThinkingLevel.fromString(level_str)) |tl| {
        self.provider.config.compat.thinking_level = tl;
        try render.writeLabeled(&stdout.interface, .success,
            try std.fmt.allocPrint(self.allocator, "thinking level: {s}", .{level_str}));
        return;
    } else {
        try render.writeLabeled(&stdout.interface, .warning,
            "Usage: /thinking none|minimal|low|medium|high|xhigh|max");
        return;
    }
}
```

`/help` 输出（`App.zig:565-575`）新增一行：

```
\\  /thinking <level> Set thinking depth: none|minimal|low|medium|high|xhigh|max
```

**注意**：`render.writeLabeled` 使用 `.success`（已有变体），不用不存在的 `.info`。

### 5c. render.zig

**无接口变更**。`MessageType` 不需要新增变体——`/thinking` 输出用已有的 `.success`。

---

## 步骤 6: agent.zig — Config 字面量同步

所有 ~14 处直接构造 `Provider.Config{}` 字面量的位置加 `.compat = .{}`。

| 大致行号（需以实际代码为准） | 上下文 |
|---------------------------|--------|
| ~403, 432, 475, 526, 574, 613, 649 | 测试中的 Provider 构造 |
| ~730, 766, 801, 837, 867, 903, 933 | 测试中的 Provider 构造 |

```zig
// 修改前：
var p = Provider{ .config = .{ .base_url = "...", .api_key = "", ... } };
// 修改后：
var p = Provider{ .config = .{ .base_url = "...", .api_key = "", ..., .compat = .{} } };
```

---

## 波及

| 文件 | 改动 | 破坏性 |
|------|------|--------|
| `src/types.zig` | 新增 `ModelCompat`/`Override`/`ThinkingFormat`/`ThinkingLevel`/`MaxTokensField`/`detectCompat()`；`Model` 新增 `compat: ?ModelCompatOverride` | 否 |
| `src/config.zig` | TOML 解析 `[models.compat]` + `thinking_level`；`resolveCompat()`；`parseThinkingFormat()`/`parseMaxTokensField()`；DEFAULT_TEMPLATE 更新 | 否 |
| `src/io/provider.zig` | `Config` 新增 `compat` + `stream_options_declined`；`buildJsonBody` compat 驱动；`buildThinkingJson()`；`isStreamOptions400Error()`/`parseHttpStatus()`；`chatCompletionStreamingOnce` 内部回退；流式双相位；`Provider.init()` + `Vendor` 降级 | **是** — 所有 `Config{}` 字面量须加 `.compat = .{}` |
| `src/core/agent.zig` | ~14 处 `Provider.Config{}` 字面量加 `.compat = .{}` | **是** — struct 字面量编译错误 |
| `src/frontends/cli/main.zig` | `--thinking` 参数；`App.init()` 签名 +1 param | 否 |
| `src/frontends/cli/App.zig` | `/thinking` REPL 命令；`/help` 更新；`init()` 签名；CLI thinking_level → Provider | 否 |
| `src/frontends/cli/render.zig` | 无变更（使用已有 `.success` 变体） | 否 |

### Config{} 字面量清单

`compat` 为 `ModelCompat` **非可选**字段。所有 `Provider.Config{}` 构造必须显式提供：

```
provider.zig 测试区 (~15 处):  .compat = .{}
agent.zig 测试/实现 (~14 处):   .compat = .{}
```

Zig 0.16 struct 字面量不提供默认值——漏加编译失败。

---

## 验证

```powershell
zig build
zig test src/test.zig --cache-dir .zig-cache 2>&1 | Select-String "^\d+/\d+|All \d+ tests|FAIL"
```

| 场景 | 预期 |
|------|------|
| `--model deepseek/deepseek-v4-pro` | 正常，无 JSON 解析错误 |
| `--model deepseek/deepseek-v4-flash` | 正常 |
| `--model aliyun/qwen3.7-max` | 不闪烁，思考文本保留 |
| DeepSeek 交错式推理 | 标签正确切换 |
| `--thinking max` | 请求体含 `"level":"max"` |
| `--thinking none` | DeepSeek 请求体含 `"type":"disabled"` |
| `/thinking low` REPL | 下一回合用低强度 |
| `/thinking none` REPL | SSE reasoning_content 不渲染 |
| 未知 provider | 默认 OpenAI 标准，不报错 |
| stream_options 400 | 自动内部重试不加 stream_options |
| 编译 + `zig test` | agent.zig/provider.zig 所有 Config{} 编译通过 |

---

## 实施顺序

```
步骤 1  (types.zig):      ModelCompat + Override + ThinkingFormat + ThinkingLevel
                           + MaxTokensField + detectCompat()
步骤 2  (config.zig):     parseAllModels compat 解析 + parseXxx 辅助函数
                           + resolveCompat() + DEFAULT_TEMPLATE 更新
步骤 3a (provider.zig):   Config 扩展 + Provider.init 调用 resolveCompat
步骤 3b (provider.zig):   buildThinkingJson() + buildJsonBody compat 驱动
步骤 3c (provider.zig):   isStreamOptions400Error() + classifyError() + isAuthError()
                            + isContextOverflowError() + isHtmlError()
                            + chatCompletionStreamingOnce 内部回退
步骤 3d (agent.zig):      所有 Config{} 字面量加 .compat = .{}
步骤 4  (provider.zig):   流式双相位标记 + .none 显示抑制
步骤 5a (main.zig):       --thinking CLI 参数 + App.init 签名
步骤 5b (App.zig):        /thinking REPL + /help 更新
```

每步后 `zig build` 验证编译通过。全部完成后 `zig test`。

---

## 术语

| 术语 | 含义 |
|------|------|
| compat | 协议适配层 — 根据 base_url 推断 API 参数格式 |
| thinking_format | 思考模式在 JSON body 中的表示格式（7 种） |
| thinking_level | 思考深度等级（none/minimal/low/medium/high/xhigh/max） |
| resolveCompat | 合并 detectCompat + TOML override → 最终 ModelCompat |
| 双相位 | thinking/text 独立跟踪，支持交错式推理 |
| stream_options 回退 | API 400 后自动内部重试（不消耗 callWithRetry 预算） |

## 已知限制

### `/load` 回放无 Markdown 渲染 + reasoning_content 不可拆分

**现象**：`/load` 加载历史会话后，消息用 `render.writeLabeled()` 直接输出纯文本，与实时 SSE 流的两条路径不一致——实时路径走 `LineBuffer` + `renderLine` (Markdown→ANSI)，`/load` 不走。

**根因**：当前 `msg.content` 是思考+输出的混合体（SSE 解析时将 `reasoning_content` 和 `content` 追加到同一个 `content_buf`）。事后无法拆分思考/输出相位，也无法独立渲染 Markdown。

**修复计划**：PHASE-4 将 `reasoning_content` 存储为独立字段 → `/load` 回放时可走完整渲染管线（begin_phase(.thinking) → 思考文本 → begin_phase(.output) → Markdown 渲染）。

**临时方案**：`/load` 仅作回放预览，纯文本输出全部消息。不影响正常 SSE 流的 Markdown 渲染。
