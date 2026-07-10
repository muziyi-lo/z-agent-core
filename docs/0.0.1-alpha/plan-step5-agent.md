# Step 5: core/agent.zig — 单轮执行引擎

> 从 z-agent 提取 AgentLoop 核心，去除 TUI/CaptureWriter/ChunkQueue/compact/permission。V1 纯同步 runTurn 模型。

## A. 源码依据

| 源文件 | 用途 |
|--------|------|
| `projects/z-agent/src/agent.zig:305-415` | AgentLoop state machine + _processResponse 参考 |
| `projects/z-agent-core/src/io/provider.zig:68` | `chatCompletionStreaming()` 签名 |
| `projects/z-agent-core/src/tool/registry.zig:20` | `Registry.execute()` + `toTools()` 签名 |
| `projects/z-agent-core/src/core/session.zig` | `Session.append()` / `flush()` / `messages()` |
| `projects/z-agent-core/src/types.zig` | ProviderResponse / ToolContext / Message / ToolCall |
| `projects/z-agent-core/src/util/signal.zig` | `isInterrupted()` 原子标志 |

## B. 模块设计

### B1. z-agent 减法

| 减法 | z-agent (不迁移) | z-agent-core V1 (替代) |
|------|-----------------|----------------------|
| TUI 耦合 | CaptureWriter, ChunkQueue, worker_thread | 直接 `*std.Io.Writer` 写字节流 |
| 压缩 | compact.compact(), appendCompaction | 不实现 — V2 |
| 权限 | permission.Permission, trust | 不实现 — V2 |
| agent 模式 | agent_mode, result_marker | 不实现 — V2 |
| 异步 | worker_thread + streaming_response + queue | 纯同步调用 |
| 状态机 | `next()` 迭代器 + finished 标志 | 单次 `runTurn()` 调用 |

### B2. 数据结构

```zig
pub const AgentLoop = struct {
    allocator: std.mem.Allocator,        // 父分配器，用于 free 工具返回值
    io: std.Io,
    provider: *provider.Provider,
    registry: registry.Registry,
    session: *session.Session,
    max_tool_rounds: u32,
    project_root: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        provider_ref: *provider.Provider,
        registry_ref: registry.Registry,
        session_ref: *session.Session,
        max_tool_rounds: u32,
        project_root: []const u8,
    ) AgentLoop;
};
```

`allocator` 为父分配器（非 arena），用于构造 `ToolContext.allocator` 和释放工具返回值。turn 内临时分配使用内部 arena，不在 AgentLoop 中存储。

### B3. 核心流程 — runTurn()

```
runTurn(writer, phase_writer) → RoundResult:
   前提：用户输入已由 App.zig 在调用前 append 到 session
   1. 记录 session 当前消息数 → pre_count
   2. 创建内部 arena（临时内存，provider 响应 + toTools 用）
   3. registry.toTools(arena.allocator()) → tools[]
   4. tool_rounds = 0
   
   5. LOOP:
      a. 检查 signal.isInterrupted() → 返回 .interrupted（不 flush，不 append 任何消息）
      b. 检查 tool_rounds >= max_tool_rounds → 返回 .max_rounds（不 flush，App 层负责持久化）
      c. msgs = session.messages() — 完整历史（含 App 添加的用户消息）
      d. provider.chatCompletionStreaming(&arena, io, msgs, tools, phase_writer) → response
     e. 从 response 构造 assistant_msg，session.append(assistant_msg)
     f. 若 response.finish_reason == .stop → 返回 .stop（不 flush，App 层负责持久化）
     g. 若 response.finish_reason == .tool_calls:
        i.   构造 ToolContext{ .allocator = self.allocator, ... } — 用父分配器
        ii.  对每个 tool_call 执行 registry.execute(ctx, name, args)
        iii. 构造 tool_msg → session.append(tool_msg)
        iv.  self.allocator.free(result) — 父分配器释放
        v.   tool_rounds += 1
        vi.  继续 LOOP
     h. 其他 finish_reason → 返回 .stop（不 flush，App 层负责持久化）
```

**内存安全保证**：
- `session.append()` 对传入 Message 的所有切片字段做深度拷贝（dupe 到 session._arena），不借用外部内存。此行为已在 Step 4 实现中验证——ProviderResponse 的 arena 与 session 的 arena 完全独立，不存在悬垂风险
- `input` 消息由 App.zig 在调用 runTurn 前 append 到 session，agent 不负责用户消息的持久化决策

