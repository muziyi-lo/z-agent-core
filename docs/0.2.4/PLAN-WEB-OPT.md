# Plan WEB-OPT: Web 前端优化

## 状态: ✅ 已完成 (v0.2.4) — 14 项体验改进全部实现，本文档作为历史参考保留

## 前置依赖

| 阻塞者 | 状态 | 被阻塞 |
|--------|------|--------|
| PHASE-7 Web 前端 MVP | ✅ 已完成 (v0.2.3) | 全部条目 |

## 问题

**现象**：Web 前端基础功能可用但体验粗糙——消息不渲染 Markdown（纯文本 whitespace 折叠）、侧边栏固定宽度、用户消息无视觉区分、无用量统计。

**根因**（四层）：
1. **Vendor JS 未注入**：`marked.js`/`highlight.js`/`DOMPurify` 已嵌入 `src/frontends/web/vendor/` 但 `serveIndex` 直接返回原始 `index.html`，不注入内联 `<script>`。320+ KB 资源闲置。
2. **消息渲染用 `textContent`**：`addMessage()` 和 `content_delta` 使用 `div.textContent +=`，换行被折叠、Markdown 不解析。
3. **侧边栏固定 240px**：无拖拽 resize，长会话名被截断。
4. **`done` 事件缺用量**：只传递 `new_messages` 计数，不含 token 用量和模型名。

## 参考

| 文件 | 用途 |
|------|------|
| `PLAN-PHASE-7-WEB-FRONTEND.md` §4 (配色 Token) §7 (SSE 事件模型) | 设计 Token 和 SSE 帧格式均已定义 |
| `vendor/` | marked.js v15 / highlight.js v11 / DOMPurify v3 — 已下载在 `src/frontends/web/vendor/` |

## 不做

- 不修改 agent 核心层 — 用量数据已在 `Message.usage` 中，handler 层读取即可
- 不加新路由 — vendor JS 编译期内联到 HTML，不增加 HTTP 请求
- 不换框架 — 保持单 HTML 文件 + vanilla JS

## 设计要点

### 0. Vendor JS 内联注入

**现状**：`serveIndex` 返回原始 HTML，vendor 文件闲置。

**方案**：`server.zig` 编译期读取 vendor 文件 + `@embedFile("index.html")`，在 `</body>` 前注入三个 `<script>` 标签（避免渲染阻塞），在 `<style>` 前注入 `@font-face`。

```zig
// server.zig — 替换 serveIndex 为 handler 内的做法
const INDEX_HTML = @embedFile("index.html");
const MARKED_JS = @embedFile("vendor/marked.min.js");
const HIGHLIGHT_JS = @embedFile("vendor/highlight.min.js");
const PURIFY_JS = @embedFile("vendor/purify.min.js");

fn serveIndex(_: *Context, request: *std.http.Server.Request) !void {
    // 在 </body> 前插入 <script>...</script>
    // 避免 <head> 内同步加载阻塞首次渲染
    var body: std.ArrayListAligned(u8, null) = .empty;
    // ... 拼接 HTML + 内联 JS（body 底部）
}
```

`@embedFile` 是编译期操作 → 零运行时开销，单文件 ~380KB（HTML 15KB + JS ~360KB）。JS 放在 body 底部确保 HTML/CSS 先渲染，再解析脚本。

### 1. 用户消息左侧 padding

CSS 非对称间距——用户消息视觉靠右，assistant 消息靠左，用 `max-width` + `margin` 区分。

```css
.msg.user { background: var(--bg-layer-02); margin-left: auto; margin-right: 0; max-width: 85%; }
.msg.assistant { margin-left: 0; margin-right: auto; max-width: 100%; }
```

### 2. 侧边栏拖拽 resize

纯 CSS + JS，无框架依赖：

```css
#sidebar { position: relative; min-width: 180px; max-width: 480px; }
#resize-handle { position: absolute; right: 0; top: 0; bottom: 0; width: 4px; cursor: col-resize; }
#resize-handle:hover, #resize-handle.active { background: var(--accent-base); }
```

