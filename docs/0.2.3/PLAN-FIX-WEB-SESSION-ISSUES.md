# Plan FIX-SESSION-CRUD: Web 会话管理 CRUD 补齐

## 状态: 已完成

## 前置依赖

| 阻塞者 | 状态 | 被阻塞 |
|--------|------|--------|
| 无 | — | — |

## 不做

- 不重构 `Session` 核心模块的 `flush()` 逻辑——文件生成规则保持不变
- 不修改 CLI 端的会话创建行为（REPL 无"重复创建"问题）
- 不做会话自动清理/过期策略——超出本次修复范围
- 不升级存储引擎（SQLite）——JSONL 保持现状
- 不做前端框架升级（React 等）——静态 HTML 保持现状

## 问题

### A. 会话重复创建（修复重点）

**现象**：用户反复点击 "+ New Session" 可无限创建空会话，侧边栏堆积大量 "New Session"。

**根因**：`handleSessionCreate` 无条件调用 `Session.init()` → `flush()`，每次生成独立文件。没有检查是否已存在未使用的空会话（name="New Session"、0 条消息）。

### B. 新会话按钮不刷新侧边栏（已在代码中修复）

**现象**：点击 "+ New Session" 后侧边栏不更新。

**根因**：前端 `index.html:299` 检查 `sess.status === 'created'`，但 `handleSessionCreate` 返回的 JSON 只有 `id/name/model`，没有 `status` 字段。判断永假。

**修复**：改为 `sess.id` 判断。

### C. 会话加载 500 错误（根因已诊断，已在代码中修复）

**现象**：加载含系统消息的旧会话返回 500，响应体为 `{"error":{"code":"internal_error","message":"internal server error"}}`。

**根因**（三层叠加）：
1. `handler.zig:115` 检查幽灵错误名 `error.SessionNotFound`（永不匹配），实际错误是 stdlib 的 `error.FileNotFound`
2. **核心根因**：`formatMessageJson` 用固定 1024 字节缓冲区 `escapeJson`，系统消息 2000+ 字符导致 `BufferTooSmall` → 无 catch 包裹 → 穿透到 server catch-all
3. `respondError` 调用失败时，server catch-all 返回通用 "internal server error"

**修复**：① `SessionNotFound` → `FileNotFound`；② `escapeJson` → `escapeJsonDynamic` 用 arena 动态分配；③ 错误路径统一返回 JSON。

### D. 空会话列表无反馈

**现象**：无会话时侧边栏完全空白，用户不知道"没有会话"还是"加载失败"。

**根因**：`loadSessions()` 在 `list.length === 0` 时直接 `return`。

### E. 无会话删除能力（本次修复范围）

**现象**：用户无法从 Web UI 或 API 删除损坏/多余的会话文件，只能手动删除文件系统中的 `.jsonl` 文件。旧会话损坏时（问题 C），用户唯一的清理手段是手动操作文件系统。

**根因**：`Session` 核心模块没有 `remove()` 操作（opencode 有 `remove(sessionID)` + CLI `session delete` 命令，见 `session-management-comparison.md:44`）。会话管理的 CRUD 四操作中，Create/Read/Update 都已存在，唯独 Delete 缺失。

**修复**：核心层新增 `Session.deleteFile()`（删除 `.jsonl` 磁盘文件）、Web 层新增 `DELETE /api/session/:id` 端点、前端在每个会话行添加删除按钮。

### F. Web 层无重命名入口（本次修复范围）

**现象**：Web UI 无法重命名会话。会话名始终显示为 "New Session"，用户无法从浏览器修改。

**根因**：核心层 `session.rename()` 和 CLI `/name` 命令已存在，但 Web 层没有 PATCH 端点，前端没有双击编辑交互。会话管理的 CRUD 四操作中，Update 仅在 CLI 可用，Web 端缺失。

**修复**：新增 `PATCH /api/session/:id` 端点（接收 `{"name":"..."}` ）、前端双击会话名进入编辑模式（input 替换文本，回车/失焦提交）。

