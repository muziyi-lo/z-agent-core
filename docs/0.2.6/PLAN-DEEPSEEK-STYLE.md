# Plan DEEPSEEK-STYLE: Web 前端向 DeepSeek 网页版取长补短

## 状态: 📋 计划中（方案设计阶段）

## 问题

**现象**：用户要求前端美术设计参考 DeepSeek 网页版（chat.deepseek.com），而非当前自创的 GitHub-dark 风格。当前 `app.css` 的 token 体系（`--bg-deep #0c0c0f` / `--accent-base #60a5fa` 蓝灰 / `--bg-layer-0x` 四级灰）与 DeepSeek 的视觉语言完全不同：DeepSeek 是**纯白/纯黑底 + 单一品牌蓝 accent + 大圆角胶囊输入框**，而当前是深灰分层层 + 小圆角 + 彩色语义状态。

**根因**：
1. 当前配色是参照 opencode Web UI 的 v2 语义 token 体系（灰阶 4 级 + 蓝 accent）设计的，与 DeepSeek 的极简单色风格（白/黑底 + 单一 accent `#3964FE`）不兼容
2. 布局参数（sidebar 240px、消息全宽、气泡 6px 圆角）未参照 DeepSeek（sidebar 261px、消息列表 max-width 840px、气泡 22px 胶囊）
3. 会话渲染结构对比 DeepSeek 有多项功能性差距（turn 组织、思考块、工具卡片视觉），不仅美术

## 概览

- 改动文件：`src/frontends/web/app.css`（token 体系 + 布局参数 + 组件样式重写）、`src/frontends/web/index.html`（结构微调）、`src/frontends/web/app.js`（渲染/交互增补）、`src/frontends/web/handler.zig`（一行）
- 不改核心层（`core/`、`io/`、`tool/`）——纯前端改造
- 思路：**先对比结构与渲染差距，再定美术方案**——结构差距决定"取长补短"做什么，美术 token 决定"补成什么样"
- 参照数据：已用 chrome-cdp 从 chat.deepseek.com 实测抓取深/浅两套设计 token（见下文 §2）
- **评审反馈：18+ 改动点不得打包一个 PR**（§0 实施拆分）——每 PR 独立可验证、可回退，测试防回归

---

## 0. 实施拆分（评审响应）

**评论者**："18+ 改动点打包一个 PR，app.css 完全重写，app.js 多处改动，且无前端测试防护网（仅 Node 渲染测试覆盖有限）。一旦某处改坏，回退成本极高。"

**拆分原则**：
1. **CSS 与 JS 分离** —— 纯样式 PR（token/布局/组件）与逻辑 PR（置顶/菜单/模型/流式）分开，样式改动不出 bug 时逻辑回退不受影响
2. **按依赖排序** —— token 是其他视觉改动的基石（新色值依赖新 token 定义），必须最前
3. **每 PR 独立可验证** —— 每个 PR 满足：L0 静态测试全绿 + L2 用户视觉确认，才进入下一个
4. **每 PR 可回退** —— 单 PR 回退 = revert 对应 commit，不影响其余已合入改动
5. **测试补强先行** —— 逻辑 PR 前先扩展 `tests/frontend/` 防护网（见下）

**PR 拆分表**：

| PR | 内容 | 文件 | 风险 | 验证方式 | 可回退 |
|----|------|------|------|----------|--------|
| **PR1** | token 体系重写（深/浅两套对齐 DeepSeek）+ 3 处解耦引用（`.msg.user`/`.session.active`/行内 code） | `app.css` `:root`+`[data-theme]` + 3 行组件引用 | 中（改 token 值 + 3 处引用） | L2 深浅对照 | 还原 `:root` 块 + 3 行引用即可，零逻辑影响 |
| **PR2** | 布局对齐（sidebar 261px、消息 840 居中、字号/字体）+ **topbar 布局重排 + ☰ 图标态/收起动画强化** | `app.css`（+`index.html` 若需 topbar 结构微调） | 低（纯布局参数） | L2 | 还原布局声明 |
| **PR3** | 组件视觉（气泡 22px、工具卡弱底、思考块样式、代码块容器） | 仅 `app.css` | 低 | L2 | 还原组件声明 |
| **PR4** | 测试防护网扩展（置顶/菜单/模型菜单/代码块 banner 的纯函数提取测试） | 新增 `tests/frontend/test-*.mjs` | 低（纯测试） | `node tests/frontend/run-tests.mjs` | 删测试文件 |
| **PR5** | 输入框胶囊 + 圆形发送按钮（千问借鉴） | `index.html` 微调 + `app.css` | 中（结构微调） | L2 + 前端测试 | 还原 HTML 容器 |
| **PR6** | 工作目录小字（health cwd） | `handler.zig` 一行 + `app.js` + `index.html` | 低 | L2 + 前端测试 | 还原一行 + 元素 |
| **PR7** | 置顶分组（K16）+ ⋮ 更多菜单（K17）——**先 K16 后 K17**（见 §1.1c 依赖说明） | `app.js` renderGroup + `app.css` | 高（DOM 交互多） | L2 + PR4 测试 | 还原 app.js 函数 + 菜单 CSS |
| **PR8** | 模型选择器迁移（M1-M4）+ **theme-btn 移入顶栏**（顶栏右侧工具区） | `index.html` + `app.js` + `app.css` | 高 | L2 + PR4 测试 | 还原迁移 |
| **PR9** | 输出渲染强化（R1 代码块 banner + R2 复制常驻） | `app.js` + `app.css` | 中 | L2 + 前端测试 | 还原 banner 注入 |

**PR 依赖图**：
```
PR1 → PR2 → PR3 ─┐
                  ├→ PR5 → PR6
PR4（测试）───────┤
                  ├→ PR7 → PR8 → PR9
（PR4 在任何逻辑 PR 前）
```

**合并节奏**：每 PR 单独 commit + 单独验证，全部完成后才更新 CHANGELOG/REMAINING。任一步视觉不达标，只回退该 PR。

**测试防护网补强（PR4 内容）**：
现有 `tests/frontend/` 用花括号匹配提取 app.js 纯函数 + 最小 DOM stub（只覆盖 buildSegment 等 5 函数，不触及 DOM 交互路径）。PR4 新增：
- `test-session-list.mjs`：提取 `loadSessions` 的分组逻辑（pinned 分组、时间分组）为可测纯函数 `groupSessions(list, pinnedIds)`
- `test-model-menu.mjs`：提取模型列表渲染 `renderModelMenu(models, currentId)` 纯函数
- `test-more-menu.mjs`：提取会话更多菜单动作分发 `moreMenuAction(action, sessionId)` 纯函数（重命名/置顶/删除）
- `test-code-banner.mjs`：提取代码块语言标签注入 `decorateCodeBlocks(html)` 纯函数

> R3（流式标记）已延期至 G4，**不建 `test-stream-mark.mjs`**（无消费方，测试无意义）。

**提取策略**：与现有测试一致——被测逻辑抽为 `function` 顶层声明，测试文件用花括号匹配提取。DOM 副作用留在调用点，纯函数只做数据变换，测试不触 DOM。

---

## 1. 结构对比分析：我们的前端 vs DeepSeek 网页版

### 1.1 差距总表

