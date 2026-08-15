# Plan N15-WEB-FEATURES: Web 输入历史 + 导出对话

## 状态: 已完成（2026-08-16）

## 前置依赖

| 阻塞者 | 状态 | 说明 |
|--------|------|------|
| 无 | — | REMAINING N15 自 P2，DESIGN-WEB-RENDER §待实现表审计登记 |

## 需求

REMAINING.md N15（P2）：Web 待实现 5 件中的前 2 件。

- **输入历史**：上下箭头导航已发送 prompt（app.js 无 inputHistory）
- **导出对话**：`GET /api/session/:id/export`（handler 无端点）+ 前端按钮

多会话标签页 / 消息编辑 / 输入框响应式高度本期不做。

## 设计要点

### 功能 A — 输入历史（纯前端，可 Node 测试）

**状态模型**（app.js 模块级）：

```js
var promptHistory = { entries: [], cursor: -1, draft: null };
```

- `entries`：已发送 prompt 数组（trim 非空；与末条相同跳过）
- `cursor`：`-1` = 新输入位置；`>=0` = 正在查看第 cursor 条历史
- `draft`：首次 Up 时保存的当前输入内容，Down 回到底时恢复

**纯函数**（测试用括号匹配提取，模式同 buildSegment）：

- `promptHistoryPush(state, text)` → 新 state（immutable 返回，不就地改）
- `promptHistoryUp(state, currentValue)` → `{state, value}`；`value` 为 null 表示无可导航（空历史）
- `promptHistoryDown(state)` → `{state, value}`

行为表：

| 操作 | cursor 条件 | 结果 |
|------|------------|------|
| Up | entries 空 | value null，状态不变 |
| Up | cursor == -1 | 存 draft=currentValue，cursor=n-1，value=entries[n-1] |
| Up | cursor > 0 | cursor--，value=entries[cursor] |
| Up | cursor == 0 | 状态不变，value=entries[0] |
| Down | entries 空 或 cursor == -1 | value null，状态不变 |
| Down | cursor == n-1 | cursor=-1，value=draft（null/空 → null） |
| Down | 其余 | cursor++，value=entries[cursor] |

**keydown 集成**（app.js:1752-1783）：ArrowUp/ArrowDown 分支保持 `slashVisible` 优先（现有逻辑不动）；未显示 slash 时走历史导航。

**guard 标志**：程序化设置 `input.value` 会触发 `input` 事件（app.js:1785），前置 `historyNavGuard = true`；input 事件见 guard 即清除并 return，避免程序赋值被当成"手动编辑"重置 cursor。`applyHistoryValue`（app.js:1731）另加 `setTimeout` 双保险：浏览器跳过 input 事件（同值赋值）时 guard 也会在下一 task 清除，防 stale guard 吞真实按键。手动输入（无 guard）且 `cursor !== -1` → cursor 重置为 -1（编辑即退出历史导航）。

**发送记录**：`sendPrompt(prompt)`（app.js:1391）入口 `promptHistory = promptHistoryPush(promptHistory, prompt)`。slash 命令走 `executeSlashCommand` 不经 sendPrompt，不记录（与"用户消息"语义一致）。

### 功能 B — 导出对话

**后端** `GET /api/session/:id/export`：

- 路由（handler.zig:93-107 GET 分发，`export` 分支在 102）加 `sub_path == "export"` → `handleSessionExport(ctx, request, id, a)`（handler.zig:469）
- 复用 `loadSession` + `writeMessagesRange` + `formatMessageJson`（handler.zig:1307）全量序列化，与 handleSessionGet 同构（无分页）
- 响应：`{"name":..., "model":..., "exported_at":<unix-秒>, "messages":[...]}`，`respondJson` 输出
- `exported_at` 用项目惯例 `Io.Clock.Timestamp.now(io, .real)` + `Io.Timestamp.toSeconds`（方案初稿引用的 `std.time.milliTimestamp()` 在 0.16 已移除，见偏差记录）

