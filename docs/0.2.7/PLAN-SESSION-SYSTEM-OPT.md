# Plan SESSION-SYSTEM-OPT: 会话系统优化（升级自 N11）

## 状态: ✅ P1 + P2 已实施（2026-08-12，后端 e2e + Node 测试通过，待浏览器 L2 双路径验证）；P3-P5 待实施

## 背景

原 N11（`docs/0.2.6/PLAN-USER-MSG-ACTIONS-FIX.md`）从"用户消息操作栏 bug 修复"出发，经根因确认（delete 索引漂移）+ revert 语义变更 + branch 从消息分叉，并与 opencode 会话管理（`e:\ProgramLibrary\Repositories\opencode\`）对照后，**范围已膨胀到消息模型/存储层**。故升级为本主题计划，分阶段独立交付，避免互相阻塞。

**既有成果（已确认，直接继承）**：
- 根因：delete 按钮 `index` 用 DOM 计数，与服务端消息数组下标漂移（工具回合 N+2 条 vs N+1 元素）→ 删错/静默 400。详见 `PLAN-USER-MSG-ACTIONS-FIX.md`
- revert 语义变更：截断 + 重新生成
- branch：从消息分叉（含该消息 + 自动命名）

## 参照：pi-repos 分支模型（2026-08-12 调研，`e:\ProgramLibrary\Repositories\pi-repos\`）

pi-repos（`packages/agent/src/harness/session/session.ts` + `compaction/branch-summarization.ts`）用**单树持久化**解决分支的悬空消息问题：

| 维度 | pi-repos | 本方案（复制模型） |
|------|----------|--------------------|
| 存储 | 一次会话一个文件，每条 entry 带 `id`+`parentId`（事件树） | 每分支新会话文件（复制截断） |
| 分支动作 | `moveTo(entryId)` 移动叶指针，不复制不截断 | `forkAt` 复制 `[0..N]` |
| 继续 | 从分支点消息**重新运行** → 新答案 append → `[...,u2,a2']` 无悬空/无连续 user | ~~手动发新消息 → `[...,u2,u3]` 悬空+连续~~ **已改方案 B** |
| 离开分支 | `branch_summary` LLM 摘要注入（"用户探索了另一分支..."） | 可借鉴（P2 可选） |
| 分支关系 | `getBranch`=到根路径、`commonAncestorId`=分叉点 → 天然支撑分支树 | 需 `parent_id`（P2 补） |

**结论**：pi 无"连续 user"问题的根因是分支点消息**本身就是重新运行的 prompt**——与本方案决策的**方案 B（branch 自动重答）**一致。

## 目标

以 **opencode 消息模型（按 ID 操作）** 为方向，系统化改造会话系统：修复索引漂移 → 消息按 ID 操作 → 会话操作增强 → 性能 → 上下文 → 可撤销。每阶段独立 PR、独立验证。

## P0: 索引方案决策（已决策 2026-08-12）

**决策：采用方案 C（消息按 ID 操作），废弃方案 A（done 后重同步）。**

| 方案 | 内容 | 决策 |
|------|------|------|
| A. done 后重同步 | `done` 事件末尾 `loadSession`，DOM 与服务端对齐 | ❌ 治标，留数组下标索引空间，P3 分页还要返工 |
| **C. 消息按 ID** | JSONL 消息加 `id`，delete/truncate/branch 全按 ID | ✅ **采用** — 治本、对齐 opencode、P3 分页 cursor 天然可用 |

**退路**：若 P1 存储改动遇阻，可临时退回 A（一行 `loadSession`），A 与 C 不冲突（A 是前端行为，C 是接口契约）。

## P1: 消息 ID 模型 + 按 ID 操作

### 消息模型升级

**字段**：`types.Message` 增 `id: u64`（单调递增、可排序 → P3 cursor 基础）。`Session` 增 `_next_id: u64`（下次分配起点）。

**id 分配路径（三种入口全覆盖）**：
- `append()`：自动填 `id = _next_id++`
- `updateFirstSystem()`（insert 到 index 0）：同样分配 `_next_id++`
- `Session.load()` 解析旧文件：行内无 `"id"` 字段 → 依序分配 `_next_id++`；有 `"id"` → `_next_id = max(_next_id, id+1)`

**旧文件迁移（不兼容策略，2026-08-12 决策）**：本项目为非正式版（v0.2.x，无对外发布），**不做向后兼容**。旧 JSONL 首次 `load` 时若检测到任一消息缺 id → 为全部消息分配 id 并**标记 `modified` + 立即 `flush` 一次**（迁移写回，id 即刻稳定）。"不维护兼容路径"指：不保留旧 id 语义、不增量对比，而非不做计数器——`_next_id` 追踪照常。

**id 稳定性规则**：
- 删除/截断（`removeMessage`/`truncateTo`）**不重编号**——id 永不复用，允许空洞，新消息 id 继续递增（保证跨操作稳定，前端缓存的 id 不会失效）
- id 一旦分配即持久化（迁移 flush），**reload 后同一条消息 id 不变** → delete/revert/branch 的 by-id 契约与分页 cursor 前提成立

**输出**：`session.messages()` 返回含 id 的消息；`handleSessionGet`/`handleSessionMessages` 输出 id（旧文件未迁移前也即时分配）。

**序列化**：`serializeMessage`（`session.zig:491`）写 `"id":N`；`Session.load` 解析（内联 `std.json.parseFromSlice`，`session.zig:85`）读取 `"id"`（缺失 → 迁移路径分配）。

### 接口变更（契约）

| 端点 | 现状 | 变更 |
|------|------|------|
| `DELETE /api/session/:id/message/:index` | 数组下标 | → `/:msg_id`（按 id，404 `message not found` 区分 400） |
| `POST /api/session/:id/truncate` | 无 | body `{"message_id":N}` → **按 id 定位数组位置 → 截断保留该位置之前的所有消息**（系统提示词 index 0 天然保留；revert 用） |
| `POST /api/session/:id/branch` | 无 | body `{"message_id":N}` → `forkAt` 按 id 定位 → 复制含该消息及其之前（branch 用） |

> **定位语义（2026-08-12 实施澄清）**：truncate/branch 均以 `message_id` **定位消息在数组中的位置**，再按位置截断/复制——**不直接比较 id 大小**。原因：系统提示词经 `updateFirstSystem` 前置但 id 取 append 顺序（可能大于用户消息），若按 `id < N` 截断会误删系统消息；按位置则 index 0 的系统提示词天然保留。

### 前端

- `sendPrompt` 不再用 DOM 计数算 index（`app.js:700`）——用户消息从 `done`/`session_ready` 响应取服务器分配的 id（或 prompt 响应回传新用户消息 id）。
- 用户消息操作栏按钮绑定消息 id：revert（truncate + 回填）、branch（fork + 切换）、delete。
- delete/revert/branch 的 `catch` 不静默，用 `status-msg` 提示（对齐 SLASH-COMMANDS §5.5）。

### 渲染模式与 DOM 所有权契约（评论补充，2026-08-12）

**背景**：PR7 已实现 `renderAssistantMessage`（parts 模型统一渲染）。须明确两种渲染模式的关系，避免"部分 DOM 重建、部分复用"混乱。

**结论：两种模式互斥，按会话边界/用户操作切换，不在同一 DOM 生命周期混用。**

| 模式 | 触发 | DOM 处理 | 所有权 |
|------|------|----------|--------|
| **增量（流式）** | `sendPrompt` SSE（`thinking_*`/`content_*`/`tool_*`） | `buildSegment` 追加到 `.msg.assistant`，**不改历史节点** | SSE 路径独占 |
| **全量替换（reload）** | `loadSession`（会话切换 / revert / branch / delete 后） | `msgs.innerHTML=''` **原子全清** → 逐条 `addMessage` → `renderAssistantMessage` 全重建（含 tool 结果填充同次新建的 `lastAsst._toolSegments`） | reload 路径独占 |

**契约**：
1. **方案 A 已废弃（方案 C 采用）** → `done` 事件**不调用** `loadSession`；流式 DOM 由增量路径独占保留，无"重建 vs 复用"混用。
2. reload 是**原子全量替换**：`innerHTML=''` 后全重建，**不存在部分复用旧节点**；tool 结果填充目标是同一次重建中新建的 `_toolSegments`，无陈旧 DOM 引用。
3. **时序互斥**：`isStreaming` 时操作守卫阻止 reload；reload 前 `evtSrc` 已关闭（`switchToSession` 模式）。两路径永不并行操作同一节点。
4. 全量重绘的视觉代价（闪烁/跳位）由滚动策略缓解；P3 分页加载天然消除全量重绘（顶部/增量插入）。

### 滚动策略（reload 缓解，2026-08-12 评论补充）

**问题**：revert/branch/delete 走 reload（`loadSession`）全量重绘，且 `addMessage` 无条件 `msgs.scrollTop = msgs.scrollHeight`（`app.js:687`）→ 用户阅读历史时触发任一操作会被强制跳底 + 全量重绘闪烁。

**方案（轻量状态机，吸收 opencode `createAutoScroll`，适配 vanilla JS）**：

| 机制 | opencode 参考 | 落地 |
|------|--------------|------|
| **暂停跟随** | `userScrolled` 标志 | 全局 `autoScrollPaused`：scroll/wheel 向上离开底部 >10px 置位；用户回底（`isNearBottom`）自动复位 |
| **程序滚动防误判** | `markAuto` 1500ms 时间戳 + ±2px 容差 | 简化版：程序锁底前记录目标，1.5s 内忽略同位置 scroll 事件 |
| **reload 保留滚动位置** | `captureHistoryAnchor`/`restoreHistoryAnchor` | 重绘前记 `{scrollTop, scrollHeight}`，重绘后**仅当用户未在底部**时恢复原位置（比例换算），底部才锁底 |
| **同帧锁底** | ResizeObserver layout 后 paint 前锁底 | `requestAnimationFrame` 包锁底，避免"跳上再拉回"闪烁 |
| **嵌套滚动豁免** | `[data-scrollable]` | 工具输出/代码块内部滚动不触发暂停 |
| **会话切换** | params.id 变化 → `resume()` | 切会话后恢复跟随（锁底） |

**边界**：流式期间（`isStreaming`）跟随底部；reload 后若用户停在历史位置，**不打断阅读**，仅在新回合开始（流式）时恢复跟随。

> 注：本策略只处理"不打断用户"，不做 P3 的分页锚点（分页插入旧消息的锚点恢复在 P3 一并实现）。

### revert / branch 语义（继承已确认决策 + 2026-08-12 方案 B 修正）

- **revert**：`truncate {message_id}` → 回填输入框 → reload → 重发重生成。守卫：message_id 定位到的消息不能是系统消息（index 0）；非流式中、服务端 busy 兜底。
- **branch（方案 B：自动重答）**：
  1. `branch {message_id}` → **fork 到该消息之前**（不含边界消息）→ `(fork #N)` 自动命名 → 自动切换
  2. **切换后自动以边界消息内容发送 prompt**（复用既有 `sendPrompt`/SSE）→ 立即生成新答案 → `[...,u1,a1,u2,a2']` 干净收尾
  3. **消除悬空/连续 user/重复消息**：fork 不含 u2，重发 u2 作为新 prompt → u2 只出现一次且必有答案（对齐 pi-repos：分支点消息即重答 prompt）
  4. 守卫同上

> **实现细节（2026-08-12 修正）**：原"含该消息 + 自动重发"会造成 `[...,u2,u2,a2']` 重复 u2——fork 已含 u2 再发 u2 必然重复。故 fork 改为**不含边界消息**，边界内容由 `branch` 响应回传（`boundary_content`），前端切换后 `sendPrompt(boundary_content)`。

> **为什么改方案 B**（评论暴露）：原"含该消息 + 手动继续"在用户发新消息后产生 `[...,u2,u3]` 连续 user 消息——API 层合法（DeepSeek/OpenAI 接受），但 u2 悬空、模型回答目标模糊，语义降级。pi-repos 验证了"分支点即重答点"才是干净语义。

**验证**：`zig build`；`zig test`；
- **delete 复现**：流式会话触发带工具回合后发新用户消息 → 点 delete（修复前：删错/静默 400 `index out of bounds`；修复后：正确删除，DOM 同步）
- **revert**：工具回合后点 revert → 该消息及之后回复消失、内容回填 → 重发重生成；系统提示词不受影响
- **branch**：点 branch → 新会话含该消息及之前、`(fork #N)` 命名、自动切换、**自动重答**（新答案立现）；原会话保留
- 旧 JSONL 会话加载正常（一次性 id 分配）；Node 前端测试回归。

## P2: 会话操作增强

- **`GET /api/session/active`**：返回当前活动会话（前端刷新恢复定位，吸收 opencode）。
- **结构化错误**：`err_mod` 细分 `session_not_found` / `message_not_found`（对齐 opencode tagged error）。
- **分支关系：`parent_id` + 侧边栏分支树（2026-08-12 借鉴 pi-repos）**：
  - `Session` 增 `parent_id: ?[]const u8`（来源会话 id），`session_ops.forkAt` 写入；JSONL header 序列化；`handleSessionGet`/`handleSessionList` 输出。
  - **侧边栏分支树显示**：会话列表按 parent_id 渲染父子关系——主会话下缩进显示 `(fork #N)` 子项 + 分支图标（`bi-git-branch`），点击父/子会话自由切换；分支节点可识别归属。对齐 pi-repos 的 `getBranch`/`commonAncestorId` 关系可视化。
  - **分支摘要注入（可选，延后到 P4 后）**：借鉴 pi-repos `branch_summary`——离开分支/切回主线时 LLM 摘要注入，告知模型"分支探索过什么"。已登记 Future。
- **fork/branch 自动命名（`(fork #N)` 递增，2026-08-12 吸收 opencode）**：
  - 替代原"`{原标题} · branch-<时间戳>`"方案——同源多分支可表达顺序关系（时间戳只能区分、不能排序）。
  - **计数范围：按"基础标题"递增（非全局）**。基础标题 = 去掉尾部 ` (fork #N)` 的标题；`forkTitle(base)` 扫描会话目录，找出标题匹配 `^<base>( \(fork #\d+\))?$` 的全部会话，取最大 N，新标题 = `{base} (fork #N+1)`（无既有分支则 `{base} (fork #1)`）。同源直接多次 fork 因取 max+1 而天然唯一，异源 base 不同不碰撞。
  - **sanitize 规则（显示名与文件名分离）**：显示名保留 `{base} (fork #N)` 原样；文件名复用 `sanitizeForkName`（`session_ops.zig:7-14`：空格/制表符 → `_`；`/`、`\` 已由 fork 入口校验拒绝）→ 例 `x (fork #1)` → 文件名 `x_(fork_#1).jsonl`。
  - **示例**：fork `x` → `x (fork #1)`；再 fork `x (fork #1)` → base=`x`，max=1 → `x (fork #2)`；直接 fork `x` → base=`x`，max=2 → `x (fork #3)`。
  - 子会话同样不再触发 LLM 自动标题（对齐 opencode：`ensureTitle` 对 parentID 会话直接 return）。

> **LLM 自动标题：延后（不入 P2）**。价值真实但属中成本（需 title 专用小请求 + 严格触发条件），且依赖 P4 compact 才复用的 LLM 基础设施。已登记 `REMAINING.md` Future 候选，P4 落地后评估。

## P3: 性能（大会话）

- **`GET /api/session/:id/messages?cursor=<msg_id>&limit=N`**：游标分页（基于 id 排序，吸收 `MessageV2.page`）。
- 前端：初始加载最近 N 条 + 向上滚动增量加载（LRU），流式回合追加走既有增量路径。
- **分页滚动锚点**：顶部插入旧消息时保存/恢复滚动锚点（吸收 opencode `captureHistoryAnchor`/`restoreHistoryAnchor`，`session.tsx:1610-1632`），插入不跳位。
- `GET /api/session` 列表可选加 cursor/search（低优先）。

## P4: 上下文压缩（P0 差距）

- **`POST /api/session/:id/compact`**：LLM 摘要历史（head）+ 保留最近 K 条 → 写回一条 `compaction` 消息（吸收 opencode compaction 流程）。
- 复用 provider + `agent.zig` 现有 `context_window` 阈值监控，触发阈值时自动 compact。
- 依赖：P1 消息 id（compaction 边界用 id 标记）。

## P5: 可撤销（轻量 history）

- 会话操作事件栈（delete/truncate/branch/revert），最近 N 步，`GET /history` + `POST /undo`。
- 简化版：不引入快照系统，undo = 逆操作（如 delete 撤销 = 恢复消息 JSONL 行、truncate 撤销 = 重新 append 被删消息）。内存 + 独立 JSONL 事件文件。
- **不做**：opencode 三阶段 revert + 文件快照恢复（代码级回退，超出范围）。

## 明确不做（对照 opencode）

| 项 | 理由 |
|----|------|
| SQLite + 事件溯源 | 架构级重构，JSONL 当前够用 |
| 三阶段 revert + 文件快照 | 服务代码级回退，成本高，非消息管理 |
| 输入准入 steer/queue + RunCoordinator | 异步/并发模型，后续架构演进 |
| children 分叉树 / share / summary / permission | 成本高或超出会话管理范围 |

## 阶段与交付

| 阶段 | 内容 | 独立可发 |
|------|------|----------|
| P1 | 消息 ID 模型 + 按 ID 操作（delete/revert/branch） | ✅ 关闭索引漂移 bug + 3 操作 |
| P2 | `/active`、结构化错误、自动命名、**parent_id + 分支树显示**、branch 自动重答 | ✅ |
| P3 | 消息游标分页 + 前端增量加载 | ✅ |
| P4 | `POST /compact` LLM 压缩 | ✅ |
| P5 | 轻量 history / undo | ✅ |

## 涉及文件（跨阶段累计）

| 文件 | 阶段 | 改动 |
|------|------|------|
| `src/types.zig` | P1 | `Message` 增 `id` |
| `src/core/session.zig` | P1/P4 | id 字段/`_next_id` 分配、迁移 flush、compaction 写入 |
| `src/core/session_ops.zig` | P1/P2 | `forkAt(source, boundary_id)` + `parent_id` 写入 + 自动重答辅助 |
| `src/frontends/web/handler.zig` | P1-P5 | message/truncate/branch/active/compact/history 端点 + branch 自动重答 SSE |
| `src/frontends/web/app.js` | P1-P5 | 按 id 操作、滚动状态机、branch 自动重答流程、分支树侧边栏渲染 |
| `src/frontends/web/app.css` | P1/P2 | 操作栏 4 按钮布局、分支树缩进样式 |
| `src/frontends/web/error.zig` | P2 | 结构化错误细分（`err_mod`，`handler.zig` 已 import） |

## 验证总则

```powershell
zig build
zig test src/test.zig --cache-dir .zig-cache 2>&1 | Select-String "^\d+/\d+|All \d+ tests|FAIL"
node tests/frontend/run-tests.mjs
node ..\.opencode\skills\zig-dev\scripts\check-catch-silent.mjs . --audit
```

浏览器验证（每阶段）：L2 双路径（流式 sendPrompt + reload loadSession）+ 用户视觉闭环。

## 备注

- 创建：2026-08-12
- 升级自：`docs/0.2.6/PLAN-USER-MSG-ACTIONS-FIX.md`（保留为根因分析）
- REMAINING.md 索引：N11