| # | 维度 | DeepSeek 网页版 | 我们当前 | 差距 | 补齐方式 |
|---|------|-----------------|----------|------|----------|
| S1 | **turn 组织** | 每条 assistant 回复是独立 turn 容器（`.msg` 内嵌 思考块+文本+工具），turn 间有分隔 | 消息平铺，无 turn 容器；assistant 用 segments 数组堆叠 | **无 turn 边界语义**，reload 后无法区分"一轮回复" | 前端引入 turn 概念：`div.msg.assistant` 即 turn，内嵌 segments；工具/思考从属于所在 assistant |
| S2 | **思考块** | 折叠卡片 `已思考（用时 N 秒）`，浅色底 / 深色 `#1B1B1C` 底，圆角 12px，展开显示完整推理 | `div.thinking-block` 只有 `▶ Thinking` 无时长、无 markdown 化（流式时 textContent） | 思考块视觉弱、无时长信息 | 思考块改 DeepSeek 折叠卡样式 + 注入推理时长（**时长注入已存在**：前端 app.js:610 + 后端 sse.zig:157，见 §3.3 证据链） |
| S3 | **代码块** | 多层嵌套容器（`#2C2C2E` 行内 / `#1B1B1C` 块），语言标签 `powershell` + 复制按钮 `复制` | `pre` 深色底 + hover 复制按钮，无语言标签展示 | 代码块缺语言标识，复制按钮仅 hover 可见 | `pre` 前加语言标签（从 marked token 提取）、复制按钮常驻 |
| S4 | **用户消息气泡** | 淡蓝 `#EDF3FE` / 深 `#1B1B1C`，圆角 **22px**，padding 10px 16px，右对齐，max-width ~452px | `--bg-layer-02` 灰、圆角 6px、`border-top-right-radius:0`、max-width 70% | 气泡视觉弱（灰底 + 直角） | 改 DeepSeek 胶囊气泡：品牌蓝淡底、22px 圆角 |
| S5 | **输入框** | 白色胶囊容器（圆角 **24px**、1px 边框、阴影），内部输入透明无边框；发送按钮圆形 | `--bg-layer-03` 矩形 + 右侧 `Send` 矩形按钮 | 输入框是主要视觉焦点，我们不够醒目 | 输入区外包胶囊容器，textarea 无边框，发送按钮圆形主色 |
| S6 | **侧边栏** | 261px、无边框、纯背景（浅白/深黑），激活项胶囊 `#E4EDFD`/`#43454A` 圆角 100px | 240px、`--bg-deep` 最深色层、激活项左边框 2px 蓝 | 侧边栏层级过重、激活态非胶囊 | 宽度 261px、激活项胶囊高亮、去左边框 |
| S7 | **消息列表宽度** | max-width 840px、水平 padding 44px、居中 | 全宽撑满 `#main` | 大屏下文本跨度过长（阅读性） | 消息列表居中限宽 840px |
| S8 | **文字排版** | 正文 16px / 行高 28px，标题 h3 20px，行内 code `#2C2C2E` 底 12.25px | 正文 13px / 行高 1.6，代码 11px | 字号偏小（DeepSeek 更易读） | 正文提至 15-16px、代码 12.5px |
| S9 | **工具卡片** | 参考消息内嵌工具/搜索卡：`搜索到 26 个网页` 卡片 + `浏览 1 个页面` 引用卡，深色 `#35363A` 底 | `div.tool-card` 浅灰底 + 边框 + name-row | 工具卡有边框但缺 DeepSeek 的"工具活动摘要"感 | 工具卡保留 name-row + 输出，改为无边框弱底 + hover 强化 |
| S10 | **消息 meta** | 每条消息下方 model / 时间（我们已有 `.msg-meta`） | 已有 `model · timestamp` | ✅ 已具备 | 保持 |
| S11 | **流式更新** | 逐 token markdown 投影（full/live/code blocks） | `textContent` 追加 + done 后整块 `innerHTML` 替换 | 流式中 markdown 不解析 | 已在 G4 规划，本期不扩（依赖 parts 模型重构） |
| S12 | **主题切换** | 跟随系统 + 手动切换（深/浅/系统三态） | 手动深/浅两态（localStorage） | 无"跟随系统"选项 | 本期可选：加入 `system` 三态 |

### 1.1b 千问网页版（qianwen.com）输入框参考

用户指出可对照千问网页版输入框。实测（chrome-cdp）千问与 DeepSeek **同源设计系统**（输入框容器类名同为 `_77cefa5 _3d616d3`，776×124，深色 `#2C2C2E`，radius 24px）。千问输入框结构：

```
┌─ 输入框胶囊 (776×124, bg #2C2C2E, radius 24px) ───────────┐
│ 第一行 toolbar:  [🧠 深度思考] [🔍 智能搜索]                │
│   ds-toggle-button--selected (radius 18px, 选中 bg #283142) │
│ 第二行:  textarea (透明无边框)                              │
│ 右侧列:  [⦿ iconLabelPrimary 34px] [➤ primary 蓝 #5686FE]  │
│          圆形 34px, radius 50%, disabled → cursor:not-allowed│
└────────────────────────────────────────────────────────────┘
底部: "内容由 AI 生成，请仔细甄别" 提示文案 (28px 高)
```

**借鉴评估**：

| 千问元素 | 是否借鉴 | 理由 |
|----------|----------|------|
| 输入框胶囊容器（深 `#2C2C2E` / 浅白 / radius 24px） | ✅ | 与 S5 一致，采纳 |
| 圆形发送按钮（34px、radius 50%、主色 `#5686FE` 蓝、disabled 置灰） | ✅ | 比当前矩形 `Send` 更接近 DeepSeek/千问风格 |
| 底部提示小字位置 | ✅ 改造用途 | 千问/DeepSeek 放"AI 生成免责声明"，我们改为**显示当前工作目录**（`project_root`），用户明确要求（见 §3.5） |
| "深度思考/智能搜索" toggle | ❌ 不借鉴 | 我们无 deepthink/web-search 模式开关；现有 `/` 斜杠命令体系（K1）已覆盖"模式切换"需求，且不占输入框空间 |
| toolbar 第一行（toggle 行） | ❌ | 无对应能力，加入空 toolbar 徒增高度 |
| disabled 发送按钮置灰 + not-allowed | ✅ | 采纳：`#send-btn:disabled` 已存在，改圆形后保持一致 |

结论：输入框胶囊化 + 圆形发送按钮 + 底部小字（工作目录）三项采纳；toggle 行不借鉴（能力不匹配，K1 斜杠命令已解决该需求）。

### 1.1c 侧边栏功能与分组对比

实测 DeepSeek 与千问侧边栏，对照我们当前实现：

| 维度 | DeepSeek | 千问 | 我们（当前） | 结论 |
|------|----------|------|--------------|------|
| 内容宽 | 236px，无边框，深底 `#1B1B1C` | 256px，白底 `#F7F7F9` | 240px，`--bg-deep` 最深色层+右边框 | 宽度 261px；去右边框（§3.2 已定） |
| 新对话按钮 | 顶部胶囊（radius 100px，`#43454A` 高亮底，40px 高） | 顶部白底圆角 8px + 图标 | 普通矩形按钮 `+ New Session` | 改胶囊高亮（随 S6 激活态统一） |
| 分组方式 | **置顶 / 今天 / 昨天 / 7天内 / 30天内** | **用户自定义分组**（新分组/提示词/Vibe Coding）+ 最近对话 | 今天 / 昨天 / 本周 / 更早 | 本期加"置顶"分组（K16）；自定义分组需后端模型，不做 |
| 会话项 | 单行名字 14px，40px 高，**无 meta** | 单行名字 14px，36px 高，radius 8px，hover 淡底 | 名字 + `model · msgs` 两行 meta | 名字加粗、meta 弱化（`--text-faint` 更小字号），保留信息 |
| 激活态 | 胶囊 radius 100px `#43454A` | 淡底 `rgba(0,0,0,0.03)` radius 8px | 左边框 2px 蓝 + 深底 | 改胶囊高亮（S6 已定） |
| 特殊能力 | 置顶分组 | 建组/命名组/多标签页 | 时间分组、双击重命名、hover 删除、拖拽 resize | 保留 K3/K5/K6；增 K16 置顶 |

