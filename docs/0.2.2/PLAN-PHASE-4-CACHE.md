# Plan PHASE-4: Cache-First 循环 + 上下文优化

## 状态: 已完成 (v0.2.2)

## 问题

**现象**：多回合对话中 token 用量线性增长，缓存命中率低。DeepSeek 自动缓存（prefix cache）无法有效工作。

**根因**：两个设计和两个实现缺陷叠加——
1. `App.zig:159` 的 `SystemPromptCb` 每回合调用 `spRebuild()`，导致 system prompt 每回合重建（`App.zig:650-655` → `buildPromptString()` 插入当前日期和 CWD → `session.updateFirstSystem()` 每次都是不同的字符串）
2. reasoning_content 无条件混入 `content_buf`（`provider.zig:311`），在 `agent.zig:225` 存入 Message 的 `content` 字段，作为普通文本回传给下一回合
3. Message 结构将推理和回复混在一个 `content` 字段，无法区分

**当前 system prompt 构建** (`App.zig:677-687`):
```zig
const prompt = try std.fmt.allocPrint(allocator,
    \\{s}
    \\
    \\<env>
    \\  Working directory: {s}
    \\  Workspace root: {s}
    \\  Platform: {s}
    \\  Today's date: {s}
    \\</env>
, .{ effective_prompt, cwd, project_root, os_tag, date });
```

每次调用 `spRebuild()` 都会获取新的 CWD 和日期，产生不同的 system prompt 字符串 → DeepSeek 前缀缓存断裂。

**当前 reasoning_content 混入** (`provider.zig:300-311`):
```zig
if (delta.get("reasoning_content")) |r_val| {
    if (r_val != .null) {
        const r = r_val.string;
        if (r.len > 0) {
            if (!in_content_phase) { ... }
            try content_buf.appendSlice(alloc, r);  // ← 混入 content_buf
            ...
        }
    }
}
```

## 概览

- **参考**：对比 Reasonix 的 cache-first 循环设计，确认了消息前缀稳定性 + reasoning_content 选择性回传两条优化路径
- **改动范围**：5 层（types → provider(SSE) → session → agent → provider(buildJsonBody) → App）
- **方案思路**：将 Message 结构中的 reasoning 从 content 中分离为独立字段；序列化时仅 tool-call 回合 + DeepSeek compat 才回传；system prompt 仅在环境变化时重建

- **对比 OpenCode**：详见 `docs/session-context-management-opencode.md`。核心借鉴：
  - ReasoningPart 作为一等字段 + start/delta/end 事件模型
  - 选择性回传规则（同模型原样，不同模型转文本，DeepSeek 强制携带）
  - 无标记前缀缓存（DeepSeek 只需消息前缀稳定，无需 cache_control 标记）
  - 上下文溢出 → LLM 总结压缩（而非粗暴截断）

## 设计要点

### 1. Message 结构分离

当前 `types.zig:6-14`:
```zig
pub const Message = struct {
    role: Role,
    content: []const u8,    // ← 混合了 reasoning + 回复文本
    tool_calls: ?[]const ToolCall = null,
    tool_call_id: ?[]const u8 = null,
    timestamp: i64 = 0,
    model: ?[]const u8 = null,
    usage: ?TokenUsage = null,
};
```

目标：
```zig
pub const Message = struct {
    role: Role,
    content: []const u8,                // 仅回复文本（保持兼容）
    reasoning_content: ?[]const u8 = null,  // 仅思考文本（NEW）
    tool_calls: ?[]const ToolCall = null,
    tool_call_id: ?[]const u8 = null,
    timestamp: i64 = 0,
    model: ?[]const u8 = null,
    usage: ?TokenUsage = null,
};
```

分离后，序列化逻辑可以独立控制 `reasoning_content` 是否回传。纯文本回合跳过 reasoning，tool-call 回合（DeepSeek compat）必须携带。

### 2. 上下文组装和缓存策略

DeepSeek 的自动缓存基于字节级前缀匹配。关键在于消息数组的前几个元素（system + 前几轮消息）是否每次请求都相同：

