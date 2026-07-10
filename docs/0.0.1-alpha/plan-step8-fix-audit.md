# Step 8: 审查修复 — 消除设计与源码偏差

> 全量审查报告（Step 7 完成后）发现 4 项严重/功能性偏差 + 5 项文档不一致。本文档定义修复计划与验收标准。

## A. 修复清单总览

| ID | 严重度 | 类型 | 描述 | 改动文件 | 状态 |
|----|--------|------|------|---------|------|
| FIX-01 | 🔴 | 代码 | 移除 agent 内全部 session.flush()：App 为唯一持久化点 | `agent.zig` | ✅ 已完成 |
| FIX-02 | 🔴 | 代码 | popLast 单条不足回滚：改 truncateTo + pre_count 截断 | `App.zig`, `session.zig` | ✅ 已完成 |
| FIX-03 | 🟡 | 代码 | /name 命令接入 `session.rename()` | `App.zig` | ✅ 已完成 |
| FIX-04 | 🟡 | 代码 | /list 命令接入 `session.list()` | `App.zig` | ✅ 已完成 |
| FIX-05 | 🟡 | 代码 | /help 命令 (用户友好) | `App.zig` | ✅ 已完成 |

> FIX-01 为第三方审查追加项（原 FIX-01 singleTurn flush 已整合到 FIX-02 的 App 统一持久化中）。FIX-06（告警条件修正）经复核确认 `>50` 行为正确，取消。
| DOC-01 | 🟢 | 文档 | plan-step5-agent.md runTurn 签名 + 依赖方向 | ✅ 已修复 |
| DOC-02 | 🟢 | 文档 | plan-step7-app-integration.md C4 与 B5 矛盾 | ✅ 已修复 |
| DOC-03 | 🟢 | 文档 | plan-step7-app-integration.md C6 buildSystemPrompt 签名 | ✅ 已修复 |
| DOC-04 | 🟢 | 文档 | PLAN-V1-CLI-CORE.md B 节依赖图 + C6 agent 描述 | ✅ 已修复 |
| DOC-05 | 🟢 | 代码 | agent.zig 文档注释 "Does NOT import render" | ✅ 已修复 |

---

## B. 分步修复

### FIX-01: 移除 agent 内部全部 session.flush() — App 为唯一持久化点

**根因**: agent.zig 有 4 处 `self.session_ref.flush()` 调用（行 94/111/125/169），App.zig 同时有 3 处 `self.session.flush()`（行 167/247/267）。每个 turn 双写磁盘。`api_error` 路径尤其危险：agent 先将含脏消息的 session flush 到 JSONL，App 再 truncateTo + flush 覆盖。若进程在两次写入之间崩溃，JSONL 文件永久损坏。

**修复**: 删除 agent.zig 全部 4 处 `flush()` 调用。App 作为"单一持久化栅栏"在 turn 结束后统一 flush。这与 PLAN-V1-CLI-CORE.md C5 "持久化栅栏" 的设计意图一致——当时由 agent 调用 flush 是因为没有 App 层回滚机制；现在 App 有了 truncateTo 回滚，flush 必须统一到 App 层。

#### 修复位置与 diff

agent.zig 行 93-95 — max_rounds 路径:
```diff
             if (tool_rounds >= self.max_tool_rounds) {
-                try self.session_ref.flush();
                 return RoundResult{ .new_message_count = new_msgs, .finish = .max_rounds };
             }
```

agent.zig 行 109-112 — api_error 路径:
```diff
                     else => {
-                        try self.session_ref.flush();
                         return RoundResult{ .new_message_count = new_msgs, .finish = .api_error };
                     },
```

agent.zig 行 123-125 — stop 路径:
```diff
             if (resp.finish_reason == .stop) {
-                try self.session_ref.flush();
                 return RoundResult{ .new_message_count = new_msgs, .finish = .stop };
             }
```

agent.zig 行 168-169 — fallback stop 路径:
```diff
-            try self.session_ref.flush();
             return RoundResult{ .new_message_count = new_msgs, .finish = .stop };
```

#### 测试影响

现有 agent 测试不校验 flush 行为（mock provider 不产生磁盘文件），无需修改。但需确认：删除 max_rounds 路径的 flush 后，App.flush() 仍然会在 turn 结束后执行——验证方式：检查 App.processLine / singleTurn 结尾均有 `session.flush()`。

