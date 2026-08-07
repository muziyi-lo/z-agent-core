# Plan WEB-UI-FIXES: Web 前端代码审查发现的 15 项修复

## 状态: ✅ 已完成 (v0.2.5, 2026-08-06)

## 问题

**现象**：`index.html` 代码审查发现严重缺陷（局域网 HTTP 下复制功能失效、移动端侧边栏不可达）、交互不一致（无会话输入被禁用、空会话刷新消失、无停止按钮、模型切换无反馈、加载会话无错误处理、SSE 异常关闭服务端空跑）及建议项。
**根因**：剪贴板 API 依赖安全上下文、移动端侧边栏切换逻辑缺失、浅色主题 token 覆盖不全、焦点样式被覆盖、复制按钮代码重复、上下文分组摘要语义误导、下拉框缺可访问性标签、发送时用户消息无索引、前端强制"先选/建会话"而服务端已支持无会话自动创建、`handleSessionCreate` 懒创建不落盘、服务端 abort 能力无前端入口、`loadSession` 无异常捕获、SSE 关闭时前端不通知服务端。

## 概览

- 改动涉及 2 个文件：`src/frontends/web/index.html`（HTML+CSS+JS）+ `src/frontends/web/handler.zig`（SSE 事件 + 空会话落盘），无核心层改动
- 15 项修复（F1-F6、F8-F16；F7 为排除项，见下），均为修改，无新增文件
- 思路：抽公共剪贴板/复制按钮工具函数消除重复，补齐响应式与主题 token，修复 a11y 与索引一致性，解除"无会话不可输入"拦截，补齐停止/空会话/错误处理/SSE 关闭等交互闭环
- 排除项（F7）：侧边栏 DOM diff 属较大重构，已有独立计划 `docs/PLAN-FUTURE-SESSION-IMPROVEMENTS.md` P2；Web fork/reset 端点见 `docs/REMAINING.md` Next N1；CLI/Web 功能差（/thinking /compact）不在本计划

## 设计要点

### F1: 剪贴板安全上下文回退

`navigator.clipboard` 仅在安全上下文（HTTPS 或 `localhost`）可用。局域网 HTTP 访问（如 `http://192.168.1.106:8080`）下属性为 `undefined`，直接调用抛 TypeError，且现有 5 处调用均无 `.catch()` 产生未处理 rejection。

方案：抽公共函数统一处理，特性检测优先，降级到 `document.execCommand('copy')`：

```js
function copyText(text, btn, doneLabel) {
  var done = function() {
    if (!btn) return;
    var orig = btn.textContent;
    btn.textContent = doneLabel || 'Copied!';
    setTimeout(function() { btn.textContent = orig; }, 1500);
  };
  if (navigator.clipboard && window.isSecureContext) {
    navigator.clipboard.writeText(text).then(done).catch(function() { fallbackCopy(text); done(); });
  } else { fallbackCopy(text); done(); }
}
function fallbackCopy(text) {
  var ta = document.createElement('textarea');
  ta.value = text;
  ta.style.position = 'fixed'; ta.style.opacity = '0';
  document.body.appendChild(ta);
  ta.select();
  try { document.execCommand('copy'); } catch(e) {}
  document.body.removeChild(ta);
}
```

**选择**：特性检测 + `execCommand` 回退，无外部依赖，兼容所有现代浏览器。

**弃用说明**：`document.execCommand()` 已被 MDN 标记为 deprecated，官方推荐 `navigator.clipboard`。但 `navigator.clipboard` 仅安全上下文可用，非安全上下文（局域网 HTTP）无其他正式剪贴板写入 API，`execCommand` 是唯一回退——故作为降级路径保留，仅非安全上下文触发。

### F2: 移动端侧边栏可达

`@media(max-width:768px)` 下 `#sidebar{display:none}` 且定义了 `.open{display:flex}`，但 JS 的折叠按钮只切换 `sidebar-collapsed`（transform），从未添加 `.open` → 移动端侧边栏永远不可见。

方案：折叠按钮按断点分派——移动端切换 `.open`，桌面端保持 `sidebar-collapsed` 持久化：

