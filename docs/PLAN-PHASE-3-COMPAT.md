# Plan PHASE-3: 协议适配层 (Compat Layer)

## 状态: 计划中

## 来源

对比 Pi 的 `detectCompat()` + compat 系统，z-agent-core 缺失整个协议适配层。当前 `params_json` 盲拼仅覆盖 DeepSeek 一种 thinking 格式，Qwen 能用纯属运气——恰好兼容 DeepSeek 的 thinking 格式 + OpenAI 标准的其他行为。下一个不兼容模型会再次崩。

## 缺口全景

| 层 | Pi | z-agent-core | 影响 |
|----|-----|-------------|------|
| **协议适配** | `detectCompat()` URL 推断 20+ 参数 | `params_json` 盲拼 | 仅 deepseek 一种格式 |
| **thinking 格式** | 7 种 | 硬编码 `thinking: {type}` | Qwen 恰好兼容，其他不保证 |
| **max_tokens 字段** | `max_completion_tokens` vs `max_tokens` 自动选择 | 硬编码 `max_tokens` | Cerebras/Cloudflare 等不兼容 |
| **流式相位** | 双独立块不互斥 | 单相位切换 | Qwen 闪烁（P0 已修复但架构未改） |
| **usage 请求** | `stream_options: { include_usage: true }` | 缺失 | 部分 provider 不返回 usage |
| **重试** | `retry-after` 头 + AbortSignal | 关键词 + 阻塞 sleep | 重试时机不准确 |
| **模型注册** | `models.json` + compat 覆盖 | TOML 仅 2 个模型模板 | 用户无法自定义 |

## compat 字段定义

### types.zig 新增 `ModelCompat`

```zig
pub const ThinkingFormat = enum { openai, deepseek, qwen, openrouter, together, zai, disabled };

pub const ModelCompat = struct {
    thinking_format: ThinkingFormat = .disabled,
    max_tokens_field: MaxTokensField = .max_tokens,
    supports_usage_in_streaming: bool = false,
    supports_store: bool = true,
    supports_developer_role: bool = true,
    supports_reasoning_effort: bool = false,
    supports_tool_choice: bool = true,
    requires_reasoning_content_on_assistant: bool = false,
    requires_assistant_content_for_tool_calls: bool = false,
};

pub const MaxTokensField = enum { max_tokens, max_completion_tokens };
```

### detectCompat — URL 启发式

```zig
pub fn detectCompat(base_url: []const u8) ModelCompat {
    if (std.mem.indexOf(u8, base_url, "api.deepseek.com") != null) {
        return .{ .thinking_format = .deepseek, .supports_developer_role = false,
                  .supports_tool_choice = false, .requires_reasoning_content_on_assistant = true,
                  .requires_assistant_content_for_tool_calls = true };
    }
    if (std.mem.indexOf(u8, base_url, "aliyun") != null) {
        return .{ .thinking_format = .qwen, .supports_usage_in_streaming = true, .supports_developer_role = false };
    }
    if (std.mem.indexOf(u8, base_url, "api.openai.com") != null) {
        return .{ .max_tokens_field = .max_completion_tokens, .supports_reasoning_effort = true };
    }
    // ...
    return .{}; // default: OpenAI-compatible standard
}
```

### buildJsonBody — 根据 compat 构建

```zig
// max_tokens 字段
switch (compat.max_tokens_field) {
    .max_tokens => buf.appendSlice(",\"max_tokens\":"),
    .max_completion_tokens => buf.appendSlice(",\"max_completion_tokens\":"),
}

// thinking 格式
switch (compat.thinking_format) {
    .deepseek => buf.appendSlice(",\"thinking\":{\"type\":\"enabled\"}"),
    .qwen => buf.appendSlice(",\"enable_thinking\":true"),
    .openai => buf.appendSlice(",\"reasoning_effort\":\"high\""),
    .disabled => {},
    else => {},
}

// usage
if (compat.supports_usage_in_streaming) {
    buf.appendSlice(",\"stream_options\":{\"include_usage\":true}");
}
```

### TOML 配置扩展

```toml
[[models]]
id = "qwen3.7-max"
compat = "qwen"              # 快捷方式，等于 detectCompat("aliyun") 的结果
# 或手动覆盖单个字段：
compat_thinking = "qwen"
compat_usage_streaming = true
```

## 实施顺序

```
Phase 3.1: types.zig — ModelCompat + detectCompat                [types + config, 无破坏性]
Phase 3.2: provider.zig — buildJsonBody 根据 compat 构建         [IO 层, 与上述正交]
            └─ 消化 FIX-2: params_json 盲拼 → compat.thinking_format 枚举
               thinking JSON 由程序化生成，无需 TOML 中转义引号
Phase 3.3: config.zig — TOML compat 字段解析                    [配置层]
Phase 3.4: provider.zig — 流式相位独立块化                         [IO 层, 修复 Qwen 闪烁根因]
```

Phase 3.1-3.3 先建立 compat 数据流，Phase 3.4 解决流式相位问题。

## 已消化文档

| 文档 | 状态 |
|------|------|
| `PLAN-FIX-2-PARAMS-JSON.md` | → 并入 Phase 3.2。`params_json` 盲拼被 `compat.thinking_format` 替代，JSON 拼接错误从根因消除 |
| `PLAN-FIX-3-SSE-GAPS.md` | → 并入 Phase 3.4（流式相位）和 Phase 3.2（stream_options） |

## 波及

| 文件 | 改动 |
|------|------|
| `src/types.zig` | 新增 `ModelCompat`、`ThinkingFormat`、`MaxTokensField`、`detectCompat()` |
| `src/config.zig` | TOML 解析 compat 字段；DEFAULT_TEMPLATE 更新 |
| `src/io/provider.zig` | `buildJsonBody` 根据 compat 构建；流式相位独立块化 |
| `src/frontends/cli/App.zig` | 无结构性改动（compat 在 Provider 内部消费） |

## 验证

```powershell
zig build
zig build test
# 回归测试：
.\z-agent-core.exe --model aliyun/qwen3.7-max        # Qwen 不闪烁 + thinking 保留
.\z-agent-core.exe --model deepseek/deepseek-v4-pro   # DeepSeek thinking 正常 + pro 不报 JSON 错误
.\z-agent-core.exe --model deepseek/deepseek-v4-flash # DeepSeek flash 正常
```