#### 验证

```
zig build check  → 编译通过
zig test src/test.zig --cache-dir .zig-cache  → 全部通过
```

---

### FIX-02: popLast → 基于 pre-count 的回滚 + App 统一持久化

**根因**: agent 在 `api_error` 返回前可能已执行 N 轮 tool 调用并将 N 条 assistant+tool 消息写入 session。`popLast()` 只移除用户消息，遗留 orphan assistant/tool 消息，污染下一 turn 上下文。

**方案**: Session 新增 `truncateTo(keep: usize)` 方法，App.zig 在调用 `runTurn` 前记录 `pre_count`，`api_error` / `interrupted` / 异常时回滚到 `pre_count`。

#### B-1. session.zig 新增方法

```zig
// core/session.zig — 在 popLast() 之后

/// Truncate message list to at most `keep` items. Scope: error rollback only.
/// App records pre_count before appending user message, calls truncateTo(pre_count)
/// on runTurn error to remove user + any partial assistant/tool messages from agent.
/// Always followed by session.flush() at the call site; not for general-purpose truncation.
pub fn truncateTo(self: *Session, keep: usize) void {
    if (keep < self._messages.items.len) {
        self._messages.shrinkRetainingCapacity(keep);
        self.modified = true;
    }
}
```

测试:
```zig
test "session: truncateTo shrinks" {
    const io = std.testing.io;
    var sess = try Session.init(std.testing.allocator, io, "test");
    defer sess.deinit();

    try sess.append(.{ .role = .system, .content = "sys" });
    try sess.append(.{ .role = .user, .content = "u1" });
    try sess.append(.{ .role = .assistant, .content = "a1" });
    try sess.append(.{ .role = .tool, .content = "t1" });

    sess.truncateTo(2);
    try std.testing.expectEqual(@as(usize, 2), sess.messages().len);
    try std.testing.expectEqualStrings("sys", sess.messages()[0].content);
    try std.testing.expectEqualStrings("u1", sess.messages()[1].content);
    try std.testing.expect(sess.modified);
}

test "session: truncateTo keep >= len is no-op" {
    const io = std.testing.io;
    var sess = try Session.init(std.testing.allocator, io, "test");
    defer sess.deinit();

    try sess.append(.{ .role = .system, .content = "sys" });
    sess.truncateTo(5);
    try std.testing.expectEqual(@as(usize, 1), sess.messages().len);
    try std.testing.expect(!sess.modified);
}
```

#### B-2. App.zig: processLine 重写回滚逻辑

当前 `processLine` (repLoop) 回滚模式:
```zig
// 当前: 对异常和 api_error/interrupted 各调用一次 popLast
// 问题: 只回滚 1 条，agent 可能写了 N 条
```

修复后:
```zig
fn processLine(self: *App, stdout: *Io.File.Writer, line: []const u8, pw: *render.PhaseWriter) !void {
    if (line.len == 0) return;
    if (std.mem.eql(u8, line, "/exit") or std.mem.eql(u8, line, "/quit")) return error.ExitRepl;
    if (std.mem.eql(u8, line, "/new")) {
        try self.resetSession();
        return;
    }
    // [FIX-03] /name 命令
    if (std.mem.startsWith(u8, line, "/name ")) {
        try self.renameSession(line["/name ".len..]);
        return;
    }
    // [FIX-04] /list 命令
    if (std.mem.eql(u8, line, "/list")) {
        try self.listSessions(stdout);
        return;
    }
    // [FIX-05] /help 命令
    if (std.mem.eql(u8, line, "/help")) {
        try self.showHelp(stdout);
        return;
    }

    const pre_count = self.session.messages().len;   // ← 记录基线
    try self.session.append(.{ .role = .user, .content = line });
    _ = stdout.interface.write("\n") catch {};

    const result = self.agent.runTurn(&stdout.interface, pw) catch |err| {
        switch (err) {
            error.OutOfMemory => {
                self.session.truncateTo(pre_count);
                return err;
            },
            else => {
                try render.writeLabeled(&stdout.interface, .err, @errorName(err));
                self.session.truncateTo(pre_count);       // ← count 回滚替代 popLast
                try self.session.flush();
                return;
            },
        }
    };

    _ = stdout.interface.write("\n") catch {};

    switch (result.finish) {
        .api_error => {
            try render.writeLabeled(&stdout.interface, .err, "API error");
            self.session.truncateTo(pre_count);           // ← count 回滚
        },
        .interrupted => {
            try render.writeLabeled(&stdout.interface, .warning, "interrupted");
            self.session.truncateTo(pre_count);           // ← count 回滚
        },
        else => {},
    }

    try self.session.flush();
}
```