```js
document.getElementById('sidebar-toggle').onclick = function() {
  if (window.matchMedia('(max-width: 768px)').matches) {
    document.body.classList.remove('sidebar-collapsed');
    document.getElementById('sidebar').classList.toggle('open');
  } else {
    var collapsed = document.body.classList.toggle('sidebar-collapsed');
    localStorage.setItem('zagent-sidebar-collapsed', collapsed ? '1' : '0');
  }
};
```

**冲突防护**：桌面端折叠后缩小窗口，`body` 残留 `sidebar-collapsed`，移动端 `open` 的 `display:flex` 会被 `transform:translateX(-100%)` 抵消。双保险——JS 移动端分支先移除 `sidebar-collapsed`；CSS 移动端 `.open` 显式 `transform:none`：

```css
@media(max-width:768px){#sidebar.open{display:flex;transform:none}}
```

### F3: 浅色主题 token 补全

`[data-theme="light"]` 只覆盖 bg/text/border 8 个 token，accent、state、diff、syntax、overlay、elevation 仍用深色值（如 `--state-bg-danger:#450a0a` 深红底），浅色下对比度不足。

方案：补齐全部语义 token 的浅色值，并对深色背景依赖元素（`.msg pre`、`.thinking-block`、`.msg code` 行内）单独适配：

```css
[data-theme="light"]{
  --accent-base:#2563eb; --accent-success:#16a34a; --accent-warning:#d97706; --accent-error:#dc2626;
  --overlay-hover:rgba(0,0,0,0.04); --overlay-pressed:rgba(0,0,0,0.08);
  --state-bg-success:#dcfce7; --state-fg-success:#16a34a;
  --state-bg-warning:#fef9c3; --state-fg-warning:#a16207;
  --state-bg-danger:#fee2e2; --state-fg-danger:#dc2626;
  --state-bg-info:#dbeafe; --state-fg-info:#2563eb;
  --diff-added:#e7f6e7; --diff-removed:#fde8e8;
  --syntax-keyword:#7c3aed; --syntax-string:#15803d; --syntax-function:#1d4ed8;
  --elevation-raised:0 2px 4px rgba(0,0,0,0.08),0 0 0 0.5px rgba(0,0,0,0.06);
  --elevation-floating:0 8px 16px rgba(0,0,0,0.12),0 0 0 0.5px rgba(0,0,0,0.06);
}
[data-theme="light"] .msg pre{background:#e8e8ec}
[data-theme="light"] .thinking-block{background:#e8e8ec}
[data-theme="light"] .msg :not(pre)>code{background:#d5d5da}
```

深色背景（`--bg-deep`）在浅色下变浅，代码块/思考块需固定为略深于页面的中性灰，保证对比。

### F4: 下拉框焦点可见

`#model-selector select:focus{outline:none}` 以 ID 优先级覆盖全局 `:focus-visible`，键盘用户无法感知焦点位置。

方案：删除 `outline:none`，仅保留边框色强调，并显式补 `:focus-visible`：

```css
#model-selector select:focus{border-color:var(--border-focus)}
#model-selector select:focus-visible{outline:2px solid var(--accent-base);outline-offset:2px}
```

### F5: 复制按钮去重

`addMessage` 与 `done` 事件两处各手写一份"代码块 Copy 按钮"创建逻辑（共约 30 行），bash 的 Copy cmd 又单独实现。

方案：抽 `addCopyButton(pre, getText)` 公共函数，5 处调用点统一走 `copyText`：

```js
function addCopyButton(pre, getText) {
  var btn = document.createElement('button');
  btn.className = 'copy-btn';
  btn.textContent = 'Copy';
  btn.onclick = function(e) {
    e.stopPropagation();
    copyText(getText ? getText() : pre.textContent, btn);
  };
  pre.appendChild(btn);
}
```

### F6: 上下文分组摘要语义

`grep: N matches` 中的 N 是 grep 工具调用次数而非匹配数，误导用户。

方案：改为工具调用计数文案 `grep: N calls`，与 read/glob 的"文件数"语义对仗（read/glob 的 N 也是调用次数）。

### F8: 下拉框可访问性标签

`<select>` 无关联标签，读屏器无法描述用途。

方案：直接加 `aria-label="Model"`：

```html
<select id="model-select" aria-label="Model"></select>
```

### F9: 发送时用户消息索引一致化

`sendPrompt` 中 `addMessage({role:'user', content:prompt})` 不带 index，本地渲染无删除按钮；reload 后（`loadSession` 传 i）却有。行为不一致。

