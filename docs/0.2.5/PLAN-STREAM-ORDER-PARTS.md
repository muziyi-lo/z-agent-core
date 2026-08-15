# Plan STREAM-ORDER-PARTS: Web 前端 parts 模型重构（根治流式/双轨渲染顺序）

## 状态: ✅ 已完成（v0.2.5，REMAINING 已标记）

## 前置依赖

| 阻塞者 | 状态 | 被阻塞 |
|--------|------|--------|
| 无 | — | — |

## 不做

- **不因兼容性掣肘重构**（正式版前约束）：v1.0 前无向后兼容义务——SSE 协议、JSONL 会话格式、DOM 结构均可自由变更，不设迁移/兼容层。本方案保持协议/JSONL 不变仅因"不需要改"，非因"不能改"；若阶段中发现协议层调整更干净（如给 content 加阶段边界事件），可随时纳入。
- **不引入前端框架/工具链**（Vite/SolidJS/TS/monorepo）：本项目是单二进制 `@embedFile` 嵌入 1150 行 HTML（`handler.zig:14`），框架级重写工程量大、且零前端测试防护（N6），大爆炸必翻车。参考 pi-repos：最轻量的实现也能用"有序数据数组"解决顺序问题。
- **不一次性重写**：无测试防护网，分阶段推进，每步浏览器双轨验证（LRN-20260806-007）。
- **不改后端 SSE 协议**：后端已按阶段发多段 `content_start`（`provider.zig:330-337`），协议信息完整。
- **不改 reload 的 JSONL 结构**：JSONL 的 assistant/tool 消息对已隐含正确顺序，复用。

## 问题

**现象**：流式渲染时 assistant 最终答案文本出现在工具卡片之前（内容块被"钉"在中间），与 reload 路径正确顺序不一致。实测"几点了？"轮渲染为 `[思考1][内容-全部][工具][思考2][工具]`。

**根因**：前端 `content_start` 用 `if (!contentDiv)` 守卫丢弃后续 content 阶段（`index.html:709`），所有 content 合并进首个 div——后端明明发了多段 `content_start`，前端只认第一段。**本质**：前端是"命令式 DOM 拼装"架构，顺序靠 `insertBefore`/`appendChild` 人肉维护，而非数据结构；content 又是不透明的单流，阶段信息被丢弃。

## 概览

- **改动范围**：4 个文件——阶段 0 拆分出 `app.js`（约 960 行 JS）/`app.css`（约 145 行 CSS），`handler.zig` 加 2 个 embed，之后 parts 重构均在 `app.js` 内；前后端协议不变，reload 的 JSONL 语义不变。
- **核心思路**：vanilla JS 引入 **parts 数据模型**——每条 assistant 消息 = 有序 segments 数组（`{type:'reasoning'|'text'|'tool'}`），**一个纯渲染函数**按数组序渲染，流式与 reload 共用。顺序 = 数组序（不可能错），双轨合一根治 LRN-20260806-007，content 阶段信息保留（`text` 一阶段一个 segment）。
- **参考实现（三份对比）**：
  | 项目 | 形态 | 顺序来源 | 工具位置 |
  |------|------|----------|----------|
  | opencode | SolidJS Web | `parts[]` 数组序，`text-start` 每段新建 part | part 内联 assistant 消息 |
  | DeepSeek-Reasonix | Wails 桌面 React | `items[]` 数组序，单 assistant 块 + 工具项后置 | 独立 item（内容在前） |
  | **pi-repos** | **轻量 TUI** | `Message[]` 数组序，工具 = 独立 `bashExecution` 消息 | 独立消息 |
  | 我们（现状） | 命令式 DOM | **DOM 插入位置** | 命令式 appendToAsst |
  
  **结论**：三份参考（含最轻量的 pi-repos）都靠"有序数据数组"而非 DOM 位置。方向一致，无分叉。

## 设计要点

### 1. 数据模型：assistant 消息 = 有序 segments

```js
// 一条 assistant 消息的渲染数据
{ id, model, timestamp,
  segments: [
    { type: 'reasoning', text, complete },
    { type: 'tool', name, args, status, output },
    { type: 'text', text },        // 一阶段一个
    ...
  ]
}
```

顺序即 segments 数组序。流式事件映射：`thinking_start/delta/end` → reasoning segment；`content_start` → **新 text segment**（这正是对齐 opencode 的 `text-start`）；`tool_start/delta/meta/error` → tool segment；reload 的 JSONL assistant/tool 消息对 → 同一结构。

**命名约定**：流式期间 `curSegments` 即当前消息对象的 `msg.segments` 引用（阶段 2 代码用 `curSegments` 指代 `msg.segments`），两者同一数组。