**前端**：

- more-menu 加 Export 项（两处会话列表渲染点：app.js:582、682）：`<div class="more-item" data-act="export">Export</div>`
- more-item 处理（app.js:712-722）加 `else if (act === 'export') exportSession(s);`
- `exportSession(s)`（app.js:2022）：`fetch(A + '/session/' + s.id + '/export')` → `r.text()` → `JSON.parse` + `JSON.stringify(_, null, 2)` pretty → Blob → `<a download>` 触发下载（服务器序列化器保持紧凑，格式化在浏览器 JSON 引擎做）；下载文件名 `sessionExportFileName(s)`（app.js:2009，见实施表）；失败 `showStatus(msg, true)`

## 实施

| 文件 | 改动 |
|------|------|
| `src/frontends/web/app.js` | 3 个纯函数（promptHistoryPush/Up/Down）+ historyNavGuard + applyHistoryValue + keydown ArrowUp/Down 分支 + input 事件 guard + sendPrompt push + more-menu Export 项 ×2 + sessionExportFileName + exportSession |
| `src/frontends/web/handler.zig` | GET 路由加 export + handleSessionExport（复用 loadSession/writeMessagesRange/formatMessageJson） |
| `tests/frontend/test-history-nav.mjs` | 新增：push 空/去重、Up 首存 draft/边界、Down 回 draft/底部 no-op、空历史 no-op |
| `tests/frontend/test-export-name.mjs` | 新增：`sessionExportFileName` sanitize（非法字符替换/首尾点空格/截断 100）/uuid 与空名回退 id |

测试（前端 13 → 15 文件；Zig 既有 325 条全量回归，handleSessionExport 与 handleSessionGet 同构、依赖真实文件 IO 不做单测）：

- `promptHistoryPush`：空串跳过、尾重复跳过、正常追加、cursor 重置为 -1
- `promptHistoryUp`：空历史 null、首次 Up 存 draft 取末条、连续 Up 递减、cursor==0 no-op
- `promptHistoryDown`：cursor==-1 no-op、末条回 draft、中途 Down 递增
- `sessionExportFileName`：正常名/中文名保留、非法字符 `_`、首尾点空格剥离、300 字符截断 100、uuid（大小写）与空/空白/缺失名回退 `session-<id>.json`、全非法 sanitize 后空回退

## 验证

- `node tests/frontend/run-tests.mjs` → All 15 file(s) passed
- `zig test src/test.zig --cache-dir .zig-cache` → All 325 tests passed
- `zig build` + `zig build -Doptimize=ReleaseSafe` 编译通过
- 实机验证：57 条真实会话 export 输出合法 JSON，与 `GET /api/session/:id` 逐消息字节一致（python 严格解析 + 对比）
- 手动浏览器验证：发送 3 条 → Up/Up/Down 导航正确；编辑即退出导航；导出按钮下载 pretty JSON（118KB→124KB 含缩进）

## 偏差记录

| 设计稿 | 实际实现 | 原因 |
|--------|---------|------|
| `exported_at` 用 `std.time.milliTimestamp()`（unix-ms） | `Io.Clock.Timestamp.now(io, .real)` + `toSeconds`（unix 秒） | `milliTimestamp` 在 Zig 0.16 已移除（common-traps:26），方案阶段复查漏查；改项目惯例 API |
| `a.download = 'session-' + s.id + '.json'` | `sessionExportFileName(s)`：sanitize 会话名，uuid/空名回退 id | 用户需求补充：下载后无需重命名即可识别内容 |
| 导出 wire 格式（设计稿未明示） | 服务器紧凑 JSON，前端 pretty（2 空格缩进） | jsonw 为紧凑序列化器（F7 收敛核心），格式化放浏览器 JSON 引擎，零后端成本 |
| `exportSession` 下载 `r.blob()` | `r.text()` + `JSON.parse`/`stringify` 后重建 Blob | 同上（pretty 前置步骤） |
