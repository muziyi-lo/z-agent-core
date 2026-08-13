# Plan SESSION-UI-FINAL: 会话系统收尾（前端操作 + 侧边栏性能 + 崩溃恢复）

## 状态: ✅ 已实施（2026-08-13，build + 263 测试 + 前端 9 文件全过；仅余既有 bash 基线失败）

## 实施差异记录

- **PATCH 路由**：fork/reset 扩展现有 PATCH 分支（handler.zig:117 已有 rename），加 sub-path 解析；`handleFork` 支持 `name_arg`（command 通道）/ body `{name}` / 空名自动 `forkTitle` 生成 `(fork #N)`
- **`listPage`**：独立函数（不动 `list`），复用 list 全量快照 + after/limit 过滤 + 深拷贝（防与 list 内存冲突）；handler `?limit=N[&after=ts]` → `{sessions, has_more}`
- **前端收起**：`renderChildren` 改为包 `.branch-children` 容器（非直挂 el），折叠用 `wrap.style.display` 控制 + localStorage 持久化 + 孤儿 ID 清理
- **分页追加**：`appendSessionsOlder` 独立节点构建（`makeSessionNode`），按 group 归属插入；滚动监听 `#session-list` 底部 100px 触发
- **Reset UI**：用现有 `confirmModal`（非自定义 modal）
- **bash 超时**：未传 timeout → `.none` 保持阻塞；传了 clamp [1,3600]；中断优先于超时；`meta.timed_out` 仅超时路径 true
- 测试 263 通过 + 1 既有失败（`tool.bash.test.bash: echo hello`，stash 基线复现，与本次改动无关）
- **修复 1（DOM diff 首插）**：组内会话 diff 首次插入空容器时 `insertBefore` 为 null → 节点从未 append（侧边栏只剩 header 无会话条目）；修 `node.parentNode !== cont` 时 append/insertBefore 兜底
- **修复 2（fork 中文名 → UUID 文件 id）**：`session_ops.fork` 原用 sanitize 显示名当文件名，中文会话名 fork 产生全下划线 id（`____.jsonl`）；改 UUID 文件 id + 显示名（forkTitle）写 header
- **修复 3（alert → inputModal）**：fork 命名从 `prompt()` 改自定义 `inputModal`（modal-overlay + input-field + placeholder `x (fork #N)`），对齐现有 modal 组件

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

- 涉及 4 模块：`core/session.zig`、`web/handler.zig`、`web/app.js`（+ `app.css`）、`tool/bash.zig`
- 新增：fork/reset REST 端点、侧边栏收起、列表分页、tmp 清理、bash 超时
- 一句话思路：**前端可发现性（按钮）→ 侧边栏性能（diff + 收起 + 分页）→ 数据容错（tmp 清理）→ 工具诚实性（bash 超时）**，四段独立可发、同属会话系统收尾
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

**reset 语义（评论者确认，明确"保留系统提示词"）**：
- `session_ops.reset`（`session_ops.zig:131-135`）保留系统提示词：`keep = 1`（index 0 为 system 时），`truncateTo(keep)`——**用户/助手/工具消息全部清空，系统提示词保留**，会话 id/name 不变
- 已有单测验证（`session_ops.zig:137-149` "reset keeps system prompt"）
- **下回合刷新**：agent 每回合 `updateFirstSystem` 重建系统提示词（含 env/date/project_context）——reset 保留的旧 system prompt 会在下一回合被覆盖为最新版，两者不矛盾
- **日志**：`session_reset` 记录 `msgs_cleared`（清空前的消息数）

- 前端 **more-menu 增 Fork/Reset 两项**（`app.js:352` more-menu 已含 rename/pin/delete，追加两项）
- Fork 点击 → 弹内联输入框（复用 rename 的 `input` 模式，`app.js:380-401`）→ PATCH fork → `switchToSession`（app.js:1279）
- Reset 点击 → `confirm()` 二次确认 → PATCH reset → `loadSessions`
- **守卫对齐**：`isSessionStreaming`（`handler.zig:882`）拒绝流式中操作；fork 命名冲突复用 `error.SessionAlreadyExists`
- **command 通道保留**：`handleCommandExec` 的 fork/reset 分支改为转发到新端点逻辑（抽共享 `handleFork`/`handleReset` 函数，避免双实现漂移）