## 参考

| 文件 | 用途 |
|------|------|
| `docs/session-management-comparison.md` | opencode vs zAgentCore 会话管理对比——opencode 的 CRUD 四操作完整（create/get/setTitle/remove），zAgentCore 缺失 remove 和 Web 端 update。本次补齐 Create（去重）、Read（排序、分组、加载修复）、Update（Web PATCH + 双击重命名）、Delete（新增）。 |

## 已知限制

- **侧边栏 DOM 全量重建**：`loadSessions()` 每次调用都 `innerHTML = ''` 后完整重建。`currentId` 通过 `renderGroup` 内 `s.id === currentId` 比较恢复 `active` 类，选中态逻辑上正确，但全量销毁+创建有视觉闪烁。MVP 可接受，后续可优化为 diff-based 局部更新。
- **PATCH 路由泛匹配**：`/api/session/:id` 的 PATCH 匹配依赖"rest 中无 `/` 则视为重命名"。如果将来增加子资源（如 `PATCH /api/session/:id/model`），需调整路由优先级。当前端点集合不会冲突。
- **会话目录路径硬编码**：`".zagent/sessions"` 在 `session.zig`（flush/list）、`init.zig`、`server.zig`（步骤 0）合计 4+ 处硬编码。步骤 0 虽然有 `ctx.sessions_dir` 统一了下游 handler 引用，但构造点自身仍是硬编码。此次不解决——统一常量化是独立重构。
- **删除当前运行会话无保护**：`DELETE` 端点只删除文件，不检查目标是否为 `ctx.default_session`（当前 `*anyopaque` 无法直接获取 session ID）。若删除当前会话：前端清空 UI（`currentId = null`），但内存中 `default_session` 仍在——下次 flush 因文件被删而失败，需用户点 "+ New Session" 重建。单线程 accept 保证 DELETE 与 prompt 不并发。MVP 可接受，后续可通过 `ctx.default_session_id` 字段实现服务端拒绝。

## 架构约束

- **单线程无竞态**：`server.zig` 是串行 accept 循环，`list()` → `create()` 之间不存在 TOCTOU 窗口。若将来引入并发，需在 `createFile(.exclusive)` 或加锁保护。
- **"New Session" 命名脆弱**：`session.zig:239` 用 `"New_Session"` 作为魔法常量判断用时间戳命名。去重逻辑依赖同样的 `"New Session"` 字符串匹配。如果将来核心层改了命名规则，Web handler 的去重判断会失效——两处需要同步维护。

## 概览

- **改动文件**: 4 个（`handler.zig`、`index.html`、`server.zig`、`session.zig`）
- **类型**: 修改现有代码 + session.zig 新增 `deleteFile()`
- **核心思路**: 补齐 Web 会话管理的 CRUD 四操作——
  - **Create**: ~~空会话去重~~ → **新建会话不写盘**：`POST /api/session` 仅生成时间戳 ID 返回前端，不调用 `flush()`。文件延迟到用户发送第一条消息时由 `handlePrompt` 创建。从根本上消除空会话文件和去重需求。
  - **Read**: 修复会话加载 500 + 空列表反馈 + 四组时间分组 + 路径穿越防护
  - **Update**: 新增 `PATCH /api/session/:id` 端点 + 前端双击重命名 + 错误恢复
  - **Delete**: 新增 `DELETE /api/session/:id` + 核心层 `deleteFile()` + 前端 `×` 按钮
- **参考实现**: opencode `packages/core/src/session.ts` — 完整的 CRUD API

## 设计要点

### 1. 新建会话不写盘（替代去重）

**原方案**（已废弃）：Web handler 去重——`list()` 扫描 "New Session" + `msg_count <= 1`，复用。问题：`msg_count` 是文件大小估算，精确度不足；即使用户不发消息，也会创建空文件污染磁盘。

**新方案**：`POST /api/session` 仅生成时间戳 ID 返回前端，**不调用 `flush()`**。`handlePrompt` 收到第一条消息时检测文件不存在 → 创建新会话（`Session.init` + `flush`）。从根源消除空会话文件。