**侧边栏优化决策**：

| # | 优化项 | 借鉴来源 | 本期? | 实现 |
|---|--------|----------|-------|------|
| SB1 | **置顶分组** | DeepSeek 置顶 | ✅ 做 | 前端 localStorage 记录置顶 id 集合（`zagent-pinned`），置顶会话渲染到独立 `Pinned` 分组顶部；提供 pin/unpin 交互（hover 显 📌，或复用现有消息操作栏模式） |
| SB2 | 激活态胶囊 | DeepSeek `#43454A` radius 100px | ✅ 做 | S6 已覆盖 |
| SB3 | 新对话胶囊按钮 | DeepSeek 顶部胶囊 | ✅ 做 | `#new-session-btn` 改胶囊高亮（radius 100px / 或 12px），与 S6 一致 |
| SB4 | meta 行弱化 | DeepSeek 无 meta | ✅ 做 | `.session .name{font-weight:600}`；`.session .meta{font-size:10px;color:var(--text-faint)}` |
| SB5 | 千问自定义分组 | 千问 | ❌ 不做 | 需后端分组数据模型 + CRUD，超出纯前端改造范围，记 REMAINING |
| SB6 | 千问多标签页（云空间/AI创作/对话） | 千问 | ❌ 不做 | 我们单域单模型，无标签语义 |
| SB7 | 千问 hover 淡底 | 千问 `rgba(0,0,0,0.03)` | ✅ 做 | `.session:hover` 改淡底 + radius 12px（对齐 DeepSeek 会话项 radius 12px） |

SB1 详细设计（置顶分组）：

```
K16 置顶分组（纯前端，无后端改动）
- localStorage key: `zagent-pinned` → JSON 数组 ["<session-id>", ...]
- loadSessions(): 先按现有时间分组，再把 pinned 集合内的会话移到 `Pinned` 组顶部（顺序按 pin 时间）
- 交互：会话项 hover 显示 `📌` 按钮（或 context 菜单），点击 toggle pin；pinned 项显示实心 📌
- 空 pinned 组不渲染（复用 renderGroup 跳过空组逻辑）
- 保留：时间分组逻辑、双击重命名、hover 删除不受影响
```

> **K16 → K17 依赖顺序（评审响应）**：两者都改动会话渲染（loadSessions 排序 vs 管理入口），存在依赖：
> - **K17 的"置顶此对话/取消置顶"菜单项依赖 K16 的置顶存储与分组渲染**（菜单 toggle 调 K16 的 `togglePin()`，Pinned 组重排由 K16 负责）
> - **必须 K16 先行落地**：K16 独立完成时已有自己的入口（hover 📌 按钮），功能自洽、可单独验证；K17 在其上复用 `togglePin()` 增补菜单入口
> - **禁止 K17 先行**：若先做 K17 菜单，置顶项无存储/分组支撑，点击无效果 → 半成品
>
> 落地顺序：PR7 内部 **Step 1 = K16（📌 + Pinned 组）→ Step 2 = K17（⋮ 菜单）**，两步各自可独立 commit 验证。若 K16 视觉/交互不达标，K17 也不做，回退 K16 即可。

### 1.1d 会话管理功能与交互对比

用户指出此前只关注视觉/分组，遗漏了**会话的管理能力与交互方式**。实测三方：

| 管理功能 | DeepSeek | 千问 | 我们当前 | 交互方式（DeepSeek/千问） |
|----------|----------|------|----------|---------------------------|
| 重命名 | ✅ | ✅ | ✅ 双击名字（隐藏） | hover 会话项 → ⋮ 菜单 → 重命名 |
| 删除 | ✅ | ✅ | ✅ hover × | hover → ⋮ 菜单 → 删除 |
| 置顶/取消置顶 | ✅ | ✅ | ❌（计划 K16） | hover → ⋮ 菜单 → 置顶此对话/取消置顶 |
| 分享 | ✅ | ✅ | ❌ | hover → ⋮ 菜单 → 分享 |
| 导出对话 | ❌ | ✅ | ❌（DESIGN-WEB-RENDER.md 待实现有规划） | hover → ⋮ 菜单 → 导出对话 |
| 批量管理 | ❌ | ✅ | ❌ | hover → ⋮ 菜单 → 批量管理 |
| 移动到分组 | ❌ | ✅ | ❌ | hover → ⋮ 菜单 → 移动到分组 |
| 分组管理（建组/重命名/置顶/删除分组） | ❌ | ✅ | ❌ | hover 分组 → ⋮ 菜单 |

**核心发现（交互层）**：DeepSeek 与千问都把会话管理**收敛到单个 ⋮ 更多菜单**（hover 会话项显现），用户可发现、入口统一。我们当前是**分散的隐藏交互**——双击重命名（无提示）、hover × 删除（语义弱）、无更多操作入口。管理能力我们弱于两者。

**决策**：

| # | 优化项 | 借鉴 | 本期? | 实现 |
|---|--------|------|-------|------|
| MG1 | **⋮ 更多菜单**（会话项 hover 显现） | DeepSeek `_254829d` + 千问 `#qwpcicon-more` | ✅ 做 | 会话项 hover 显示 `⋮` 按钮，点击弹出菜单：**重命名 / 置顶·取消置顶 / 删除**（分享/导出/批量管理/移动到分组本期不做，记 REMAINING）。菜单项沿用现有 `.slash-item` 类名的视觉（复用 K1 弹层样式，新增 `.more-menu` 容器） |
| MG2 | **重命名入菜单** | 两者 | ✅ 做 | 菜单项"重命名"复用现有双击重命名逻辑（提取为 `renameSession(id)` 函数，双击与菜单共用） |
| MG3 | **删除入菜单** | 两者 | ✅ 做 | 菜单项"删除"复用现有 `deleteSession()` + confirm modal |
| MG4 | 置顶入菜单 | DeepSeek | ✅ 做 | 与 K16 置顶分组打通：菜单项"置顶此对话/取消置顶"toggle pin |
| MG5 | 分享/导出/批量/移动分组 | 千问 | ❌ 不做 | 分享需服务端、批量/移动分组需分组模型、导出在 `docs/DESIGN-WEB-RENDER.md` §待实现 已有规划（`GET /api/session/:id/export`）。本期只收敛管理入口，不加能力 |
| MG6 | 保留双击重命名、hover × 删除快捷 | — | ✅ 保留 | 快捷路径保留，⋮ 菜单作为可发现入口，两者不冲突 |

**MG1 交互细节**：
- 会话项 hover：`⋮` 按钮 opacity 0→1（复用 `.delete-btn` 显隐模式）
- 点击 `⋮`：弹出 `.more-menu`（absolute 定位，`--elevation-floating` 阴影，radius 12px），含 3 项：`重命名 / 置顶此对话·取消置顶 / 删除`
- 点击菜单外 / Esc：关闭（复用 confirm modal 的 Esc/遮罩模式）
- 删除项用 `.msg-action.danger` 红色（危险操作语义保留）
- 菜单不冒泡触发 `loadSession`（`e.stopPropagation()`）

**MG1 HTML 结构**（loadSessions renderGroup 内）：
```html
<div class="session [active]">
  <div class="name">…</div>
  <div class="meta">…</div>
  <span class="pin-btn">📌</span>       <!-- K16 置顶快捷 -->
  <span class="delete-btn">×</span>     <!-- 现有 -->
  <button class="more-btn">⋮</button>   <!-- MG1 新增 -->
  <div class="more-menu">              <!-- MG1 新增，默认隐藏 -->
    <div class="more-item" data-act="rename">重命名</div>
    <div class="more-item" data-act="pin">置顶此对话</div>
    <div class="more-item danger" data-act="delete">删除</div>
  </div>
</div>
```