```
当前 (每回合重建 system prompt):
system: "You are z-agent-core...\n<env>\nWorking directory: C:\Test\nPlatform: windows\nToday's date: 2026-07-16\n</env>"
  ↑ CWD 和日期每回合变 → 前缀不稳定 → 缓存断裂

目标 (环境变化时重建, 无日期):
system: "You are z-agent-core...\n<env>\nWorking directory: C:\Test\nPlatform: windows\n</env>"
  ↑ 移除日期字段，CWD 仅启动时/显式切换时更新 → 前缀稳定
```

### 3. reasoning_content 选择性回传

只在 DeepSeek compat 模式下生效。其他 provider 始终跳过：

| 回合类型 | DeepSeek compat | 其他 provider |
|----------|----------------|---------------|
| assistant + tool_calls | 回传 reasoning_content | 跳过 |
| assistant 纯文本 | 跳过 | 跳过 |
| user / tool / system | 不适用 | 不适用 |

**判断逻辑**：`compat.thinking_format == .thinking_object` （DeepSeek）且消息 `.tool_calls != null`。

### 4. append-only 原则

Reasonix 核心设计：只追加消息不修改已有消息，保持前缀字节不变。当前 `agent.zig:183` 在 max_rounds 和 `agent.zig:198` 在 context_warning 时追加 system 消息——这些消息插入位置会影响前缀但影响可接受（DeepSeek cache 以 message array 前缀匹配，追加在末尾不影响）。

但 `session.updateFirstSystem()`（`session.zig:209`）修改了第一条消息的内容——这正是缓存断裂的主要来源。

### 5. 上下文溢出 → 结构化压缩

当前 `agent.zig` 仅在 85% 窗口阈值时注入 system warning（`StormBreaker`），不做实际压缩。PHASE-4 将其升级为完整的压缩管线：

#### 触发条件
- 每回合结束后检查 token 占用 > usable（`model.context_window - reserved`）
- reserved = max(model.max_tokens, buffer) — buffer 默认 20000

#### 压缩流程
1. **选择 head/tail**：保留最近 2 轮完整对话（tail），其余作为 head 送去压缩
2. **构建总结提示**：调用 LLM 将 head 消息总结为结构化 JSON
3. **注入总结**：将总结作为系统消息插入，前面加 `"Context from earlier in conversation (auto-compacted):"`
4. **继续对话**：tail 消息保持不变

#### 总结结构（借鉴 OpenCode compaction.ts）
```json
{
  "goal": "用户的目标",
  "constraints_progress": "约束与进展",
  "key_decisions": ["关键决策"],
  "next_steps": ["下一步"],
  "critical_context": "不可丢失的上下文",
  "relevant_files": ["涉及的路径"]
}
```

#### 常规定义
```zig
const COMPACTION_RESERVED: u32 = 20000;      // buffer tokens
const COMPACTION_TAIL_TURNS: usize = 2;       // preserve last N turns  
const COMPACTION_MIN_SAVE: u32 = 2000;        // minimum token savings to trigger
```

### 6. 工具输出轻量修剪

比压缩更轻量的优化：将旧工具调用的输出截断至 2000 字符。

```
条件: 至少节省 20000 tokens 才触发
保护: 最近 40000 tokens 的工具调用不修剪
特殊: "skill" 工具的输出始终保护
```

### 7. 跨模型 reasoning 转文本

切换模型时（如 DeepSeek → OpenAI），reasoning_content 不能直接回传（格式不兼容）：

| 场景 | 处理 |
|------|------|
| 同 provider + 同模型 | reasoning 原样回传 |
| 同 provider + 不同模型 | reasoning 原样回传（API 自行忽略或接受） |
| 不同 provider | reasoning 转为纯文本追加到 content 末尾（格式: `[已经过思考: ...]`） |

`buildJsonBody` 中在序列化消息前判断：`msg.model != self.config.model` → 合并 reasoning 到 content。

### 8. Session 回放渲染管线

PHASE-3 中 `/load` 用 `render.writeLabeled` 直接输出纯文本。reasoning_content 独立后，回放可走完整管线：