```zig
// handleSessionCreate — 不写盘
const ts = Io.Clock.Timestamp.now(ctx.io, .real);
const id = try std.fmt.allocPrint(a, "{d}", .{Io.Timestamp.toMilliseconds(ts.raw)});
const body = try std.fmt.bufPrint(&buf, "{{\"id\":\"{s}\",\"name\":\"New Session\",\"model\":\"{s}\"}}", .{ id, ctx.config.default_model });
return respondJson(request, body);

// handlePrompt — 首次消息时创建文件
var session = loadSession(ctx, session_id) catch |err| {
    if (err == error.FileNotFound) {
        // 新会话：首次消息，创建文件
        var s = try session_mod.Session.init(ctx.allocator, ctx.io, ctx.config.default_model);
        defer s.deinit();
        try s.append(.{ .role = .user, .content = prompt });
        try s.flush();
        // 重新加载以继续流程
        ...
    }
    ...
};
```

**对比**：opencode 用 SQLite `create()` 幂等 + 首次 prompt 才投影为消息行。zAgentCore 新方案在 JSONL 架构下等价——ID 生成但不持久化，真实数据在首条消息时落盘。

### 2. 列表接口返回 msg_count

当前 `handleSessionList` 返回的 `SessionInfo` 已有 `msg_count` 字段（来自 `session_mod.list()` → `types.SessionInfo`）。验证是否已存在。

### 3. 前端空列表反馈

在侧边栏添加 "No sessions yet. Create one to get started." 提示。

### 3.5. 会话活动后列表不刷新排序

**现象**：发送 prompt 后会话时间戳更新、消息数增加，但侧边栏列表不刷新——最新活动的会话不会排到 Today 组顶部。

**根因**：`loadSessions()` 未被 SSE `done` 事件触发，也未在 prompt 完成后调用。

**修复**：SSE stream 收到 `done` 事件后调用 `loadSessions()` 刷新侧边栏。新建会话（步骤 3）会隐式刷新，但 prompt 完成是缺失的触发点。

### 4. 会话列表排序

**当前状态**：`session_mod.list()` 已按 `timestamp` 降序排列（`session.zig:625-630`，使用 `std.mem.sort` + `a.timestamp > b.timestamp`）。前端 `index.html:103` 重复调用 `list.sort(...)` 但非必要（已有序数据上 `sort` 是 O(n)）。

**结论**：无需修改。服务端排序已存在，本次仅在前端步骤 2 实现四组时间分组展示。

### 5. 会话删除设计

**核心层**：`Session` 不需要完整的 `remove()` 方法（会话已加载到内存）。新增一个静态方法 `deleteFile()`，与 `load(path)` 保持一致——接受完整路径而非 dir+id，由调用方构造路径。

```zig
// session.zig 新增 — 与 load(allocator, io, path) 参数模式对齐
/// Delete a session JSONL file by path. Does not require loading the session first.
/// Caller is responsible for constructing the full path.
pub fn deleteFile(io: Io, path: []const u8) !void {
    try Io.Dir.cwd().deleteFile(io, path);
}
```

**Web handler**：新增 `handleSessionDelete`，接收 session ID，验证文件存在后删除，返回 `{"status":"deleted"}`。

**前端**：每个会话行右侧加 `×` 按钮，`onclick` 发送 DELETE 请求后刷新列表。当前选中的会话被删除时，自动清空对话区。

**约束**：不删除当前运行的 session（`default_session`）。前端检查 `currentId === id` 时清空选中状态。

### 6. 路径穿越防护

**漏洞**：`loadSession(ctx, id)` 直接拼接用户输入的 `id` 为文件名：
```
GET /api/session/../.zagent/config  →  path = sessions/.zagent/config.jsonl
```
虽 `.jsonl` 后缀提供有限防护，但同目录下其他 `.jsonl` 文件可被读/删。