> **为什么保留 command**：`/fork`、`/reset` slash 命令已在 command 注册表（`command.zig builtin`），Web slash popover 从 `GET /api/command` 自动列出。保留兼容零成本，且 CLI 侧 `/fork` 独立存在不受影响。

### D2 — N3a：侧边栏 DOM diff（含分支树收起）

**现状**：`loadSessions` 全量重建；`renderChildren` 递归无收起。

**方案**：`loadSessions` 改为**增量 patch**，核心是 `sessionKey`（id）+ 收起状态：

- **DOM 定位**：会话条目 `div.session` 加 `data-session-id` 属性（`app.js:344` div.className 处追加），diff 时按 id 查找既有节点；**更新文本用 `div.querySelector('.name')`/`.meta` 改 innerText**（`renderItem` 用 innerHTML 构建，`.name`/`.meta` 子元素可定位）
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

**分组层 diff（评论者确认，防 header 重复/错位）**：

侧边栏按 `groupSessions`（app.js:8-23）分 5 组（pinned/today/yesterday/week/older），每组前插 `.section-header`。**分页追加（D3）与 diff 的交互核心在分组边界**：追加更早会话可能跨组（如 today 组满 → 新会话落 yesterday 组），若 diff 只对比 session 节点会漏建/错建 header。

**正确设计：diff 两层结构，分组为第一层**：

1. **分组层**：重算 `groupSessions` 得各组 → 对比当前 DOM 的 header 序列（header 加 `data-group` 属性）
   - 新分组出现（如追加后出现 yesterday）→ 创建 header + 空组容器
   - 分组消失 → 移除 header
   - 顺序变化 → 移动 header
2. **会话层**（组内）：只对存在的组做 id 级 diff——新增插入组内 **timestamp desc 正确位置**、删除移除、更新文本
3. **追加路径**：分页加载的新会话先经分组层判定归属组 → 组存在则插组内正确位置；组不存在（更早时间段首次出现）则先建 header 再插

**防重复插入**：分组 header 用 `data-group="today"` 等作为唯一键——追加/全量重建都按"DOM 是否已有该 data-group"判断创建，天然不重复。**禁止**用文本匹配（"Today" 文本可能被翻译/改动）。

> **评论者边界确认**：纯"新增节点 + 插最近位置"的 diff 会把追加会话插到错误分组（today 末尾而非 yesterday）。**分组层 diff 是必要结构**，非可选优化——分页（D3）依赖它保证 header 不重复、会话落对组。

**边界**：孤儿分支（父已删）提升到顶层（现有逻辑 `app.js:324-334` 保留）；收起父时其下所有深度后代一并收起（`renderChildren` 递归判断）。

**收起状态健壮性（评论者确认）**：

| 场景 | 行为 | 处理 |
|------|------|------|
| 父会话删除，其收起状态残留 | 子会话提升顶层（无收起钮）；`isCollapsed(父id)` 找不到 DOM 节点 | 静默忽略，无影响（评论者确认） |
| 收起状态数组含已删会话 ID | `collapsed` 中孤儿 ID 永不清除，长期累积脏数据 | **loadSessions 时清理**：diff 完成后 `collapsed` 过滤掉不在 `knownIds` 中的 ID，写回 localStorage（对齐 pinned 的清理思路——`getPinnedIds` 无清理但 pinned 数量少；collapsed 随删除累积更多） |
| 子会话提升后自身是顶层 | 不再有收起钮（`data-has-children` 判断 childrenMap 为空） | 子会话原收起状态若存在则清理（同上） |

> **评论者边界确认**：父删后残留的收起状态**不会**影响正确性——`isCollapsed` 找不到节点即忽略。但为防 `collapsed` 数组长期增长，在 `loadSessions` 的 diff 完成后按 `knownIds` 过滤孤儿 ID 写回（一次清理，与 diff 同生命周期，零额外成本）。