```zig
// /load 回放每条 assistant 消息:
if (msg.reasoning_content) |rc| {
    pw.begin_phase(.thinking);
    pw.write_raw(rc);        // 思考文本（灰色/斜体）
}
pw.begin_phase(.content);
for (renderLine chunks of msg.content) |line| {
    pw.write_rendered(line); // Markdown→ANSI 渲染
}
pw.end_phase();
```

回放后的会话可直接继续交互。

---

## 实施

实施分七步。从数据层（types）开始，经过存储层（session）和传输层（provider），再到业务层（agent/App），最后到渲染层（/load 回放）和运维层（上下文压缩）。

### 步骤 1: Message 结构扩展

**文件**: `src/types.zig`
**改动**: `Message` 新增 `reasoning_content` 字段，`ProviderResponse` 新增 `reasoning_content` 字段

```zig
pub const Message = struct {
    role: Role,
    content: []const u8,
    reasoning_content: ?[]const u8 = null,  // NEW
    tool_calls: ?[]const ToolCall = null,
    tool_call_id: ?[]const u8 = null,
    timestamp: i64 = 0,
    model: ?[]const u8 = null,
    usage: ?TokenUsage = null,
};

pub const ProviderResponse = struct {
    content: ?[]const u8,
    reasoning_content: ?[]const u8 = null,  // NEW
    tool_calls: ?[]const ToolCall,
    finish_reason: FinishReason,
    usage: ?TokenUsage = null,
};
```

**向下兼容**：所有现有代码创建 `Message` 时不设置 `reasoning_content`，默认 `null`。

### 步骤 2: SSE 解析分离累积

**文件**: `src/io/provider.zig`
**改动**: 流式解析时，reasoning 文本累积到独立的 `reasoning_buf`，不混入 `content_buf`

**当前代码** (`provider.zig:212-213`):
```zig
var content_buf = std.ArrayListAligned(u8, null).empty;
var tool_calls_buf = std.ArrayListAligned(types.ToolCall, null).empty;
```

**目标代码**:
```zig
var content_buf = std.ArrayListAligned(u8, null).empty;
var reasoning_buf = std.ArrayListAligned(u8, null).empty;  // NEW
var tool_calls_buf = std.ArrayListAligned(types.ToolCall, null).empty;
```

**当前 reasoning_content 处理** (`provider.zig:304-316`):
```zig
if (delta.get("reasoning_content")) |r_val| {
    if (r_val != .null) {
        const r = r_val.string;
        if (r.len > 0) {
            if (!in_content_phase) {
                if (pw) |p| p.begin_phase(p.context, .thinking);
            }
            try content_buf.appendSlice(alloc, r);  // ← BUG: 混入 content_buf
            if (!in_content_phase) {
                if (pw) |p| p.write_raw(p.context, r);
            }
        }
    }
}
```

**目标代码**:
```zig
if (delta.get("reasoning_content")) |r_val| {
    if (r_val != .null) {
        const r = r_val.string;
        if (r.len > 0) {
            if (!thinking_started) {  // PHASE-3 双标志
                thinking_started = true;
                if (pw) |p| p.begin_phase(p.context, .thinking);
            }
            try reasoning_buf.appendSlice(alloc, r);  // ← 累积到独立 buf
            if (pw) |p| p.write_raw(p.context, r);
        }
    }
}
```

**content delta 累积保持不变**（仍然写入 `content_buf`）。

**ProviderResponse 构造** (行 401-415):
```zig
// 当前:
return types.ProviderResponse{
    .content = content_buf.items,
    .tool_calls = null,
    .finish_reason = finish_reason,
    .usage = usage,
};

// 目标:
return types.ProviderResponse{
    .content = content_buf.items,
    .reasoning_content = if (reasoning_buf.items.len > 0) reasoning_buf.items else null,
    .tool_calls = null,
    .finish_reason = finish_reason,
    .usage = usage,
};
```

