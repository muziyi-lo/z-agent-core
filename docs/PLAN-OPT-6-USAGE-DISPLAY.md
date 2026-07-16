# Plan OPT-6: 用量数据显示增强

## 状态: 计划中

## 来源

- 社区/开发者反馈：用量显示不友好（原始数字 + 含义模糊的标签）
- DeepSeek KV 缓存功能已支持但未展示命中率

## 不做

| 项 | 理由 |
|----|------|
| 工具 schema 缓存排序（稳定化 prompt prefix） | 独立优化，非本计划范围 |
| 每步 prompt 前缀稳定性优化 | 已有 P1-5，与本计划正交 |
| 自动根据缓存命中率调整策略 | 高级功能，延后 |

## Core 层改动

### 1. TokenUsage 字段扩展

**`types.zig`** — 新增 2 字段：

```zig
pub const TokenUsage = struct {
    input: u32,
    output: u32,
    total: u32,
    cache_hit: ?u32 = null,
    cache_miss: ?u32 = null,
};
```

| 字段 | 来源 | 含义 |
|------|------|------|
| `input` | `prompt_tokens` | 本次请求的 prompt 端 token 数 |
| `output` | `completion_tokens` | 本次回复的 token 数 |
| `total` | `total_tokens` | input + output |
| `cache_hit` | `prompt_cache_hit_tokens` | prompt 中缓存命中的 token 数。`null` = API 未返回（非 DeepSeek 模型） |
| `cache_miss` | `prompt_cache_miss_tokens` | prompt 中缓存未命中的 token 数。`null` = API 未返回 |

### 2. SSE 解析

**`io/provider.zig`** — 在 `chatCompletionStreamingOnce` 的 `usage` 解析块中，**在现有 `usage = .{...}` 赋值之后**添加（用 `if (usage) |*u|` 守卫避免空指针）：

```zig
if (usage) |*u| {
    if (u_val.object.get("prompt_cache_hit_tokens")) |hit_val| {
        if (hit_val != .null) u.cache_hit = @intCast(hit_val.integer);
    }
    if (u_val.object.get("prompt_cache_miss_tokens")) |miss_val| {
        if (miss_val != .null) u.cache_miss = @intCast(miss_val.integer);
    }
}
```

### 3. JSONL 序列化

**`core/session.zig`**:

**写入** (`serializeMessage`) — 仅当 `cache_hit != null` 时才写入字段（含 `0`），`null` 省略：

```zig
if (u.cache_hit) |ch| {
    try buf.appendSlice(",\"cache_hit\":");
    var ch_buf: [16]u8 = undefined;
    const ch_s = try std.fmt.bufPrint(&ch_buf, "{d}", .{ch});
    try buf.appendSlice(ch_s);
}
```

**读取** (`load` usage 解析) — 安全读取，字段缺失 → `null`：

```zig
const cache_hit: ?u32 = if (u.get("cache_hit")) |ch|
    if (ch != .null) @as(?u32, @intCast(ch.integer)) else null
else null;
```

| 写入 | JSONL 内容 | 加载后 |
|------|-----------|--------|
| `cache_hit = null` | 字段省略 | `?u32 = null` |
| `cache_hit = 0` | `"cache_hit":0` | `?u32 = 0` |
| `cache_hit = 950` | `"cache_hit":950` | `?u32 = 950` |

## CLI 层改动

### 4. 显示格式

**`frontends/cli/App.zig`** — 单次和 REPL 模式的双处用量显示，替换为：

```
用量  输入 1.5K (命中 63%) | 输出 220t | 上下文 500t / 1M (0.05%)
```

**数据来源修正**：当前代码遍历所有消息累加 `total_tokens`，但 API 每轮的 `total_tokens` 已包含完整对话历史（非增量），累加得到的是无意义的重复计数。修正为：直接取最后一条带 `usage` 的消息的 `total_tokens` = 当前上下文实际占用。

**中断回合处理**：Ctrl+C 中断时 LLM 不发送 `[DONE]` 帧，`usage` 缺失。`last_usage` 回退到上一回合导致显示过期数据。修正：中断后不显示用量行（所有段数据不可靠）。`result.finish == .interrupted` → 跳过用量渲染。

**渲染规则**：

| 段 | 数据 | 计算 |
|----|------|------|
| `输入 1.5K` | `last_usage.input` | 动态单位（K/M），<1000 显示原始数字 |
| `(命中 63%)` | `last_usage.cache_hit` | 有值显示 `(命中 N%)`（包括 0%），`null` 显示 `(缓存 N/A)` |
| `输出 220t` | `last_usage.output` | 动态单位 |
| `上下文 500t / 1M` | `last_usage.total` / `context_window` | 最后一条带 usage 的消息的 total_tokens，非累加 |
| `(0.05%)` | 占比 | `total * 100 / context_window` |

**动态单位**：
- `< 1000` → 显示原始数字，如 `220t`
- `>= 1000 且 < 1_000_000` → `/ 1000` 保留 1 位小数 + `K`，如 `1.5K`
- `>= 1_000_000` → `/ 1_000_000` 保留 1 位小数 + `M`，如 `1.2M`

**formatToken** 辅助函数——写入调用方提供的栈缓冲区，零堆分配：

```zig
fn formatToken(n: u32, buf: []u8) ![]const u8 {
    if (n < 1000) return try std.fmt.bufPrint(buf, "{d}t", .{n});
    if (n < 1_000_000) {
        const k = @as(f32, @floatFromInt(n)) / 1000;
        return try std.fmt.bufPrint(buf, "{d:.1}K", .{k});
    }
    const m = @as(f32, @floatFromInt(n)) / 1_000_000;
    return try std.fmt.bufPrint(buf, "{d:.1}M", .{m});
}
```

调用方用 4 个 16 字节栈缓冲承载中间值，最终一次 `allocPrint` 生成显示标签：

```zig
var t1: [16]u8 = undefined;
var t2: [16]u8 = undefined;
// ...
const label = try std.fmt.allocPrint(allocator, "...", .{
    try formatToken(input, &t1),
    try formatToken(output, &t2),
    // ...
});
defer allocator.free(label);
```

## 验证

```powershell
zig build
zig build test
```

目标：不减少测试数。

## G7 对照表

| # | 方案中的调用 | 源码确认 | 匹配? |
|---|------------|---------|-------|
| 1 | `TokenUsage { input, output, total, cache_hit, cache_miss }` | `types.zig:17-21` 扩展 | ✅ |
| 2 | `parsed.object.get("usage")` → `prompt_cache_hit_tokens` | `io/provider.zig:271` SSE usage 解析 | ✅ |
| 3 | `std.fmt.allocPrint(allocator, "{d:.1}K", .{k})` | `zig/zig/lib/std/fmt.zig` 浮点格式 | ✅ |
| 4 | `@as(f32, @floatFromInt(n)) / 1000` | Zig 0.16 合法转换 | ✅ |