#### B-3. App.zig: singleTurn 回滚

```zig
fn singleTurn(self: *App, prompt: []const u8) !void {
    var obuf: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), self.io, &obuf);
    var pw = render.PhaseWriter.init(&stdout.interface);

    try render.writeLabeled(&stdout.interface, .user, prompt);
    try stdout.interface.flush();

    const pre_count = self.session.messages().len;         // ← 记录基线
    try self.session.append(.{ .role = .user, .content = prompt });
    _ = stdout.interface.write("\n") catch {};

    const result = self.agent.runTurn(&stdout.interface, &pw) catch |err| {
        switch (err) {
            error.OutOfMemory => {
                self.session.truncateTo(pre_count);
                try self.session.flush();
                return err;
            },
            else => {
                self.session.truncateTo(pre_count);         // ← count 回滚
                try self.session.flush();                   // [FIX-01] 补齐 flush
                return;
            },
        }
    };
    _ = stdout.interface.write("\n") catch {};
    if (result.finish == .interrupted) {
        try render.writeLabeled(&stdout.interface, .warning, "interrupted");
    }
    // api_error 在 singleTurn 中不显示标签 (单次模式静默退出)
    if (result.finish == .api_error or result.finish == .interrupted) {
        self.session.truncateTo(pre_count);                 // ← count 回滚
    }
    try self.session.flush();
}
```

---

### FIX-03: /name 命令

**改动**: `App.zig` `processLine` 新增 `/name <name>` 分支 + `renameSession` 方法。

```zig
/// Rename current session and persist. Displays success/error to stderr.
fn renameSession(self: *App, new_name: []const u8) !void {
    const trimmed = std.mem.trim(u8, new_name, " \t");
    if (trimmed.len == 0) {
        var ebuf: [256]u8 = undefined;
        var ew: Io.File.Writer = .init(.stderr(), self.io, &ebuf);
        try ew.interface.print("Usage: /name <new-name>\n", .{});
        return;
    }
    try self.session.rename(trimmed);
    try self.session.flush();  // rename 不自动 flush
    var ebuf: [256]u8 = undefined;
    var ew: Io.File.Writer = .init(.stderr(), self.io, &ebuf);
    try ew.interface.print("Session renamed to: {s}\n", .{trimmed});
}
```

---

### FIX-04: /list 命令

**改动**: `App.zig` `processLine` 新增 `/list` 分支 + `listSessions` 方法。

```zig
/// List all sessions in .zagent/sessions/ to stderr.
fn listSessions(self: *App, stdout: *Io.File.Writer) !void {
    const sessions = try session_mod.list(self.allocator, self.io, self.session_dir);
    defer session_mod.freeSessionInfoList(self.allocator, sessions);

    if (sessions.len == 0) {
        try stdout.interface.print("No saved sessions.\n", .{});
        return;
    }

    try stdout.interface.print("Saved sessions ({d}):\n", .{sessions.len});
    for (sessions) |s| {
        try stdout.interface.print("  {s}  {s}  ~{d} msgs\n", .{ s.name, s.model, s.msg_count });
    }
}
```

---

### FIX-05: /help 命令

```zig
fn showHelp(self: *App, stdout: *Io.File.Writer) !void {
    _ = self;
    try stdout.interface.print(
        \\z-agent-core commands:
        \\  /exit, /quit    Exit the REPL
        \\  /new            Start a new session
        \\  /name <name>    Rename current session
        \\  /list           List saved sessions
        \\  /help           Show this help
        \\
    , .{});
}
```

---

### FIX-06: session.zig 告警条件

**问题** (`session.zig:218`): `items.len > 50` 只在消息数严格大于 50 时告警。设计文档写 ">50" 是对的，但代码用 `>` 没问题——50 条刚好不告警是合理的。维持不变。**此项取消**。