方案：发送时以当前已渲染消息数作为 index，但**限定前提**——仅当会话已加载且无流式进行时用 DOM 计数（DOM 顺序与服务端 JSONL 顺序一致，含 tool 卡片）：

```js
var nextIndex = document.querySelectorAll('#messages .msg, #messages .tool-card').length;
addMessage({role:'user', content:prompt}, nextIndex);
```

**一致性约束**（与 F12 关联）：`nextIndex` 是服务端 JSONL 索引的前端近似，SSE 流式期间 DOM 重建（如删除消息触发 loadSession）会导致流式节点被移除、索引漂移。因此**流式进行中禁用消息删除操作**（删除按钮置灰或隐藏），保证 index 与磁盘一致。空会话（msg_count==0）首条消息 index 为 0，`index > 0` 守卫下无删除按钮，与 reload 行为一致。

### F10: 无会话时允许直接输入（等同新会话）

**现状不一致**：服务端 `handler.zig` 的 `handlePrompt` 在 session_id 不存在（FileNotFound）时已自动创建新会话（prompt 命名 + append 消息），但前端初始 `#prompt-input`/`#send-btn` 为 disabled，`sendPrompt` 无 `currentId` 直接 return——「必须先生成/选择会话」是前端强加的流程。

方案：解除前端拦截，无会话时首条输入自动建会话。

1. **前端**：移除初始 HTML disabled；`sendPrompt` 无 `currentId` 时用 `crypto.randomUUID()` 生成会话 ID，SSE URL 直接使用；`deleteSession` 删除当前会话后恢复可输入态（下次输入自动建新会话）：

```js
if (!currentId) {
  currentId = genUuidV4();
}
function genUuidV4() {
  if (crypto.randomUUID) return crypto.randomUUID(); // 安全上下文（HTTPS/localhost）
  var b = new Uint8Array(16);
  crypto.getRandomValues(b); // 非安全上下文可用
  b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80;
  var hex = Array.prototype.map.call(b, function(x) { return ('0' + x.toString(16)).slice(-2); });
  return hex.slice(0,4).join('') + '-' + hex.slice(4,6).join('') + '-' + hex.slice(6,8).join('') + '-' +
         hex.slice(8,10).join('') + '-' + hex.slice(10,16).join('');
}
var url = A + '/session/' + currentId + '/prompt?prompt=' + encodeURIComponent(prompt);
```

2. **服务端**：`handlePrompt` 在 `is_new` 时、SSE 头之后发送 `session_ready` 事件携带 session_id **和 name**（服务端已按 prompt 前 30 字命名，直接回传避免前端显示 UUID）；同时 `done` 帧并入 `session_id` 字段作兜底：

```zig
// session_ready（流首，早建立 currentId；name = session.name 的 JSON 转义）
if (is_new) {
    var sid_buf: [256]u8 = undefined;
    const sid_payload = std.fmt.bufPrint(&sid_buf, "{{\"id\":\"{s}\",\"name\":\"{s}\"}}", .{ session_id, session_name }) catch "{}";
    try sse_state.writeFrame("session_ready", sid_payload);
}
// done 帧（流尾）并入 session_id —— buildDonePayload 增加参数
```

3. **前端**：监听 `session_ready` 设置 `currentId`/`currentName`（用回传 name，而非 UUID）并更新 topbar；`done` 处理器做兜底——若 `currentId` 尚未建立则用 `d.session_id` 补齐：

```js
evtSrc.addEventListener('session_ready', function(e) {
  var d = JSON.parse(e.data);
  if (d.id) {
    currentId = d.id;
    if (d.name) { currentName = d.name; document.getElementById('topbar').textContent = d.name; }
  }
});
// done 兜底
var d = JSON.parse(e.data);
if (d.session_id && !currentId) currentId = d.session_id;
```

**时序防御**：SSE 为单连接顺序字节流，`session_ready`（流首）必然先于 `done`（流尾）到达，不存在网络乱序；done 并入 `session_id` 是冗余兜底——即使 `session_ready` 事件因任何原因未生效，`done` 也能恢复 `currentId`，消除"依赖单一事件建立 currentId"的脆弱性。

**选择**：沿用服务端自动创建逻辑，仅补回传 id 的 SSE 事件，避免前端二次请求（POST 建会话再 prompt 会丢失 prompt 命名）。

