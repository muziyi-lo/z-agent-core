# Plan CARD-UNIFY: 可折叠卡片统一抽象（thinking / tool / system prompt）

## 状态: 已完成（2026-08-14，commit 1f0abfb + e06754a）

> 实施完成。偏差记录见文末"实施偏差"节。关键修复（e06754a）：card-body 双重嵌套 + reload 命令输入块重建——均通过浏览器实测确认。

## 前置依赖

| 阻塞者 | 状态 | 被阻塞 |
|--------|------|--------|
| 无（纯前端重构，P0-FIXES 已提交，无依赖） | — | — |
| 本计划 | 实施后 | 可折叠卡片模板（用户提出作为未来卡片基座） |

## 不做

- **不改三卡片的核心内容渲染**：thinking 的 md 文本、tool 的 ToolRegistry 类型化视图、system prompt 的 sys-block 结构都保持
- **不统一三卡片的整体外观**：thinking/tool/system 各自的特化样式（字体、边距、tool output max-height 等）保留——统一的是**折叠骨架**（head/body + .open 契约），不是整卡视觉
- **不做卡片主题系统**（CSS 变量深色/浅色 token 是另一待办，LRN 待决 #0）
- **不迁移 `<details>/<summary>` 原生语义**——本计划维持 makeCard（`.open` 类）；`<details>` 作为**下一轮重构选项**（见"备选方案评估"节），未来新卡片组件可独立采用
- **不补卡片键盘操作**（`.card-head` tabindex + 空格/回车 handler）——aria-expanded 已纳入 setCardOpen（见 a11y 决策节）；键盘事件是新增交互逻辑、量稍大，作为后续项（`<details>` 迁移时原生获得键盘支持）
- **不采纳 `data-open` 属性替代 `.open` 类**（审查讨论）——理由：① `.open` 是项目既有状态约定（more-menu/sidebar 同用，:153/:221/:563/:684），data-open 引入第二套状态机制、认知成本增加；② CSS 特异性已用子选择器解决（`.card.open > .card-body` (0,3,0)），无实际冲突；③ 调试无差别（class="card open" 在 DevTools 同样可见）。若未来状态语义需与样式彻底解耦可重估
- **不抽独立 card.js 模块**（审查讨论，架构决策，LRN-20260814-006）——makeCard/setCardOpen/handleCardClick 保持 app.js 顶层函数；项目是**单文件 + @embedFile 嵌入**架构（handler.zig:28/196，无 package.json/构建工具），拆模块需引入构建工具是**架构级决策**，非本次范围。卡片函数当前单处，抽模块是超前抽象（LRN-20260814-002"≥2 处才抽"判据）。演进方向：app.js 膨胀至 ~3000 行或新增多模块时评估，届时优先 IIFE 命名空间过渡（不动构建），ES modules 与 @embedFile 单文件模型冲突不可行

## 问题

**现象**：thinking-block、tool-card、system prompt 三处"可收起内容"各用一套折叠机制——thinking 用 `.open` 类 + onclick（点 content 误收起）、tool 用 `.open` 类 + onclick（含 .output 守卫）+ transform 旋转图标、system prompt 用 CSS hover（max-height 60px）。三套范式并存，新增卡片（未来 MCP/预览等）无从复用。

**根因**：无统一卡片抽象；折叠契约（open 状态、图标、守卫）各自实现，未收敛。

## 概览

- 改动 3 个文件：`src/frontends/web/app.js`、`src/frontends/web/app.css`、`tests/frontend/test-build-segment.mjs`（+ 新增 makeCard 测试文件）
- 纯前端重构，无后端改动
- 思路：新增 `makeCard` 纯函数提供统一折叠骨架（head + body + `.open` 契约 + 守卫 + 默认态），三卡片各自保留修饰类名并委托 makeCard
- 参考实现：无外部参考；对齐项目已有 buildSegment 单一入口模式

---

## 设计要点

### 统一折叠契约

三卡片收敛为同一 DOM 骨架（thinking / tool 直接是卡片）：

```html
<div class="card [open] thinking-block|tool-card">
  <div class="card-head">…标题/图标/操作区…</div>   <!-- 点击 toggle -->
  <div class="card-body">…内容…</div>               <!-- .open 控制显隐 -->
</div>
```

### 备选方案评估：原生 `<details>/<summary>`（审查讨论，未采纳）

评论者提出更语义化的原生替代：`<details open>` 天然表示展开/收起，点击 `<summary>` 自动切换 + 浏览器内置键盘可访问性，无需手动 `.open` 类与守卫。

**对比**：