```js
// resize handle
let resizeHandle = document.getElementById('resize-handle');
let isResizing = false;
resizeHandle.onmousedown = (e) => { isResizing = true; e.preventDefault(); };
document.onmousemove = (e) => { if (!isResizing) return; sidebar.style.width = Math.min(480, Math.max(180, e.clientX)) + 'px'; };
document.onmouseup = () => { isResizing = false; };
```

### 3. 多行输入 (Shift+Enter / Ctrl+Enter)

当前 `Enter` = 发送，`Shift+Enter` 已阻止发送（光标在 `<textarea>` 中默认插入换行）。补充 `Ctrl+Enter`：

```js
inp.onkeydown = (e) => {
  if (e.key === 'Enter' && !e.shiftKey && !e.ctrlKey) { e.preventDefault(); sendBtn.click(); }
};
```

`<textarea>` 原生支持换行——不需额外处理，只需确保 Enter 不被拦截。

### 4. 消息页脚用量统计

**后端**：`handlePrompt` 在 `agent.runTurn()` 完成后，从 session 最后一条 assistant 消息提取 `usage` 字段，拼入 `done` 事件 JSON。

```zig
// handler.zig handlePrompt — done 事件扩展
var done_buf: [256]u8 = undefined;
const msgs = session.messages();
var usage_json: []const u8 = "null";
for (var i: usize = msgs.len; i > 0;) { i -= 1; if (msgs[i].role == .assistant and msgs[i].usage != null) { usage_json = ... break; } }
const msg = try std.fmt.bufPrint(&done_buf, "{{\"new_messages\":{d},\"usage\":{s},\"model\":\"{s}\"}}", .{ ... });
```

**前端**：`done` 事件处理后，在 assistant 消息底部追加用量行：

```html
<div class="usage-footer">
  <span>{model}</span> · <span>{input_tokens}↑</span> <span>{output_tokens}↓</span> · <span>{cache_hit}% cache</span>
</div>
```

```css
.usage-footer { margin-top: 6px; padding-top: 4px; border-top: 1px solid var(--border-muted); font-size: var(--text-xs); color: var(--text-faint); }
```

### 5. 流式 Markdown 渲染

**现状**：`content_delta` 使用 `textContent += d.text` ——纯文本、不渲染 Markdown。

**方案**：流式时不渲染（累积到 `rawContent` 字符串），`done` 事件时用 `marked.parse()` + `DOMPurify.sanitize()` 一次性渲染为 HTML，替换 `contentDiv` 内容。

```js
let rawContent = '';
evtSrc.addEventListener('content_delta', (e) => {
  const d = JSON.parse(e.data);
  rawContent += d.text || '';
  // 流式阶段：显示纯文本（带 pre-wrap）避免频繁 DOM 重解析
  contentDiv.textContent = rawContent;
  msgs.scrollTop = msgs.scrollHeight;
});
evtSrc.addEventListener('done', () => {
  // 最终渲染 Markdown → HTML
  const html = DOMPurify.sanitize(marked.parse(rawContent));
  contentDiv.innerHTML = html;
  // 代码块语法高亮
  contentDiv.querySelectorAll('pre code').forEach(block => hljs.highlightElement(block));
  // 显示用量
  ...
});
```