对照 DeepSeek 网页版，我们**已具备且 DeepSeek 没有或不完整**的能力。改造只换"皮肤"（token/布局/圆角），**保留功能与 DOM 结构语义**：

| # | 优势项 | 位置 | 保留要求 |
|---|--------|------|----------|
| K1 | **斜杠命令 popover**（`/` 列表/过滤/键盘导航/回车执行） | `app.js` slashShow/slashUpdate/slashRender | CSS 重写但保留交互逻辑与 `.slash-popover/.slash-item` 类名 |
| K2 | **上下文工具分组**（连续 read/grep/glob 折叠为 "Gathering context"） | `app.js:1150`（wrapContextToolGroups）+ `.context-tool-group` | 保留分组逻辑与折叠交互 |
| K3 | **侧边栏拖拽 resize**（180-480px） | `app.js:77` + `#resize-handle` | 保留拖拽；默认宽改 261px |
| K4 | **ToolMeta 结构化展示**（exit_code/byte_count/match_count） | `sse.zig:227` tool_meta + `.tool-meta` | 保留 `.tool-meta` 渲染 |
| K5 | **会话时间分组**（Today/Yesterday/Week/Older） | `app.js:204` | DeepSeek 用"今天/昨天/7天内"，语义等价，保留 |
| K6 | **双击重命名 + hover 删除** | `app.js:178` + `.rename-input` | 保留 |
| K7 | **消息操作栏**（revert/copy/delete 用户消息） | `app.js` + `.msg-actions` | 保留 |
| K8 | **滚动中断保护**（距底 <50px 才自动滚底） | `app.js` isNearBottom | 保留 |
| K9 | **Markdown 块级增量**（data-markdown-key + hash） | `app.js` renderMdBlocks | 保留（G4 已实现） |
| K10 | **renderMd LRU 缓存 200 条** | `app.js` renderMd._cache | 保留 |
| K11 | **语法高亮**（highlight.js + Copy 按钮） | `app.js` addCopyButton + hljs | 保留；仅加语言标签 |
| K12 | **system prompt 分块渲染**（sys-block） | `app.js` renderSystemBlocks | 保留 |
| K13 | **空会话落盘 / 无会话自动创建 / abort 停止** | handler.zig | 后端不动 |
| K14 | **a11y**：`:focus-visible`、`aria-label`、modal Esc/遮罩关闭、`prefers-reduced-motion` | app.css + app.js | 保留 |
| K15 | **移动端断点**（768px 侧边栏抽屉） | app.css `@media` | 保留 |
| K16 | **置顶分组**（Pinned，localStorage，SB1） | app.js loadSessions 改造 | 新增功能，不破坏 K5 时间分组 |
| K17 | **⋮ 更多菜单**（重命名/置顶/删除，MG1） | app.js renderGroup 增补 + `.more-menu` | 新增功能；重命名/删除复用现有逻辑（MG2/MG3），置顶打通 K16 |

### 1.1e 模型替换模块对比（千问）

用户指出千问有明确的模型替换模块。实测千问模型选择器位于**主内容区顶部左上角**（非侧边栏），Radix UI dialog 触发（`aria-haspopup="dialog"`、`aria-controls="radix-:*"`）：

```
┌─ 顶栏 (h-12, 48px) ──────────────────────────────────────────┐
│ [🔽 Qwen3.7-千问] ← 模型胶囊按钮 (136×32, radius 8px)        │
│  ├ 模型名 (text-16, ellipsis)                                 │
│  └ 下拉箭头 (qwpcicon-down, rotate 过渡)                      │
│   → 点击弹 Radix dialog（模型列表）                           │
└──────────────────────────────────────────────────────────────┘
```

**三方对比**：

| 维度 | 千问 | DeepSeek | 我们（当前） |
|------|------|----------|--------------|
| 位置 | 主内容区顶部左上角（顶栏 h-12） | 侧边栏底部用户区 | 侧边栏底部 `#model-selector` |
| 形态 | 胶囊按钮 + 自定义 dialog 菜单 | 胶囊按钮/下拉 | 原生 `<select>` 下拉 |
| 触发 | Radix dialog（可滚动、可搜索） | 下拉列表 | 原生 select 展开 |
| 当前模型显示 | 模型名常驻可见（text-16） | 可见 | 可见（select value） |
| 降级 | — | — | localStorage 缓存 + "Default" 回退 |
| 新会话提示 | — | — | "applies to new sessions only" 提示 |
| a11y | Radix 全量（aria-expanded/controls/haspopup） | — | `aria-label="Model"` |

**我们的优势（保留）**：localStorage 持久化、API 失败降级到缓存/Default、"new sessions only" 提示、`aria-label`。这些比千问/DeepSeek 更稳。

**决策**：

| # | 优化项 | 借鉴 | 本期? | 实现 |
|---|--------|------|-------|------|
| M1 | **模型选择器移入顶栏** | 千问 | ✅ 做 | 从侧边栏 `#model-selector` 移到 `#topbar`（`#topbar` 现在是 `☰ + 会话名`，模型胶囊放会话名右侧；与千问一致：当前模型常驻可见） |
| M2 | **原生 select → 胶囊按钮** | 千问 | ✅ 做 | `<select>` 改自定义胶囊按钮（显示当前模型名 + `▾`），点击弹出自定义列表（`.model-menu`，复用 `.more-menu`/`.slash-popover` 弹层视觉）；每项显示模型名（id 作 title） |
| M3 | **保留全部降级逻辑** | — | ✅ 保留 | `loadModels()` 的 localStorage 缓存、空回退、onchange 提示全部保留，只改渲染形态（select → div 列表） |
| M4 | **Radix 完整 a11y** | 千问 | ⚠️ 部分 | 补齐 `aria-haspopup`/`aria-expanded`/`aria-controls` 到胶囊按钮 + 列表项 `role="menuitem"`；键盘 Esc/方向键导航（复用 slash popover 的键盘逻辑） |
| M5 | 模型分组/说明展示 | 千问（推断 dialog 含分组） | ❌ 不做 | 后端 `/api/model` 只返回 `{id,name,provider,context_window}`，无分组/说明字段；本期只换形态，数据源不动 |

**M2 交互细节**：
- 胶囊按钮：`#model-btn`（`display:flex; align-items:center; gap:6px; padding:4px 12px; border-radius:100px; background:var(--bg-layer-01); hover→var(--bg-layer-02)`），内：`<span id="model-btn-name">DeepSeek V4 Pro</span> <span class="caret">▾</span>`
- 点击：弹出 `.model-menu`（absolute，`--elevation-floating`，radius 12px），列表项：`<div class="model-item" data-id="...">name</div>`（选中项高亮 + ✓）
- 选中：写 `currentModel` + localStorage + 关闭菜单 + 触发"new sessions only"提示（复用现有 onchange 逻辑，提取为 `selectModel(id)`）
- 关闭：点菜单外 / Esc（复用 confirm modal 模式）
- 移动端：胶囊在窄屏保留在 `#topbar`（`#topbar` 已有 flex，胶囊 `flex-shrink:0`）

**文件**：`index.html`（`#model-selector` 移出 sidebar、`#topbar` 加 `#model-btn`）+ `app.js`（`loadModels` 渲染目标从 `#model-select` 改为 `#model-btn` 列表；onchange → `selectModel`）+ `app.css`（`.model-menu`/`.model-item`/`#model-btn` 样式）

### 1.1f 输出 markdown 渲染方案对比（DeepSeek/千问实测）