| 维度 | makeCard（选） | `<details>/<summary>` |
|------|---------------|----------------------|
| 状态 | `.open` 类手动维护 | `open` 属性原生 |
| 可访问性 | 需手动加 aria 扩展 | 浏览器内置 |
| 守卫 | makeCard 内置（body/head 控件） | summary 才切换，天然隔离 body；但 copy-cmd 在 summary 内需处理 |
| 流式 seg.open | `makeCard defaultOpen: !!seg.open` | `details.open = true/false` |
| 图标 | `.card-head::before`（▶/▼） | `summary::before` + `details[open] summary::before` |
| 现有代码迁移 | 改动集中 buildSegment | **更大**：`.open` 契约已用于非卡片（more-menu/sidebar）但不冲突；卡片 CSS 选择器全改 `details[open]` |
| 内容结构 | body 可任意 DOM | `<details>` 内容需合规（details 只能含 summary + flow content） |

**决策**：维持 makeCard（`.open` 类）方案。理由：
1. **卡片 CSS 选择器迁移成本高**：`thinking-block .content`/`tool-card .output` 特化规则需从 `.open` 改 `details[open]`，且 system prompt 容器模型更复杂
2. **守卫与现有模式耦合**：copy-cmd 需 stopPropagation 或移出 summary；守卫逻辑从"点击过滤"变"DOM 结构隔离"，改动面扩散
3. **`.open` 类已与项目既有 UI 状态约定一致**（more-menu/sidebar 也用 `.open`），统一认知成本低
4. **本项目无框架、交互简单**：键盘可访问性收益有限，`.card-head` 点击 + 后续补 aria 即可

**记录**：`<details>` 方案在**未来新卡片组件**（如 MCP 工具卡、预览卡）值得重新评估——若新卡片需要原生可访问性优先，可独立采用，不阻塞当前统一。

**无障碍（a11y）现状与决策（审查讨论）**：
- **现状核实**：项目**已有 a11y 先例**——`aria-pressed`（sidebar-toggle :225/:230）、`aria-expanded`（model-btn/下拉菜单 :413-441）、`keydown` Escape/Enter（:310/:330/:1574）。非零基础，只是卡片折叠未做。
- **aria-expanded 同步纳入**（审查补充，成本极低）：
  - setCardOpen 是统一状态写入口，在其中同步 `aria-expanded`（约 3 行）——**零风险**，且与项目既有 aria-expanded 先例（model-menu :413-441）对齐
  - 理由：既然状态已收敛到单一写入口，aria 同步是"写入口顺带保持状态一致性"，非额外功能；不补则未来补 aria 时 setCardOpen 已成型，改动更散
- **键盘事件（tabindex + 空格/回车）暂缓**：
  - `.card-head` 设 `tabindex="0"` + keydown handler（空格/回车触发 toggle）是**新增交互逻辑**，量稍大；本项目是开发者工具、鼠标交互为主，收益有限
  - 记录为后续项：与 `<details>` 重构关联（`<details>` 原生获得键盘支持，成本归零）
- **后续项**（与 `<details>` 重构关联）：
  - 若未来切 `<details>/<summary>` → 浏览器原生获得键盘可访问性 + 语义，a11y 键盘成本归零
  - 若维持 `.open` 类 → 补 head 键盘 handler（tabindex + keydown），优先级低于其他功能

**system prompt 例外模型**（审查补充，避免 .card 嵌套）：
`#system-prompt` 是**容器**（持有 id、参与 `:not(#system-prompt)` 排除），内部是 makeCard 产物的 `.card` 子元素——**外层容器不含 card 类**，与 thinking/tool 的"卡片即元素"不同：

```html
<div id="system-prompt" class="msg system">        <!-- 容器：无 .card -->
  <div class="card [open]">                         <!-- 卡片：makeCard 产物 -->
    <div class="card-head">System prompt</div>
    <div class="card-body">…sys-blocks…</div>
  </div>
</div>
```

- `.card-head`：点击切换 `.open`；含 `::before` 图标（CSS 统一，transform 旋转）
- `.card-body`：`.open` 时显示（CSS `display:block`），默认隐藏
- `.open` 是唯一状态类；守卫（点 body / head 内控件不 toggle）由委托 handler 承担（见"守卫规则 + 事件委托"节）
- **原修饰类名保留**：`thinking-block`/`tool-card` 作为 .card 的附加类；`msg.system` 作为**容器类**——被 CSS/JS 强依赖（tool-card 被 :376/:1521/:2002 引用；`#system-prompt` 被 :376 排除），特化样式零迁移
- **`.msg.system` 容器不再有卡片视觉**：现实现 el 有 padding/background（app.css:75），改造后移到内部 .card 上（或 .card-head/body 样式），避免容器+卡片双重卡片样式

### makeCard 接口

```js
function makeCard(opts) {
  // opts: { head: string, body: Node, defaultOpen: bool }
  // returns div.card[.open] with .card-head + .card-body
  // 纯 DOM 构造，不绑定事件——折叠交互由 #messages 上的统一委托 handler
  // 承担（见"事件委托"节）：body 内不 toggle、head 内交互控件不 toggle。
  // head 契约：必须是**已转义的 HTML**（见 XSS 说明）——makeCard 直接 innerHTML，
  //   不代做 esc（与 buildSegment 现有 esc(seg.name) 模式一致）
}
```