**工具内存契约**：`ToolContext.allocator` 必须设为 `self.allocator`（父分配器），不能是 arena。工具通过 ctx.allocator 分配返回值，agent 用同一个 allocator 释放。此约定已存在于所有现有工具实现中（`tool/{read,write,bash,grep,glob,skill}.zig` 均使用 `ctx.allocator`），agent 只需确保传入正确的 allocator。

### B4. 消息拼接

Agent 不拼接"输入"——用户消息由 App.zig 在调用前 append 到 session。Agent 只负责：

- **每轮 LLM 调用前**：调用 `session.messages()` 获取全部历史（含 App 添加的用户消息）
- **每次响应/工具结果**：`session.append()` 追加到 session

session 本身就是累加器，无需单独的临时数组。

### B5. 失败路径

| 场景 | 行为 |
|------|------|
| provider API 调用失败（已重试 3 次后仍失败） | 返回 `.api_error`（不 flush，App 层负责回滚与持久化） |
| 工具执行失败 | 工具返回错误字符串（由 `registry.execute` 捕获，不传播到 agent）。tool_msg 仍 append 到 session |
| Ctrl+C 中断 | 不 flush，返回 `.interrupted`。已部分写入 stdout 的内容为视觉残留，V1 接受 |
| max_tool_rounds 达到 | 返回 `.max_rounds`（不 flush，App 层负责持久化）。不注入"强制文本响应"（V2） |
| arena OOM | 传播 error.OutOfMemory，App 层处理——agent 不 flush（arena 已不可用） |

### B6. RoundResult 接口

```zig
pub const RoundResult = struct {
    new_message_count: usize,        // 本轮新增消息数
    finish: TurnFinish,
};

pub const TurnFinish = enum {
    stop,           // LLM 正常结束
    max_rounds,     // 超出工具轮次上限
    interrupted,    // Ctrl+C
    api_error,      // provider 调用失败
};
```

**内存安全**：不返回消息切片。`new_message_count` 是整数，调用方通过 `session.messages()[len - count ..]` 获取新增消息——数据归属 session._arena，生命周期由 session 保证，无悬垂风险。

TurnFinish 与 `types.FinishReason` 语义不同——前者是 turn 级别的控制流终止原因，后者是 LLM API 的逐次响应状态。两者不共享命名空间。

## C. 接口设计

### C1. AgentLoop.init()

```zig
pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    provider_ref: *provider.Provider,
    registry_ref: registry.Registry,
    session_ref: *session.Session,
    max_tool_rounds: u32,
    project_root: []const u8,
) AgentLoop
```

无失败路径——所有参数由调用方保证有效。

### C2. runTurn()

```zig
pub fn runTurn(
    self: *AgentLoop,
    writer: *std.Io.Writer,
    phase_writer: ?*anyopaque,        // Step 7 追加: PhaseWriter 指针，透传给 provider
) !RoundResult
```

- 用户输入已由 App.zig 在调用前 `session.append(user_msg)` — agent 不处理用户消息的持久化
- `writer`: LLM 流式输出目标（stdout writer），也用于工具标签输出（`render.writeLabeled`）
- `phase_writer`: 透传给 `provider.chatCompletionStreaming()` 的 PhaseWriter 指针（`?*anyopaque`），provider 内部转回 `*render.PhaseWriter` 做流式相位标注。V1 务实选择：通过 opaque 指针避免 agent 依赖 render 类型定义
- 返回：`RoundResult{ .new_message_count, .finish }`
- `new_message_count` 语义：agent 本轮追加到 session 的消息数。`.stop` — 完整，`.max_rounds`/`.api_error` — 部分完成（含已完成工具轮次），`.interrupted` — 可能为 0

调用方使用方式（App.zig）：
```zig
session.append(user_msg);
const pre_len = session.messages().len;
const result = try agent.runTurn(writer, &pw);
const new_msgs = session.messages()[pre_len..][0..result.new_message_count];
```

### C3. 依赖方向

```
types.zig           ← Message, ProviderResponse, ToolContext, ToolCall
    ↑
io/provider.zig     ← chatCompletionStreaming
    ↑  render/cli.zig   ← V1 务实：agent 调用 writeLabeled 输出工具标签
    ↑              ↑     phase_writer 通过 ?*anyopaque 透传，agent 不持有 PhaseWriter 类型
core/session.zig    ← append / flush / messages
    ↑
core/agent.zig      ← 不依赖 config / toml。V1 务实：import render/cli.zig 仅用于工具标签（writeLabeled）。
                     V2 应改为 App 层通过回调注入工具标签输出，消除此依赖。
```

