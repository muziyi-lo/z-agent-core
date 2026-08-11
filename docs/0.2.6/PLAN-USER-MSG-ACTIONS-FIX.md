# Plan USER-MSG-ACTIONS-FIX: 用户消息 hover 操作栏功能缺陷修复

## 状态: 📋 待办（问题已确认存在，待排查实施）

## 问题

**现象**：用户消息的 hover 操作栏（`.msg-actions`：revert / copy / delete 三个图标按钮）存在功能缺陷。用户在 PR7 收尾阶段反馈"用户消息的菜单功能有问题"，具体表现待复现确认。

**来源**：`docs/0.2.6/PLAN-DEEPSEEK-STYLE.md` PR7（⋮ 更多菜单 MG1-MG4）收尾时发现的遗留问题。该功能随 v0.2.6 一起合入，但存在功能缺陷未修复即收尾。

## 现状

**相关代码**（`src/frontends/web/app.js`）：
- `.msg-actions` 创建：`addMessage()` 中 `role === 'user'` 分支（约行 645-684）
- 三个按钮：`revertBtn`（回填输入框）/ `copyBtn`（复制内容）/ `delActionBtn`（删除消息）
- 图标：Bootstrap Icons（`biIcon()` 生成的 revert/copy/trash SVG）
- CSS（`app.css`）：`.msg-actions` 定位在气泡下方（`top:100%; right:0`），气泡 `margin-bottom:30px` 预留空间

**相关功能在 PR7 的决策**（`PLAN-DEEPSEEK-STYLE.md` §1.1d）：
- MG6：保留双击重命名、hover × 删除快捷路径
- 用户消息操作栏是 K7 保留项（revert/copy/delete）

## 待排查方向（未确认）

1. **定位问题**：操作栏是否在 hover 时正常显示？按钮点击是否生效？
2. **图标显示**：`biIcon()` 生成的 SVG 是否渲染正常？
3. **copy 反馈**：`copyText` 对图标按钮用 title 反馈，是否正确？
4. **revert 行为**：回填 prompt 是否正常？
5. **delete 行为**：confirm modal + 删除 + reload 是否正常？
6. **与 PR7 其他改动冲突**：`setStreaming()`/`closeAllMoreMenus()` 等新增交互是否影响操作栏？

## 涉及文件

| 文件 | 改动 |
|------|------|
| `src/frontends/web/app.js` | 用户消息操作栏逻辑（约行 645-684） |
| `src/frontends/web/app.css` | `.msg-actions`/`.msg-action` 样式 |

## 验证

1. 复现用户报告的问题，确认具体表现
2. 修复后 L2 用户浏览器验证（hover 显示、三个按钮各自功能）
3. 回归：用户消息操作栏不影响其他消息（assistant 删除按钮、⋮ 菜单）

## 备注

- 创建时间：2026-08-11（v0.2.6 PR7 收尾时）
- REMAINING.md 索引：N11