> **为何不完全流式渲染**：`marked.parse()` 对不完整的 Markdown 边界（` ```未闭合`、`**未闭合**`）输出不良 HTML。先累积到 `done` + 一次性渲染 = 正确语义。

### 6. 消息换行修复

**现状**：`addMessage()` 使用 `div.textContent = content` → whitespace 折叠，`\n\n` 段落间距丢失。

**修复**：历史消息加载时经过 Markdown 渲染：

```js
function addMessage(role, content) {
  const div = document.createElement('div');
  div.className = 'msg ' + role;
  if (role === 'assistant') {
    const html = DOMPurify.sanitize(marked.parse(content || ''));
    div.innerHTML = html;
    // 代码高亮
    div.querySelectorAll('pre code').forEach(block => hljs.highlightElement(block));
  } else {
    // 用户消息：纯文本 + pre-wrap（保留换行）
    div.style.whiteSpace = 'pre-wrap';
    div.textContent = content || '';
  }
  msgs.appendChild(div);
  msgs.scrollTop = msgs.scrollHeight;
  return div;
}
```

### 7. Markdown CSS 补充

marked.js 输出标准 HTML 标签，CSS 需覆盖代码块、表格、列表：

```css
.msg pre { background: var(--bg-deep); border-radius: var(--radius-md); padding: 12px; overflow-x: auto; margin: 8px 0; }
.msg code { font-family: 'JetBrains Mono', monospace; font-size: var(--text-xs); }
.msg pre code { background: none; padding: 0; }
.msg table { border-collapse: collapse; margin: 8px 0; }
.msg th, .msg td { border: 1px solid var(--border-base); padding: 4px 8px; text-align: left; }
.msg ul, .msg ol { padding-left: 20px; margin: 4px 0; }
.msg blockquote { border-left: 3px solid var(--accent-base); padding-left: 12px; margin: 8px 0; color: var(--text-muted); }
.msg hr { border: none; border-top: 1px solid var(--border-base); margin: 12px 0; }
.msg a { color: var(--accent-base); }
.msg p { margin: 4px 0; }
.msg h1,.msg h2,.msg h3,.msg h4 { color: var(--text-strong); margin: 12px 0 4px; }
```

### 8. 消息删除按钮

**现状**：无可删除单条消息的能力。误发送或 LLM 错误输出只能通过 fork + 重来间接处理。

**方案**：每条消息 hover 时显示 × 按钮，点击后确认 → DELETE 请求 → session 重写 + DOM 移除。

**后端**：`session.zig` 不支持随机删除。需新增 `removeMessage(index)` 方法——读取全部消息、跳过目标索引、原子重写文件。

```zig
// session.zig 新增
pub fn removeMessage(self: *Session, io: Io, index: usize) !void {
    const msgs = self.messages();
    if (index >= msgs.len) return error.IndexOutOfBounds;
    // 原子重写：写临时文件 → rename
    const tmp_path = try std.fmt.allocPrint(arena, "{s}.tmp", .{self.path.?});
    defer arena.free(tmp_path);
    // 写入保留的消息（跳过 index）
    // ... atomic rename
}
```

**API**：`DELETE /api/session/:id/message/:index` — handler 加载 session → 调用 `removeMessage` → 返回 JSON。

**前端**：每条 `.msg` div 内含隐藏的 × 按钮，hover 时显示：

```css
.msg { position: relative; }
.msg .msg-delete { position: absolute; top: 4px; right: 8px; opacity: 0; cursor: pointer;
  color: var(--text-faint); font-size: var(--text-sm); padding: 2px 6px; border-radius: var(--radius-sm); }
.msg:hover .msg-delete { opacity: 0.5; }
.msg .msg-delete:hover { opacity: 1; color: var(--accent-error); background: var(--bg-layer-02); }
```

```js
function addMessage(role, content, index) {
  // ... 现有渲染逻辑 ...
  const delBtn = document.createElement('span');
  delBtn.className = 'msg-delete';
  delBtn.textContent = '\u00d7';
  delBtn.onclick = async (e) => {
    e.stopPropagation();
    if (!confirm('Delete this message?')) return;
    await api('/session/' + currentId + '/message/' + index, { method: 'DELETE' });
    div.remove();
    // 重载 session 更新索引偏移
    await loadSession(currentId);
  };
  div.appendChild(delBtn);
  ...
}
```

**边界约束**：
- 不删除系统消息（索引 0，role=system）——前端不渲染删除按钮
- 删除后重载 session 保持索引一致性（后续消息索引前移）

### 9. 会话删除按钮优化

**现状**：侧边栏每个 session 条目有 `×` 删除按钮，使用原生 `confirm()` 弹窗——样式不统一、不可自定义、无过渡动画。

**方案**：替换为自定义 confirm 弹窗 + 视觉优化。

**自定义 confirm modal**（纯 CSS + JS，零依赖）：

```html
<div id="confirm-modal" class="modal-overlay" style="display:none">
  <div class="modal-box">
    <div class="modal-msg" id="confirm-msg"></div>
    <div class="modal-actions">
      <button class="modal-cancel">Cancel</button>
      <button class="modal-danger" id="confirm-ok">Delete</button>
    </div>
  </div>