用户要求查看两家的脚本获取方案强化输出渲染。chrome-cdp 实测两家渲染实现：

**DeepSeek**：
- **语法高亮 = Prism.js**：network 加载 `prism-common.47bdd2a788.js`，`window.Prism` 存在（20 语言）
- 代码块结构（`md-code-block md-code-block-dark`，bg `#1B1B1C`，radius 12px）：
  ```
  div.md-code-block.md-code-block-dark
  ├── div.md-code-block-banner-wrap
  │   └── div.md-code-block-banner
  │       ├── "powershell"（语言标签）
  │       └── 复制按钮（ds-button--borderless）
  ├── pre > span > span.token.xxx（Prism token：function/punctuation/string/operator）
  └── svg ×2
  ```
- markdown 容器：`ds-markdown` + `ds-markdown-paragraph`（段落级容器）
- 语义标签渲染：`h3` 20px/700、`li`、`blockquote`（与 marked 输出一致）

**千问**：
- **markdown 组件化渲染**：`qk-md-paragraph`/`qk-md-strong`/`qk-md-head`/`qk-md-ul`/`qk-md-li`/`qk-md-code`/`qk-md-em`/`qk-md-blockquote`/`qk-md-hr` 等
- **流式状态标记**：组件带 `complete`/`incomplete` 类（当前 212 个 `complete`，流式时为 `incomplete`）——即 **flow 式流式投影**（每段独立渲染，完成才标 complete）
- 行内 code `qk-md-code`：浅色 bg `rgba(13,13,13,0.06)`、radius 6px、pad 2px 5px
- 语义标签：`h3`(qk-md-head) 28px、`strong`、`em`、`blockquote`、`hr`

**我们当前**：marked.js + DOMPurify + highlight.js，流式时 `textContent` 追加、done 后整块 `innerHTML=renderMd()` 替换；代码块 `pre>code[class*=language-]` + hljs。

**三方对比**：

| 维度 | DeepSeek | 千问 | 我们 |
|------|----------|------|------|
| 高亮库 | **Prism**（token 化 `span.token`） | 未暴露（bundle 内，推断 Prism/自研） | highlight.js |
| 代码块 | `md-code-block` 容器 + 语言标签 banner + 复制按钮 | `qk-md-code` 组件 | `pre>code` + hover 复制 |
| markdown 结构 | `ds-markdown-paragraph` 段落容器 | `qk-md-*` 组件 + **complete/incomplete** | 整块 innerHTML |
| 流式策略 | 推断逐段/逐 token 投影 | **组件级 complete/incomplete 状态** | textContent 追加 + done 整块替换 |
| 语义标签 | 原生 h3/li/blockquote | 原生 + qk-md 包装 | marked 原生输出 |

**决策**：

| # | 优化项 | 借鉴 | 本期? | 实现 |
|---|--------|------|-------|------|
| R1 | **代码块语言标签 banner** | DeepSeek `md-code-block-banner` | ✅ 做 | 渲染后处理 `pre`:从 `code[class*=language-]` 提取语言名，pre 前插 `<div class="code-banner"><span class="code-lang">lang</span><button class="copy-btn">复制</button></div>`；banner 随 pre 一起包进容器 `.code-block`（bg `--bg-layer-01`，radius 12px）。S3 已列，此处给具体结构 |
| R2 | **复制按钮常驻**（hover 可见） | DeepSeek banner 内常驻 | ✅ 做 | 复制按钮移入 banner（原 pre 内 hover 显隐保留为兜底） |
| R3 | **流式段落标记**（complete/incomplete） | 千问 `qk-md-* complete` | ❌ 延期 | 价值依赖 G4 完整投影消费方；本期做会产生**孤立 `.incomplete` 类**（无消费者、过渡期死代码）。**与 G4 一起实施**（G4 落地时类名才被投影机制消费） |
| R4 | **Prism 替换 highlight.js** | DeepSeek | ⚠️ 评估 | 两者能力相当。我们的 `vendor/highlight.min.js` 已注入且 G5 已激活。**本期不换库**（避免回归 + vendor 体积），仅对齐代码块容器视觉（R1/R2）。换 Prism 记 REMAINING |
| R5 | **段落级容器** `ds-markdown-paragraph` | DeepSeek | ❌ 暂缓 | 需要 renderMd 返回结构拆分，与 G4 块级增量合并推进。与 R3 同步在 G4 落地 |

> **R3 延期理由（评审响应）**：R3 的唯一消费者是 G4 的完整投影机制，而 G4 依赖 parts 模型重构（本期不做）。若本期加入 `.incomplete` 类，过渡期内该 CSS/类名无任何实际作用（流式仍走 textContent 追加），属孤立死代码。故 R3 移入"本期不做"，与 G4、R5 一并实施，避免过渡期代码。


**执行原则**：CSS 选择器沿用现有类名（`.tool-card`、`.thinking-block`、`.msg`、`.slash-popover` 等），只改声明块内的值——确保 K1-K17 的 JS/DOM 依赖不破坏。

### 1.3 结论：取长补短优先级

**本期做（P0）**：S1 不需要（turn=assistant 已隐含）、S2 思考块样式、S3 代码块语言标签、S4 用户气泡、S5 输入框胶囊、S6 侧边栏、S7 消息限宽、S8 字号、S9 工具卡片样式、SB1 置顶分组、SB2-SB4/SB7 侧边栏视觉、MG1-MG4 会话管理菜单、M1-M4 模型选择器移顶栏、R1-R2 输出渲染强化（代码块 banner + 复制常驻）。这些全部是 **CSS 为主 + 少量 JS 增补**（思考块时长、代码块语言标签、置顶 pin、⋮ 菜单、模型胶囊）。保留 K1-K15 全部功能，新增 K16-K17（**顺序：先 K16 后 K17**）。

**执行**：按 **§0 拆 9 个 PR** 分批落地，每 PR 独立 commit + L2 验证 + 可回退。逻辑 PR 前先完成 PR4 测试防护网扩展。

**本期不做（后续）**：S11 流式 markdown 投影（依赖 parts 模型重构，见 `docs/DESIGN-WEB-RENDER.md` G4）、R3 流式 complete 标记 + R5 段落级容器（**与 G4 一并实施**，避免孤立类名）、S12 跟随系统（`prefers-color-scheme` 三态，低成本可顺手加）、SB5 千问自定义分组、SB6 千问多标签页、MG5 分享/导出/批量/移动分组、M5 模型分组/说明、R4 Prism 替换 hljs（部分入 REMAINING）。K1-K17 保留不受影响。

---

## 2. DeepSeek 网页版设计 token（chrome-cdp 实测）

### 2.1 浅色主题（`chat.deepseek.com` 实测）

| token | 值 | 用途 |
|-------|-----|------|
| 页面背景 | `#FFFFFF` 纯白 | body / sidebar |
| 正文 | `#0F1115` | 主文本 |
| 主色 accent | `#3964FE` | 链接 / 发送按钮 / 焦点 |
| 链接 | `#3964FE` | a |
| 用户气泡 | `#EDF3FE`（淡蓝） | `.msg.user` 背景 |
| 选中/激活 | `#E4EDFD`（淡蓝） | 侧边栏激活项 / hover |
| 次级区块 | `#F9FAFB`（极浅灰） | 思考块 / 代码块容器 |
| 行内 code | `#2C2C2E` 深底 | 行内代码（浅色下也保持深底对比） |
| 侧边栏宽 | 261px | `--sider-width` |
| 消息 max-width | 840px | `--message-list-max-width` |
| 消息 padding | 44px 水平 | `--message-list-padding-horizontal` |
| 输入框容器 | 白底 + 1px 边框 + 圆角 24px | 胶囊 |
| 气泡圆角 | 22px | 用户消息 |
| 卡片圆角 | 12px | 思考块 / 代码块 |
| 正文字号 | 16px / 行高 28px | 消息正文 |
| 代码字号 | 13px / 行内 12.25px | pre / code |
| 字体 | Inter + system-ui + CJK patch | `--dsw-font-family` |