### UI 设计（新增，对齐现有视觉语言）

> 所有样式沿用现有 CSS 变量（`--bg-layer-01/02/03`、`--border-base`、`--accent-base`、`--text-*`），不新增色板。图标用现有 `biIcon` helper（app.js:104）或 UTF-8 符号。

**N1 — Fork/Reset 按钮（more-menu）**：

| 元素 | 设计 |
|------|------|
| Fork 菜单项 | `more-menu` 内 rename 与 pin 之间插 `<div class="more-item" data-act="fork">Fork</div>`（`app.js:352` 的 innerHTML 追加）；hover 同现有 `.more-item:hover` 样式 |
| Fork 命名输入 | 复用 rename 的 `input` 模式（`app.js:380-401`）：点击后 name 区变 `input.rename-input`，Enter/失焦提交；**预填默认 `{base} (fork #N)`**（服务端 forkTitle 计算，PATCH 无 name 时服务端生成）——简化交互，用户可改可留空 |
| Reset 菜单项 | `<div class="more-item danger" data-act="reset">Reset</div>`（danger 类，对齐现有 delete 样式 `.more-item.danger:hover` 红色） |
| Reset 确认 | 用现有 `modal-overlay`（`app.css:165-173`）弹确认框："Reset this session? All messages will be cleared. (System prompt is kept.)" + `modal-cancel`/`modal-danger` 按钮——比 `confirm()` 更贴合现有 modal 组件；文案明确"消息清空、系统提示词保留" |
| Fork 成功后 | `switchToSession(fork_id, name)`（app.js:1279）自动切换 + `loadSessions` 刷新分支树 |

**N3a — 分支树收起（视觉）**：

| 元素 | 设计 |
|------|------|
| 折叠按钮 | 父会话条目左侧新增 `▸/▾` 符号（`font-size:10px`、`--text-faint`），置于 branch-icon 之前（若同时是分支则 ▸ 在前）；点击 toggle |
| 定位 | `position:absolute; left:6px; top:50%; translateY(-50%)`（现有 pin-btn/delete-btn 用 absolute 定位，但靠右；折叠钮靠左避免与名称重叠） |
| 有子会话标记 | `data-has-children` 且 `childrenMap[id].length > 0` 才显示折叠钮（叶子无钮） |
| 收起态 | `div.collapsed` class：子分支 DOM `display:none`；▸ 旋转或替换为 ▾ |
| 缩进 | 折叠钮随 `padding-left` 移动（现有 `app.js:346` 按 depth 缩进 28+14*(depth-1)px）——折叠钮固定在每行最左，`left` 用 `padding-left + 6` 计算 |

**N3b — 分页加载（视觉）**：

| 元素 | 设计 |
|------|------|
| 加载中指示 | `session-list` 底部追加 `<div class="sessions-loading">`（`--text-faint`、`font-size:11px`、`padding:8px`、居中），显示 "Loading more…"（复用 `.empty-hint` 风格） |
| 无更多 | 到底后显示一次 "No more sessions" 后移除（不常驻） |
| 加载 spinner | 复用 `.spinner`（app.css:146）——loading 行内小 spinner + 文本 |
| 滚动阈值 | `#session-list` 底部 100px 内触发加载更早；`loading` 标志防重复（追加中不重复触发） |

**新增 CSS**（app.css 追加，对齐现有单行紧凑风格）：

```css
/* branch collapse */
.collapse-btn{position:absolute;left:6px;top:50%;transform:translateY(-50%);width:16px;height:16px;display:flex;align-items:center;justify-content:center;color:var(--text-faint);font-size:10px;cursor:pointer;border-radius:var(--radius-sm);user-select:none;background:none;border:none}
.collapse-btn:hover{color:var(--text-strong);background:var(--bg-layer-02)}
.session.collapsed .branch-children{display:none}
/* paging */
.sessions-loading{padding:8px;color:var(--text-faint);font-size:11px;text-align:center;display:flex;align-items:center;justify-content:center;gap:6px}
```