**判定统一**（与 F12 一致）：本方案引用的"自动创建"判定收敛为 `is_new`——FileNotFound（新建 + prompt 命名）或 `session.messages().len == 0`（空会话标记，不 rename），不再单独描述为"FileNotFound"。

### F11: Web 停止/中断按钮

服务端有完整 `POST /api/session/:id/abort` + `agent.abort()`，前端却无入口——SSE 流式期间只能干等或关页面。

方案：输入栏追加停止按钮（发送时显示、完成后隐藏），点击调 abort 端点：

```js
var abortInFlight = false;
function abortPrompt() {
  if (!currentId || abortInFlight) return;
  abortInFlight = true;
  fetch(A + '/session/' + currentId + '/abort', { method: 'POST' })
    .catch(function() {})
    .finally(function() { abortInFlight = false; });
  if (evtSrc) { evtSrc.close(); evtSrc = null; }
  // 恢复输入态 + 移除 spinner
}
```

**注意**：abort 后服务端会发 error+done 帧（runTurn 被中断），前端需在 abort 时关闭 evtSrc 避免继续接收；服务端 `handleAbort` 对无活动请求返回 404（no active prompt），前端 catch 忽略即可。

### F12: 空会话落盘（New Session 刷新不消失）

`handleSessionCreate` 只生成 UUID 返回、不写文件；文件在首次 prompt 才由 FileNotFound 分支创建。副作用：新建后不发送、刷新页面 → 空会话消失，侧边栏从未出现。

方案：`handleSessionCreate` 立即创建空会话文件（JSONL header 行）；`handlePrompt` 对已存在空会话标记 `is_new`（session_ready 用）并正常 append，**不 rename**——`Session.rename()` 会重命名 JSONL 文件，破坏 session_id→UUID 文件名映射，故空会话保持 "New Session"（用户双击重命名），仅 FileNotFound 路径用 prompt 前 30 字命名：

```zig
// handlePrompt 加载后
if (!is_new) {
    if (session.messages().len == 0) is_new = true; // 空会话：仅标记，不 rename
    try session.append(.{ .role = .user, .content = prompt });
}

// handleSessionCreate
var s = try session_mod.Session.init(ctx.allocator, ctx.io, model);
defer s.deinit();
const filename = try std.fmt.allocPrint(a, "{s}.jsonl", .{id});
const path = try std.fs.path.join(a, &.{ ctx.sessions_dir, filename });
s.path = path;
try s.flush(); // 空文件落盘（含 header 行，Session.load 可正常解析）
```

**注意**：`Session.msg_count()` 不存在，消息数统一用 `session.messages().len`；`rename()` 会改文件名，**禁止对已有 UUID 路径的空会话调用 rename**（否则 `GET /api/session/:id` 失效）；needsAutoCreate 概念收敛为"is_new 判定"（FileNotFound 或 `messages().len==0`），不再作为独立函数引入。

### F13: loadSession 异常处理

`loadSession` 直接 `await api()`，会话被其他 tab 删除时 rejection 未捕获，控制台报错 + 页面卡旧状态。其余 API 调用均有 catch，此处不一致。

方案：`loadSession` 加 try-catch，失败时提示并重置输入态：

```js
async function loadSession(id) {
  var sess;
  try { sess = await api('/session/' + id); }
  catch(e) {
    console.error('loadSession error', e);
    return; // 侧边栏保持不变，输入态不动
  }
  ...
}
```

### F14: 模型切换对已有会话的提示

`currentModel` 只作用于新建会话，已加载会话继续用旧模型，无反馈。

方案：`#model-select` onchange 时，若当前会话已有消息，显示轻量提示（复用 `.status-msg` 或临时 toast）"模型切换仅对新会话生效"；空会话（msg_count=0）则直接应用。

### F15: topbar 初始文案随 F10 调整

F10 后新启动可直接输入，topbar 仍显示 "Select a session to start" 矛盾。改为 `"z-agent-core"`（与 deleteSession 后的复位文案一致），输入态由 F10 统一管理。

### F16: SSE 异常关闭时前端通知服务端

前端 `evtSrc.onerror` 中 `close()` 后，服务端第一个请求仍在 runTurn（未 abort），浪费 token 且状态不一致。