顶层纯函数（可被前端测试提取），buildSegment 与 renderSystemPrompt 委托。

#### head XSS 契约（审查补充）

评论指出：`head.innerHTML = opts.head` 存在潜在 XSS——若 head 含未转义的用户/模型数据会执行脚本。

**项目既有 XSS 防线（LRN-20260813-015，已修复）**：工具输出（`.output`/`.content` body）渲染走 `renderMd`/`renderMdBlocks`（app.js:1055/1074 `DOMPurify.sanitize(raw, { FORBID_TAGS:['style','link'] })`）——工具输出是**不可信内容**（模型/工具任意 HTML），DOMPurify 默认保留 `<style>` 曾致全局布局污染，已用 FORBID_TAGS 修复。**本次 makeCard 不得破坏 body 的 renderMd 净化链**（body 参数必须是净化后的内容）。

**head 是本次新增关注面**：head 不走 renderMd（直接 innerHTML），无 DOMPurify 兜底，靠调用方转义。

**当前风险核实**（低）：
- thinking head = 固定字符串 `'Thinking'`，无外部数据
- tool head 的 name = `esc(seg.name)`（buildSegment:1139 已转义）+ copy-cmd 是内部创建按钮；tool_error 重建 `esc(d.name)`（:1403 已转义）
- system head = 固定字符串 `'System prompt'`
- seg.name 来源 = 模型 tool_calls name → **模型可控**，但当前已 esc

**契约约定**（防未来回归）：
- **`head` 参数必须是已转义 HTML**——调用方对任何用户/模型数据必须用 `esc()`，makeCard 不代做（保持纯函数、与既有 esc 模式一致）
- tool 分支：head 内的 name 用 `esc(seg.name)`（模型可控）；**copy-cmd 不涉 XSS**——按钮文本固定 `'Copy cmd'`（textContent，:1884），复制内容走 `copyText` 的 textContent/clipboard 赋值，无 innerHTML 注入路径
- 文档测试断言：test-card 增加"head 内用户数据未转义时 XSS 暴露"的防御用例（验证调用方传 `esc('<img onerror>')` 后 head 内无原始标签）——若未来新增 head 内容来源，此契约作为强制项
- **备选加固**（未来若 head 频繁含动态数据可升级）：makeCard 支持 `headText`（自动 esc）+ `headHtml`（信任已转义）双通道，默认走 headText。当前不引入（YAGNI，现有调用方全部可手动 esc）

#### 守卫规则 + 事件委托（审查补充：head 内交互控件 / 每卡片监听器）

评论指出两点：① guard 只挡 `.card-body` 不够——tool 的 **copy-cmd 按钮在 `.card-head` 内**，点击复制按钮若冒泡到 card onclick 会误 toggle 折叠；② makeCard 为**每个卡片**绑定 `el.onclick`，流式场景会累积大量监听器，且 `clear` 命令 `#messages.innerHTML=''`（:1602/:1756/:1803）清空容器时每卡片监听器随卡片销毁，但**委托在容器上更稳**。

**统一方案**：守卫逻辑 + 事件监听全部收敛到 `#messages` 上的**一个委托 handler**（与既有 scroll 委托同容器，app.js:288）：

```js
// 页面加载时在 #messages 绑一次。守卫规则在 handler 内：
//  body 内不 toggle（保护可选中文本）；head 内交互控件不 toggle（复制按钮等）。
// 统一走 setCardOpen（同步 .open + aria-expanded，见实施步骤 1 handleCardClick）。
function handleCardClick(e) {
  var card = e.target.closest('.card');
  if (!card) return;
  var t = e.target;
  if (t.closest('.card-body')) return;
  if (t.closest('.card-head') && (t.closest('button') || t.closest('a') || t.closest('[data-no-toggle]'))) return;
  setCardOpen(card, !card.classList.contains('open'));
}
```

- **makeCard 不绑定 onclick**——退化为纯 DOM 构造（head/body + .open 类），`handleCardClick(e)` 提取为顶层函数便于测试（见实施步骤 1）
- 守卫 = 委托 handler 内 `closest` 拦截，三卡片共享同一套规则；**无 guard 参数**（`opts` 不含 guard）——额外拦截（如特定工具整个 head 不折叠）未来通过 `data-*` 属性承载，不在本计划引入
- **每卡片零监听器**：长会话/流式大量卡片无累积
- copy-cmd 的 stopPropagation 保留无害（双保险），新控件无需再记得
- 现有 `e.stopPropagation()`（:1886 等）不删——对 card 外的事件（会话卡片等）仍必要
- system prompt 卡片在 `#messages` 内被委托覆盖；`#system-prompt` 容器自身不绑（.card 是其子元素）
- **非卡片区域点击零开销**：handler 先 `closest('.card')` 快速返回

### 三卡片映射