</div>
```

```css
.modal-overlay { position: fixed; inset: 0; background: rgba(0,0,0,0.5); display: flex; align-items: center; justify-content: center; z-index: 100; }
.modal-box { background: var(--bg-layer-01); border: 1px solid var(--border-base); border-radius: var(--radius-lg); padding: 20px; min-width: 300px; }
.modal-msg { color: var(--text-base); margin-bottom: 16px; font-size: var(--text-base-fs); }
.modal-actions { display: flex; justify-content: flex-end; gap: 8px; }
.modal-cancel { padding: 6px 14px; background: var(--bg-layer-02); border: 1px solid var(--border-base); border-radius: var(--radius-md); color: var(--text-base); cursor: pointer; }
.modal-danger { padding: 6px 14px; background: var(--accent-error); border: none; border-radius: var(--radius-md); color: white; cursor: pointer; font-weight: 600; }
```

```js
function confirmModal(msg) {
  return new Promise(resolve => {
    document.getElementById('confirm-msg').textContent = msg;
    const overlay = document.getElementById('confirm-modal');
    overlay.style.display = 'flex';
    document.getElementById('confirm-ok').onclick = () => { overlay.style.display = 'none'; resolve(true); };
    overlay.querySelector('.modal-cancel').onclick = () => { overlay.style.display = 'none'; resolve(false); };
  });
}

// deleteSession 改用自定义 confirm
async function deleteSession(id) {
  if (!(await confirmModal('Delete this session?'))) return;
  // ... 原有删除逻辑 ...
}
```

**按钮样式统一**：会话删除按钮与消息删除按钮使用一致的视觉语言——同色系、同圆角、同 hover 行为。

```css
.delete-btn { position: absolute; top: 4px; right: 6px; width: 20px; height: 20px; display: flex;
  align-items: center; justify-content: center; opacity: 0; cursor: pointer; color: var(--text-faint);
  font-size: 14px; border-radius: var(--radius-sm); transition: opacity 0.15s, color 0.15s, background 0.15s; }
#session-list .session:hover .delete-btn { opacity: 0.4; }
#session-list .session .delete-btn:hover { opacity: 1; color: var(--accent-error); background: var(--bg-layer-03); }
```

**改进点**：
- `position: absolute` 替代 `float: right`（更精确的定位控制）
- `transition` 平滑过渡替代瞬时切换
- 统一的 `.delete-btn` 类：会话和消息共用同一组件样式
- 自定义 confirm modal 替代浏览器 `confirm()`

### 10. 字体注入

**现状**：`vendor/inter.woff2` (338KB) 和 `vendor/jetbrains-mono.ttf` (296KB) 已下载但 `serveIndex` 不注入 `@font-face`。当前回退到 `system-ui`。

**方案**：`serveIndex` 在 `<style>` 块前注入 base64 内联 `@font-face`（字体在 `<head>` 中因为 CSS 需要尽早声明，且 woff2/ttf 本身不阻塞渲染）。

```zig
// handler.zig serveIndex — 拼接 @font-face
const INTER_WOFF2  = @embedFile("vendor/inter.woff2");
const JETBRAINS_TTF = @embedFile("vendor/jetbrains-mono.ttf");
// <style>@font-face{font-family:'Inter';src:url(data:font/woff2;base64,{s})}...</style>
```

CSS 变量改用自定义字体：
```css
--font-ui:   'Inter', system-ui, sans-serif;
--font-code: 'JetBrainsMono', monospace;
body { font-family: var(--font-ui); }
.msg code, .msg pre { font-family: var(--font-code); }
```

### 11. 代码块复制按钮

**现状**：代码块无复制能力。opencode 对标实现：hover 时右上角出现 copy 图标，点击后切换为 check（`markdown.css:202-227`）。

**方案**：`done` 事件渲染 Markdown 后，为每个 `<pre>` 动态注入复制按钮。

```js
// done 事件渲染完成后
contentDiv.querySelectorAll('pre').forEach(pre => {
  const btn = document.createElement('button');
  btn.className = 'copy-btn';
  btn.textContent = 'Copy';
  btn.onclick = async () => {
    await navigator.clipboard.writeText(pre.textContent);
    btn.textContent = 'Copied!';
    setTimeout(() => btn.textContent = 'Copy', 1500);
  };
  pre.appendChild(btn);
});
```

```css
.msg pre { position: relative; }
.msg pre .copy-btn { position: absolute; top: 8px; right: 8px; padding: 2px 8px;
  background: var(--bg-layer-02); border: 0.5px solid var(--border-base);
  border-radius: var(--radius-sm); color: var(--text-muted); font-size: var(--text-xs);
  cursor: pointer; opacity: 0; transition: opacity 0.15s; }