---

## C. 新增/修改文件清单

| 文件 | 操作 | 内容 |
|------|------|------|
| `src/core/session.zig` | 新增方法 | `truncateTo(keep: usize)` + 2 个测试 |
| `src/App.zig` | 修改 | processLine 回滚重写 + /name /list /help 四条命令 |
| `src/App.zig` | 修改 | singleTurn 补齐 flush + count 回滚 |
| `docs/plan-step5-agent.md` | 已修复 | runTurn 签名 + 依赖方向 |
| `docs/plan-step7-app-integration.md` | 已修复 | C4 食谱 + C6 buildSystemPrompt 签名 |
| `docs/PLAN-V1-CLI-CORE.md` | 已修复 | B 节依赖图 + C2/C6 描述 |
| `src/core/agent.zig` | 已修复 | runTurn 文档注释 |

---

## D. 测试计划

| 测试 | 覆盖 | 类型 |
|------|------|------|
| `session: truncateTo shrinks` | truncateTo(2) 后 messages 保持 2 条 | 单元 (新增) |
| `session: truncateTo keep >= len is no-op` | 不修改 | 单元 (新增) |
| `agent: runTurn api_error rollback` | api_error 后 session 消息数 = pre_count | 单元 (已有 mock) |
| `agent: runTurn interrupted rollback` | interrupted 后 session 消息数 = pre_count | 单元 (已有 mock) |
| `app: /name renames session` | /name 后 session.name 更新 | 集成 (手动) |
| `app: /list shows sessions` | /list 输出会话列表 | 集成 (手动) |
| `app: /help shows commands` | /help 输出命令列表 | 集成 (手动) |
| `app: api_error rollback preserves session` | api_error 后 session 不残留 orphan 消息 | 集成 (手动) |

---

## E. 验证命令

```
zig build check                              # 编译 + 架构扫描
zig test src/test.zig --cache-dir .zig-cache # 全量测试通过
zig build run                                # REPL 交互测试: /help /name /list
zig build run -- --prompt "hello"            # 单次模式端到端
```

---

## F. 架构变更（FIX-01 引入）

**持久化栅栏从 agent → App**：原设计 agent 在 4 个退出点调用 `session.flush()`。发现与 App 层 `truncateTo` 回滚冲突后，移除 agent 所有 flush，App 成为唯一持久化点。架构变更：

```
修复前:  agent.stop → flush        ← 双写
         App.stop  → flush
         agent.api_error → flush   ← 写脏状态
         App.api_error → truncateTo + flush  ← 覆盖

修复后:  agent.*   → 不持久化，仅内存操作
         App.*    → 根据 result.finish 决定 truncateTo 或 flush
```

依赖方向不变。

---

## G. V1 已知限制

| 项目 | 说明 |
|------|------|
| /load | 不实现——V1 无交互式会话恢复 |
| /compact | 不实现——上下文超出时仅 truncateTo 回滚无效 turn，不压缩 |
| /model | 不实现——仅 --model flag 启动时选择 |
| agent import render | V1 务实——V2 通过回调注入消除 |
| provider import render | V1 务实——V2 通过 PhaseWriter interface 消除 |
| 回滚逻辑重复 | processLine/singleTurn 有 2 处独立 pre_count → truncateTo 代码，V2 抽取辅助 |

---

## H. 第三方审查确认记录

| 审查项 | 结论 | 处置 |
|--------|------|------|
| Agent flush 与 App 回滚竞态冲突 | ✅ 确认存在 | 新增 FIX-01：移除 agent 全部 flush |
| 回滚逻辑重复 | ⚠️ 观察正确 | V2 再抽取，V1 只有 2 处可接受 |
| truncateTo modified 标志语义 | ⚠️ 部分合理 | 已加 scope 注释；no-op 情况已正确不设 modified |
| /list 缺少错误处理 | ❌ 不成立 | session.list() 已 `catch return &.{}` |
| mock 依赖未确认 | ❌ 不成立 | MockChatter + ChatFn 已存在（agent.zig:174-222） |
| 实践方案 2: Agent 不碰 flush | ✅ 强烈采纳 | 即 FIX-01 实施内容 |