## D. 新增/修改文件清单

| 文件 | 操作 | 内容 |
|------|------|------|
| `src/core/agent.zig` | 替换 stub | AgentLoop + init/runTurn (~200 行) |
| `src/types.zig` | 无需修改 | 已有所有需要类型 |

## E. 测试计划

| 测试 | 覆盖 |
|------|------|
| `agent: init stores fields` | init 后字段值正确 |
| `agent: runTurn stop` | 模拟 provider 返回 content → RoundResult.stop |
| `agent: runTurn tool_calls` | 模拟 provider 返回 tool_calls → 执行工具 → 再调 provider → stop |
| `agent: runTurn max_rounds` | tool_rounds 达到上限 → RoundResult.max_rounds |
| `agent: runTurn interrupted` | 工具执行前检查信号 → RoundResult.interrupted |
| `agent: runTurn api_error` | provider 返回错误 → RoundResult.api_error |
| `agent: runTurn appends to session` | agent 内部调用 session.append() |

> 注：需要 mock provider（注入测试 Provider 或函数指针）。V1 使用函数指针注入：AgentLoop 持有 `chatFn: *const fn(...)` 而非直接 import provider，测试时替换为 mock。

## F. G7 对照表：Zig 0.16 stdlib API 验证

| # | 方案中的调用 | 源码文件:行号 | 实际签名/声明 | 匹配? |
|---|------------|-------------|-------------|-------|
| 1 | `provider.chatCompletionStreaming(&arena, io, messages, tools, phase_writer)` | `io/provider.zig:74` | `fn chatCompletionStreaming(self: *Provider, arena: *ArenaAllocator, io: Io, messages: []const Message, tools: ?[]const Tool, phase_writer: ?*anyopaque) !ProviderResponse` | ✅ |
| 2 | `registry.execute(ctx, name, args_json)` | `tool/registry.zig:20` | `fn execute(self: Registry, ctx: ToolContext, name: []const u8, args_json: []const u8) anyerror![]const u8` | ✅ |
| 3 | `registry.toTools(allocator)` | `tool/registry.zig:29` | `fn toTools(self: Registry, allocator: Allocator) ![]Tool` | ✅ |
| 4 | `signal.isInterrupted()` | `util/signal.zig` | `fn isInterrupted() bool` | ✅ |
| 5 | `session.append(msg)` | `core/session.zig:114` | `fn append(self: *Session, msg: Message) !void` | ✅ |
| 6 | `session.flush()` | `core/session.zig:157` | `fn flush(self: *Session) !void` | ✅ |
| 7 | `session.messages()` | `core/session.zig:148` | `fn messages(self: *const Session) []const Message` | ✅ |
| 8 | `std.heap.ArenaAllocator.init(allocator)` | `ArenaAllocator.zig:46` | `fn init(child_allocator: Allocator) ArenaAllocator` | ✅ |
| 9 | `arena.allocator()` | `ArenaAllocator.zig:34` | `fn allocator(arena: *ArenaAllocator) Allocator` — needs `*` mutable | ✅ |
| 10 | `ProviderResponse` | `types.zig:58` | `{ content: ?[]const u8, tool_calls: ?[]ToolCall, finish_reason: FinishReason }` — 字段归 arena 所有 | ✅ |
| 11 | `ToolContext` | `types.zig:20` | `{ allocator, io, project_root, display_writer: *Io.Writer }` | ✅ |
| 12 | `ToolContext.allocator` 分配器契约 | `tool/*.zig` 全部 6 个工具 | 所有工具用 `ctx.allocator` 分配返回值，agent 必须传入父分配器（非 arena），`free` 用同一分配器 | ✅ |
| 13 | `Io.Clock.Timestamp.now(io, .real)` | `Io.zig:821` | 返回 `Clock.Timestamp{ .raw: Io.Timestamp, .clock: Clock }` | ✅ |
| 14 | `Io.Writer.Interface.of(.stderr())` | `Io.zig` | 用于构造 display_writer（工具确认消息） | ✅ |

## G. 预估行数

| 文件 | 行数 |
|------|------|
| `src/core/agent.zig` | ~200 (实现) + ~200 (测试) = ~400 |
| **合计** | ~400 |
