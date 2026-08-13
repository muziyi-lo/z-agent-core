# Plan SESSION-UI-FINAL: 会话系统收尾（前端操作 + 侧边栏性能 + 崩溃恢复）

## 状态: 计划中

## 问题

**现象**：
1. Web 端 fork/reset 只有 slash 命令（`/fork`、`/reset`），无显式 UI 按钮，用户不可发现
2. 侧边栏 `loadSessions()` 每次全量重建 DOM，分支树递归全展开，会话多时闪烁 + 占满空间
3. 会话列表无分页，`GET /api/session` 全量返回
4. 崩溃后 `{path}.tmp` 残留（`session.flush` 的 tmp+rename 中断），下次可能复用污染

**根因**：
1. `handleCommandExec` 的 fork/reset 逻辑已实现（`handler.zig:564-577`），但前端 `slashLocal`（app.js:1149）无对应按钮；无独立 REST 端点
2. `loadSessions`（app.js:311-338）`innerHTML=''` 全量重建；`renderChildren`（app.js:408）无收起状态
3. `session.zig:764 list()` 无 limit/after 参数
4. `flush` 的 tmp 清理是 `defer`（正常路径），崩溃中断则残留

## 概览

- 涉及 3 模块：`core/session.zig`、`web/handler.zig`、`web/app.js`（+ `app.css`）
- 新增：fork/reset REST 端点、侧边栏收起、列表分页、tmp 清理
- 一句话思路：**前端可发现性（按钮）→ 侧边栏性能（diff + 收起 + 分页）→ 数据容错（tmp 清理）**，三段独立可发、同属会话系统收尾
- 参照：opencode `SessionPrompt` 的分支 UI + `createAutoScroll` 状态持久化先例

## 前置依赖

| 阻塞者 | 状态 | 被阻塞 |
|--------|------|--------|
| 无 | — | — |

## 设计要点

### D1 — N1：Fork/Reset 双通道（前端按钮 + REST 端点）

**现状**：`handleCommandExec` 的 fork/reset 走 `POST /api/command`（`handler.zig:564-577`），前端 slash 输入可用但无 UI 入口；无独立 REST 端点。

**方案**：**REST 端点为主通道，command 保留兼容**（slash 输入继续可用）：

| 端点 | 方法 | 说明 |
|------|------|------|
| `PATCH /api/session/:id/fork` | body `{name?: string}` | fork 当前会话，`session_ops.fork` 复用；返回 `{session_id, name}` |
| `PATCH /api/session/:id/reset` | 无 body | 清空会话消息，`session_ops.reset` + flush；返回 `{status:"ok"}` |

- 前端 **more-menu 增 Fork/Reset 两项**（`app.js:352` more-menu 已含 rename/pin/delete，追加两项）
- Fork 点击 → 弹内联输入框（复用 rename 的 `input` 模式，`app.js:380-401`）→ PATCH fork → `switchToSession`（app.js:1279）
- Reset 点击 → `confirm()` 二次确认 → PATCH reset → `loadSessions`
- **守卫对齐**：`isSessionStreaming`（`handler.zig:882`）拒绝流式中操作；fork 命名冲突复用 `error.SessionAlreadyExists`
- **command 通道保留**：`handleCommandExec` 的 fork/reset 分支改为转发到新端点逻辑（抽共享 `handleFork`/`handleReset` 函数，避免双实现漂移）

> **为什么保留 command**：`/fork`、`/reset` slash 命令已在 command 注册表（`command.zig builtin`），Web slash popover 从 `GET /api/command` 自动列出。保留兼容零成本，且 CLI 侧 `/fork` 独立存在不受影响。

### D2 — N3a：侧边栏 DOM diff（含分支树收起）

**现状**：`loadSessions` 全量重建；`renderChildren` 递归无收起。

**方案**：`loadSessions` 改为**增量 patch**，核心是 `sessionKey`（id）+ 收起状态：