| 卡片 | head | body | defaultOpen |
|------|------|------|-------------|
| thinking | `Thinking`（::before 图标） | .content（md pre-wrap） | false |
| tool | `&#9881;`+name（::before 图标） | .output（md） | true |
| system | `System prompt`（::before 图标） | sys-blocks | false |

（守卫由委托 handler 统一承担，无需 per-card 配置；tool 的 toggle-icon span **移除**，见图标统一。tool head **不含 copy-cmd**——copy-cmd 由 ToolRegistry bash 分支动态创建（见实施步骤 2 注释），避免创建时机与 _toolData.input 解析冲突。）

### 图标统一

当前双轨（thinking=::before 换字符、tool=.toggle-icon transform 旋转）统一为 **.card-head::before + transform 旋转**（用户提出：content 换字符瞬间切换无动画，transform 旋转交互效果更好）：

- `.card-head::before` 固定 `▼` 字符（`\25BC`），不换字符
- 收起态 `.card:not(.open) .card-head::before` → `transform: rotate(-90deg)`（▼ 转朝右 ▶ 视觉）
- 展开态 `.card.open .card-head::before` → `transform: rotate(0deg)`（▼ 朝下）
- `transition: transform var(--transition-fast)` —— **平滑旋转动画**（复用原 tool-card .toggle-icon 的 :98-100 动画模式）
- **tool 的 `.toggle-icon` span 全部移除**（3 处，审查补充）：buildSegment:1139 构造 + **tool_start :1392**（name-row 重建）+ **tool_error :1429**（name-row 重建含 error 态）——head 内图标全部由 .card-head::before + transform 承担，避免双图标重复渲染；`.toggle-icon` 的 CSS（app.css:98-100）同步删除（其 transform 旋转逻辑已被骨架 ::before 继承）
- **tool_start/tool_error 的 name-row 重建需适配 .card-head**（审查补充）：:1392/:1429 直接 `querySelector('.name-row').innerHTML = ...` 重建 head——改造后 card-head 由 makeCard 构造，这两处重建应改为更新 `.card-head` 内 `.name` 文本（`querySelector('.card-head .name')` 更新 textContent），而非整体重建 innerHTML（否则 toggle-icon 残留 + .card-head::before 图标与重建内容叠加）。tool_error 的 error 类仍加在 card 元素上（:1427 不变）

### system prompt 交互变更（G11 对比式）

**当前**（hover 展开）:
```
.msg.system { max-height:60px; overflow-y:auto; }
.msg.system:hover { max-height:none }
```

**实施后**（点击折叠）:
```
.msg.system .card-body { display:none }
.msg.system.open .card-body { display:block }
```
- hover 展开移除（用户明确要求，习惯以点击为准）
- `renderSystemPrompt` 重建时保留 open 状态：读 `el.querySelector('.card')` 的 `.open` 类（.open 状态在 card 子元素上，非 el 外层）→ makeCard 传 defaultOpen 恢复（见实施步骤 3）
- renderSystemPrompt 每次 `el.innerHTML = ''` 全量重建（app.js:984 现状）——重建骨架时检测旧 card 的 open 状态，新骨架设置 defaultOpen

### thinking 守卫修复（附带）

当前 thinking onclick 无守卫（:1123），点击 content 内可选中文本会误 toggle。统一后委托 handler 守卫拦截——点 .card-body 不 toggle。

### G16 交互矩阵（三卡片 × 既有特性）

| × | thinking | tool | system prompt |
|---|----------|------|---------------|
| thinking | — | 同属消息流，独立 DOM，无交叉 | 无交叉 |
| tool | 无交叉 | — | 无交叉 |
| system prompt | 无交叉 | 无交叉 | 与 `#messages .tool-card` 计数（app.js:376）互不影响——system 是 `:not(#system-prompt)` 排除项 |

三卡片均为消息流内独立元素，与分组/分页/撤销无交互；system prompt 是 `#messages` 首个独立 banner，不参与会话消息 diff。

---

## 实施

### 步骤 1: 新增 makeCard + CSS 骨架 + 事件委托

**文件**: `src/frontends/web/app.js`
**改动**: 新增顶层 `makeCard` 纯函数（buildSegment 之前）+ `#messages` 点击委托