### 2. 统一渲染函数：流式与 reload 共用

```js
function renderAssistantMessage(container, msg) {  // 纯渲染
  msg.segments.forEach(seg => container.appendChild(buildSegment(seg)));
}
```

流式路径：SSE 事件增量更新当前消息的 segments 数组 + **段级精确更新**（见设计要点 5）。reload 路径：JSONL 构造 segments → 全量 `renderAssistantMessage`。`appendToAsst`/`contentDiv` 守卫/`updateMarkdownBlocks` 单块假设删除。

### 3. 双轨合一（LRN-20260806-007 根治）

现状两条路径产出不同 DOM 结构。统一后：
- reload = 构造 segments + 全量 `renderAssistantMessage`
- 流式 = 事件增量更新 segments + **段级精确更新**（非全量 `renderAssistantMessage`，见设计要点 5）
- 同一渲染契约（`buildSegment`/segments 结构一致），顺序一致，无"修了流式 reload 还是乱"的问题。

### 4. 渐进迁移，不一次性重写

零测试防护下，先建数据模型 + 纯渲染函数（用 reload 数据验证），再切流式，最后删死代码。每步浏览器双轨验证。

### 5. 段级精确更新，不整消息重渲染（评审补充）

流式 delta 到达时**两种更新策略**必须明确选一：

| 方案 | 优点 | 缺点 |
|------|------|------|
| A. 全量重渲染消息（每次 delta 调 `renderAssistantMessage`） | 代码最简单，纯数据→DOM | 丢失滚动位置、闪烁；长流 O(n) 次重建 → O(n²)；打字流中 markdown 反复渲染 |
| B. 段级精确更新 | O(1)/delta、无闪烁、滚动稳定 | 需维护 segment 的 DOM 引用 |

**选择**：方案 B。每个 segment 在**创建时**生成 DOM 元素并挂到 asst（顺序 = 数组序），同时把元素引用存在 `seg.el`；delta 只追加该元素内部的文本节点。全量 `renderAssistantMessage` **仅用于**：消息创建（reload / 消息进入终态），不在流式中调用。

```js
// segment 结构带 DOM 引用（渲染层与数据层双向挂接）
segments.push({ type: 'text', text: '', el: null });
// 通用惰性挂载骨架（阶段 2 的 ensureTextSegment 是其 text 特化：含类型检查）
function ensureSegmentEl(seg, asst) {
  if (!seg.el) { seg.el = buildSegment(seg); asst.appendChild(seg.el); }
  return seg.el;
}
// content_delta: 精确追加文本，不重渲染
seg.el.querySelector('.content').textContent = seg.text;
```

**text segment 元素结构约定**（阶段 1 实现时固定）：text segment 的 `buildSegment` 产出含 `.content` 子元素的容器（区别于现有无类的 contentDiv），`querySelector('.content')` 才成立；thinking 段复用现有 thinking-block（已含 `.content`），tool 段复用 tool-card（含 `.output`）。

**注意**：thinking/text 段的文本更新用 `textContent`（无 HTML 注入），tool 段 `output` 更新同理；done 时对每个 text segment 一次性 markdown 渲染（现 `updateMarkdownBlocks` 逻辑迁移）。滚动行为沿用现有 `scrollToBottom`，因无重渲染不受影响。

**竞态分析（评审补充）**：本设计**不需要** renderVersion 计数器，原因：

| 事实 | 结论 |
|------|------|
| `EventSource` 单线程主循环串行派发，handler 跑完才派发下一个 | 无并发 DOM 写入 |
| delta 处理器全同步（`textContent +=`/`scrollToBottom`），无 promise/worker | 无异步完成顺序问题 |
| markdown 渲染在 done 一次性同步执行 | 无"旧慢渲染覆盖新快渲染" |

"后发先至"竞态要求**异步渲染管道**（如 opencode `markdown-shiki.worker` 的 worker 高亮）才可能出现。**前置条件声明**：若后续演进采纳"worker 化流式 markdown"（见后续演进·架构层），届时每个消息必须维护 `renderVersion` 计数器，异步渲染完成前检查版本号防过期写入——此要求随 worker 引入强制生效，不在本方案内预置死代码。

## 实施（分阶段，每步编译+双轨验证）

### 阶段 0: 拆分 HTML/CSS/JS（纯移动，零逻辑变更）

**文件**: `src/frontends/web/index.html` + `src/frontends/web/handler.zig`
**改动**: 将 `<style>` 与 `<script>` 移出 index.html 为独立文件，`handler.zig` 加 `@embedFile` 注入。**只移动不改造**——多个 `<script>` 标签共享 window 全局作用域，函数仍互相可见，无需 ES 模块化、不动依赖关系，拆分是纯移动、diff 干净。

