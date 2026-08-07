# Plan FUTURE-SESSION: 会话系统后续优化

## 状态: 占位

## 前置依赖

| 阻塞者 | 状态 | 被阻塞 |
|--------|------|--------|
| `PLAN-FIX-WEB-SESSION-ISSUES` | 已完成 (v0.2.3) | 全部条目 |

## 条目

### P1: 会话删除 CLI 命令

**现状**：Web 有 `DELETE /api/session/:id`，CLI 无 `/delete` 命令。

**方案**：REPL 新增 `/delete <id>` 指令 → `Session.deleteFile()` + 侧边 `listSessions()` 刷新。

### P1: 会话目录路径常量化

**现状**：`".zagent/sessions"` 在 `session.zig`、`init.zig`、`server.zig` 合计 4+ 处硬编码。

**方案**：`session.zig` 顶层 `pub const sessions_subdir = ".zagent/sessions"`，所有引用点统一使用。

### P1: 删除当前运行会话保护

**现状**：`DELETE` 不检查目标是否为 `default_session`。文件被删后内存 session 残留，下次 flush 失败。

**方案**：`Context` 新增 `default_session_id: []const u8`，`handleSessionDelete` 检查并拒绝。

### P2: 侧边栏 DOM diff 更新

**现状**：`loadSessions()` 每次 `innerHTML = ''` 全量重建，视觉闪烁。

**方案**：基于 `s.id` 做局部 patch——新增/删除/更新条目，保留未变动的 DOM 节点。

### P2: 会话列表分页

**现状**：`GET /api/session` 全量返回。会话数 >100 时带宽浪费。

**方案**：核心层 `list(offset, limit)` → 游标分页。Web API 增加 `?after=<timestamp>&limit=20` 参数。

### P2: 冒烟测试

**现状**：Web 前端无自动化测试，全部依赖手动验证。

**方案**：`test "web: session CRUD roundtrip"` — 创建 → 加载 → 重命名 → 删除，验证 HTTP 状态码和 JSON 结构。

## 术语

| 术语 | 含义 |
|------|------|
| UUID v4 | RFC 9562，基于随机数的 128 位唯一标识符，格式 `8-4-4-4-12` |