```js
// 纯 DOM 构造，不绑定 onclick（事件委托接管，审查补充）：
// 每卡片零监听器，流式大量卡片无累积；容器清空时监听器不泄漏。
function makeCard(opts) {
  var el = document.createElement('div');
  el.className = 'card' + (opts.defaultOpen ? ' open' : '');
  el.setAttribute('aria-expanded', opts.defaultOpen ? 'true' : 'false');  // 初始 a11y 状态
  var head = document.createElement('div');
  head.className = 'card-head';
  head.innerHTML = opts.head;
  var body = document.createElement('div');
  body.className = 'card-body';
  body.appendChild(opts.body);
  el.appendChild(head);
  el.appendChild(body);
  return el;
}

// 统一卡片状态写入口（审查补充）：所有 .open 修改收敛于此。
// 委托 handler、expand-all、未来程序化控制（流式默认展开/恢复状态）都调它，
// 避免散落 classList.toggle('open')（改逻辑时漏一处即状态漂移）。
// aria-expanded 在此同步（审查补充）：成本极低、与项目既有 aria-expanded
// 先例对齐（model-menu :413-441）——状态写入口顺带保持 a11y 状态一致。
function setCardOpen(card, open) {
  if (open) card.classList.add('open');
  else card.classList.remove('open');
  card.setAttribute('aria-expanded', open ? 'true' : 'false');
}

// 既有 expand-all（done 路径，app.js:1534）改调 setCardOpen，统一状态写入口：
//   tools.forEach(function(tc) { setCardOpen(tc, expand); });
// （改造前是 tc.classList.toggle('open', expand)）

// 顶层函数（可被 test-card.mjs 提取测试）。守卫规则在 handler 内：
// body 内不 toggle（保护可选中文本）；head 内交互控件不 toggle（复制按钮等）。
function handleCardClick(e) {
  var card = e.target.closest('.card');
  if (!card) return;
  var t = e.target;
  if (t.closest('.card-body')) return;
  if (t.closest('.card-head') && (t.closest('button') || t.closest('a') || t.closest('[data-no-toggle]'))) return;
  setCardOpen(card, !card.classList.contains('open'));
}

// 交互边界推演（G5，审查补充）——closest 检查的顺序与覆盖：
// ① 点击 .card-body 内任意元素（含 <a> 链接）→ ① 先拦截，不 toggle；
//    body 是 head 的兄弟，closest('.card-body') 不会跨级误匹配 head → ① 优先于 ② 顺序正确
// ② 点击 .card-head 内 button/a/[data-no-toggle] → ② 拦截，不 toggle（复制按钮等）
// ③ 点击 .card-head 内非控件元素（name 文本 span）→ 不匹配 ①② → toggle（点标题折叠，预期）
// ④ 点击 .card 自身间隙（非 head 非 body，如 padding 区）→ toggle（合理）
// ⑤ 点击卡片外（非 .card）→ 首个 closest('.card') 返回 → 快速 return，零副作用
// ⑥ body 内链接：不折叠 + 默认跳转仍执行（合理，点链接不该折叠卡片）
// 边界兜底：head 内未来新增自定义交互元素若需"点击不折叠"，加 [data-no-toggle] 即可

// 页面加载时绑一次（与 #messages scroll 委托同容器、同时机，app.js:288）。
// #messages 是 index.html 静态容器（:22），初始化时必然存在；null 守卫为
// 未来容器结构变化的轻量防御（审查补充）——容器缺失时静默跳过而非抛错。
var messagesEl = document.getElementById('messages');
if (messagesEl) {
  messagesEl.addEventListener('click', handleCardClick);
}
```

**注意**: 
- 委托 handler 定义为**顶层函数** `handleCardClick(e)`（非匿名回调）——前端测试按函数名提取（test-card.mjs 直接调用它并传构造的 event）
- 绑定在页面初始化处执行一次（与 :288 scroll 委托并列）；**容器存在性防御**（审查补充）：`#messages` 是 index.html:22 静态容器初始化必存在，但绑定处加 `if (messagesEl)` null 守卫——未来容器结构变化时静默跳过而非抛错（scroll 委托 :288 无此守卫，本计划绑定是新增代码，采用更稳写法）
- `handleCardClick` 独立于容器可测：测试无需真实 DOM 容器，直接构造 event 对象调用

**文件**: `src/frontends/web/app.css`
**改动**: 新增骨架规则 + 图标统一

```css
.card{position:relative}
.card-head{display:flex;align-items:center;gap:6px;user-select:none;cursor:pointer}
/* 图标：::before 固定 ▼ 字符，transform 旋转切换朝向 + transition 平滑动画（审查补充，
   用户提出：content 换字符是瞬间切换无动画，transform 旋转交互效果更好，且复用原
   tool-card .toggle-icon 的 :98-100 模式） */
.card-head::before{content:"\25BC";font-size:9px;display:inline-block;transition:transform var(--transition-fast)}
.card:not(.open) .card-head::before{transform:rotate(-90deg)}   /* 收起：▼ 转 90° → ▶ */
.card.open .card-head::before{transform:rotate(0deg)}           /* 展开：▼ 朝下 */
/* 骨架显隐用 3 类选择器提升特异性 (0,3,0)，恒胜特化规则 (0,2,0)——消除源顺序依赖（审查补充） */
.card > .card-body{display:none;margin-top:6px;user-select:text;cursor:auto}
.card.open > .card-body{display:block}
```