### 2.2 深色主题（实测）

| token | 值 |
|-------|-----|
| 页面背景 | `#151517` |
| 正文 | `#F9FAFB` |
| 用户气泡 | `#1B1B1C`（比背景略亮） |
| 激活项 | `#43454A`（胶囊圆角 100px） |
| 代码/卡片底 | `#1B1B1C` / `#2C2C2E` |
| 搜索卡/工具卡 | `#35363A` |
| 输入框容器 | `#2C2C2E` + 边框 `rgba(255,255,255,0.06)` + 圆角 24px + 阴影 `rgba(0,0,0,0.02) 0 4px 10px` |
| 链接 | 白 `#FFFFFF` / `#F9FAFB` |

### 2.3 token 映射方案

保持现有 CSS 变量名（`--bg-base`、`--accent-base` 等），**只改值**，避免改 200+ 处引用。映射：

| 现有变量 | 浅色新值 | 深色新值 | 说明 |
|----------|----------|----------|------|
| `--bg-deep` | `#F9FAFB` | `#1B1B1C` | 深层/侧边栏（**深色 ≠ main `#151517`，保留一档亮差区分**；浅色微差于白 main） |
| `--bg-base` | `#FFFFFF` | `#151517` | 主背景 |
| `--bg-layer-01` | `#F9FAFB` | `#1B1B1C` | 卡片/思考块/次级区块 |
| `--bg-layer-02` | `#F0F1F3` | `#26262A` | 通用 hover/表格头/按钮底（**非气泡**，保持中性灰） |
| `--bg-layer-03` | `#F5F5F7` | `#2C2C2E` | 输入容器/控件底（浅色近白 + 1px 边框、深色对齐实测 `#2C2C2E`） |
| `--bg-inline-code`（新增） | `#2C2C2E` | `#2C2C2E` | **行内 code 专用**：深浅两主题都保持深底高对比（对齐 DeepSeek 实测），替代原 `.msg :not(pre)>code` 对 `--bg-layer-03` 的引用 |
| `--bg-user-bubble`（新增） | `#EDF3FE` | `#1B1B1C` | **用户气泡专用**（淡蓝/黑），替代原 `--bg-layer-02` 的 `.msg.user` 用法 |
| `--bg-active`（新增） | `#E4EDFD` | `#43454A` | **侧边栏激活项/胶囊高亮专用**，替代原 `--bg-layer-01`+左边框 |
| `--text-strong` | `#0F1115` | `#F9FAFB` | 强调文本 |
| `--text-base` | `#0F1115` | `#F9FAFB` | 正文 |
| `--text-muted` | `#667085` | `#B4B8BE` | 次级 |
| `--text-faint` | `#9CA3AF` | `#71717A` | 最淡 |
| `--accent-base` | `#3964FE` | `#3964FE` | 主色（两主题同） |
| `--border-base` | `#E5E7EB` | `rgba(255,255,255,0.08)` | 边框 |
| `--border-muted` | `#F3F4F6` | `rgba(255,255,255,0.04)` | 淡边框 |
| `--border-focus` | `#3964FE` | `#3964FE` | 焦点 |
| `--radius` | 气泡 22px / 卡 12px / 输入 24px / 激活 100px | 同左 | 圆角体系 |
| `--text-base-fs` | 15px | 15px | 正文 |
| `--font-code` | JetBrainsMono | 同左 | 保持 |

> **token 语义冲突修复（审查发现）**：原 §2.3 把 `--bg-layer-02` 映射为气泡淡蓝 `#EDF3FE`、`--bg-layer-03` 映射为输入容器色——但这两个 token 被 19 处多语义组件共用（`--bg-layer-02`: 11 处 hover/表格头/按钮；`--bg-layer-03`: 8 处行内 code/输入/控件），改值会大面积波及。**新增 3 个专用 token 解耦**：
> - `--bg-user-bubble`（气泡淡蓝/黑）→ 替代 `.msg.user`（app.css:45）
> - `--bg-active`（激活胶囊）→ 替代 `.session.active`（app.css:34）+ hover 胶囊
> - `--bg-inline-code`（深浅同深底）→ 替代 `.msg :not(pre)>code`（app.css:56）
>
> PR1 执行时同步改这 3 处引用，其余 `--bg-layer-02/03` 保持中性值不变。被改动的 3 处不与其他组件共用 token，解耦后各自独立。

语义状态色（success/warning/error/diff/syntax）保持现有，但**降低饱和度**以贴近 DeepSeek 极简风（`#E4EDFD` 类淡蓝语义）。

---

## 3. 设计要点

### 3.0 Token 分层评估（评论建议）

**评论者**：建议 CSS 变量改用 Design Token 层级（primitive 原始色板 → semantic 语义 → component 组件三层）。

**数据核查**（app.css 实测）：44 个 token 定义 / 210 次 `var()` 引用 / 单文件 152 行。其中 33 个色值 token 已用 `[data-theme="light"]` 覆盖（换肤），11 个非色值 token（font/radius/text-size/transition）不随主题变。16 个 token 目前未被直接引用（state-*/diff-*/syntax-*，部分被浅色覆盖或语法高亮类间接用）。

**评估结论：不引入完整三层分层。** 理由：

1. **规模不匹配**：三层分层（primitive+semantic+component）是 1000+ token / 多产品线 / 有组件库消费者的大型设计系统范式（opencode v2、Salesforce Lightning）。本项目 44 token 单文件，分层收益趋近于零
2. **已具备分层核心收益**：当前"语义命名 token + `[data-theme]` 覆盖换肤"正是 Design Token 的 semantic 层用法——换肤能力已实现，再拆 primitive 层只是多一层间接
3. **分层成本与"改动过大"矛盾**：44→100+ token，210 处引用全部改为 `var(--semantic)` 引用 `var(--primitive)`，diff 翻倍、回退面扩大——与评审者自身提出的"避免打包大 PR / 回退成本"诉求冲突
4. **token 纪律本已偏松**：16 个死 token 说明维护已重；再引入层级会增加维护负担而非降低

**采纳的子项（token 命名语义化）**：
- 保留现有 44 个 token 名（改动即 210 引用全动，违背"保留变量名只改值"原则）
- **不新增 primitive 层**；仅在本期 PR1 中顺手清理死 token（state-bg/fg 若确认无引用则删除，或标注 `--legacy-` 保留）
- 新增 6 个语义 token（布局 3 个 + 背景解耦 3 个）：`--msg-max-width`/`--sider-width`/`--bubble-radius`/`--bg-user-bubble`/`--bg-active`/`--bg-inline-code`（后 3 个为 §2.3 token 冲突修复，见下），沿用语义命名，为未来真正需要分层时留出演化路径

**死 token 精确清单**（定义数 44，`var()` 引用数 28，差集 16；双向核对无"引用未定义"）：

| 死 token | 为何死 |
|----------|--------|
| `--accent-success`、`--accent-warning` | 定义但无 `var()` 引用（成功/警告色只用在了工具 error 态 `--accent-error`） |
| `--state-bg-success/warning/danger/info` | 全 8 个，定义未引用 |
| `--state-fg-success/warning/danger/info` | 同上 |
| `--diff-added`、`--diff-removed` | 无 diff 视图功能 |
| `--syntax-keyword/string/function` | highlight.js 用自己的内置主题色，未消费我们的 token |
| `--transition-panel` | 侧边栏动画定义的是 `--transition-fast`，panel 值未用 |

