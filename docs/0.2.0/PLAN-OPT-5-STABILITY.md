# Plan OPT-5: 运行时稳定性

## 状态: 已完成 (2026-07-16)

## 前置依赖

| 阻塞者 | 状态 | 被阻塞 |
|--------|------|--------|
| OPT-3 (ToolMeta) | ✅ 已完成 | OPT-4、TUI/Web |
| — | — | OPT-5 独立于 OPT-4，两者无交叉依赖 |

OPT-4 与 OPT-5 可并行推进（OPT-4 改会话管理，OPT-5 改运行时逻辑，不同模块）。

## 来源

与 opencode agent 实现对比发现的健壮性差距。

## 不做

| 项 | 理由 |
|----|------|
| 多模型提示模板（7 套 variant） | 仅针对 DeepSeek，不需要 |
| 自动标题生成 | 体验优化，非健壮性 |
| 流式事件系统（15+ event types） | 架构级重构，延后到新前端 |
| SQLite 会话存储 | JSONL 工作良好，单用户无需数据库 |
| Effect 并发框架 | Zig 同步模型匹配 CLI 定位 |

## P0: 阻断级（无此必崩）

### 1. 上下文压缩

**问题**：消息无上限增长，终将超过 DeepSeek 131K token 窗口，API 返回错误且用户无感知。

**opencode 方案**（三段式）：
- `isOverflow()`：累计 token > 可用窗口 - 预留缓冲 → 触发压缩
- `process()`：LLM 摘要旧消息，保留最近 N 轮原文
- `prune()`：标记旧工具输出为已压缩，释放空间

**z-agent-core 方案**：
- 已有 `TokenUsage` 数据，需做累计统计
- `runTurn` 入口处检查累计 token 是否超阈值
- 超阈值时插入系统消息提示 LLM 自行调用 `compact` 工具（或自动摘要）
- `compact` 工具（Phase 2F）用 API 端点生成摘要替换旧消息

| 文件 | 改动 |
|------|------|
| `core/agent.zig` | `runTurn` 入口累计 token 检查 |
| `tool/compact.zig` | 实现摘要压缩工具（已有设计，PHASE2 2F） |
| `core/session.zig` | 消息替换方法（已有 API） |

### 2. API 重试与退避

**问题**：DeepSeek API 返回 429/503 时直接报 `api_error`，下一轮继续输入全新请求。

**当前**：
```zig
const resp = raw_resp catch |err| {
    return finishTurn(self, new_msgs, .api_error, @errorName(err));
};
// → 用户看到 "ERROR APIRateLimitExceeded"，需手动重新输入
```

**实施后**：
```zig
var retries: u8 = 0;
while (retries < 5) : (retries += 1) {
    const resp = raw_resp catch |err| {
        if (!isRetryable(err)) return finishTurn(...);
        phase_writer.writeStatus("Retrying ({d}/5)...", .{retries + 1});
        std.time.sleep(backoffMs(retries) * std.time.ns_per_ms);
        continue;
    };
    break;
}
// → 自动重试 5 次，用户看到 "Retrying (2/5)..." 后成功或最终失败
```

**问题**：DeepSeek API 返回 429/503 时直接报 `api_error`，下一轮继续输入全新请求。没有指数退避、没有 `retry-after` 尊重、没有状态显示。

**opencode 方案**（`SessionRetry.policy`）：
- 错误分类：可重试（5xx、429、超时）vs 致命（4xx、content filter）
- 指数退避，尊重 HTTP `retry-after-ms`/`retry-after` 头
- 最大重试次数 + 总超时
- 重试期间状态更新（"Retrying..."）

**z-agent-core 方案**：
- `provider.zig` 中 curl 调用处加入重试逻辑
- 退避策略：500ms → 1s → 2s → 4s → 8s（最多 5 次）
- 超时分类：`connect_timeout` / `max_timeout`（已有配置）
- 重试期间 PhaseWriter 输出提示

| 文件 | 改动 |
|------|------|
| `io/provider.zig` | 重试循环 + 退避 + HTTP 错误分类 |
| `core/agent.zig` | `runTurn` 调用层处理重试后的最终失败 |

## P1: 重要（提升可靠性）

### 3. 死循环检测