**特异性决策（审查补充，评论指出）**:
- `.card.open > .card-body` 特异性 **(0,3,0)**（`.card`+`.open`+`.card-body` 三个类；子选择器 `>` 不增加特异性）> `.thinking-block .content`/`.tool-card .output` **(0,2,0)**
- 无论源顺序，骨架显隐恒胜特化规则——展开态 `.card.open > .card-body{display:block}` 不会被特化的 `display:none` 覆盖
- **特化类移除 display 声明**：`.thinking-block .content`（app.css:88）与 `.tool-card .output`（:94）的 `display:none` **删除**（只保留排版：margin/white-space/max-height 等），显隐完全交给骨架——双保险
- body 元素 className 用 `card-body content`（骨架 + 特化双类），特化类只管排版

**system prompt 特化 CSS 调整**（.msg.system 规则，app.css:74-82）:
- `:75` `max-height:60px; overflow-y:auto; cursor:pointer` **移除**——折叠改由 .card-body 骨架控制；`:hover`（:76）**移除**
- `:79` `.msg.system::before{content:'System prompt'}` **移除**——标签由 .card-head 内 "System prompt" 文本承担，且避免与 .card-head::before 图标伪元素冲突（同一元素不能共存两个 ::before）
- **卡片视觉迁移到内部 .card**（审查补充）：`.msg.system` 的 padding/background（:75）移到 `.msg.system .card`；容器只留 border-bottom（:74 分隔线）+ margin——避免容器 + 卡片双重卡片样式
- `.msg.system` 的 font-size/`.sys-block` 特化保留（.sys-block 在 card-body 内 pre）
- 新增 `.msg.system .card-body` 规则由骨架 .card-body 通用规则覆盖（`.card > .card-body` 已控制显隐，特异性更高）

### 步骤 2: thinking / tool 分支委托 makeCard

**文件**: `src/frontends/web/app.js`
**改动**: buildSegment reasoning/tool 分支改为 makeCard 调用

```js
// reasoning —— 守卫由 #messages 委托 handler 承担（body 选中保护），makeCard 纯构造
var card = makeCard({
  head: 'Thinking',
  body: contentEl,
  defaultOpen: !!seg.open,
});
card.className += ' thinking-block';
return card;
```

```js
// tool —— head 含模型可控的 name（innerHTML 注入 head），必须 esc（XSS 契约）。
// copy-cmd 按钮**不由 buildSegment 创建**——保持 ToolRegistry bash 分支动态创建
//（:1881 幂等守卫 + textContent 赋值天然安全），避免创建时机与 _toolData.input
// 解析时序冲突。toggle-icon span 移除（图标由 .card-head::before 承担）。
var head = '<span class="tool-label">&#9881;</span><span class="name">' + esc(seg.name || 'tool') + '</span>';
var card = makeCard({
  head: head,
  body: outputEl,
  defaultOpen: true,
});
card._toolName = seg.name;
card.className += ' tool-card';
return card;
```

**注意**: 
- `defaultOpen: !!seg.open`——流式 seg.open 未定义→收起；reload :1172 `open:true`→展开（保留现行为，本计划不改默认态）
- 原 `.thinking-block .content` / `.tool-card .output` 类名需保留在 body 元素上（特化样式 + 流式更新代码 `querySelector('.content')`/`.output'` 依赖）——makeCard 的 body 参数就是这些元素，className 设为 `card-body content`（骨架+特化双类）
- **特化 display 移除**（CSS 特异性修复，审查补充）：`.thinking-block .content`/`.tool-card .output` 的 `display:none` 删除，只留排版（margin/white-space/max-height）——显隐完全由 `.card.open > .card-body` 骨架控制，避免 (0,3,0) 与 (0,2,0) 同级竞争
- **tool head 转义契约**（审查补充）：`seg.name` 经 `esc()` 后 innerHTML 注入 head（模型可控数据）；**copy-cmd 不涉及 XSS**——按钮文本固定 `'Copy cmd'`（:1884 textContent，非用户数据），复制的 command 走 `copyText` 的 textContent/navigator.clipboard 赋值，无 innerHTML 注入路径
- **tool_start/tool_error head 重建适配**（审查补充）：app.js:1392（tool_start）/:1429（tool_error）当前 `querySelector('.name-row').innerHTML = ...` 整体重建 head——改造后改 `querySelector('.card-head .name').textContent = esc(...)` 更新 name 文本，不整体重建（保留 .card-head::before 图标 + 避免 toggle-icon 残留）；tool_error 的 error 类加在 card 上不变
- **`.name-row` 全局替换为 `.card-head`**（实现发现，文档审查补录）：`.name-row` 是 tool 卡片既有结构锚点，被 **ToolRegistry bash**（app.js:1924 copy-cmd 插入点）与 **setToolMeta**（:2033 tool-meta 定位）依赖。改造后统一改 `.card-head`：
  - :1924 bash 分支 `toolDiv.querySelector('.name-row')` → `.card-head`（copy-cmd append 到 head）
  - :2033 setToolMeta `toolDiv.querySelector('.name-row')` → `.card-head`（tool-meta 插到 head 后）
  - 同步 ToolRegistry 其他工具的 name-row 引用（若有）