**agent.zig 存储 Message** (`agent.zig:223-229`):
```zig
try self.session_ref.append(.{
    .role = .assistant,
    .content = resp.content orelse "",
    .reasoning_content = resp.reasoning_content,   // NEW
    .tool_calls = resp.tool_calls,
    .usage = resp.usage,
});
```

### 步骤 3: Session 存储更新

**文件**: `src/core/session.zig`
**改动**: `serializeMessage()` / 反序列化 (`load()`) 中增加 `reasoning_content` 字段的 JSONL 读写

**序列化** (`session.zig:443-514`, 在 `content` 字段后):

```zig
fn serializeMessage(buf: *std.array_list.Managed(u8), msg: types.Message) !void {
    try buf.appendSlice("{\"role\":\"");
    try buf.appendSlice(@tagName(msg.role));
    try buf.appendSlice("\"");

    try buf.appendSlice(",\"content\":\"");
    try appendEscapedJsonString(buf, msg.content);
    try buf.appendSlice("\"");

    // NEW: serialize reasoning_content when present
    if (msg.reasoning_content) |rc| {
        try buf.appendSlice(",\"reasoning_content\":\"");
        try appendEscapedJsonString(buf, rc);
        try buf.appendSlice("\"");
    }

    // ... tool_calls, tool_call_id, model, timestamp, usage (unchanged) ...
}
```

**反序列化** (`session.zig:60-152`, 在解析 content 之后):

```zig
// 在 content_val 解析之后 (约 line 91), 新增:
const reasoning_content: ?[]const u8 = if (obj.get("reasoning_content")) |v|
    if (v == .string) try arena.dupe(u8, v.string) else null
else null;

// 在 append 调用中:
try self._messages.append(arena, .{
    .role = role,
    .content = try arena.dupe(u8, content_val),
    .reasoning_content = reasoning_content,  // NEW
    .tool_calls = tool_calls,
    .tool_call_id = tool_call_id,
    .timestamp = ts,
    .model = msg_model,
    .usage = usage,
});
```

### 步骤 4: buildJsonBody 条件回传

**文件**: `src/io/provider.zig`
**改动**: 在构建 messages 数组时，仅当 compat 标志允许且消息有 `tool_calls` 时，回传 `reasoning_content`

**当前 assistant 消息序列化** (`provider.zig:443-461`):
```zig
if (msg.tool_calls) |tcs| {
    try buf.appendSlice(allocator, ",\"content\":null,\"tool_calls\":[");
    // ... tool_calls 序列化 ...
} else {
    try buf.appendSlice(allocator, ",\"content\":\"");
    try appendEscapedJsonString(&buf, allocator, msg.content);
    try buf.appendSlice(allocator, "\"");
}
```

**目标代码** (在 content/tool_calls 之后追加 reasoning_content):

```zig
if (msg.tool_calls) |tcs| {
    try buf.appendSlice(allocator, ",\"content\":null");
    // NEW: include reasoning_content on tool-call messages when compat requires it
    if (self.config.compat.require_reasoning_on_tool_calls) {
        if (msg.reasoning_content) |rc| {
            try buf.appendSlice(allocator, ",\"reasoning_content\":\"");
            try appendEscapedJsonString(&buf, allocator, rc);
            try buf.appendSlice(allocator, "\"");
        }
    }
    try buf.appendSlice(allocator, ",\"tool_calls\":[");
    // ... tool_calls 序列化 ...
} else {
    try buf.appendSlice(allocator, ",\"content\":\"");
    try appendEscapedJsonString(&buf, allocator, msg.content);
    try buf.appendSlice(allocator, "\"");
    // NOTE: reasoning_content NOT included for pure-text turns (even on DeepSeek)
}
```

**判断逻辑精确化**：
- 仅在 `self.config.compat.require_reasoning_on_tool_calls == true` 时检查
- 仅在消息 `.role == .assistant` 且 `.tool_calls != null` 时回传
- 纯文本 assistant 消息永远不回传（即使 compat 标志为 true，这是 DeepSeek 的优化惯例）

### 步骤 5: system prompt 按需重建

**文件**: `src/core/agent.zig`、`src/frontends/cli/App.zig`