.msg pre:hover .copy-btn { opacity: 1; }
.msg pre .copy-btn:hover { color: var(--text-strong); border-color: var(--border-focus); }
```

### 12. CSS Token 扩展

**现状**：`:root` 仅 14 个变量，缺 overlay 交互态、语义状态三色组、elevation 阴影、diff 色、过渡变量。

**方案**：一次性扩展到 30+ 变量（参考 opencode `theme.css` + `colors.css`）。

```css
:root {
  /* ...现有 14 个变量保留... */

  /* 叠加交互态 */
  --overlay-hover:   rgba(255,255,255,0.06);
  --overlay-pressed: rgba(255,255,255,0.10);

  /* Elevation */
  --elevation-raised:   0 2px 4px rgba(0,0,0,0.3), 0 0 0 0.5px rgba(255,255,255,0.08);
  --elevation-floating: 0 8px 16px rgba(0,0,0,0.3), 0 0 0 0.5px rgba(255,255,255,0.08);

  /* 语义状态三色组 (bg/fg 两组即可) */
  --state-bg-success: #052e16;  --state-fg-success: #4ade80;
  --state-bg-warning: #422006;  --state-fg-warning: #facc15;
  --state-bg-danger:  #450a0a;  --state-fg-danger:  #f87171;
  --state-bg-info:    #172554;  --state-fg-info:    #60a5fa;

  /* Diff */
  --diff-added:   #1b3b1b;
  --diff-removed: #3b1b1b;

  /* 动效 */
  --transition-fast: 120ms;
  --transition-panel: 240ms cubic-bezier(0.22, 1, 0.36, 1);
}
```

### 13. 工具卡片视觉升级

**现状**：`.tool-card` 仅左边框强调。opencode 对标：完整卡片（border 0.5px + radius 6px + 背景透明层 + hover 过渡 + 操作按钮）。

**方案**：纯 CSS 升级，不改 JS 结构。

```css
.tool-card { border: 0.5px solid var(--border-base); border-radius: var(--radius-md);
  background: var(--overlay-hover); transition: border-color var(--transition-fast), background var(--transition-fast); }
.tool-card:hover { border-color: var(--border-focus); background: var(--overlay-pressed); }
.tool-card .name-row { display: flex; align-items: center; gap: 6px; }
.tool-card .name { font-weight: 600; }
.tool-card .output { border-top: 0.5px solid var(--border-muted); padding-top: 6px; margin-top: 4px; }
```

### 14. 可访问性与动效

**现状**：无 `:focus-visible` 样式、无 `prefers-reduced-motion` 适配。

```css
:focus-visible { outline: 2px solid var(--accent-base); outline-offset: 2px; border-radius: 2px; }

