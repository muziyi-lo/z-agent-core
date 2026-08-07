# Plan FIX-SYSTEM-PROMPT: 核心功能归位

## 状态: 已完成

## 前置依赖

| 阻塞者 | 状态 | 被阻塞 |
|--------|------|--------|
| 无 | — | — |

## 不做

- 不在 Web handler 中手动构建任何系统提示词
- `SystemPromptCb` 保留为仅前端特有注入（如 CLI 单次模式的 "no user interaction possible" 提示）

## 问题

**现象**：Web 前端所有对话中 agent 自我标识为"Claude, from Anthropic"，而非"z-agent-core"。系统提示词完全缺失。

**根因**（两层）：

1. **架构倒置**：`AgentLoop.init()` 中 `system_prompt` 默认为 `null`，依赖外部（前端）通过 `SystemPromptCb` 回调注入。核心层对自身身份无默认定义——agent 不知道自己是谁。

2. **计划遗漏**：PLAN-PHASE-7-WEB-FRONTEND.md 共 766 行，覆盖颜色 Token、字体 vendor、CSS 动画，但 `SystemPromptCb` 未被提及。`AgentLoop.init(..., .{})` 一行未展开，三个回调契约只接入了两个。

### B. 路径穿越防护在 Web handler 而非核心层

**现象**：`isValidSessionId` 在 `handler.zig:298`——CLI 当前无 `/delete` 命令故未暴露，但一旦 CLI 加删除功能，需重复实现相同安全检查。

**根因**：路径穿越是文件系统安全，不属于任何特定前端。应移到 `session.zig` 的 `load()` / `deleteFile()` 入口统一校验。

## 概览

- **改动文件**: 5 个（`core/agent.zig`、`core/session.zig`、`util/uuid.zig` 新建、`frontends/cli/App.zig`、`frontends/web/handler.zig`）
- **类型**: 核心层新增默认行为 + UUID 会话 ID + 安全逻辑归位 + 前端简化
- **核心思路**:
  1. `AgentLoop.runTurn()` 自动注入 baseline 系统提示词——前端不再负责 agent 身份
  2. `Session.load()` / `deleteFile()` 入口统一 `isValidSessionId`——不再由各前端自行校验

## 设计要点

### 1. 默认系统提示词在 runTurn 中完整构建

```zig
// agent.zig runTurn() 开头新增
const msgs = self.session_ref.messages();
if (msgs.len == 0 or msgs[0].role != .system) {
    try self.session_ref.updateFirstSystem(try buildPromptString(self));
}
```

`buildPromptString` 构建完整 system prompt：身份 + 工作区 + 平台 + AGENTS.md 内容 + skills 列表。CLI 的当前实现移入核心层。AGENTS.md 读取失败 → 跳过 project_context 块（非致命）。skills 目录不存在 → 跳过 available_skills 块（非致命）。

**固定标签名**（确保跨前端一致）：

```
<env>
  Workspace root: {project_root}
  Platform: {os}
</env>
<available_skills>
  {name}: {description}
  ...
</available_skills>
<project_context>
  {AGENTS.md 全文}
</project_context>
```

### 2. CLI SystemPromptCb 简化为追加交互模式

核心层已注入完整 prompt → CLI 回调不再重建，仅**追加**单行提示（`session.append`，非 `updateFirstSystem`）：

```zig
// CLI App.zig — SystemPromptCb.rebuild 简化后
fn rebuildSystemPrompt(ctx: ?*anyopaque) anyerror!void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (app.single_prompt != null) {
        try app.session.append(.{
            .role = .system,
            .content = "Interaction mode: single-shot. No user interaction possible.",
        });
    }
}
```

REPL 模式下不追加任何内容——核心层 prompt 已足够。

## 实施

### 步骤 1: agent.zig 默认构建完整 system prompt

**文件**: `src/core/agent.zig`
**改动**: 新增 `buildPromptString` 方法（从 CLI `App.zig` 移入）；`runTurn()` 中检测无 system 消息时自动调用
**关键代码**:

```zig
fn buildPromptString(self: *AgentLoop, allocator: std.mem.Allocator) ![]const u8 {
    var buf: std.ArrayListAligned(u8, null) = .empty;
    try buf.appendSlice(allocator, "You are z-agent-core, an interactive CLI agent ...\n");
    try buf.appendSlice(allocator, "<env>\n  Workspace root: ");
    try buf.appendSlice(allocator, self.project_root);
    try buf.appendSlice(allocator, "\n  Platform: ");
    try buf.appendSlice(allocator, @tagName(builtin.os.tag));
    try buf.appendSlice(allocator, "\n</env>\n");

    // 读取 AGENTS.md（文件不存在或读取失败 → 跳过，非致命）
    if (readAgentsMd(allocator, self.io, self.project_root)) |content| {
        try buf.appendSlice(allocator, "\n<project_context>\n");
        try buf.appendSlice(allocator, content);
        try buf.appendSlice(allocator, "\n</project_context>\n");
    }

    // 读取 skills 列表（目录不存在或为空 → 跳过，非致命）
    try appendSkillsList(allocator, self.io, self.project_root, &buf);

    return buf.toOwnedSlice(allocator);
}
```

**注意**: `AgentLoop` 已有 `project_root`(l84)、`io`(l79)、`allocator`(l78)。需在 agent.zig 头部增加 `const builtin = @import("builtin");`。`readAgentsMd` 和 `appendSkillsList` 从 CLI `App.zig` 对应逻辑提取。CLI 的 `SystemPromptCb.rebuild` 同步简化为仅追加交互模式提示——不再重复读取 AGENTS.md 和 skills。

