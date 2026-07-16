# Plan PHASE-4: Cache-First 循环 + 上下文优化

## 状态: 计划中

## 问题

**现象**：多回合对话中 token 用量线性增长，缓存命中率低。DeepSeek 自动缓存（prefix cache）无法有效工作。

**根因**：两个设计和两个实现缺陷叠加——
1. P1-5 每回合重建 system prompt，破坏消息前缀的字节稳定性
2. reasoning_content 无条件回传（混在 content_buf 中），纯文本回合也携带推理文本
3. Message 结构将推理和回复混在一个字段，无法区分

## 概览

- **参考**：对比 Reasonix 的 cache-first 循环设计，确认了消息前缀稳定性 + reasoning_content 选择性回传两条优化路径
- **改动范围**：5 层（types → provider(SSE) → session → agent → provider(buildJsonBody)）
- **方案思路**：将 Message 结构中的 reasoning 从 content 中分离为独立字段；序列化时仅 tool-call 回合 + DeepSeek compat 才回传；system prompt 仅在环境变化时重建

## 设计要点

### 1. Message 结构分离

当前 Message 将所有文本（思考 + 回复）存在 `content` 字段中。需要新增独立的 `reasoning_content` 字段：

| 字段 | 当前 | 目标 |
|------|------|------|
| `content` | 包含 reasoning + 回复文本 | 仅回复文本 |
| `reasoning_content` | 不存在 | 仅思考文本（可选，null） |
| `tool_calls` | null 或 tool calls 数组 | 不变 |

分离后，序列化逻辑可以独立控制 reasoning_content 是否回传。纯文本回合跳过 reasoning，tool-call 回合（DeepSeek compat）必须携带。

### 2. 上下文组装和缓存策略

DeepSeek 的自动缓存基于字节级前缀匹配。关键在于消息数组的前几个元素（system + 前几轮消息）是否每次请求都相同：

```
当前 (P1-5 每回合重建):
system: "You are...\n<env>\nWorking directory: C:\Test\nPlatform: windows\nToday's date: 2026-07-16\n</env>"
  ↑ 日期和 cwd 每回合变 → 前缀不稳定 → 缓存断裂

目标 (环境变化时重建):
system: "You are...\n<env>\nWorking directory: C:\Test\nPlatform: windows\n</env>"
  ↑ 移除日期字段，cwd 仅启动时设置一次 → 前缀稳定
```

同时，P1-5 的 `SystemPromptCb` 改为仅在 `_env_changed` 标志为真时重建（如 `/new` 后、手动切换目录后）。

### 3. reasoning_content 选择性回传

只在 DeepSeek compat 模式下生效。其他 provider 始终跳过：

| 回合类型 | DeepSeek compat | 其他 provider |
|----------|----------------|---------------|
| assistant + tool_calls | ✅ 回传 reasoning_content | 跳过 |
| assistant 纯文本 | 跳过 | 跳过 |
| user / tool / system | 不适用 | 不适用 |

## 实施

### 步骤 1: Message 结构扩展

**文件**: `src/types.zig`
**改动**: `Message` 新增 `reasoning_content: ?[]const u8 = null`

### 步骤 2: SSE 解析分离累积

**文件**: `src/io/provider.zig`
**改动**: 流式解析时，reasoning 文本累积到独立的 `reasoning_buf`，不混入 `content_buf`。`ProviderResponse` 新增 `reasoning_content: ?[]const u8` 字段

### 步骤 3: Session 存储更新

**文件**: `src/core/session.zig`
**改动**: `serializeMessage` / 反序列化中增加 `reasoning_content` 字段的 JSONL 读写

### 步骤 4: buildJsonBody 条件回传

**文件**: `src/io/provider.zig`
**改动**: 在构建 messages 数组时，仅当 `compat.thinking_format == .deepseek` 且消息有 `tool_calls` 时，回传 `reasoning_content`

### 步骤 5: system prompt 按需重建

**文件**: `src/core/agent.zig`、`src/frontends/cli/App.zig`
**改动**: `SystemPromptCb` 增加 `_env_changed` 检查；非环境变化时跳过重建

## 验证

```powershell
zig build
zig build test
```

| 测试场景 | 预期结果 |
|----------|----------|
| DeepSeek V4 Flash 多回合对话 | 第 2 回合起缓存命中率 > 80% |
| DeepSeek V4 Pro tool-call 回合 | reasoning_content 回传，不报 400 |
| 纯文本回合 | reasoning_content 不回传，prompt_tokens 明显减少 |
| Qwen / 非 DeepSeek | 不受影响，reasoning_content 始终不回传 |

## 波及

| 文件 | 改动 | 破坏性 |
|------|------|--------|
| `src/types.zig` | Message 新增 `reasoning_content` 字段 | 否（新字段可选） |
| `src/io/provider.zig` | SSE 解析分离 + buildJsonBody 条件回传 | 否 |
| `src/core/session.zig` | JSONL 序列化新字段 | 否 |
| `src/core/agent.zig` | SystemPromptCb 按需重建 | 否 |
| `src/frontends/cli/App.zig` | system prompt 移除日期字段 | 否 |

## 术语

| 术语 | 含义 |
|------|------|
| reasoning_content | DeepSeek API 的思考文本，在 assistant 消息中作为独立字段返回 |
| 选择性回传 | 仅在 tool-call 回合 + DeepSeek compat 时才将 reasoning_content 发送给 API |
| 缓存前缀稳定性 | 消息数组的前几个元素每回合保持一致，让 DeepSeek 自动缓存命中 |
| append-only history | Reasonix 的核心理念——只追加消息不修改已有消息，保持前缀字节不变 |