> **交互一致性**：收起/分页/按钮全部走现有 hover/active 视觉模式（`opacity:0→hover:0.4→active:1` 三段式，对齐 delete/pin/more 按钮）；`prefers-reduced-motion` 已全局处理（app.css:176），diff 不新增动画。

### D3 — N3b：会话列表分页

**现状**：`session.zig:764 list()` 全量返回；`GET /api/session`（handler.zig:270 附近）无分页。

**方案**：
- **新增 `session.zig` 独立函数 `listPage`**（**不动既有 `list`**——`list` 有 5 个调用点：`session_ops.zig:66`、`init.zig:117`、`App.zig:609`、`handler.zig:274/308`，改签名破坏全部；`listPage` 复用 `list` 内部逻辑加 limit/after 过滤）：
  - `listPage(allocator, io, session_dir, limit: usize, after_ts: ?i64) ![]SessionInfo` → 返回最近 `limit` 条且 `timestamp < after_ts` 的会话
- `GET /api/session?limit=N&after=<ts>` → 分页响应 `{sessions: [...], has_more}`（handler 调 `listPage`；`has_more` = listPage 返回条数 == limit 且仍有更早）
- 前端 `loadSessions` 首次加载 `limit=50`，滚动到侧边栏底部附近 → 增量加载更早会话（`after` = 当前最早 timestamp）
- **既有 `list` 保持**：`GET /api/session` 无参数时走 `list` 全量（兼容），有 limit/after 走 `listPage`

> **游标用 timestamp 而非 id**：会话列表按 `timestamp desc` 排序（list 现状），分页游标天然是 timestamp；消息分页才用 id（已 id 化）。侧边栏加载用**追加**而非全量——与 D2 的增量 patch 兼容（追加 = 纯新增节点）。

**交互**：`#session-list` 滚动监听（`scroll` 事件），接近底部 `threshold=100px` 触发加载更早；加载中置 `loading` 标志防重复。

### D4 — F5：崩溃恢复（tmp 残留清理）

**现状**：`session.flush` 的 tmp 清理是正常路径 `defer`（`session.zig:419`），崩溃中断则 `{path}.tmp` 残留；下次 flush 复用 `{path}.tmp`（`session.zig:416`）覆盖旧 tmp，无数据污染但残留文件累积。

**方案**：
- **启动清理**：`init.zig`（`init_mod.init`）在确定 `sessions_dir` 后，扫描目录删除 `*.jsonl.tmp` 残留（崩溃孤儿）
- 清理在 `init` 内执行（CLI/Web 共用 `init_mod.init`，`frontends/init.zig:100` 后），一次性、低开销
- **不做**：文件损坏自动修复（`Session.load` 已跳过坏行，`session.zig:103` 起）、`.tmp` 半写内容恢复（tmp 是完整新文件，rename 前崩溃则旧文件完好，直接删 tmp 即恢复）

> **为什么 tmp 残留值得清**：崩溃是真实场景（本次 `std.http` 裸 POST panic 已演示），残留 tmp 占用磁盘 + 混淆目录。删除 tmp 即可恢复（tmp 与正式文件原子替换，不删也不影响正确性，但堆积）。

### D5 — 日志覆盖（新增，对齐 LOGGING-SYSTEM 宗旨）

**现状审查（2026-08-13）**：session CRUD 操作日志覆盖稀疏——只有 `session_list`（handler.zig:272）、`session_new`（handler.zig:967）、`sse_*` 流式序列。**delete/rename/truncate/branch/undo/fork/reset 均无 `log.*` 调用**。这与 LOGGING-SYSTEM "补关键路径日志" 宗旨（可定位到功能阶段）不符。

**方案**：本计划新增操作 + 既有 CRUD 顺带补日志，事件名统一 `session_*` 前缀（对齐现有 `session_list`/`session_new`）：