**处理**：PR1 中删除这 16 个死 token（零风险，无引用）。注意 `--state-*`/`--accent-success` 在 `[data-theme="light"]` 覆盖行也有定义——删除时两处都删，避免"浅色覆盖指向已删 token"。

**演进时机**（未来若需分层）：当出现 ≥3 套主题、或多组件库消费者、或 token >200 时，再按 `--color-*`(primitive) + `--bg-*`/`--text-*`(semantic) 重构。本期不执行。

### 3.1 CSS 变量替换（`app.css` :root + `[data-theme="light"]`）

重写两套 token 值，保持变量名。同时新增 6 个语义变量（3 布局 + 3 背景解耦）：
```css
--msg-max-width: 840px;
--sider-width: 261px;
--bubble-radius: 22px;
--bg-user-bubble: #EDF3FE;   /* 浅色；深色 #1B1B1C */
--bg-active: #E4EDFD;        /* 浅色；深色 #43454A */
--bg-inline-code: #2C2C2E;   /* 深浅同色，行内 code 高对比 */
```
PR1 执行时同步改 3 处引用：`.msg.user`→`var(--bg-user-bubble)`、`.session.active`→`var(--bg-active)`、`.msg :not(pre)>code`→`var(--bg-inline-code)`。

### 3.2 布局调整

| 元素 | 当前 | 改为 |
|------|------|------|
| `#sidebar` | `width:240px` | `width:261px`（`--sider-width`） |
| `#messages` | `padding:16px` 全宽 | `max-width:840px; margin:0 auto; padding:16px 44px` |
| `#input-bar` | 透明 + 底部边框 | 外层胶囊：`max-width:840px; margin:0 auto; background:var(--bg-layer-03); border:1px solid var(--border-base); border-radius:24px; box-shadow:var(--elevation-raised); padding:8px 12px`（对齐 DeepSeek 输入容器：深 `#2C2C2E`/浅 `#EAECEF`，§2.3 `--bg-layer-03`；**非 `--bg-base`**，否则胶囊与页面同色无区分） |
| `textarea` | 自身有边框 + `--bg-layer-03` | 无边框透明 `background:transparent`（胶囊容器已提供底色），仅内部 `flex:1` |
| `#send-btn` | 矩形 `Send` | 圆形主色按钮（34px、`border-radius:50%`、图标 `→`；disabled 置灰 + `cursor:not-allowed`），参考千问 `ds-button--primary`（浅 `#5686FE`/深 `#3964FE`） |
| `#stop-btn` | 矩形 `Stop` | 保持文字 `Stop` 但同圆形化，或改红色圆形 `■` 图标（视觉与 send 对称） |
| 侧边栏激活 | 左边框 2px 蓝 + `--bg-layer-01` | 胶囊高亮 `background:var(--bg-active); border-radius:100px`（去左边框） |
| 用户气泡 | 灰 6px 直角 `--bg-layer-02` | 淡蓝 22px 胶囊 `background:var(--bg-user-bubble); border-radius:22px` |

**topbar 布局重排（PR2）**：当前 `#topbar` 仅 `☰ + 会话名`。重排后：
```
┌─ #topbar ────────────────────────────────────────────────┐
│ [☰] 会话名 ... 右侧工具区（PR2 空位，PR8 填充）            │
│      左侧: sidebar-toggle + 会话名                        │
│      右侧: 预留 .topbar-actions 容器（PR8 放 model-btn + theme-btn）│
└───────────────────────────────────────────────────────────┘
```
- PR2 只做结构：`#topbar{display:flex;justify-content:space-between;align-items:center}`，右侧加空容器 `#topbar-actions`（CSS 可见性隐藏或用 `visibility:hidden` 占位），**不迁入任何按钮**
- ☰ 图标态强化：`#sidebar-toggle` 折叠时显示 `▸`（CSS `::after` 或 JS 切换），收起动画沿用现有 240ms `--transition-panel`
- 目的：PR2 完成 topbar 骨架，PR8 直接往 `#topbar-actions` 放按钮，避免 PR2/PR8 结构冲突

**theme-btn 位置调整（PR8，用户要求）**：当前 `#theme-btn` 在 sidebar-header 与 New Session 之间（侧边栏顶部），侧边栏收起时不可见。移入 `#topbar-actions`（右侧工具区）：
- 与千问/DeepSeek 一致：DeepSeek 顶栏右上 34px 圆形、千问顶栏右侧 32px 圆形
- 全局常驻：侧边栏收起时主题切换仍可用
- 移除 sidebar 中的 `#theme-btn` 元素，样式从按钮化改为顶栏图标化（`34px` 圆形胶囊，`--bg-layer-01` 底 + hover 提亮，沿用现有 ☀/☾ 图标）

### 3.3 组件样式对齐

**思考块**（S2）：
```css
.thinking-block{background:var(--bg-layer-01);border-radius:12px;padding:10px 12px}
.thinking-block .header{color:var(--text-muted);font-size:12px}
.thinking-block .header::before{content:'已思考';...} /* 或保留 ▶ 图标 + 时长 */
```
JS 增补：流式 `thinking_end` 时在 header 写入 `（用时 N 秒）`（当前只有 `▶ Thinking`，app.js:610 已有 `dur` 变量可复用）。

> **`dur` 可用性证据链（评审核实）**：评论者质疑 `dur` 是否在 thinking_end 被正确赋值。核实结论——**端到端已通，无需新增逻辑**：
> - 前端 `app.js:606` thinking_end 处理器内 `:609` `var dur = d.duration_ms ? (d.duration_ms/1000).toFixed(0)+'s' : ''`，`:610` 注入 `.header`。`dur` 为 thinking_end 局部变量，作用域正确
> - 后端 `sse.zig:57` `thinking_start_ms` 字段，`:118` thinking_start 时记录 `Io.Timestamp` 毫秒，`:157` `duration_ms = end_ms - thinking_start_ms`（防御 `end<=start` → 0），`:159` 发送 `{"duration_ms":N}`
> - 数据流：`thinking_start`→记 `thinking_start_ms`→`thinking_end`→算 `duration_ms`→SSE JSON→前端 `d.duration_ms`→`dur`→header
> - S2 只需改 CSS（`.thinking-block` 样式），header 时长注入已存在，**零 JS 改动**

**代码块语言标签**（S3）：
- 在 `renderMd`/`renderMdBlocks` 后处理：`pre > code[class*=language-]` 中提取语言名，前置 `<div class="code-lang">powershell</div>`
- 复制按钮从 hover-only 改为常驻（`opacity:1`）

**工具卡片**（S9）：
```css
.tool-card{background:var(--bg-layer-01);border:none;border-radius:12px;padding:8px 12px}
.tool-card:hover{background:var(--bg-layer-02)}
.tool-card .name{color:var(--text-base);font-weight:500}
```
去掉 `border:0.5px solid`，改弱底 + hover 提亮；error 态保留红色强调。

**消息 meta**：保持现状（S10 已具备）。

### 3.4 主题切换三态（可选 S12）

`theme-btn` 循环 dark → light → system；`system` 用 `window.matchMedia('(prefers-color-scheme: dark)')` 解析后写 `data-theme`，并监听变化。

### 3.5 底部工作目录小字（借鉴千问免责声明位）

千问/DeepSeek 在输入框下方放一行 AI 免责声明小字。我们改为**显示当前工作目录**（`project_root`），既是全局定位信息，也方便用户确认 agent 的 cwd 作用域。