**关键结构**:

```
src/frontends/web/
  index.html      # 仅结构
  app.css         # 原 <style> 内容
  app.js          # 原 <script> 内容（parts 重构在此文件内推进）
  vendor/*        # 既有
```

**handler.zig**: 加 `const APP_JS = @embedFile("app.js");` / `const APP_CSS = @embedFile("app.css");`。**CSS 与 JS 用各自独立的 marker，不共用**（评审补充）：

| marker | 位置 | 载荷 | 理由 |
|--------|------|------|------|
| `STYLE_MARKER`（新，`<!-- STYLES -->`） | `<head>` | `<style>` + `APP_CSS`（内含 `/* FONTS */` 字体 base64 替换） | CSS 归属 head；`/* FONTS */` 占位随 CSS 移入 app.css |
| `SCRIPT_MARKER`（既有，`<!-- SCRIPTS -->`） | `</body>` 前 | vendor 脚本 + `APP_JS` | JS 在 body 尾，避免阻塞渲染 |

两 marker 位置与载荷不同，共用一个只能把 CSS 塞 body（非惯用）或 JS 塞 head（阻塞首屏）。`serveIndex` 现两段注入逻辑（`handler.zig:130-141` 的 SCRIPT 段 + `:114-128` 的 FONT 段）扩展为三段：STYLE（含字体）→ SCRIPT（vendor + app.js）。

**验证**: `zig build`；浏览器刷新，行为与拆分前完全一致（功能回归：流式/reload/CRUD 全绿）。

### 阶段 1: 定义 segments 结构 + 纯渲染函数

**文件**: `src/frontends/web/app.js`
**改动**: 新增 `buildSegment(seg)` 与 `renderAssistantMessage(container, msg)`，**不接入任何路径**。先实现 tool/reasoning/text 三种 segment 的 DOM 构建（复用现有 thinking-block / tool-card / markdown 渲染逻辑）。

**验证**: `zig build`；临时在 console 用伪造 segments 数据调用 `renderAssistantMessage`，核对 DOM 结构与现 reload 一致。

### 阶段 2: 流式路径迁移到 segments

**文件**: `src/frontends/web/app.js`
**改动**: SSE 事件改为更新当前消息的 segments 数组；`content_start` 确保新 text segment（复用或新建，见阶段 2 代码与 content_start 语义）；增量渲染。

**关键代码**（阶段 2 的 content 处理，对应原 `index.html:709-722`；段级精确更新，见设计要点 5）:

```js
// 防御事件乱序/协议异常：delta 先于 start 到达时惰性创建 text segment。
// 不假设 curSegments 末尾是 text 类型（可能仍是 reasoning）。
function ensureTextSegment() {
  var last = curSegments[curSegments.length - 1];
  if (!last || last.type !== 'text') {
    var seg = { type: 'text', text: '', el: null };
    curSegments.push(seg);
    seg.el = buildSegment(seg);
    asst.appendChild(seg.el);
    return seg;
  }
  return last;
}

evtSrc.addEventListener('content_start', function() {
  ensureTextSegment();          // 确保存在 text segment（末尾已是 text 则复用，否则新建）
});
evtSrc.addEventListener('content_delta', function(e) {
  var d = JSON.parse(e.data);
  var seg = ensureTextSegment();  // 乱序路径：惰性创建，类型安全
  seg.text += d.text || '';
  seg.el.querySelector('.content').textContent = seg.text;  // 精确更新，O(1)
  scrollToBottom(msgs);
});
```

**content_start 语义**：走 `ensureTextSegment`（复用或新建），而非强制新建——若乱序时 content_delta 已惰性创建 text segment，后续到达的 content_start 复用该段，**避免产生空块**。正常路径下（delta 晚于 start）末尾必是新段，行为等价于"每阶段新段"。

thinking/tool 事件同模式：`thinking_delta` 更新当前 reasoning segment 文本；`tool_start` 新建 tool segment 元素并 appendChild、`tool_delta` 流式更新 output、`tool_meta` 收尾（exit code/用量）、`tool_error` 标记错误——全程无整消息重渲染。**thinking_delta 孤儿丢弃**（无前置 thinking_start 时静默跳过，沿用原 `if (!thinkingContent) return`，语义对齐 opencode 的 `drop orphan deltas`）。