| 操作 | 事件名 | 级别 | 字段 |
|------|--------|------|------|
| fork | `session_fork` | biz_info | session_id, fork_id, name |
| reset | `session_reset` | biz_info | session_id, msgs_cleared |
| 删除（既有补） | `session_delete` | biz_info | session_id |
| 重命名（既有补） | `session_rename` | biz_info | session_id, old→new |
| 截断（既有补） | `session_truncate` | biz_info | session_id, kept |
| 分支（既有补） | `session_branch` | biz_info | session_id, fork_id |
| undo（既有补） | `session_undo` | biz_info | session_id, kind |
| 列表分页（D3） | `session_list_paged` | req_info | dir, limit, after, has_more |
| tmp 清理（D4） | `session_tmp_cleanup` | dbg | removed_count |

**日志落点**：`handler.zig` 各 handler 函数内（成功路径 `biz_info`，错误路径已由 `err_mod` 响应；不新增错误日志避免重复）。`tmp 清理` 在 `init.zig`（`log.dbg`，级别低——正常启动无残留时应静默，有残留才可见）。

> **为什么这是本计划范围**：session CRUD 日志是会话系统收尾的一部分（LOGGING-SYSTEM P1 只覆盖了 SSE/agent/provider/compact，会话管理操作是遗漏领域）。本计划触碰这些 handler（抽 fork/reset 共享函数、加 list 分页），顺带补齐零增量成本。

### D6 — bash 超时修复（工具诚实性，评论者场景确认）

**问题**：`bash.zig` 的 `timeout` 参数标注 "informational only — process execution is blocking"（bash.zig:15），**实际不生效**——`std.process.run` 调用（bash.zig:56-68）未传 `options.timeout`，阻塞命令无限挂起。模型要么等用户 Ctrl+C（返回 `"Command aborted by user."`），要么**永远等不到结果、无感知**（opencode 中观察到的"人工中断后模型无感知"即此场景的变体——中断感知有，但超时感知缺）。

**方案**：传 `options.timeout`（`std.process.run` 已支持，`process.zig:485` `timeout: Io.Timeout = .none`），超时自动 kill 子进程 + 明确返回给模型：

| 状态 | 现状 | 修复后 | 模型感知 |
|------|------|--------|---------|
| 完成 | `Command exited with code N.` | 不变 | ✅ 完成 |
| 中断（Ctrl+C） | `"Command aborted by user."` | 不变 | ✅ 中断 |
| **超时** | **无限阻塞** | **`Command timed out after Ns.` + `meta.timed_out=true`** | ✅ 超时（新增） |

**实现**：
- `bash.zig` 读 `timeout` 参数（秒）：**未传 → `.none`（保持现状无限阻塞，不破坏既有长命令行为）**；传了 → clamp 到 `[1, 3600]`（防 `@intCast` 溢出）：
  ```zig
  const timeout_opt: Io.Timeout = if (args.object.get("timeout")) |tv| blk: {
      if (tv == .integer and tv.integer > 0) {
          const secs: u32 = @intCast(@min(tv.integer, 3600));
          // Clock.Duration = { raw: Io.Duration, clock: Io.Clock }（Io.zig:2398 构造参考）
          break :blk Io.Timeout{ .duration = .{
              .raw = Io.Duration.fromSeconds(secs),
              .clock = Io.Clock.real,
          } };
      }
      break :blk .none;
  } else .none;
  ```
- `std.process.run` 传 `.timeout = timeout_opt`；超时 → `run` 返回 `error.Timeout`（`AwaitConcurrentError` 含 `Timeout.Error`，Io.zig:582）→ catch 分支返回 `"Command timed out after Ns."`
- `meta.timed_out = true`（替换当前硬编码 false，bash.zig:139）
- 中断路径保留（`signal.isInterrupted()` 分支，bash.zig:94-96）——**中断优先**：先查 `signal.isInterrupted()` 返回 aborted，再查超时；用户意图 > 自动超时