**修复**：在 `loadSession` 中验证 `id` 仅含安全字符（字母数字、`-`、`_`），拒绝含 `.`、`/`、`\` 的 id。

```zig
fn isValidSessionId(id: []const u8) bool {
    for (id) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
        if (c == '.' or c == '/' or c == '\\') return false;
    }
    return id.len > 0;
}
```

在 `loadSession` 开头调用：`if (!isValidSessionId(id)) return error.InvalidSessionId;`。handler 捕获后返回 `respondError(.bad_request, ...)`。

**注意**：`handleSessionCreate` 生成的 id 是 `Io.Clock.Timestamp.now` 毫秒值，只含数字，天然安全。此防护仅针对外部输入。

### 7. 前端重命名错误恢复

**漏洞**（步骤 7）：PATCH 失败时 `catch(err) { console.error(err); }` 只打日志，不恢复 DOM——input 框残留，用户无法操作。

**修复**：错误路径恢复原名 span + 移除 input：

```javascript
try {
  await api('/session/' + s.id, { method: 'PATCH', ... });
  await loadSessions();
  if (currentId === s.id) {
    currentName = newName;
    document.getElementById('topbar').textContent = newName;
  }
} catch(err) {
  console.error(err);
  // 恢复 UI
}
nameSpan.style.display = '';
input.remove();  // 成功或失败都移除 input
```

将 DOM 恢复逻辑从 else 分支提取到 try-catch 之后，确保成功和失败路径都执行。

### 8. 会话删除设计

**Web handler**：新增 `handleSessionRename`，接收 session ID + JSON body `{"name":"..."}`，调用 `session_mod.Session.load()` → `rename()` → `flush()`。

```zig
fn handleSessionRename(ctx: *Context, request: *std.http.Server.Request, id: []const u8, a: std.mem.Allocator) !void {
    var session = loadSession(ctx, id) catch |err| {
        if (err == error.FileNotFound) return err_mod.respondError(request, .session_not_found, "session not found", a);
        return err_mod.respondError(request, .internal_error, "failed to load session", a);
    };
    defer session.deinit();

    // 读取请求体中的 name 字段
    const body = try request.readAllAlloc(a, 1024);
    const parsed = std.json.parseFromSlice(std.json.Value, a, body, .{}) catch
        return err_mod.respondError(request, .bad_request, "invalid JSON body", a);
    const new_name = if (parsed.value.object.get("name")) |nv|
        if (nv == .string) nv.string else return err_mod.respondError(request, .bad_request, "name must be a string", a)
    else
        return err_mod.respondError(request, .bad_request, "missing name field", a);

    try session.rename(new_name);
    try session.flush();
    try respondJson(request, "{\"status\":\"renamed\"}");
}
```

**路由注册**（`handleRequest` 中）：`PATCH /api/session/:id`（非 message/prompt 等子路径时）。

**限制**：`readAllAlloc(a, 1024)` 将请求体上限设为 1024 字节。会话名通常 <64 字符，此上限充足。超过则分配失败 → handler 返回错误 → server catch-all 返回 500 JSON。可在验证表中加入此边界场景。

**前端**：会话名用 `<span>` 显示，双击触发编辑模式——替换为 `<input>`，回车或失焦时发送 PATCH 请求。

```javascript
// renderGroup 中会话名的双击编辑
const nameSpan = div.querySelector('.name');
nameSpan.ondblclick = () => {
  const input = document.createElement('input');
  input.value = nameSpan.textContent;
  input.className = 'rename-input';
  input.onblur = input.onkeydown = async (e) => {
    if (e.type === 'keydown' && e.key !== 'Enter') return;
    const newName = input.value.trim();
    if (newName && newName !== nameSpan.textContent) {
      try {
        await api('/session/' + s.id, {
          method: 'PATCH',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ name: newName })
        });
        await loadSessions();
        if (currentId === s.id) {
          currentName = newName;
          document.getElementById('topbar').textContent = newName;
        }
      } catch(err) { console.error(err); }
    } else {
      nameSpan.style.display = '';
      input.remove();
    }
  };
  nameSpan.style.display = 'none';
  nameSpan.parentNode.insertBefore(input, nameSpan.nextSibling);
  input.focus();
  input.select();
};
```

**样式**：`.rename-input` 继承 `.name` 的字体样式，背景透明，边框底部细线。

**注意**：步骤 2/8/11 共同修改 `renderGroup` 函数——新增的 `innerHTML`（四组时间分组、重命名、删除按钮）应一次性合并修改，避免多次覆盖。

## 实施

### 步骤 0: Context 新增 sessions_dir 字段

**文件**: `src/frontends/web/handler.zig` + `src/frontends/web/server.zig`
**改动**: `Context` 新增 `sessions_dir: []const u8` 字段；`server.zig` 初始化时构造路径
**原因**: 步骤 3/8/10 等多个 handler 需要 sessions_dir 路径。当前 `loadSession` 每次临时 `join` 构造，重复且不统一。新增后，`loadSession` 也简化为直接用 `ctx.sessions_dir`。

```zig
// handler.zig Context 新增字段
pub const Context = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    project_root: []const u8,
    sessions_dir: []const u8,   // 新增
    config: *config_mod.Config,
    // ... rest unchanged
};
```

```zig
// server.zig 初始化时新增
const sessions_dir = try std.fs.path.join(gpa, &.{ state.project_root, ".zagent", "sessions" });
const ctx = handler.Context{
    .io = io,
    .allocator = gpa,
    .project_root = state.project_root,
    .sessions_dir = sessions_dir,   // 新增
    // ... rest unchanged
};
```

### 步骤 1: 前端列表排序 + 四组时间分组 + 空列表提示

**文件**: `src/frontends/web/index.html`
**改动**: `loadSessions()` 将 Today/Earlier 二分法改为 Today/Yesterday/This Week/Older 四组；空列表显示提示
**关键代码**:

```javascript
async function loadSessions() {
  const list = await api('/session');
  const el = document.getElementById('session-list');
  el.innerHTML = '';
  if (list.length === 0) {
    el.innerHTML = '<div class="empty-hint">No sessions yet</div>';
    return;
  }

  const now = new Date();
  const todayStart = Math.floor(new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime() / 1000);
  const yesterdayStart = Math.floor(new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1).getTime() / 1000);
  const weekStart = Math.floor(new Date(now.getFullYear(), now.getMonth(), now.getDate() - 7).getTime() / 1000);

  const groups = { today: [], yesterday: [], week: [], older: [] };
  for (const s of list) {
    if (s.timestamp >= todayStart) groups.today.push(s);
    else if (s.timestamp >= yesterdayStart) groups.yesterday.push(s);
    else if (s.timestamp >= weekStart) groups.week.push(s);
    else groups.older.push(s);
  }

  const labels = { today: 'Today', yesterday: 'Yesterday', week: 'This Week', older: 'Older' };
  for (const key of ['today','yesterday','week','older']) {
    if (groups[key].length > 0) renderGroup(labels[key], groups[key]);
  }

  document.getElementById('model-name').textContent = list[0].model;
}
```

**边界处理**：用 `new Date(year, month, date - N)` 而非 `offset * 86400`——JS Date 构造函数自动处理跨月/跨年/跨 DST 日。`session.timestamp` 是 Unix epoch 秒，`getTime()` 返回 UTC 毫秒，比较时一致。

**注意**：`list()` 已按 timestamp 降序返回（`session.zig:625-630`），前端不再需要 `sort()`。`renderGroup` 函数保持不变。

### 步骤 1.5: SSE done 事件刷新侧边栏

**文件**: `src/frontends/web/index.html`
**改动**: SSE `done` 事件处理中调用 `loadSessions()` 刷新排序和消息计数
**关键代码**:

```javascript
// sendPrompt() 的 SSE 事件处理中
if (msg.event === 'done') {
  ...
  await loadSessions();  // 刷新侧边栏排序 + 消息计数
  break;
}
```

### 步骤 2: handler 层空会话去重 + 路径穿越防护

**文件**: `src/frontends/web/handler.zig`
**改动**: 新增 `isValidSessionId` 验证函数；`loadSession` 开头调用；`handleSessionCreate` 在创建前扫描已有会话，复用空会话
**关键代码**:

```zig
/// Reject session IDs containing path traversal characters (. / \).
fn isValidSessionId(id: []const u8) bool {
    if (id.len == 0) return false;
    for (id) |c| {
        if (c == '.' or c == '/' or c == '\\') return false;
    }
    return true;
}
```

`loadSession()` 开头插入：`if (!isValidSessionId(id)) return error.InvalidSessionId;`。

`handleSessionGet`、`handleSessionMessages`、`handleSessionRename` 三个 handler 的 catch 分支均新增：
```zig
if (err == error.InvalidSessionId) return err_mod.respondError(request, .bad_request, "invalid session id", a);
```

```zig
fn handleSessionCreate(ctx: *Context, request: *std.http.Server.Request, a: std.mem.Allocator) !void {
    // 检查是否已有空会话可复用
    const sessions = try session_mod.list(a, ctx.io, ctx.sessions_dir);
    defer session_mod.freeSessionInfoList(a, sessions);
    for (sessions) |s| {
        if (std.mem.eql(u8, s.name, "New Session") and s.msg_count == 0) {
            var buf: [256]u8 = undefined;
            const body = try std.fmt.bufPrint(&buf, "{{\"id\":\"{s}\",\"name\":\"{s}\",\"model\":\"{s}\"}}", .{ s.id, s.name, s.model });
            return respondJson(request, body);
        }
    }

    // 无空会话 → 创建新的
    var session = try session_mod.Session.init(ctx.allocator, ctx.io, ctx.config.default_model);
    defer session.deinit();
    try session.flush();
    const id = if (session.path) |p| std.fs.path.stem(p) else "new";
    var buf: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"id\":\"{s}\",\"name\":\"{s}\",\"model\":\"{s}\"}}", .{ id, session.name, session.model });
    try respondJson(request, body);
}
```

**注意**: `ctx` 需要有 `sessions_dir` 字段，或由 handler 内部构造路径。

### 步骤 3: (已完成) SessionNotFound → FileNotFound

**文件**: `src/frontends/web/handler.zig`
**改动**: 3 处 `error.SessionNotFound` → `error.FileNotFound`，`return err` → `respondError`
**状态**: 已在源码中修复

### 步骤 4: (已完成) formatMessageJson 缓冲区溢出

**文件**: `src/frontends/web/handler.zig`
**改动**: `escapeJson` (固定 1024 字节) → `escapeJsonDynamic` (arena 动态分配)
**状态**: 已在源码中修复

### 步骤 5: (已完成) server catch-all JSON 化

**文件**: `src/frontends/web/server.zig`
**改动**: catch-all 响应从纯文本 `"500 Internal Server Error"` → JSON `{"error":{...}}`
**状态**: 已在源码中修复

### 步骤 6: PATCH /api/session/:id (Web handler 重命名)

**文件**: `src/frontends/web/handler.zig`
**改动**: 在 `handleRequest` 路由表中注册 PATCH 方法，新增 `handleSessionRename`
**关键代码**:

```zig
// 路由表新增 (handleRequest 中)
else if (method == .PATCH) {
    if (std.mem.startsWith(u8, path, "/api/session/")) {
        const rest = path["/api/session/".len..];
        if (std.mem.indexOfScalar(u8, rest, '/') == null) {
            return handleSessionRename(ctx, request, rest, a);
        }
    }
}