- **DOM 定位**：会话条目 `div.session` 加 `data-session-id` 属性（`app.js:344` 追加），diff 时按 id 查找既有节点
- **增量策略**：
  - 新增：`list` 有但 DOM 无 → `renderItem` 创建并插入正确分组/位置
  - 删除：DOM 有但 `list` 无 → `remove()`
  - 更新：标题/msg_count/model 变化 → 更新该节点文本（不重建）
  - 未变：跳过
- **收起**：父会话条目加 `▸/▾` 折叠按钮（`data-has-children` 时显示）：
  - 收起 → `childrenMap[parentId]` 对应子树 `display:none`（或从 DOM 移除）
  - **状态持久化**：`localStorage['zagent-collapsed']` = JSON 数组 of session ids
  - 展开/收起切换只重渲染该子树，不重建整树

> **为什么收起状态必须持久化**：`loadSessions` 在每次 prompt done、rename、delete 后触发（app.js 多处）。若收起状态不持久化，任何刷新/操作都回到全展开，用户折叠选择丢失。

**边界**：孤儿分支（父已删）提升到顶层（现有逻辑 `app.js:324-334` 保留）；收起父时其下所有深度后代一并收起（`renderChildren` 递归判断）。

### D3 — N3b：会话列表分页

**现状**：`session.zig:764 list()` 全量返回；`GET /api/session`（handler.zig:270 附近）无分页。

**方案**：
- `session.zig list()` 增可选参数：`list(allocator, io, session_dir, limit: ?usize, after_ts: ?i64)` → 返回最近 `limit` 条且 `timestamp < after_ts` 的会话
- `GET /api/session?limit=N&after=<ts>` → 分页响应 `{sessions: [...], has_more}`
- 前端 `loadSessions` 首次加载 `limit=50`，滚动到侧边栏底部附近 → 增量加载更早会话（`after` = 当前最早 timestamp）

> **游标用 timestamp 而非 id**：会话列表按 `timestamp desc` 排序（list 现状），分页游标天然是 timestamp；消息分页才用 id（已 id 化）。侧边栏加载用**追加**而非全量——与 D2 的增量 patch 兼容（追加 = 纯新增节点）。

**交互**：`#session-list` 滚动监听（`scroll` 事件），接近底部 `threshold=100px` 触发加载更早；加载中置 `loading` 标志防重复。

### D4 — F5：崩溃恢复（tmp 残留清理）

**现状**：`session.flush` 的 tmp 清理是正常路径 `defer`（`session.zig:419`），崩溃中断则 `{path}.tmp` 残留；下次 flush 复用 `{path}.tmp`（`session.zig:416`）覆盖旧 tmp，无数据污染但残留文件累积。

**方案**：
- **启动清理**：`init.zig`（`init_mod.init`）在确定 `sessions_dir` 后，扫描目录删除 `*.jsonl.tmp` 残留（崩溃孤儿）
- 清理在 `init` 内执行（CLI/Web 共用 `init_mod.init`，`frontends/init.zig:100` 后），一次性、低开销
- **不做**：文件损坏自动修复（`Session.load` 已跳过坏行，`session.zig:103` 起）、`.tmp` 半写内容恢复（tmp 是完整新文件，rename 前崩溃则旧文件完好，直接删 tmp 即恢复）

> **为什么 tmp 残留值得清**：崩溃是真实场景（本次 `std.http` 裸 POST panic 已演示），残留 tmp 占用磁盘 + 混淆目录。删除 tmp 即可恢复（tmp 与正式文件原子替换，不删也不影响正确性，但堆积）。

## 实施

### 步骤 1: fork/reset REST 端点 + 共享逻辑

**文件**: `src/frontends/web/handler.zig`
**改动**: 抽 `handleFork`/`handleReset`（从 `handleCommandExec:564-577` 提取），新增 PATCH 路由；`handleCommandExec` 转发
**关键代码**:

```zig
// handleRequest PATCH 分支（handler.zig:113 附近）
} else if (method == .PATCH) {
    if (std.mem.startsWith(u8, path, "/api/session/")) {
        const rest = path["/api/session/".len..];
        // parse id + sub = "fork" | "reset"
    }
}
```

**注意**: PATCH 路由需处理 `/api/session/:id/fork` 与 `/reset` 两个 sub；守卫 `isSessionStreaming` 一致；fork 返回 session_id 供前端切换

### 步骤 2: 前端 more-menu Fork/Reset 按钮

**文件**: `src/frontends/web/app.js` + `app.css`
**改动**: more-menu 追加 Fork/Reset 项；Fork 弹输入框（复用 rename 模式）、Reset 用 `confirm()`；调用 PATCH 端点
**注意**: fork 成功后 `switchToSession`（app.js:1279）；reset 后 `loadSessions`；流式中禁用（`isStreaming` 前端标志）

### 步骤 3: 侧边栏 DOM diff + 收起

**文件**: `src/frontends/web/app.js` + `app.css`
**改动**: `loadSessions` 重写为增量 patch；`data-session-id` 定位；`localStorage` 收起状态；`renderChildren` 支持收起
**关键代码**:

```js
// 收起状态读写
var collapsed = JSON.parse(localStorage.getItem('zagent-collapsed') || '[]');
function isCollapsed(id) { return collapsed.indexOf(id) !== -1; }
function toggleCollapse(id) {
  var i = collapsed.indexOf(id);
  if (i === -1) collapsed.push(id); else collapsed.splice(i, 1);
  localStorage.setItem('zagent-collapsed', JSON.stringify(collapsed));
}
```

**注意**: diff 必须处理分组（Pinned/Today/Yesterday/...）变化——分组 header 与条目一起增量；收起父时子树隐藏

### 步骤 4: 会话列表分页

**文件**: `src/core/session.zig` + `web/handler.zig` + `web/app.js`
**改动**: `list` 增 limit/after；`GET /api/session` 增分页参数与响应；前端滚动增量加载
**注意**: 兼容无分页参数（全量返回，保持 `N2` 兼容）；`has_more` 判断；追加加载时保持收起状态

### 步骤 5: tmp 残留清理

**文件**: `src/frontends/init.zig`
**改动**: `init` 确定 `sessions_dir` 后扫描删除 `*.jsonl.tmp`
**关键代码**:

```zig
// init.zig 在 session_dir join 之后（frontends/init.zig:100 附近）
var it = Io.Dir.cwd().iterate();
while (it.next(io) catch null) |entry| {
    if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".jsonl.tmp")) {
        Io.Dir.cwd().deleteFile(io, join(session_dir, entry.name)) catch {};
    }
}
```

**注意**: 目录可能不存在（首启）→ `iterate` 惰性 + `next(io) catch null` 跳过（对齐 `session.zig:777-778` 既有模式，Zig 0.16 `Io.Dir.iterate()` 无参、`next(io)` 返回 `!?Entry`）；不递归子目录

### 步骤 6: 测试

**文件**: `src/core/session.zig`、`src/frontends/web/handler.zig`、`tests/frontend/`
**改动**: `list` 分页单测（limit/after/has_more）；`handleFork`/`handleReset` 单测（复用 handler 测试模式）；`tmp 清理` 单测（造 `.jsonl.tmp` → init → 消失）；前端 Node 测试适配 `loadSessions` 新逻辑（若测试引用旧全量重建行为需更新）
**注意**: handler 测试用 `testing.io`（无子进程）——fork/reset 无 LLM 调用，可测

## 验证

```powershell
zig build
zig test src/test.zig --cache-dir .zig-cache 2>&1 | Select-String "^\d+/\d+|All \d+ tests|FAIL"
node tests/frontend/run-tests.mjs
node ..\.opencode\skills\zig-dev\scripts\check-catch-silent.mjs . --audit
```