**API 验证（G7）**：`Io.Timeout` union（Io.zig:1132，`.none`/`.duration: Clock.Duration`/`.deadline`）+ **`Clock.Duration` 构造 `.{ .raw = Io.Duration, .clock }`**（Io.zig:2398 参考，**非 `fromSeconds`——那是顶层 `Io.Duration` 方法** Io.zig:986）+ `Io.Duration.fromSeconds`（Io.zig:986）+ `RunOptions.timeout`（process.zig:485）+ `AwaitConcurrentError` 含 `Timeout.Error`（Io.zig:582/1137）——全部已确认存在。

## 实施

### 步骤 1: fork/reset REST 端点 + 共享逻辑

**文件**: `src/frontends/web/handler.zig`
**改动**: 抽 `handleFork`/`handleReset`（从 `handleCommandExec:564-577` 提取）；**扩展现有 PATCH 分支**（`handler.zig:117-124` 已存在，目前只处理裸 id → rename）：加 `/fork`、`/reset` 子路径解析（对齐 POST 分支 handler.zig:104-115 的 sub-path 模式）；`handleCommandExec` 转发；**补日志**（D5）：fork → `session_fork`、reset → `session_reset`（`msgs_cleared`）；顺带补 delete/rename/truncate/branch/undo 的 `session_*` 事件；**reset 语义**：`session_ops.reset` 保留系统提示词（`session_ops.zig:131`），实现直接复用不改
**关键代码**:

```zig
// handleRequest PATCH 分支（handler.zig:117 现有，扩展子路径）
} else if (method == .PATCH) {
    if (std.mem.startsWith(u8, path, "/api/session/")) {
        const rest = path["/api/session/".len..];
        if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
            const id = rest[0..slash];
            const sub = rest[slash + 1 ..];
            if (std.mem.eql(u8, sub, "fork")) return handleFork(ctx, request, id, a);
            if (std.mem.eql(u8, sub, "reset")) return handleReset(ctx, request, id, a);
        } else {
            // 无子路径 = rename（现有逻辑）
            const id = if (std.mem.indexOfScalar(u8, rest, '?')) |qm| rest[0..qm] else rest;
            return handleSessionRename(ctx, request, id, a);
        }
    }
}
```

**注意**: PATCH 分支需先解析 sub-path（fork/reset），无 sub-path 才走 rename；守卫 `isSessionStreaming` 一致；fork 返回 session_id 供前端切换

### 步骤 2: 前端 more-menu Fork/Reset 按钮

**文件**: `src/frontends/web/app.js` + `app.css`
**改动**: more-menu 追加 Fork/Reset 项（`app.js:352` innerHTML 追加 `data-act="fork"/"reset"`）；Fork 复用 rename 输入模式（`app.js:380-401`）+ 预填 forkTitle；Reset 用 modal 确认框（`modal-overlay` 组件）；调用 PATCH 端点
**注意**: fork 成功后 `switchToSession`（app.js:1279）；reset 后 `loadSessions`；流式中禁用（`isStreaming` 前端标志）；UI 规范见「UI 设计」节

### 步骤 3: 侧边栏 DOM diff + 收起

**文件**: `src/frontends/web/app.js` + `app.css`
**改动**: `loadSessions` 重写为增量 patch；`data-session-id` 定位；`localStorage` 收起状态；`renderChildren` 支持收起（`collapse-btn` + `.session.collapsed`）；UI 规范见「UI 设计」节
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

**注意**: diff 分两层——先分组层（`data-group` header 增删移），再组内会话层（id 级 diff）；分组 header 用 `data-group` 唯一键防重复（见 D2 分组层 diff）；收起父时子树隐藏；分页追加与分组边界交互按分组层设计处理

### 步骤 4: 会话列表分页

**文件**: `src/core/session.zig` + `web/handler.zig` + `web/app.js`
**改动**: 新增 `session.zig listPage`（复用 list 内部逻辑 + limit/after 过滤，**不动既有 list**）；`GET /api/session` 有 limit/after 时走 listPage + `has_more`；前端滚动增量加载；**日志**（D5）：`session_list_paged` 记录 limit/after/has_more
**注意**: 无分页参数 → 走既有 `list` 全量（兼容，5 个既有调用点不变）；`has_more` 判断（返回 == limit 且仍有更早）；追加加载时保持收起状态