**前端**：
```html
<div id="input-bar">
  <div id="input-wrap">...textarea + stop + send...</div>
  <div id="cwd-hint">~/Projects/zAgentCore</div>
</div>
```
CSS：`#cwd-hint{font-size:11px;color:var(--text-faint);text-align:center;padding:4px 0;font-family:var(--font-code);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}`

**数据来源**：扩展 `GET /api/health` 响应带 `cwd` 字段。`Context.project_root` 已存在（server.zig:225 注入 handler Context），后端只需：
```zig
if (std.mem.eql(u8, path, "/api/health")) {
    const body = try std.fmt.allocPrint(a, "{{\"status\":\"ok\",\"cwd\":\"{s}\"}}", .{ctx.project_root});
    return respondJson(request, body);
}
```
前端 `init` 时 fetch `/api/health` 写入 `#cwd-hint`；失败则隐藏该元素（不阻塞主流程）。

**取舍**：不显示免责声明——我们无搜索来源，语义不符；工作目录是用户明确的差异化需求。

---

## 4. 涉及文件（按 PR 归属）

| 文件 | PR | 改动 |
|------|-----|------|
| `src/frontends/web/app.css` | PR1-3 | token 值重写 + 布局参数 + 组件样式（纯样式，三 PR 分批） |
| `src/frontends/web/app.css` | PR5/7/8/9 | 胶囊输入框 / more-menu / model-menu / code-banner / topbar-actions / theme-btn |
| `src/frontends/web/app.js` | PR4 | 新纯函数抽取（groupSessions/renderModelMenu/moreMenuAction/decorateCodeBlocks）供测试 |
| `src/frontends/web/app.js` | PR6/7/8/9 | health cwd / 置顶+⋮菜单 / 模型胶囊 / 代码块 banner |
| `src/frontends/web/index.html` | PR5/6/8 | 输入框胶囊容器 + cwd-hint 元素 + model-selector 迁移、topbar 加 model-btn + **`#topbar-actions` 容器 + `#theme-btn` 移入** |
| `src/frontends/web/index.html` | PR2 | `#topbar` 结构重排 + `#topbar-actions` 空容器占位 |
| `src/frontends/web/handler.zig` | PR6 | `/api/health` 响应加 `cwd` 字段（一行） |
| `tests/frontend/test-*.mjs` | PR4 | 新增 4 个测试文件（session-list/model-menu/more-menu/code-banner） |

无核心层改动。逻辑 PR（PR4/6/7/8/9）走 `node tests/frontend/run-tests.mjs`（PR4 后断言数从 37 → 60+）；纯样式 PR（PR1/2/3/5）依赖 L2 视觉验证 + L0 语法心智检查。

---

## 5. 验证

1. **L0 静态**：`node tests/frontend/run-tests.mjs` 全绿（PR4 前 37 断言，PR4 后 60+）
2. **L1 诊断**：chrome-cdp `console` 无 error；`network --filter=4xx,5xx` 干净
3. **L2 视觉（必做）**：每个 PR 单独验证。用户浏览器硬刷新（Ctrl+F5）后对照：
   - 浅色主题 = DeepSeek 白底淡蓝气泡 + 蓝 accent
   - 深色主题 = DeepSeek `#151517` 黑底 + `#1B1B1C` 气泡
   - 消息居中 840px、输入框胶囊 24px、侧边栏 261px + 胶囊激活
   - 思考块带时长、代码块带语言标签、复制按钮常驻
   - 与 `chat.deepseek.com` 同屏对照逐项确认

4. **K1-K17 功能回归（L2 必做）**：PR7/8/9 后逐项点验不丢失——`/` 斜杠命令弹出、上下文工具分组折叠、侧边栏拖拽、消息操作栏、会话双击重命名、滚动中断保护、system prompt 分块、移动端抽屉、**置顶分组**（pin/unpin、刷新保持、pinned 组置顶）、**⋮ 更多菜单**（hover 显现、重命名/置顶/删除执行、菜单外点击关闭、不误触发 loadSession）。任一失效即回退该 PR。**K16→K17 按序验证**（先验 📌 置顶，再验 ⋮ 菜单置顶项）。

5. **PR7 功能测试（L0，PR4 后）**：`test-session-list.mjs`（groupSessions pinned/时间分组）、`test-more-menu.mjs`（moreMenuAction 分发）

6. **模型选择器验证（M1-M4，PR8）**：模型胶囊在顶栏显示当前模型；点击展开模型列表；选中后写 localStorage + "new sessions only" 提示；API 失败降级缓存/Default；Esc/外点关闭；选中项 ✓ 高亮。配套 `test-model-menu.mjs`。**theme-btn 迁移验证**：按钮位于顶栏右侧 `#topbar-actions`；侧边栏收起时仍可切换主题；sidebar 中不再有 `#theme-btn`；☀/☾ 图标与 localStorage 持久化正常。

7. **输出渲染验证（R1-R2，PR9）**：代码块含语言标签 banner + 常驻复制按钮；代码块复制/语法高亮（K11）不回归。配套 `test-code-banner.mjs`。（R3 流式标记延期至 G4，本期不验）

8. **千问借鉴项验证（PR5/6）**：发送按钮圆形化后 `disabled` 态仍置灰不可点；`Stop` 与 `Send` 视觉对称；`#cwd-hint` 显示当前工作目录（`/api/health` cwd 字段）；health 失败时小字隐藏且页面正常。

9. **PR 级回退**：任一 PR 视觉/功能不达标 → `git revert <pr-commit>`，其余 PR 不受影响。

## 6. 风险

| 风险 | 缓解 |
|------|------|
| 变量值改动影响语义状态色对比度 | 降低饱和度但保留 state-bg 深底，浅色下实测对比 |
| 胶囊输入框破坏移动端布局 | 保留现有 `@media(max-width:768px)` 断点，胶囊在窄屏 `margin:8px` |
| 代码块语言标签提取依赖 marked token | `marked.lexer` 已内置（vendor/marked.min.js），DOM 后处理兜底 |
| turn 概念不引入（S1 不做） | turn=assistant 已隐含，工具从属于所在 assistant，本期不拆 DOM |
| `project_root` 含特殊字符破坏 JSON | 后端 `allocPrint` 前做 JSON 转义（`jsonEscapeBuf` 已有现成实现，sse.zig 使用） |
| **改动面过大（评审）** | §0 拆 9 PR，每 PR 独立 commit + 独立 L2 验证 + 独立回退；CSS 与 JS 分离，样式回退不影响逻辑 |
| **无前端测试防护网（评审）** | PR4 先扩测试（groupSessions/renderModelMenu/moreMenuAction/decorateCodeBlocks 四纯函数），逻辑改动前先行 |
| **app.css 完全重写（评审）** | PR1-3 拆三步（token→布局→组件），每步只动一组声明；token 保留变量名只改值，减少 diff |
| **app.js 多处改动（评审）** | 逻辑改动全部抽纯函数（PR4 可测），DOM 副作用集中到调用点；每 PR 只动一个功能域 |
| **R3 孤立死代码（评审）** | R3 延期至 G4 与完整投影一并实施；本期不做 `.incomplete` 类，无过渡期死代码 |
| **K16/K17 顺序不清（评审）** | 明确 K16 先行（置顶存储+分组渲染+📌 入口自洽）→ K17 复用 `togglePin()` 增菜单项；PR7 内两步独立 commit |
| **Token 分层（评论建议）** | 评估见 §3.0：规模不匹配不引入三层分层，保留语义 token + 主题覆盖；本期仅清理死 token，避免 210 引用全动 |
| **theme-btn 迁移影响（用户要求）** | 移入 topbar 后 app.js:24 的 `#theme-btn` 引用仍生效（同 id）；JS 只按 id 绑定不依赖父级，迁移零逻辑改动。PR8 验证侧边栏收起后可切换 |