**事件顺序说明**：SSE 基于单条 TCP 连接，`EventSource` 严格按序投递，`content_delta` 实际不可能先于 `content_start`（TCP 保序）。上述惰性创建是**防御协议异常/后端缓冲**，非臆测乱序——代价一行，换取 handler 全程类型安全（不假设末尾 segment 类型）。

**验证**: 手工多段流（叙述→工具→思考→工具→答案）→ `[思考][内容-叙述][工具][思考][工具][内容-答案]`；reload 同会话顺序一致。

### 阶段 3: reload 路径迁移到统一渲染函数

**文件**: `src/frontends/web/app.js`
**改动**: `loadSession` 的 `addMessage` assistant 分支改为构造 segments（JSONL assistant 消息 → reasoning/text segments，tool 消息对 → tool segment）→ `renderAssistantMessage`。工具卡片从"#messages 平级兄弟"变为 assistant 消息内 segment（与流式同构）。

**验证**: reload 旧会话顺序、工具折叠、thinking 折叠与流式一致。

### 阶段 4: 删除死代码

**文件**: `src/frontends/web/app.js`
**改动**: 删除 `appendToAsst`、`contentDiv` 守卫逻辑、`rawContent` 累积、改造 `updateMarkdownBlocks`（从单块假设改为按 text segment 逐个渲染，见设计要点 5）、删除 `addMessage` 的 assistant DOM 拼装。

**`wrapContextToolGroups` 兼容性检查**（评审补充，四项具体核对，`index.html:1090` 定义、`:895` 流式传 `asst`、`:433` reload 传 `msgs`）：

1. **工具名来源**：`isContextTool` 读 DOM 属性 `c._toolName`（`:1090` Pass 1）。parts 模型下 `buildSegment` 生成的 tool 元素必须提供工具名——统一为 `el.dataset.toolName = seg.name`（或保留 `_toolName`），否则判定全 false、分组失效。**现 reload 已因 `addMessage` 未设 `_toolName` 而不分组，属既有双轨差异**（流式分组、reload 不分组），阶段 3 统一时一并收敛。
2. **分组范围**：新结构工具段是 `asst` 子元素，`container.querySelectorAll('.tool-card')`（后代选择器）在 `wrapContextToolGroups(asst)` 下仍命中；"连续上下文工具"run 限定在单 assistant 消息内——被 reasoning/text 段隔开的工具不归组（正确）。流式调用点 `:895` 本就传 `asst`，天然适配。
3. **兄弟遍历**：Pass 2 的 `nextSibling` 遍历（`:1090`）在 asst 内成立（工具段为直接兄弟）；断言 `group.from`/`group.to` 同属一 asst——run 由相邻兄弟构成，跨消息不可能误组。
4. **调用时机统一**：reload 从 `wrapContextToolGroups(msgs)`（整列表）改为与流式一致，在每条 assistant 消息渲染后调 `wrapContextToolGroups(asst)`（阶段 3 统一渲染函数时收敛，消除双轨差异）。

**验证**: 全功能回归（新建/删除/重命名/停止/模型切换/双轨），`node scripts/check-catch-silent.mjs . --audit`。

## 验证

```powershell
zig build
node ..\.opencode\skills\zig-dev\scripts\check-catch-silent.mjs . --audit
```

| 测试场景 | 预期结果 |
|----------|----------|
| 阶段 0：拆分后刷新 | 行为与拆分前完全一致（流式/reload/CRUD 全绿） |
| 阶段 1：伪造 segments 渲染 | DOM 与 reload 一致 |
| 阶段 2：多段流（叙述→工具→思考→工具→答案） | `[思考][内容-叙述][工具][思考][工具][内容-答案]` |
| 阶段 2：content 全部在末尾（常规工具轮） | `[思考][工具][思考][工具][内容]` |
| 阶段 3：reload 旧会话 | 顺序与流式一致 |
| 阶段 4：功能回归 | 新建/删除/重命名/停止/模型切换全绿 |

前端为 `@embedFile` 嵌入，每阶段 `zig build` + 重启服务端生效。

## 波及

| 文件 | 改动 | 破坏性? |
|------|------|----------|
| `src/frontends/web/index.html` | 阶段 0 拆出 CSS/JS，仅留结构 | 否 |
| `src/frontends/web/app.js` | 阶段 0 迁入 JS（约 960 行）+ 阶段 1-4 parts 重构 | 否（协议/JSONL 不变） |
| `src/frontends/web/app.css` | 阶段 0 迁入样式（纯移动） | 否 |
| `src/frontends/web/handler.zig` | 加 `APP_JS`/`APP_CSS` embed + 注入 | 否 |
| `src/frontends/web/server.zig` | 无改动 | 否 |
| `src/io/provider.zig` | 无改动（协议已完整） | 否 |
| `docs/REMAINING.md` | 已登记本方案 | 否 |
| `docs/0.2.5/PLAN-FIX-APIKEY-ENV.md` | 无关联 | 否 |