fn handleSessionRename(ctx: *Context, request: *std.http.Server.Request, id: []const u8, a: std.mem.Allocator) !void {
    var session = loadSession(ctx, id) catch |err| {
        if (err == error.FileNotFound) return err_mod.respondError(request, .session_not_found, "session not found", a);
        return err_mod.respondError(request, .internal_error, "failed to load session", a);
    };
    defer session.deinit();

    const body = try request.readAllAlloc(a, 1024);
    const parsed = std.json.parseFromSlice(std.json.Value, a, body, .{}) catch
        return err_mod.respondError(request, .bad_request, "invalid JSON body", a);
    const new_name = if (parsed.value.object.get("name")) |nv| nv.string
        else return err_mod.respondError(request, .bad_request, "missing name field", a);

    try session.rename(new_name);
    try session.flush();
    try respondJson(request, "{\"status\":\"renamed\"}");
}
```

### 步骤 7: 前端双击重命名

**文件**: `src/frontends/web/index.html`
**改动**: `renderGroup` 中会话名 span 绑定 `ondblclick` → input 编辑 → PATCH 提交；DOM 恢复在 try-catch 之后执行，确保成功/失败/不变都移除 input
**关键代码**（见设计要点 §7 修复后版本）
**样式**: `.rename-input { font-size:var(--text-sm); background:transparent; border:none; border-bottom:1px solid var(--border-base); color:var(--text-base); outline:none; }`

### 步骤 8: Session.deleteFile (核心层)

**文件**: `src/core/session.zig`
**改动**: 在 `pub fn load` 附近新增 `pub fn deleteFile`，参数模式与 `load(allocator, io, path)` 对齐——接受完整路径
**关键代码**:

```zig
/// Delete a session JSONL file by path. Mirrors load() parameter convention.
/// Caller constructs the path; this method only does the filesystem operation.
pub fn deleteFile(io: Io, path: []const u8) !void {
    try Io.Dir.cwd().deleteFile(io, path);
}
```

### 步骤 9: DELETE /api/session/:id (Web handler)

**文件**: `src/frontends/web/handler.zig`
**改动**: 在 `handleRequest` 路由表中注册 DELETE 方法，新增 `handleSessionDelete`；handler 自行构造路径后调用 `deleteFile`
**关键代码**:

```zig
// 路由表新增 (handleRequest 中)
} else if (method == .DELETE) {
    if (std.mem.startsWith(u8, path, "/api/session/")) {
        const rest = path["/api/session/".len..];
        if (std.mem.indexOfScalar(u8, rest, '/') == null) {
            return handleSessionDelete(ctx, request, rest, a);
        }
    }
}