**核心思路**：`SystemPromptCb` 增加环境变化检测。只在以下情况重建 system prompt：
1. 首次启动（session 的 system message 为空）
2. 用户手动 `/new` 或 `/load` 切换会话
3. 用户手动切换工作目录（未来功能）

每次 `runTurn` 调用 `spRebuild` 不再无条件重建。

**agent.zig SystemPromptCb 扩展**:

```zig
// agent.zig — 修改 SystemPromptCb 语义
pub const SystemPromptCb = struct {
    context: ?*anyopaque = null,
    rebuild: *const fn (ctx: ?*anyopaque, force: bool) anyerror!void,
    //                                                 ^^^^^ NEW: force flag
};
```

**agent.zig runTurn 调用点上移** (从 line 159 移到 App 层控制):

当前 `agent.zig:159-161`:
```zig
if (self.system_prompt) |sp| {
    try sp.rebuild(sp.context);
}
```

改为 agent 中保留调用但由 App 的 flag 控制:

```zig
// agent.zig — 保持调用但参数变为 force: bool
// App 通过 agent 的 _env_changed 字段控制
_ = self; // spRebuild now managed by App before runTurn

// 或更简单：在 runTurn 中保留调用但 App 的 rebuild 函数自行判断
```

实际上最简单的方案是让 `spRebuild` 自行决定是否重建。在 App 中加入 `_env_changed` 标志：

**App.zig 修改**:

```zig
pub const App = struct {
    // ... existing fields ...
    _env_changed: bool = true,   // NEW: force first rebuild
};

fn spRebuild(ctx: ?*anyopaque) anyerror!void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    if (!self._env_changed) return;       // NEW: skip if no env change
    self._env_changed = false;

    const prompt = try buildPromptString(
        self.allocator, self.io,
        self.project_root, self.project_context, self.base_prompt);
    defer self.allocator.free(prompt);
    try self.session.updateFirstSystem(prompt);
}

// 在 /new, /load, /fork 命令中设置:
// self._env_changed = true;
```

**System prompt 内容优化** (`App.zig:657-717`):

去掉日期字段（`Today's date`），只保留静态环境信息：

```zig
fn buildPromptString(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    project_context: ?[]const u8,
    base_prompt: ?[]const u8,
) ![]const u8 {
    const os_tag = @tagName(builtin.os.tag);
    const effective_prompt = base_prompt orelse BASE_PROMPT;

    // NOTE: CWD and date REMOVED for cache prefix stability
    const prompt = try std.fmt.allocPrint(allocator,
        \\{s}
        \\
        \\<env>
        \\  Workspace root: {s}
        \\  Platform: {s}
        \\</env>
        \\
    , .{ effective_prompt, project_root, os_tag });

    // Skills + project_context (unchanged)
    // ...
}
```

如果用户需要在 prompt 中看到日期或 CWD，可以在用户消息中携带（agent 在上下文超过阈值时自动警告）。`Working directory` 信息仍然重要但可以通过工具 `bash pwd` 获取。

---

## 验证

```powershell
zig build
zig test src/test.zig --cache-dir .zig-cache 2>&1 | Select-String "^\d+/\d+|All \d+ tests|FAIL"
```

| 测试场景 | 预期结果 |
|----------|----------|
| DeepSeek V4 Flash 多回合对话 | 第 2 回合起缓存命中率 > 80%（log 中可见 `cache_hit_tokens` 增长） |
| DeepSeek V4 Pro tool-call 回合 | reasoning_content 回传，不报 400 |
| 纯文本回合 | reasoning_content 不回传，prompt_tokens 明显减少 |
| Qwen / 非 DeepSeek | 不受影响，reasoning_content 始终设置为 null |
| 多个回合后 system prompt | 前缀内容不变（无日期变化），cache 持续命中 |
| `/new` 后 system prompt | 重建一次，之后每回合不变 |
| Session 反序列化旧格式 | 缺少 `reasoning_content` 字段的消息正确加载为 null |
| `/load` 回放带 reasoning 的会话 | 思考内容以 .thinking 相位渲染，回复走 Markdown→ANSI |
| 第 6 回合上下文超过阈值 | 自动压缩前 4 轮为结构化摘要，token 占用回落 < 60% |
| DeepSeek → OpenAI 模型切换 | reasoning_content 转为 `[已经过思考: ...]` 注记 |