| 测试场景 | 预期结果 |
|----------|----------|
| Web 会话 more-menu 点 Fork | 弹输入框 → 确认 → 新会话出现在侧边栏（`(fork #N)`）→ 自动切换 |
| Web 会话 more-menu 点 Reset | `confirm()` → 会话消息清空（保留系统提示词）→ 侧边栏刷新 |
| 流式会话 Fork/Reset | `agent_busy` 拒绝（isSessionStreaming） |
| slash `/fork` `/reset` | 兼容保留（command 通道转发新逻辑） |
| 侧边栏收起父会话 | 子树隐藏；刷新/操作后**收起状态保持**（localStorage） |
| 侧边栏会话多 | 只更新变化的条目，无全量闪烁 |
| 孤儿分支（父已删） | 提升顶层（既有逻辑），收起状态不受影响 |
| 会话列表 >50 | 首屏 50 + 滚动到底加载更早，`has_more` 正确 |
| 无分页参数 `GET /api/session` | 全量返回（兼容） |
| 崩溃后残留 `.jsonl.tmp` | 启动清理删除；无 tmp 时启动正常 |
| fork 命名冲突 | `error.SessionAlreadyExists` → 400 提示 |
| 分页与收起共存 | 追加加载更早会话时，已收起父的子树保持收起 |

## 波及

| 文件 | 改动 | 破坏性? |
|------|------|----------|
| `src/frontends/web/handler.zig` | fork/reset PATCH 端点 + 抽共享函数 | 否（command 保留） |
| `src/frontends/web/app.js` | more-menu 按钮 + loadSessions diff + 收起 + 分页加载 | 是（loadSessions 重写，前端测试需适配） |
| `src/frontends/web/app.css` | 收起按钮样式、diff 过渡 | 否 |
| `src/core/session.zig` | `list` 增 limit/after | 否（默认全量） |
| `src/frontends/init.zig` | tmp 残留清理 | 否 |
| `tests/frontend/*` | loadSessions 相关测试适配 | 是 |

## 明确不做

- **undo 栈持久化**：撤销窗口重启丢失可接受（对齐 opencode 内存 undo）；崩溃恢复聚焦消息层（F5 已定）
- **会话文件损坏自动修复**：`load` 已跳坏行，不做逐行重建
- **`.tmp` 半写内容恢复**：tmp 是完整新文件，rename 前崩溃则旧文件完好，删 tmp 即恢复
- **侧边栏虚拟滚动**：分页 + 收起已控规模，DOM diff 足够
- **消息级无限滚动**：`GET /session/:id?limit=50` 已有游标分页（一期 P3），本次只做会话列表级

## 术语

| 术语 | 含义 |
|------|------|
| more-menu | 侧边栏每条会话的"⋮"更多操作菜单（rename/pin/delete/Fork/Reset） |
| DOM diff | 对比新旧列表差异，只更新变化的 DOM 节点（vs 全量 `innerHTML` 重建） |
| 收起（collapse） | 分支树父节点折叠其子分支，状态存 localStorage |
| 游标分页 | 基于排序字段（timestamp/id）定位"取此之前 N 条"的分页方式 |
| tmp 残留 | `session.flush` 的 tmp+rename 原子写因崩溃中断遗留的 `*.jsonl.tmp` |

## 备注

- 创建：2026-08-13
- 承接：`SESSION-SYSTEM-OPT`（一期）+ `OPT2`（二期）+ `LLM-AUTO-TITLE`，会话系统主题收尾；归入 docs/0.2.7（用户决策：会话系统整体完成后开新周期）
- REMAINING 索引：N1、N3、F5
- 调研结论来源：`app.js` slashLocal/more-menu/renderChildren/loadSessions 现状 + `handler.zig:564-577` fork/reset + `session.zig:764` list + `flush` tmp 生命周期
