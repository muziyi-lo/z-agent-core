# Plan FIX-3: SSE 流处理与 Pi 对比缺口

## 状态: 计划中

## 来源

对比 Pi (`openai-completions.ts`) 与 z-agent-core (`provider.zig`) 的 SSE delta 处理，发现 4 项缺口。

## 结构映射

| Pi (`openai-completions.ts:207-343`) | z-agent-core (`provider.zig:304-325`) | 差异 |
|------|------|------|
| `ensureTextBlock()` + `ensureThinkingBlock()` 双独立块 | `PhaseWriter.beginPhase()` 单相位切换 | **⚠️ 分叉** — 并行累积 vs 互斥切换 |
| content/reasoning 独立 `if` 块处理 | reasoning → content 顺序处理，共享 PhaseWriter | **⚠️ 分叉** — 无状态冲突 vs 共享状态 |
| `stream_options: { include_usage: true }` | 无 | **❌ 缺失** |
| `retry-after-ms` / `retry-after` 头解析 | isRetryableBody 简单关键词 | **⚠️ 分叉** |
| `sleep` 支持 AbortSignal 取消 | kernel32.Sleep 阻塞不可取消 | **⚠️ 分叉** |

## 路径推演：Qwen 同 delta 双字段

### Pi 行为 (line 207-343)

```
delta = {reasoning_content: "I should...", content: "Hello!"}
  → ensureTextBlock() 不存在 → create → push text_start
  → text += "Hello!" → push text_delta
  → ensureThinkingBlock() 不存在 → create → push thinking_start
  → thinking += "I should..." → push thinking_delta
  // thinking 和 text 作为独立块并存于 output.content[]
  // 后续 deltas 继续追加对应块，不会发生任何切换
```

### 当前行为

```
delta = {reasoning_content: "I should...", content: "Hello!"}
  → begin_phase(.thinking) → phase = .thinking
  → content_buf += "I should..."
  → begin_phase(.content) → phase = .content (切换，thinking 关闭)
  → content_buf += "Hello!"
  // 下个 delta 同理 → 每 chunk 触发切换 → 闪烁
```

## 影响

| # | 诊断 | 描述 | 症状 |
|---|------|------|------|
| 1 | ⚠️ 分叉 | PhaseWriter 单状态 vs Pi 双独立块 | Qwen 闪烁 + 思考丢失（两次修复的根因） |
| 2 | ❌ 缺失 | 无 `stream_options: include_usage` | 部分 provider 不返回 usage 数据 |
| 3 | ⚠️ 分叉 | 不尊重 `retry-after` 头 | 重试时机不准确 |
| 4 | ⚠️ 分叉 | `sleep` 无取消支持 | 中断后重试延迟不可取消 |

## 修复方案

### P0: PhaseWriter 块化 (解决 #1)

**`io/provider.zig`** — 将 PhaseWriter 的单相位模型改为 Pi 风格的独立块跟踪：

- `thinking_started: bool` — 思考块是否已开始
- `text_started: bool` — 文本块是否已开始
- 两个块独立跟踪，不互斥

```zig
var thinking_started = false;
var text_started = false;

// reasoning — 独立于 content
if (delta.get("reasoning_content")) |r_val| {
    if (r_val != .null) {
        const r = r_val.string;
        if (r.len > 0) {
            if (!thinking_started) {
                thinking_started = true;
                if (pw) |p| p.begin_phase(p.context, .thinking);
            }
            try content_buf.appendSlice(alloc, r);
            if (pw) |p| p.write_raw(p.context, r);
        }
    }
}

// content — 独立于 reasoning
if (delta.get("content")) |c_val| {
    if (c_val != .null) {
        const c = c_val.string;
        if (!text_started) {
            text_started = true;
            if (pw) |p| p.begin_phase(p.context, .content);
        }
        try content_buf.appendSlice(alloc, c);
        if (pw) |p| p.write_raw(p.context, c);
    }
}
```

**关键差异**：两个 `if` 块独立，不共享 `in_content_phase` 锁。`thinking_started` 和 `text_started` 各自跟踪，互不干扰。Pi 在同一个 delta 中可以同时发送 `text_start` 和 `thinking_start` ——这就是 Qwen 场景。

### P1: stream_options (解决 #2)

**`io/provider.zig` buildJsonBody** — 添加 `stream_options`：

```zig
if (stream) {
    try buf.appendSlice(alloc, ",\"stream\":true");
    try buf.appendSlice(alloc, ",\"stream_options\":{\"include_usage\":true}");
}
```

### P2: retry-after (解决 #3, #4)

延后——当前简单重试已够用。

## 波及

| 文件 | 改动 |
|------|------|
| `src/io/provider.zig` | PhaseWriter 块化 + stream_options |
| `src/frontends/cli/render.zig` | 可能需要适配流关闭逻辑（`closeOpenBlocks`） |

## 验证

```powershell
zig build
zig build test
.\z-agent-core.exe --model deepseek/deepseek-v4-flash   # DeepSeek: thinking 正常
.\z-agent-core.exe --model aliyun/qwen3.7-max            # Qwen: 不闪烁 + 思考保留
```