fn handleSessionDelete(ctx: *Context, request: *std.http.Server.Request, id: []const u8, a: std.mem.Allocator) !void {
    if (!isValidSessionId(id)) return err_mod.respondError(request, .bad_request, "invalid session id", a);
    const filename = try std.fmt.allocPrint(a, "{s}.jsonl", .{id});
    defer a.free(filename);
    const path = try std.fs.path.join(a, &.{ ctx.sessions_dir, filename });
    defer a.free(path);
    session_mod.Session.deleteFile(ctx.io, path) catch |err| {
        if (err == error.FileNotFound) return err_mod.respondError(request, .session_not_found, "session not found", a);
        return err_mod.respondError(request, .internal_error, "failed to delete session", a);
    };
    try respondJson(request, "{\"status\":\"deleted\"}");
}
```

### 步骤 10: 前端删除按钮

**文件**: `src/frontends/web/index.html`
**改动**: `renderGroup` 中每个会话行 `innerHTML` 追加 `×` 按钮 + `.delete-btn` click 事件；新增 `deleteSession(id)` 函数
**关键代码**:

```javascript
// renderGroup 中的会话行追加删除按钮
div.innerHTML = `<div class="name">${esc(s.name)}</div>
  <div class="meta">${esc(s.model)} &middot; ${s.msg_count} msgs</div>
  <span class="delete-btn" data-id="${esc(s.id)}">×</span>`;