**问题**：LLM 可能连续用相同参数调用同一工具（如"读 .exe 找源码"），用户只能等 max_rounds 耗尽。

**opencode 方案**（`StormBreaker`）：
- 跟踪最近 N 次工具调用（name + args hash）
- 连续 3 次相同 → 追加系统消息："可能陷入循环，请调整策略"
- 可配置阈值

**z-agent-core 方案**：
- `runTurn` 中维护 FIFO 队列（容量 5）
- 每次工具调用前检查历史
- 命中阈值时追加 system message

| 文件 | 改动 |
|------|------|
| `core/agent.zig` | FIFO 队列 + 检测逻辑 |

### 4. 工具上下文增强

**问题**：`ToolContext` 只有 5 个字段，工具无法访问消息历史、无法更新自身状态。

**opencode 对应**：`ctx.messages`（全量历史）、`ctx.metadata()`（自更新状态）、`ctx.ask()`（权限询问）、`ctx.abort`（标准 AbortSignal）。

**z-agent-core 方案**：
- `ToolContext` 新增 `messages: ?[]const types.Message` 引用（非拥有）
- `ToolContext` 新增 `session_ref: ?*Session`（内部工具用）
- 已有 `api_endpoint`（LLM 访问）、`abort_target`（中断信号）

| 文件 | 改动 |
|------|------|
| `types.zig` | `ToolContext` 新增 `messages` + `session_ref` |
| `core/agent.zig` | 创建 ToolContext 时填充新字段 |

### 5. 每步重组系统提示

**问题**：系统提示在 `init` 时构建一次，会话中技能加载/环境变化不反映。

**opencode 方案**：每步重组——`env + instructions + skills + mcp` 四源并行组合。

**z-agent-core 方案**：
- `buildSystemPrompt` 从 App.init 移到 AgentLoop.runTurn
- 每次 turn 构建（或仅在环境变化时重建）
- 技能列表动态注入（OPT-4 已规划）

| 文件 | 改动 |
|------|------|
| `core/agent.zig` | `runTurn` 入口调用 `buildSystemPrompt` |
| `frontends/cli/App.zig` | 移除 init 中的一次性构建 |

## 实施顺序

```
P0-2 (API 重试)  ← 独立，最快见效
    ↓
P0-1 (上下文压缩)  ← 依赖 compact 工具设计
    ↓
P1-3 (死循环) → P1-4 (工具上下文) → P1-5 (每步重组)
```

## 验证

```powershell
zig build
zig build test
```

## G7 对照表：Zig 0.16 stdlib API 验证

| # | 方案中的调用 | 源码文件:行号 | 实际签名 | 匹配? |
|---|------------|-------------|---------|-------|
| 1 | `session.messages()` | `core/session.zig:183` | `pub fn messages(self: *const Session) []const types.Message` | ✅ |
| 2 | `session.append(msg)` | `core/session.zig:151` | `pub fn append(self: *Session, msg: types.Message) !void` — arena 自动 dupe | ✅ |
| 3 | `session.truncateTo(keep)` | `core/session.zig:193` | `pub fn truncateTo(self: *Session, keep: usize) void` | ✅ |
| 4 | `registry.toTools(allocator)` | `tool/registry.zig:44` | `pub fn toTools(self: Registry, allocator: std.mem.Allocator) ![]types.Tool` | ✅ |
| 5 | `TokenUsage { input, output, total }` | `types.zig:17-21` | 三个 `u32` 字段 | ✅ |
| 6 | `ToolContext { allocator, io, project_root, api_endpoint, abort_target }` | `types.zig:40-49` | 5 个字段 + 3 个新增 (`messages`, `session_ref`, `provider_ref`) | ✅ |
| 7 | `ApiEndpoint { base_url, api_key, model }` | `types.zig:24-28` | 三个 `[]const u8` 字段 | ✅ |
| 8 | `provider.chatCompletionStreaming(&arena, io, msgs, tools)` | `io/provider.zig:60` | `pub fn chatCompletionStreaming(self: *Provider, arena: *ArenaAllocator, io: Io, msgs: []const types.Message, tools: ?[]const types.Tool) anyerror!ProviderResponse` | ✅ |

目标：不减少测试数。