@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after { animation-duration: 0.01ms !important; transition-duration: 0.01ms !important; }
  .spinner { animation: none; }
}
```

## 实施

| 步骤 | 文件 | 内容 |
|------|------|------|
| 1 | `handler.zig` | `serveIndex` 注入 `@embedFile` vendor JS + 字体 @font-face base64 |
| 2 | `index.html` CSS | Token 扩展 (14→30+) + 用户消息气泡 + resize handle + Markdown 样式 + usage-footer + msg-delete + 工具卡片升级 + :focus-visible + reduced-motion |
| 3 | `index.html` JS | resize 拖拽、多行输入 Enter/Ctrl+Enter 逻辑 |
| 4 | `index.html` JS | `addMessage()` 改为 Markdown 渲染 + 代码高亮 + 消息删除按钮 |
| 5 | `index.html` JS | `sendPrompt()` 流式累积 rawContent → done 时 marked.parse 一次性渲染 + 代码块复制按钮 |
| 6 | `handler.zig` | `done` 事件新增 `usage` + `model` 字段 |
| 7 | `index.html` JS | `done` 事件渲染 usage-footer |
| 8 | `session.zig` | 新增 `removeMessage(io, index)` — 原子重写 JSONL |
| 9 | `handler.zig` | 新增 `DELETE /api/session/:id/message/:index` 端点 |
| 10 | `index.html` | 自定义 confirm modal + 会话/消息删除按钮样式统一 |

## 验证

```powershell
zig build
zig build run -- --web
# 打开 http://localhost:8090
```

| 测试场景 | 预期结果 |
|----------|----------|
| 用户消息 vs assistant 消息 | 用户消息偏右（max-width 85%），assistant 偏左 |
| 侧边栏拖拽 | 拖拽 handle 改变宽度，范围 180-480px |
| Shift+Enter 输入 | textarea 内换行，不发送 |
| Ctrl+Enter 输入 | textarea 内换行，不发送 |
| Enter 发送 | 发送消息（无修饰键） |
| Assistant 消息 Markdown | 解析 `**bold**`、` ```code``` `、表格、列表 |
| 代码块语法高亮 | `<pre><code>` 内容经 highlight.js 着色 |
| 消息页脚 | 显示模型名 + input/output token 用量 |
| 流式 → done 渲染 | 流式阶段显纯文本，done 时切换为 HTML |
| 历史消息回放 | 加载旧 session 消息时 Markdown 正确渲染 |
| XSS 防护 | `<script>alert(1)</script>` 不执行（DOMPurify 净化） |
| 消息删除 | hover 显示 ×，点击确认后消息移除 + session 重写 |
| 系统消息保护 | 首条 system 消息不显示删除按钮 |
| 删除后索引一致性 | 重载 session，后续消息索引前移不混乱 |
| 会话删除 confirm | 自定义 modal 弹窗替代浏览器 `confirm()` |
| 删除按钮样式 | 会话/消息 × 按钮视觉一致，hover 渐变过渡 |
| 字体加载 | Inter + JetBrainsMono 渲染正文和代码 |
| 代码块复制 | hover 显示 Copy 按钮，点击后写入剪贴板 + Copied 反馈 |
| 工具卡片 | 完整边框 + 圆角 + hover 过渡 |
| :focus-visible | Tab 导航可见焦点环 |
| reduced-motion | 系统动效偏好关闭时禁用动画 |

## 波及

| 文件 | 改动 | 破坏性? |
|------|------|----------|
| `core/session.zig` | 新增 `removeMessage(io, index)` | 否 |
| `handler.zig` | `serveIndex` 注入 vendor JS | 否 |
| `handler.zig` | `handlePrompt` done 事件扩展 usage/model 字段 | 否 |
| `handler.zig` | 新增 `DELETE /api/session/:id/message/:index` | 否 |
| `index.html` | CSS ~100行 + JS 重写渲染逻辑 + 消息删除 | 否 |

## 术语

| 术语 | 含义 |
|------|------|
| Vendor JS | 编译期内联到 HTML 的第三方 JS 库（marked + highlight + purify） |
| rawContent | 流式 SSE content_delta 累积的原始 Markdown 字符串 |
| usage-footer | assistant 消息底部的 token 用量 + 模型名显示 |