**生命周期**：调用方（`runTurn`）负责 `self.allocator.free(result)`。`updateFirstSystem` 已 `dupe` 进 session arena。当前 `self.allocator` 均为 arena（CLI: `process.arena`，Web: `gpa_arena`），显式 `free` 无实际效果，但防止未来换非 arena 分配器。

### 步骤 2: session.zig 新增 isValidId

**文件**: `src/core/session.zig`
**改动**: 新增 `pub fn isValidId`，所有前端统一调用
**关键代码**:

```zig
/// Reject session IDs containing path traversal characters.
/// Accepts alphanumeric, `-` (UUID v4), `_`.
pub fn isValidId(id: []const u8) bool {
    if (id.len == 0) return false;
    for (id) |c| {
        if (c == '.' or c == '/' or c == '\\') return false;
    }
    return true;
}
```

**调用点**：`loadSession` 和 `handleSessionDelete` 在构造 path 前调用。未来 CLI `/delete` 同位置插入。

```zig
// loadSession 开头（handler.zig:254）
if (!session_mod.Session.isValidId(id)) return error.InvalidSessionId;

// handleSessionDelete 开头（handler.zig:213）
if (!session_mod.Session.isValidId(id)) return err_mod.respondError(request, .bad_request, "invalid session id", a);
```

### 步骤 3: handler.zig 转发 + 移除补丁

**文件**: `src/frontends/web/handler.zig`
**改动**: `isValidSessionId` 改为转发 `session_mod.Session.isValidId`；移除 `handlePrompt` 中手动 `updateFirstSystem`；`handleSessionCreate` 改用 UUID v4

### 步骤 4: util/uuid.zig 新建

**文件**: `src/util/uuid.zig`（新建）
**改动**: 实现 `v4(allocator) ![]const u8`——16 随机字节 + 版本/变体位 + 格式化
**关键代码**:

```zig
/// Generate a UUID v4 (random) string. Caller owns returned memory (allocator).
pub fn v4(allocator: std.mem.Allocator) ![]const u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10xx
    return std.fmt.allocPrint(allocator, "{s}-{s}-{s}-{s}-{s}", .{
        std.fmt.fmtSliceHexLower(bytes[0..4]),
        std.fmt.fmtSliceHexLower(bytes[4..6]),
        std.fmt.fmtSliceHexLower(bytes[6..8]),
        std.fmt.fmtSliceHexLower(bytes[8..10]),
        std.fmt.fmtSliceHexLower(bytes[10..16]),
    });
}
```

### 步骤 5: isValidId 允许 `-`

**文件**: `src/core/session.zig`
**改动**: `isValidId` 循环中拒绝字符列表不含 `-`（UUID v4 含连字符）

### 步骤 6: 常量化

**文件**: `src/core/session.zig` + `src/core/agent.zig`
**改动**:

| 常量 | 文件 | 值 |
|------|------|-----|
| `DEFAULT_SESSION_NAME` | session.zig | `"New Session"` |
| `DEFAULT_SESSION_FILENAME` | session.zig | `"New_Session"` |
| `ENV_TAG` / `SKILLS_TAG` / `CONTEXT_TAG` | agent.zig | `"<env>"` / `"<available_skills>"` / `"<project_context>"` |

handler.zig 中 `"New Session"` 字面量替换为 `session_mod.DEFAULT_SESSION_NAME`。session.zig flush() 中的 `"New_Session"` 比较替换为 `DEFAULT_SESSION_FILENAME`。

## 验证

```powershell
zig build
zig test src/test.zig --cache-dir .zig-cache 2>&1 | Select-String "^\d+/\d+|All \d+ tests|FAIL"
```

| 测试场景 | 预期结果 |
|----------|----------|
| Web 首次对话 | agent 自称为 "z-agent-core"，含 AGENTS.md + skills |
| CLI 对话（回归） | system prompt 含 AGENTS.md + skills（核心层注入）+ 交互模式提示（回调追加） |
| 空 session + runTurn | 完整 system prompt 自动注入 |
| `isValidId("550e8400-e29b-...")` | true（UUID v4） |
| `isValidId("1785395461494")` | true（时间戳） |
| `isValidId("../.zagent/config")` | false（路径穿越） |
| `isValidId("session.test")` | false（含 `.`） |
| `isValidId("")` | false（空字符串） |

## 波及

| 文件 | 改动 | 破坏性? |
|------|------|----------|
| `src/core/agent.zig` | `runTurn()` 新增 `buildPromptString`；标签名常量化 | 否 |
| `src/core/session.zig` | 新增 `isValidId()`（含 `-`）；`DEFAULT_SESSION_NAME`/`FILENAME` 常量 | 否 |
| `src/util/uuid.zig` | 新建——`v4(allocator) ![]const u8` | 否 |
| `src/frontends/cli/App.zig` | `SystemPromptCb.rebuild` 简化 | 否 |
| `src/frontends/web/handler.zig` | `isValidSessionId` 转发；移除补丁；`handleSessionCreate` 改用 UUID | 否 |

## 术语

| 术语 | 含义 |
|------|------|
| baseline prompt | agent 身份定义的最简系统提示词，核心层自动注入 |
| SystemPromptCb | 回调接口，前端用于覆盖/增强 baseline prompt |