方案：`onerror` 中在关闭连接的同时调 `POST /api/session/:id/abort`，通知服务端终止：

```js
evtSrc.onerror = function() {
  abortPrompt(); // 复用 F11 防重入逻辑（abortInFlight 守卫避免与停止按钮竞态重复调用）
  document.getElementById('send-btn').disabled = false;
  document.getElementById('prompt-input').disabled = false;
  var spinners = asst.querySelectorAll('.spinner');
  for (var j = 0; j < spinners.length; j++) spinners[j].remove();
};
```

**注意**：`abortPrompt` 的 `abortInFlight` 防重入同时覆盖 F11（停止按钮）与 F16（onerror）两条路径——连接先断触发 onerror 与用户点停止几乎同时发生时不重复 POST abort；abort 命中已完成请求返回 404，catch 忽略。

## 实施

### 步骤 1: F1 剪贴板公共函数

**文件**: `src/frontends/web/index.html`
**改动**: 在 `esc()` 附近新增 `copyText` + `fallbackCopy` 两个函数
**注意**: 5 处替换点——`addMessage` assistant 复制（现 549 行）、user 复制（600）、done 事件代码块复制（795）、bash Copy cmd（944/946）

### 步骤 2: F2 移动端侧边栏分派

**文件**: `src/frontends/web/index.html`
**改动**: 替换 `#sidebar-toggle` 的 onclick（约 191 行）
**注意**: 桌面端持久化逻辑保持不变

### 步骤 3: F3 浅色主题 token 补全

**文件**: `src/frontends/web/index.html`
**改动**: 扩展 `[data-theme="light"]` 块 + 追加 pre/thinking-block/code 适配
**注意**: 需 L2 用户视觉确认对比度

### 步骤 4: F4 焦点样式修正

**文件**: `src/frontends/web/index.html`
**改动**: 修改 `#model-selector select:focus` 规则（115 行附近）

### 步骤 5: F5 复制按钮重构

**文件**: `src/frontends/web/index.html`
**改动**: 新增 `addCopyButton`，替换两处代码块按钮创建 + bash Copy cmd
**注意**: bash Copy cmd 当前是 `name-row` 子元素，不走 `pre`，单独适配

### 步骤 6: F6 + F8 摘要文案与 aria-label

**文件**: `src/frontends/web/index.html`
**改动**: `wrapContextToolGroups` 摘要文案 + `<select>` 标签

### 步骤 7: F9 用户消息索引

**文件**: `src/frontends/web/index.html`
**改动**: `sendPrompt` 的 `addMessage` 传计算索引
**注意**: 删除后 `index > 0` 守卫意味着首条消息（index 0）不可删，与 reload 行为一致

### 步骤 8: F10 无会话直接输入

**文件**: `src/frontends/web/index.html` + `src/frontends/web/handler.zig`
**改动**:
1. index.html 移除 `#prompt-input`/`#send-btn` 初始 disabled
2. `sendPrompt` 无 `currentId` 时生成 UUID（`crypto.randomUUID` 带回退）
3. 新增 `session_ready` SSE 监听 → 设置 `currentId`/`currentName`/topbar
4. `done` 处理器兜底：`d.session_id` 补齐 `currentId`（handler.zig `buildDonePayload` 增加 session_id 参数）
5. `deleteSession` 删除当前会话后不再禁用输入
6. handler.zig `handlePrompt` 在 `is_new` 时、SSE 头之后发 `session_ready` 事件
**注意**: `sse_state` 定义位置需在写 `session_ready` 前；前端 UUID 需符合 v4 格式避免路径校验拒绝；done 帧兜底保证 currentId 建立不依赖单事件；`session_ready` 回传 `name`（prompt 命名）避免 topbar 显示 UUID

### 步骤 9: F11 停止按钮 + F16 SSE 异常关闭 abort

**文件**: `src/frontends/web/index.html`
**改动**: 输入栏追加停止按钮（CSS + HTML + JS），发送时显示、done/error/onerror 时隐藏；`onerror` 和停止按钮共用 `abortPrompt()`（含 `abortInFlight` 防重入）
**注意**: 停止按钮与 send 按钮互斥显示；abort 404 忽略

### 步骤 10: F12 空会话落盘