### 步骤 5: tmp 残留清理

**文件**: `src/frontends/init.zig`
**改动**: `init` 确定 `sessions_dir` 后扫描删除 `*.jsonl.tmp`；**日志**（D5）：清理 `session_tmp_cleanup` 记录 removed_count（`log.dbg`，无残留时静默）
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
**改动**: `list` 分页单测（limit/after/has_more）；`handleFork`/`handleReset` 单测（复用 handler 测试模式）；`tmp 清理` 单测（造 `.jsonl.tmp` → init → 消失）；前端 Node 测试适配 `loadSessions` 新逻辑（若测试引用旧全量重建行为需更新）；**日志验证**（D5：fork/reset/delete/rename/truncate/branch/undo 成功路径打 `session_*` 事件，grep 日志确认）
**注意**: handler 测试用 `testing.io`（无子进程）——fork/reset 无 LLM 调用，可测；日志验证在 e2e（真实进程）下做，单测不依赖日志

### 步骤 7: bash 超时（D6）

**文件**: `src/tool/bash.zig`
**改动**: 读 `timeout` 参数（秒，默认 120）→ `std.process.run` 传 `Io.Timeout{ .duration = Clock.Duration.fromSeconds(secs) }`；超时 catch 返回 `"Command timed out after Ns."` + `meta.timed_out = true`；中断路径保留，signal.reset 时机区分超时/中断
**关键代码**:

```zig
// bash.zig execute() 内，解析 timeout 参数
const timeout_secs: u32 = if (args.object.get("timeout")) |tv|
    (if (tv == .integer) @intCast(@max(tv.integer, 1)) else 120) else 120;
const timeout_opt = Io.Timeout{ .duration = Io.Clock.Duration.fromSeconds(@intCast(timeout_secs)) };

// std.process.run 传入 .timeout；catch 区分超时 vs 其他
// error.Timeout → "Command timed out after {timeout_secs}s."
// 其他 err → 现状 "Error: execution failed: {s}"
// meta.timed_out = true（超时分支）
```

**注意**: 超时分支不碰 signal；中断分支（`signal.isInterrupted()`）在超时判断之后——命令超时被 kill 与用户 Ctrl+C 是两条独立路径，不可互相吞状态；`meta.timed_out` 不再硬编码 false

## 验证

```powershell
zig build
zig test src/test.zig --cache-dir .zig-cache 2>&1 | Select-String "^\d+/\d+|All \d+ tests|FAIL"
node tests/frontend/run-tests.mjs
node ..\.opencode\skills\zig-dev\scripts\check-catch-silent.mjs . --audit
```

