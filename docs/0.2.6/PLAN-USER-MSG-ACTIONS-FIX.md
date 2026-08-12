# Plan USER-MSG-ACTIONS-FIX: 用户消息 hover 操作栏功能缺陷修复

## 状态: 🔄 已并入 SESSION-SYSTEM-OPT（2026-08-12）

> 本计划已升级为 `docs/0.2.7/PLAN-SESSION-SYSTEM-OPT.md`（会话系统优化，分阶段 P1-P5）。本文件保留为**根因分析**与 revert/branch 决策参考，不再单独实施。索引方案已定案为 **方案 C（消息按 ID 操作）**。

## 问题

**现象**：用户消息的 hover 操作栏（`.msg-actions`：revert / copy / delete 三个图标按钮）存在功能缺陷。用户在 PR7 收尾阶段反馈"用户消息的菜单功能有问题"。

## 根因（已确认，2026-08-12 排查）

**核心缺陷：delete 按钮的 `index` 来自前端 DOM 计数，与服务端持久化的消息数组下标是两个不同的索引空间。**

**机制**（证据见代码行号）：

1. `sendPrompt()`（`app.js:700-701`）为新增用户消息计算：
   ```js
   var nextIndex = document.querySelectorAll('#messages .msg, #messages .tool-card').length;
   addMessage({role:'user', content:prompt}, nextIndex);
   ```
   即 **DOM 元素计数**。

2. 但 `DELETE /api/session/:id/message/:index`（`handler.zig:524-543` → `session.removeMessage(index)`，`session.zig:343-374`）按**原始消息数组下标**删除（index 0 = system prompt）。

3. **两个空间发生漂移**：一次带工具调用的 assistant 回合，服务端持久化为 **N+2 条**数组条目（assistant+tool_calls、N×tool 结果、最终 assistant 文本，见 `agent.zig:271-278 / 294-368 / 362-367` 的 append），而前端只渲染为 **N+1 个** DOM 元素（1 个 `.msg.assistant` + N 个 `.tool-card`）。→ **每经历一个工具回合，DOM 计数比服务端数组长度少 1**。

4. **后果**：
   - 流式会话（未 reload）中，工具回合**之后**新增的用户消息，其 delete 按钮拿到的 `index` 比真实服务端下标小（漂移数）。点击 delete → 删错消息；漂移越界时返回 400 `"message index out of bounds"`。
   - **前端静默吞错**（`app.js:679` `catch(err){ console.error(err); }`），无任何用户可见反馈 → 按钮表现"点了没反应"，与用户反馈"菜单功能有问题"吻合。
   - reload 路径（`loadSession`，`app.js:385` `addMessage(m, i)` 直接用服务端下标）索引正确 → 所以**删除在 reload 后正常、在当前流式会话中异常**，表现具迷惑性。

**已排除**（原待排查方向的结论）：
- ✅ hover 显示/图标渲染正常：`.msg` 有 `position:relative`，`.msg-actions` 定位正确；`biIcon('revert'/'copy'/'trash')` 三个图标均有定义（`app.js:91-100`）。
- ✅ revert / copy 功能正常：只用 `content`，不依赖 index。
- ✅ confirm modal 存在（`index.html:36-41`），删除流程能走到 API。
- ✅ 与 PR7 交互无冲突：`setStreaming()`/`closeAllMoreMenus()` 不影响 `.msg-actions`。

## 决策摘要（已定案，2026-08-12）

> 本文件**不再承载实现细节**。端点、涉及文件、验证以 `docs/0.2.7/PLAN-SESSION-SYSTEM-OPT.md` 为准。

| 项 | 定案 |
|----|------|
| **索引方案** | **方案 C（消息按 ID）**——JSONL 消息加 `id`，delete/truncate/branch 全按 id。~~A（done 后重同步）~~ 已废弃（留作退路），~~B（服务端权威计数）~~ 不采用 |
| **revert** | 截断 + 重新生成：`POST /truncate {message_id}` → 回填输入框 → reload → 重发重生成 |
| **branch** | 从消息分叉：`POST /branch {message_id}` → 新会话含 `id ≤ N` → `(fork #N)` 自动命名 → 自动切换 |
| **守卫** | 非首条、非流式中；服务端 `busy` 兜底；操作 `catch` 用 `status-msg` 提示不静默 |
| **滚动/渲染** | reload 全量替换 + 滚动状态机（暂停/防误判/位置保留）——见 SESSION-SYSTEM-OPT P1 滚动策略与 DOM 契约 |

## 来源

## 背景

**相关代码**（`src/frontends/web/app.js`）：
- `.msg-actions` 创建：`addMessage()` 中 `role === 'user'` 分支（约行 643-684）
- 现有按钮：`revertBtn` / `copyBtn` / `delActionBtn`（将扩为 4 个：revert/copy/branch/delete）
- 图标：Bootstrap Icons（`biIcon()` 生成的 revert/copy/trash SVG，需补 branch 图标）
- CSS（`app.css`）：`.msg-actions` 定位在气泡下方（`top:100%; right:0`），气泡 `margin-bottom:30px` 预留空间

**相关功能在 PR7 的决策**（`PLAN-DEEPSEEK-STYLE.md` §1.1d）：
- MG6：保留双击重命名、hover × 删除快捷路径
- 用户消息操作栏是 K7 保留项（revert/copy/delete）

## 备注

- 创建时间：2026-08-11（v0.2.6 PR7 收尾时）
- 根因确认：2026-08-12
- **验证清单已并入** `docs/0.2.7/PLAN-SESSION-SYSTEM-OPT.md`（P1 验证含 delete 复现步骤）
- REMAINING.md 索引：N11