**文件**: `src/frontends/web/handler.zig`
**改动**: `handleSessionCreate` 创建空文件并 flush（UUID 路径）；`handlePrompt` 空会话标记 `is_new`（`messages().len==0`）并正常 append，不 rename（避免 `Session.rename()` 改文件名破坏 UUID 映射）
**注意**: 验证 `Session.load` 对空文件（仅 header 行）返回 `messages().len==0`；空会话保持 "New Session" 显示名，由用户双击重命名

### 步骤 11: F13 loadSession 异常处理

**文件**: `src/frontends/web/index.html`
**改动**: `loadSession` 加 try-catch，失败仅 console 报错并返回

### 步骤 12: F14 模型切换提示

**文件**: `src/frontends/web/index.html`
**改动**: `#model-select` onchange 时判断当前会话是否有消息，有则显示提示
**注意**: 需要会话消息数状态，可在 loadSession/new-session/deleteSession 时维护一个全局计数

### 步骤 13: F15 topbar 初始文案

**文件**: `src/frontends/web/index.html`
**改动**: 初始 `#topbar` 文案从 "Select a session to start" 改为 "z-agent-core"

### 步骤 14: 全量验证 + 回归

**文件**: `src/frontends/web/index.html` + `handler.zig`
**改动**: 重新编译、跑既有 SSE 测试、浏览器实测全部 F1-F16 场景
**注意**: 涉及 `handler.zig` 改动，需跑 `zig test` 确认 SSE/handler 相关测试不回归

## 验证

```powershell
zig build
zig test src/test.zig --cache-dir .zig-cache 2>&1 | Select-String "^\d+/\d+|All \d+ tests|FAIL"
```

| 场景 | 预期 |
|------|------|
| 局域网 HTTP 访问复制代码/命令 | 按钮显示 Copied!，内容进剪贴板（execCommand 回退） |
| localhost/HTTPS 访问复制 | 走 navigator.clipboard |
| 窗口 <768px 点 ☰ | 侧边栏显示，再点隐藏 |
| 桌面点 ☰ | 折叠+localStorage 持久化（不变） |
| 切浅色主题 | 按钮/状态/diff/代码块对比度正常，无深色残留 |
| Tab 到模型下拉 | 焦点环可见 |
| 发送消息后 user 气泡 | 有删除按钮，点击删除 index 正确 |
| grep 分组摘要 | 显示 "grep: N calls" |
| 新启动直接输入首条消息 | 自动建会话，侧边栏出现 prompt 命名会话，后续可继续对话 |
| 删除当前会话后直接输入 | 创建新会话，不再被禁用 |
| 流式期间点停止 | 请求终止，输入恢复可用，无残留 spinner |
| SSE 断线/异常关闭 | 服务端请求被 abort，不空跑 |
| New Session 后刷新页面 | 空会话仍在侧边栏（已落盘） |
| 加载被删除的会话 | 控制台报错，页面不卡死 |
| 已有会话时切换模型 | 显示"仅对新会话生效"提示 |
| 空会话切换模型 | 直接应用，无提示 |
| 新启动 topbar 文案 | 显示 "z-agent-core" 而非 "Select a session to start" |

L2 用户确认：F3 主题切换、F2 移动端行为需用户浏览器实际操作确认。

## 波及

| 文件 | 改动 | 破坏性? |
|------|------|----------|
| `src/frontends/web/index.html` | 15 项修复 + 公共函数 + 停止按钮 | 否（纯前端） |
| `src/frontends/web/handler.zig` | `handlePrompt` session_ready 事件 + 空会话 is_new 判定 + `handleSessionCreate` 空会话落盘 + `buildDonePayload` 增加 session_id 参数 | 是（handler 行为变更，需跑 SSE/handler 测试回归） |

## 术语

| 术语 | 含义 |
|------|------|
| 安全上下文 | Secure Context，指 HTTPS 或 localhost 页面环境，navigator.clipboard 等 API 仅在此可用 |
| execCommand 回退 | 基于 `document.execCommand('copy')` 的剪贴板降级方案，非安全上下文通用 |
| 断点分派 | 按 `matchMedia` 结果在移动/桌面两种侧边栏切换逻辑间选择 |
| session_ready 事件 | 服务端在自动创建会话后回传 session_id 的 SSE 事件，前端据此建立 currentId |
| 空会话落盘 | handleSessionCreate 即写空 JSONL 文件，使"New Session"刷新不消失 |