| 测试场景 | 预期结果 |
|----------|----------|
| Web 会话 more-menu 点 Fork | 名称变输入框（预填 `(fork #N)`）→ Enter → 新会话出现在侧边栏 → 自动切换 |
| Web 会话 more-menu 点 Reset | modal 确认框（Cancel/Danger，文案含"System prompt is kept"）→ 确认后会话消息清空、**系统提示词保留**（index 0）→ 侧边栏刷新 |
| Reset 后发消息 | 系统提示词被 agent 下回合 `updateFirstSystem` 刷新为最新（env/date），消息从用户新输入开始 |
| Fork/Reset 按钮 hover | 三段式 opacity（0→0.4→1），Reset danger 红色 hover（对齐 delete） |
| 流式会话 Fork/Reset | `agent_busy` 拒绝（isSessionStreaming）+ 按钮禁用态 |
| slash `/fork` `/reset` | 兼容保留（command 通道转发新逻辑） |
| 父会话折叠按钮 | 有子会话显示 `▸`，点击变 `▾` + 子树隐藏；叶子无按钮 |
| 侧边栏收起父会话 | 子树隐藏；刷新/操作后**收起状态保持**（localStorage） |
| 收起嵌套分支 | 收起 2 代父 → 所有后代隐藏；展开父 → 后代按各自收起状态恢复 |
| 侧边栏会话多 | 只更新变化的条目，无全量闪烁 |
| 孤儿分支（父已删） | 提升顶层（既有逻辑），收起状态不受影响 |
| **收起状态孤儿 ID 清理** | 删除会话后，`collapsed` 中该 ID 在下次 loadSessions 被过滤；`isCollapsed` 对不存在节点静默忽略 |
| 会话列表 >50 | 首屏 50 + 滚动到底显示 "Loading more…" spinner → 加载更早，`has_more` 正确 |
| 无更多会话 | 显示一次 "No more sessions" 后移除 |
| 无分页参数 `GET /api/session` | 全量返回（兼容） |
| 崩溃后残留 `.jsonl.tmp` | 启动清理删除；无 tmp 时启动正常 |
| fork 命名冲突 | `error.SessionAlreadyExists` → 400 提示 |
| **日志覆盖（D5）** | fork/reset/delete/rename/truncate/branch/undo 成功路径均打 `session_*` 事件；`session_list_paged` 分页、`session_tmp_cleanup` 清理有日志 |
| **分页与收起共存** | 追加加载更早会话时，已收起父的子树保持收起 |
| **分组 header 不重复（评论者场景）** | 追加跨组（today 满 → yesterday）→ yesterday header 只创建一次，会话落对组；全量重建/追加均按 `data-group` 判定，无重复 header |
| **分组消失** | 会话全删/移组后，空组 header 被移除 |
| **追加会话落组正确** | 更早会话插入对应组 timestamp desc 位置，非"最近节点后" |
| **bash 阻塞命令超时（D6）** | `timeout: 2` + `sleep 10` → 约 2s 返回 `"Command timed out after 2s."`，`meta.timed_out=true`，命令被 kill |
| **bash 未传 timeout** | 保持现状无限阻塞（`.none`），既有长命令行为不变 |
| **bash timeout 超大值** | clamp 到 3600s（`@intCast` 无溢出 panic） |
| **bash 正常命令** | 完成返回，`timed_out=false`，行为不变 |
| **bash 中断** | Ctrl+C → `"Command aborted by user."`（既有），中断优先于超时 |
| reduced-motion | 收起/加载无动画（全局已处理） |

## 波及

| 文件 | 改动 | 破坏性? |
|------|------|----------|
| `src/frontends/web/handler.zig` | fork/reset PATCH 端点 + 抽共享函数 + **补 session CRUD 日志（D5）** | 否（command 保留） |
| `src/frontends/web/app.js` | more-menu 按钮 + loadSessions diff + 收起 + 分页加载 | 是（loadSessions 重写，前端测试需适配） |
| `src/frontends/web/app.css` | `.collapse-btn` / `.session.collapsed` / `.sessions-loading` 样式 | 否 |
| `src/core/session.zig` | 新增 `listPage`（limit/after，复用 list 内部逻辑；**既有 `list` 不动**，5 调用点不受影响） | 否 |
| `src/tool/bash.zig` | bash 超时（D6）：timeout 参数生效 + timed_out 上报 | 否（默认无超时变更，仅新增能力） |
| `src/frontends/init.zig` | tmp 残留清理 | 否 |
| `tests/frontend/*` | loadSessions 相关测试适配 | 是 |

## 明确不做

- **undo 栈持久化**：撤销窗口重启丢失可接受（对齐 opencode 内存 undo）；崩溃恢复聚焦消息层（F5 已定）
- **会话文件损坏自动修复**：`load` 已跳坏行，不做逐行重建
- **`.tmp` 半写内容恢复**：tmp 是完整新文件，rename 前崩溃则旧文件完好，删 tmp 即恢复
- **侧边栏虚拟滚动**：分页 + 收起已控规模，DOM diff 足够
- **bash 执行耗时上报给模型**：模型需要"完成/超时/中断"三态，不需要耗时数值（D6 边界）
- **bash 后台化/异步**：超时 kill 已解决挂死，后台任务执行是更大特性，另立
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