**技术债关联**：本方案根治 N6（前端零测试防护网，先以分阶段+双轨验证缓解，长期引入 DOM 结构断言）、LRN-20260806-005/006/007 三个 DOM 位置 bug 类。

## 后续演进（对比 opencode 的差距清单）

> 以下差距基于对 opencode `packages/app` + `session-ui` 的实际扫描。**本方案不包含**这些功能——它们依赖 parts 模型落地，属后续独立项，等重构完成后逐项定优先级。

### 工程层（"成熟"的标志）

| 差距 | opencode 现状 | 我们的缺口 | 优先级 |
|------|---------------|------------|--------|
| 前端测试 | vitest 单测 + e2e（markdown/时间线/file 均有 .test.ts） | 零测试（N6） | 高——防再犯 |
| 类型契约 | SDK 生成类型，前后端共享 schema | 裸 JSON 无校验 | 中 |
| i18n | `useT()` 全量 | 硬编码中文 | 低 |
| 组件库/构建 | `@opencode-ai/ui` + Storybook + TS | 手写 CSS + vanilla | 低（见不做） |

### 架构层

| 差距 | opencode 现状 | 说明 |
|------|---------------|------|
| 数据模型 | parts 数组 + 声明式渲染 | **本方案已覆盖** |
| 虚拟滚动 | `tanstack-virtual` 虚拟化时间线 | 我们全量渲染，长会话卡顿 |
| 流式 markdown | 增量渲染 + `markdown-shiki.worker` worker 化高亮 | 我们 done 才渲染，流式纯文本 |
| 状态管理 | SolidJS 响应式 store | 全局变量 |

### 功能层（按对我们"单二进制 CLI 控制台"定位排序）

**高价值**：
- **diff/补丁视图**（`apply-patch-file`/`DiffView`）——工具改文件后看改动，现 `edit` 工具只返回文字。
- **工具审批**（ApprovalModal）——危险命令执行确认。
- **文件/图片预览**（`file.tsx`/`file-media`）——读文件/看图内联渲染。

**中价值**：
- 多标签、命令面板、会话归档（`home-session-archive`）。
- 错误边界（ErrorBoundary）——现一个 JS 报错整页白屏。
- SSE 重连/心跳（`heartbeat`）——现断开只能手动刷新。

**低价值（超出 CLI 控制台范围，可不做）**：行内评论、项目/工作区切换、记忆面板、TODO 面板、effort 切换。

### 落地建议

1. parts 重构（本方案）完成后，先补**前端测试防护网**（阶段 1 的纯渲染函数是天然的 DOM 断言测试点）。
2. 功能层按"高价值"三件（diff/审批/预览）逐项评估，每项独立 PLAN，不并入本方案。

### 与当前方案的关系（无冲突声明）

本方案与后续演进**不冲突**，关系如下：

| 演进项 | 关系 |
|--------|------|
| 前端测试 | 协同——阶段 1 纯渲染函数即测试落点 |
| 虚拟滚动 | 兼容——虚拟化作用于消息列表层，parts 作用于消息内层；按消息渲染正是按需渲染形态 |
| diff/审批/文件预览 | 协同——parts 模型天然可扩展（新 segment 类型 / 增强 tool segment） |
| 流式 markdown / worker 高亮 | 无冲突——增强渲染层，不动 parts 结构 |

**框架决策与演进清单的关系**：演进清单是"差距观察"，非承诺。"状态管理（SolidJS store）"与"类型契约（SDK/TS）"列为差距，与"不做"的"不引框架"**保持一致默认不做**——若未来重审框架决策，仅渲染函数层（`buildSegment`/`renderAssistantMessage`）会被组件替代，**segments 数据模型存活**（框架无关），本方案投资不浪费。segments 形状对齐 opencode 的 `Part` union（reasoning/text/tool），天然是未来 typed schema 的蓝本，向前兼容。


## 术语

| 术语 | 含义 |
|------|------|
| parts/segments 模型 | 消息 = 有序类型化片段数组（reasoning/text/tool），顺序即数组序 |
| 统一渲染函数 | `renderAssistantMessage(container, msg)`，流式与 reload 共用同一渲染契约 |
| content 阶段 | 模型流中一段连续 content 输出，后端 `begin_phase(.content)` 标记一次 |
| 双轨渲染 | 流式（sendPrompt）与 reload（loadSession）两条渲染路径（LRN-20260806-007） |