### 步骤 3: system prompt 改造

**文件**: `src/frontends/web/app.js`
**改动**: renderSystemPrompt 改用 makeCard；重建时保留 open 状态

```js
function renderSystemPrompt(content) {
  var el = document.getElementById('system-prompt');
  // 审查修正: .open 状态在 makeCard 的 card 元素上，不在 el 外层——
  // 必须查 el 内的 .card，而非 el.classList。否则重建时永远读到 false。
  var wasOpen = false;
  if (el) {
    var oldCard = el.querySelector('.card');
    if (oldCard) wasOpen = oldCard.classList.contains('open');
  }
  if (!el) {
    el = document.createElement('div');
    el.id = 'system-prompt';
    var msgs = document.getElementById('messages');
    msgs.insertBefore(el, msgs.firstChild);
  }
  if (!content) { el.style.display = 'none'; return; }
  el.innerHTML = '';   // 清空重建骨架
  el.className = 'msg system';
  // renderSystemBlocks 返回 HTML 字符串；包成 body 节点
  var bodyWrap = document.createElement('div');
  bodyWrap.innerHTML = renderSystemBlocks(content);
  var card = makeCard({
    head: 'System prompt',
    body: bodyWrap,
    defaultOpen: !!wasOpen,
  });
  el.appendChild(card);
  el.style.display = '';
}
```

**注意**:
- **open 状态检测位置**：`el.querySelector('.card')` 而非 `el.classList`——评论审查修正的核心（见代码注释）。检测旧 card → 新 card 的 defaultOpen，状态正确跨重建保留
- `renderSystemBlocks` 保留返回 HTML 字符串，包一层 `bodyWrap` 作为 makeCard 的 body（**不新增** `renderSystemBlocksAsNode` 函数，最小改动）
- **容器/卡片分离**（审查补充）：`el.className = 'msg system'` **不含 card**——el 是容器（持 id），makeCard 产物的 .card 是唯一卡片。**禁止**给 el 加 card 类（否则 .card 嵌套，全局 .card{position:relative} 作用到容器）
- **`.msg.system` 容器样式迁移**：现 el 的 padding/background（app.css:75）是卡片视觉，改造后应落在内部 `.card` 上（`.msg.system .card`），容器只留 border-bottom（:74 分隔线）+ margin
- CSS `.msg.system` 的 `max-height:60px`/`:hover` 移除（见步骤 1）；`.sys-block` 特化保留在 body 内
- `:not(#system-prompt)` 排除逻辑（app.js:376）不受影响

### 步骤 4: 测试

**文件**: `tests/frontend/test-card.mjs`（新增）
**改动**: makeCard 纯构造 + 委托 handler 测试（事件委托是审查重点，需全覆盖）
- defaultOpen true/false → 初始 .open 类
- head/body 结构正确（.card-head/.card-body 存在）
- **委托守卫**（审查补充）: 将委托 handler 提取为顶层函数 `handleCardClick(e)`（容器 click 回调），测试直接调用并传构造的 event.target：
  - 点击 .card-body → 不 toggle
  - 点击 .card-head 内 button（模拟 copy-cmd）→ 不 toggle
  - 点击 .card-head 空白区 → toggle
  - 点击非 .card 区域（卡片外）→ 不报错、无副作用
  - 点击 .card-head 内 name 文本（非控件）→ toggle（点标题折叠，边界 ③）
  - 点击 .card 自身间隙（非 head 非 body）→ toggle（边界 ④）
  - 点击 .card-body 内 `<a>` → 不 toggle（边界 ⑥）
- **head XSS 契约**（审查补充）: 调用方传 `esc('<img onerror=...>')`（转义后 `&lt;img...&gt;`）→ head.innerHTML 不含原始 `<img` 标签（验证调用方 esc 契约 + makeCard 不破坏转义）
- **setCardOpen 状态写入口**（审查补充）:
  - `setCardOpen(card, true)` → 含 .open；`setCardOpen(card, false)` → 不含
  - 幂等：重复 setCardOpen(card, true) 不报错、状态不变
  - **aria 同步**（审查补充）: `setCardOpen(card, true)` → `aria-expanded="true"`；false → `"false"`；makeCard 构造 defaultOpen 初始 aria 正确
  - 委托 handler 的 toggle 行为 = `setCardOpen(card, !contains('open'))`——经 handleCardClick 用例覆盖

#### 卡片 .open 全量排查（审查补充，确认收敛）

评论要求确认除 expand-all 外无其他直接操作卡片 `.open` 的代码。全库 grep `classList.(add|remove|toggle)('open')` / className 拼接 / `' open'` 排查：

**卡片 `.open` 直接操作点（5 处，全部收敛）**:

| 位置 | 现代码 | 收敛方式 |
|------|--------|----------|
| app.js:1117 | `className='thinking-block'+(seg.open?' open':'')` | makeCard `defaultOpen: !!seg.open` |
| app.js:1123 | thinking onclick `classList.toggle('open')` | 委托 handler（handleCardClick） |
| app.js:1137 | `className='tool-card open'` | makeCard `defaultOpen: true` |
| app.js:1146 | tool onclick `classList.toggle('open')` | 委托 handler（handleCardClick） |
| app.js:1534 | expand-all `toggle('open', expand)` | `setCardOpen(tc, expand)` |

**非卡片 `.open`（7 处，不收敛，保持原样）**: app.js:153/563/567/684/689（more-menu 下拉）、:221（sidebar）、:304/324/326（overlay modal）——非折叠卡片状态，不动。

**结论**: 卡片 `.open` 写入口全量收敛到 setCardOpen（构造经 defaultOpen、交互经 handleCardClick、批量经 expand-all）；`:1172` reload 的 `open:true` 是 makeCard 的 defaultOpen 输入（状态来源，非 DOM 操作）。无遗漏。

**文件**: `tests/frontend/test-build-segment.mjs`
**改动**: 现有 reasoning/tool 断言适配（卡片仍含 .thinking-block/.tool-card 类，结构检查 .card-head/.card-body）

---

## 验证

```powershell
node tests/frontend/run-tests.mjs   # 全前端测试（含新 makeCard + 适配后 buildSegment）
zig build                           # app.js @embedFile 重新嵌入
```

| 测试场景 | 预期结果 |
|----------|----------|
| thinking 点击展开/收起 | 图标 ▶/▼ 切换，点 content 不误收起 |
| tool 点击展开/收起 | 图标统一为 ::before + transform，copy-cmd 仍工作 |
| tool_start/tool_error 重建 | head name 更新而非整体重建，图标无残留、error 态正常（审查补充） |
| system prompt 点击折叠 | hover 移除，点击展开/收起，reload 后保持状态 |
| 流式 thinking_delta/tool_delta | 更新 .content/.output，不影响 .open 状态 |
| done 路径 markdown 渲染 | tool-card 遍历（:1521）正常 |
| reload 后 thinking 默认展开 | 保留现行为（open:true） |
| **CSS 特异性回归（chrome-cdp 浏览器实测）** | 展开态 body 真实 `display:block`（不受特化 display:none 覆盖）——骨架 (0,3,0) 恒胜，收起态 `display:none` 正常 |

## 波及

| 文件 | 改动 | 破坏性? |
|------|------|----------|
| `src/frontends/web/app.js` | 新增 makeCard（纯构造 + 初始 aria-expanded）+ `setCardOpen` 状态写入口（同步 aria-expanded）+ `handleCardClick` 委托 handler + #messages 绑定；buildSegment 两分支 + renderSystemPrompt 委托；expand-all 改调 setCardOpen | 是（thinking/tool/system 卡片 DOM 结构变化 + 每卡片 onclick 改容器委托，测试断言需适配） |
| `src/frontends/web/app.css` | 新增 .card 骨架 + 图标统一；.msg.system hover 移除 | 是（system prompt 交互 hover→click） |
| `tests/frontend/test-card.mjs` | 新增 makeCard + handleCardClick + setCardOpen 测试 | — |
| `tests/frontend/test-build-segment.mjs` | 适配 reasoning/tool 断言 | — |

## 术语

| 术语 | 含义 |
|------|------|
| 折叠骨架 | card-head/card-body 结构 + .open 状态类，与具体卡片特化样式解耦 |
| 守卫（guard） | 委托 handler 内的点击拦截规则：目标在 body 内或 head 内交互控件时 return（不 toggle） |
| 修饰类名 | thinking-block/tool-card 作为 .card 的附加类；msg.system 作为**容器类**（#system-prompt 内嵌 .card，不含 card 类） |

## 实施偏差（阶段 5.5 记录）

实施与设计文档的差异，全部经浏览器实测确认：

| # | 偏差 | 说明 | 状态 |
|---|------|------|------|
| 1 | **body 元素不含 card-body 类** | 设计步骤 2 注意写 `card-body content` 双类——实现时错误地把 card-body 类设到内容元素（content/output），被 makeCard 再包一层致**双重嵌套**。修正：body 只带特化类，card-body 由 makeCard 包 | 已修复（e06754a） |
| 2 | **reload 命令输入块重建** | 设计未覆盖：服务端 tool 消息 content 不持久化 ```` ```input ```` args header，reload 无法还原命令显示。补充：renderMessages 从 tool_calls arguments 重建 input 块 | 已修复（e06754a） |
| 3 | **测试 stub 局限** | input 块重建在测试 stub 下无法精确断言（stub renderMd 不产 pre，bash 分支覆盖）——改为断言 `_toolData.input` 恢复，input 块显示靠浏览器实测 | 记录 |

**残留扫描**：无过时函数名/类名残留（makeCard/setCardOpen/handleCardClick/.card-head/.card-body/aria-expanded 全部就位）。