### 测试用例

**types.zig 新增测试**:

1. `test "Message with reasoning_content"`:
   ```zig
   const msg = types.Message{
       .role = .assistant,
       .content = "I'll read that file.",
       .reasoning_content = "The user wants me to read a file...",
       .tool_calls = &.{ .{ .id = "c1", .name = "read", .arguments = "{}" } },
   };
   try testing.expect(msg.reasoning_content != null);
   try testing.expectEqualStrings("I'll read that file.", msg.content);
   ```

2. `test "Message default no reasoning"`:
   ```zig
   const msg = types.Message{ .role = .user, .content = "hello" };
   try testing.expect(msg.reasoning_content == null);
   ```

**provider.zig 新增测试**:

3. `test "buildJsonBody reasoning on tool_calls with DeepSeek compat"`:
   ```zig
   var p = Provider{ .config = .{ ..., .compat = .{
       .require_reasoning_on_tool_calls = true, .thinking_format = .thinking_object }}};
   const msgs = [_]types.Message{
       .{ .role = .user, .content = "read file" },
       .{ .role = .assistant, .content = "",
          .reasoning_content = "Need to read the file first",
          .tool_calls = &.{ .{ .id = "c1", .name = "read", .arguments = "{}" } } },
   };
   const body = try p.buildJsonBody(testing.allocator, &msgs, null, true);
   defer testing.allocator.free(body);
   try testing.expect(std.mem.indexOf(u8, body, "\"reasoning_content\"") != null);
   try testing.expect(std.mem.indexOf(u8, body, "Need to read") != null);
   ```

4. `test "buildJsonBody no reasoning on pure text with DeepSeek compat"`:
   ```zig
   var p = Provider{ .config = .{ ..., .compat = .{
       .require_reasoning_on_tool_calls = true, .thinking_format = .thinking_object }}};
   const msgs = [_]types.Message{
       .{ .role = .user, .content = "hello" },
       .{ .role = .assistant, .content = "Hi there!", .reasoning_content = "Just greeting" },
   };
   const body = try p.buildJsonBody(testing.allocator, &msgs, null, false);
   defer testing.allocator.free(body);
   try testing.expect(std.mem.indexOf(u8, body, "\"reasoning_content\"") == null);
   ```

5. `test "buildJsonBody no reasoning on standard compat"`:
   ```zig
   var p = Provider{ .config = .{ ..., .compat = .{
       .require_reasoning_on_tool_calls = false }}};
   const msgs = [_]types.Message{
       .{ .role = .user, .content = "hello" },
       .{ .role = .assistant, .content = "",
          .reasoning_content = "should not appear",
          .tool_calls = &.{ .{ .id = "c1", .name = "read", .arguments = "{}" } } },
   };
   const body = try p.buildJsonBody(testing.allocator, &msgs, null, false);
   defer testing.allocator.free(body);
   try testing.expect(std.mem.indexOf(u8, body, "\"reasoning_content\"") == null);
   ```

**session.zig 新增测试**:

6. `test "session: serialize/deserialize reasoning_content"`:
   ```zig
   // Roundtrip test: create session, add message with reasoning_content,
   // flush, load, verify reasoning_content preserved
   var sess = try Session.init(testing.allocator, io, "deepseek/model");
   defer sess.deinit();
   try sess.append(.{
       .role = .assistant, .content = "result",
       .reasoning_content = "thinking process...",
       .timestamp = 1752062401,
   });
   // flush → load → assert reasoning_content matches
   ```

7. `test "session: load old format without reasoning_content"`:
   ```zig
   // Create session without reasoning_content field in JSONL, load, verify null
   const content =
       \\{"type":"header","timestamp":"2026-07-09T12:00:00Z","model":"m","name":"Test"}
       \\{"role":"assistant","content":"hello","model":"m","timestamp":1}
       \\
   ;
   // ... create file, load, verify msg.reasoning_content == null
   ```