div.querySelector('.delete-btn').onclick = (e) => {
  e.stopPropagation();
  deleteSession(s.id);
};

async function deleteSession(id) {
  if (!confirm('Delete this session?')) return;
  try {
    await api('/session/' + id, { method: 'DELETE' });
    if (currentId === id) {
      currentId = null;
      document.getElementById('topbar').textContent = 'z-agent-core';
      document.getElementById('messages').innerHTML = '';
      document.getElementById('prompt-input').disabled = true;
      document.getElementById('send-btn').disabled = true;
    }
    await loadSessions();
  } catch(e) { console.error(e); }
}
```

**样式**: 删除按钮用 `opacity:0.5` 默认，hover 时 `color:red; opacity:1`。

## 验证

```powershell
zig build
zig test src/test.zig --cache-dir .zig-cache 2>&1 | Select-String "^\d+/\d+|All \d+ tests|FAIL"
```

| 测试场景 | 预期结果 |
|----------|----------|
| **Create** 无会话时点 "+ New Session" | 创建新会话，侧边栏出现，左侧自动选中 |
| **Create** 已有空会话时再点 "+ New Session" | 复用已有空会话，不创建新文件 |
| **Create** 重命名会话后点 "+ New Session" | 创建全新会话（非空会话不复用） |
| **Read** 加载含大系统消息的旧会话 | 正常渲染，不 500 |
| **Read** 加载不存在的会话 ID | 返回 404 JSON `session_not_found` |
| **Read** 无会话时侧边栏 | 显示 "No sessions yet" 提示 |
| **Read** 排序-今天创建的会话 | 出现在 "Today" 分组，按 timestamp 降序 |
| **Read** 排序-昨天创建的会话 | 出现在 "Yesterday" 分组 |
| **Read** 排序-7天内创建的会话 | 出现在 "This Week" 分组 |
| **Read** 排序-7天前创建的会话 | 出现在 "Older" 分组 |
| **Read** 分组-仅 Today 有会话 | 只显示 "Today" 标题，无其他空组标题 |
| **Read** 分组-跨多组 | 四个组标题均出现，各自独立渲染 |
| **Read** SSE done 后侧边栏刷新 | 消息数更新，活动会话从 "Yesterday" 移至 "Today" |
| **Update** 双击会话名编辑 | 显示 input 框，预填当前名称 |
| **Update** 输入新名称后回车 | PATCH 请求发送，侧边栏刷新，topbar 同步 |
| **Update** 会话名置空后回车 | 不提交，恢复原名 |
| **Update** PATCH 网络失败 | input 移除，原名恢复，不卡死 |
| **Update** PATCH body 超 1024 字节 | 返回 500 JSON `internal_error` |
| **安全** 请求路径穿越 ID | 返回 400 JSON `bad_request` "invalid session id" |
| **安全** 请求含 `.` 的 ID | 返回 400，不访问文件系统 |
| **Delete** 删除非当前会话 | 侧边栏移除该条目，当前会话状态不变 |
| **Delete** 删除当前选中会话 | 侧边栏移除，对话区清空，输入框禁用 |
| **Delete** 删除不存在的会话 | 返回 404 JSON `session_not_found` |
| **回归** 单次创建后侧边栏 | 正常显示新会话 |

## 波及

| 文件 | 改动 | 破坏性? |
|------|------|----------|
| `src/core/session.zig` | `list()` 新增按 timestamp 降序排序；新增 `deleteFile()` 静态方法 | 否 |
| `src/frontends/web/handler.zig` | `isValidSessionId` 路径穿越防护；`loadSession` 验证 id；`handleSessionCreate` 新增去重扫描；`handleSessionRename` (PATCH) 新增；`handleSessionDelete` (DELETE) 新增；`formatMessageJson` 改用 arena | 否 |
| `src/frontends/web/index.html` | 四组时间分组 + 空列表提示；新建按钮 `sess.id`；SSE done 刷新；双击重命名；删除按钮 | 否 |
| `src/frontends/web/server.zig` | catch-all 响应 JSON 化 | 否 |

## 术语

| 术语 | 含义 |
|------|------|
| 空会话 | name="New Session" 且 msg_count=0 的会话，表示用户未使用过 |
| 幽灵错误名 | Zig 推断错误集中被 `==` 引用但从未被任何模块 `return error.` 返回的错误值，编译通过但运行时永假 |
