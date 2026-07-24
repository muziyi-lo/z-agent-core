# Plan REF-1: PhaseWriterCb per-call 化 — 消除共享 context 字段

## 状态: 已完成

## 前置依赖

| 阻塞者 | 状态 | 被阻塞 |
|--------|------|--------|
| PHASE-7 Web MVP | ✅ 已完成 | 本方案 |
| 无 | — | **PLAN-REF-2** (init.zig 抽取) |

## 问题

**现象**：`provider.phase_writer.context` 是共享可变字段。CLI 每轮 turn 前需手动 `@ptrCast` 覆盖，Web 后续加并发时存在 data race（见 REF-2 风险表已删条目）。

**根因**：`PhaseWriterCb` 设计为"函数指针 + 外部注入 context"，而非"函数 + 自带 context"。`begin_phase(ctx, phase)` 的 context 来自 `PhaseWriterCb.context` 字段，而非调用时传入。

## 概览

- **改动范围**：~3 个文件修改（provider.zig 内部 + agent.zig + CLI App.zig），无新增文件
- **核心思路**：`PhaseWriterCb` 改为与 `ToolDisplayCb` 一致的调用模式——回调函数签名自带 context 参数，`agent.runTurn()` 传入 `PhaseWriterCb`（而非从 provider 字段读取）。provider 不再持有 `phase_writer` 字段。
- **附带收益**：消除并发风险、简化 init.zig（REF-2 `FrontendState.provider` 变为不可变）、移除 CLI App.zig 的 per-turn context swap 代码

## 设计要点

### 1. PhaseWriterCb 调用模式对齐 ToolDisplayCb

当前：
```zig
// provider.zig — 从共享字段读取
const pw = self.phase_writer;
if (pw) |p| p.begin_phase(p.context, .thinking);  // context 来自字段
```

改造后：
```zig
// agent.zig runTurn() — 作为参数传入
pub fn runTurn(self: *AgentLoop, tool_display: ?ToolDisplayCb, phase_writer: ?PhaseWriterCb) !RoundResult {
    // ...
    if (phase_writer) |pw| pw.begin_phase(pw.context, .thinking);
}
```

`PhaseWriterCb` 在调用点传入，provider 内部不再持有引用。

### 2. Provider 简化

移除 `Provider.phase_writer` 字段：

```zig
// 删除
phase_writer: ?PhaseWriterCb = null,

// Provider.init 移除 phase_writer 参数
pub fn init(allocator, entry, model, vendor_override, io) !Provider {
    // 不再存储 phase_writer
}
```

provider 需要输出 phase 事件时，改为通过返回值/out 参数通知调用方，或改为纯函数——由 `agent.runTurn()` 在调用 provider 的 SSE 流解析时传入 `PhaseWriterCb`。

### 3. 数据流路径

```
agent.runTurn(tool_cb, phase_cb)
    │
    ├─→ 调用 LLM (provider.callWithRetry)
    │       └─→ SSE 解析 → phase_cb.begin_phase(ctx, .thinking)
    │                      → phase_cb.write_raw(ctx, bytes)
    │
    ├─→ 工具执行 → tool_cb.render(ctx, ...)
    │
    └─→ 返回 RoundResult
```

`phase_cb` 和 `tool_cb` 来自调用方栈帧，生命周期匹配 turn 持续时间。

### 4. 对 CLI App.zig 的影响

移除 per-turn context swap（App.zig:237-240）：

```zig
// 删除
if (self.provider.phase_writer) |*cb| {
    cb.context = @ptrCast(@alignCast(&wc));
}
// 改为
const phase_cb = provider_mod.PhaseWriterCb{
    .context = @ptrCast(@alignCast(&wc)),
    .begin_phase = pwBeginPhase,
    // ...
};
const result = self.agent.runTurn(tool_cb, phase_cb) catch ...;
```

### 5. 对 Web 前端的影响

SSE handler 无需修改 provider 共享状态：

```zig
// 当前 (有 data race 风险)
if (ctx.provider.phase_writer) |*pw| {
    pw.context = @ptrCast(@alignCast(&sse_state));
}

// 改造后
const phase_cb = sse.createPhaseWriter(&sse_state);
ctx.agent.runTurn(tool_cb, phase_cb) catch ...;
```

### 6. 与 REF-2 的衔接

REF-2 的 `init.zig` 不再需要关心 `phase_writer` 的传递——provider 无此字段。`FrontendState.provider` 变为不可变共享数据，并发风险自然消除。

## 实施

### 步骤 1: 修改 `agent.zig` — runTurn 签名扩展

**文件**: `src/core/agent.zig`
**改动**: `runTurn` 新增 `phase_writer: ?PhaseWriterCb` 参数，透传给 provider 的 `callWithRetry/call`。

### 步骤 2: 修改 `provider.zig` — 移除 phase_writer 字段

**文件**: `src/io/provider.zig`
**改动**: 
- 移除 `Provider.phase_writer` 字段
- `Provider.init` 移除 `phase_writer` 参数
- `callWithRetry/call` 新增 `phase_writer: ?PhaseWriterCb` 参数

### 步骤 3: 修改 `App.zig` — 移除 context swap

**文件**: `src/frontends/cli/App.zig`
**改动**: `singleTurn/processLine` 中移除 per-turn context 覆盖，改为每次创建 `PhaseWriterCb` 并传入 `runTurn`。

### 步骤 4: 修改 `server.zig` — 移除 webPhaseWriterCb 注入

**文件**: `src/frontends/web/server.zig`
**改动**: `Provider.init` 调用移除 `sse.webPhaseWriterCb()` 参数。

### 步骤 5: 更新测试

- provider 测试中移除 `phase_writer` 相关测试
- agent mock chatter 适配新签名
- SSE 测试适配（`webPhaseWriterCb` 可能不再需要）

## 验证

```powershell
zig build
zig test src/test.zig --cache-dir .zig-cache
```

| 测试场景 | 预期结果 |
|----------|----------|
| CLI `单次模式` — thinking 正常显示 | 思考内容流式输出不变 |
| CLI REPL — 多轮 turn 无状态泄漏 | 每轮 context 独立，不相互干扰 |
| Web SSE — 无 provider 共享状态 | 每个 handler 独立创建 PhaseWriterCb |
| agent 所有现有测试 | 全部通过（适配新签名后） |

## 风险

| 风险 | 概率 | 缓解 |
|------|------|------|
| agent 测试中的 mockChatFn 需适配新签名 | 确定 | 一次性批量更新 ~15 个测试的 mock 函数 |
| provider 内部 retry 状态消息写 phase_writer | 低 | retry 逻辑中 `write_rendered` 调用需随 PhaseWriterCb 参数透传 |

## 波及

| 文件 | 改动 | 破坏性? |
|------|------|----------|
| `src/core/agent.zig` | `runTurn` 签名加参数 | 是——所有调用方需更新 |
| `src/io/provider.zig` | 移除 `phase_writer` 字段，`init/callWithRetry` 参数变更 | 是——测试需适配 |
| `src/frontends/cli/App.zig` | 移除 context swap，改为 per-turn 创建 PhaseWriterCb | 否 |
| `src/frontends/web/server.zig` | `Provider.init` 移除 phase_writer 参数 | 否 |
| `src/frontends/web/sse.zig` | `webPhaseWriterCb()` 可能移除 | 否 |

## 术语

| 术语 | 含义 |
|------|------|
| per-call context | 每次回调调用时传入 ctx 参数，而非从共享字段读取 |
| context swap | CLI 当前的 `provider.phase_writer.context = &wc` 逐轮覆盖模式 |