**agent.zig 现有测试兼容性验证**:

8. 所有现有 agent 测试不做修改——新字段默认 `null`，行为不变。

**App.zig 测试** (手工, 非自动化):

9. `test "spRebuild only on env change"`:
   - 首次启动 → `_env_changed = true` → system prompt 重建
   - 第二回合 → `_env_changed = false` → system prompt 不变（缓存命中）
   - `/new` 命令 → `_env_changed = true` → system prompt 重建一次

---

## 波及

| 文件 | 改动 | 破坏性 |
|------|------|--------|
| `src/types.zig` | `Message` 新增 `reasoning_content` 字段；`ProviderResponse` 新增 `reasoning_content` 字段 | 否（新字段可选，有默认值 null） |
| `src/io/provider.zig` | SSE 解析新增 `reasoning_buf` 分离累积；`buildJsonBody` 条件回传 reasoning_content；`ProviderResponse` 构造含 reasoning_content | 否 |
| `src/core/session.zig` | `serializeMessage` + `load` 反序列化新增 `reasoning_content` 字段 | 否 |
| `src/core/agent.zig` | `runTurn` 中 Message append 含 `reasoning_content`；`SystemPromptCb` 调用语义不变（App 层自行控制是否跳过） | 否 |
| `src/frontends/cli/App.zig` | `spRebuild` 新增 `_env_changed` 检查；`buildPromptString` 移除日期字段 | 否 |
| `src/core/agent.zig` | `runTurn` 后检查溢出 → 触发压缩；压缩总结提示构建 | 否 |

## 术语

| 术语 | 含义 |
|------|------|
| reasoning_content | DeepSeek API 的思考文本，在 assistant 消息中作为独立字段返回 |
| 选择性回传 | 仅在 tool-call 回合 + DeepSeek compat 时才将 reasoning_content 发送给 API |
| 缓存前缀稳定性 | 消息数组的前几个元素每回合保持一致，让 DeepSeek 自动缓存命中 |
| append-only history | Reasonix 的核心理念——只追加消息不修改已有消息，保持前缀字节不变 |
| 前缀断裂 | system prompt 或前几轮消息发生字节级变化 → DeepSeek cache miss |
| 上下文窗口（context window） | 模型一次请求能处理的最大 token 数（input + output） |
| 结构化压缩 | 调用 LLM 将历史对话总结为 Key Decisions / Next Steps / Critical Context |
| 工具输出修剪 | 截断旧工具调用输出至 2000 字符以节省 token |

## 实施顺序

```
步骤 1 (types.zig):     Message + ProviderResponse 新增 reasoning_content 字段
步骤 2 (provider.zig):  SSE 解析分离 reasoning_buf + agent.zig append 含新字段
步骤 3 (session.zig):   serializeMessage + load 反序列化 reasoning_content
步骤 4 (provider.zig):  buildJsonBody 条件回传 reasoning_content + 跨模型 reasoning→text
步骤 5 (App.zig):       spRebuild 按需重建 + buildPromptString 移除日期
步骤 6 (App.zig):       /load 完整回放渲染管线（reasoning→thinking 相位 + Markdown 渲染）
步骤 7 (agent.zig):     上下文溢出检测 + LLM 结构化压缩 + 工具输出修剪
```

每步用 `zig build` 验证编译通过。步骤 3 和步骤 5 的测试依赖文件 IO，在 `zig test` 中需要切换 CWD（参考现有 `session: flush writes JSONL` 测试的模式）。

## 性能预期

| 指标 | 当前（每回合重建） | 目标（cache-first） |
|------|-------------------|---------------------|
| system prompt 字节稳定性 | 每回合变化 | 仅在 /new 时变化 |
| 第 2 回合 prompt_tokens | ~2000-5000 | ~100-500 (cache hit) |
| 第 5 回合 prompt_tokens | ~4000-10000 | ~500-2000 |
| reasoning 无意义回传 | 每回合都带 | 仅 tool-call 回合带 |
