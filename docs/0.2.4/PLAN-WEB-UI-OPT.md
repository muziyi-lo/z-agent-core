# PLAN: Web UI 优化 — 侧边栏+模型切换+消息渲染+工具卡片+命名

> **状态**: ✅ 全部 10 项已实现。本文档作为历史参考保留，行号引用和部分早期设计（工具默认折叠/≥3 阈值）已被后续实现覆盖，以 `docs/DESIGN-WEB-RENDER.md` 为准。

## 术语表

| 术语 | 含义 |
|------|------|
| sidebar | 左侧侧边栏，含标题+模型名+新建按钮+会话列表 |
| 模型选择器 | sidebar 底部的下拉菜单，切换当前模型 |
| system-prompt | `#system-prompt` 容器，显示首条系统消息 |

## 现状

- `index.html:115-123` — sidebar HTML 结构：header(h1+model名) + new-session-btn + session-list
- `index.html:70-73` — `.msg.system` 使用 `textContent` 渲染，非 markdown
- `index.html:49` — `.msg.user` 已右对齐 `margin-left:auto;max-width:85%`
- `handler.zig:51` — `GET /api/model` 返回模型列表 `[{id, name, provider, context_window}]`
- `handler.zig:52` — `GET /api/provider` 返回 providers

## 改动点 (10 项)

### 1. 侧边栏可收起

**修改**: `index.html` CSS + JS

- CSS: `.sidebar-collapsed #sidebar { transform: translateX(-100%) }` — 移出视口，保留宽度和 resize 状态
- `.sidebar-collapsed` 时 `#resize-handle` 随 sidebar 一起移出，无需单独处理
- 折叠/展开过渡: `transition: transform var(--transition-panel)`
- 展开: 移除 `sidebar-collapsed` class，`translateX(0)` 自动恢复

**交互设计**:
- 折叠按钮 `#sidebar-toggle` 位于 `#topbar` 左侧，始终可见（`#topbar` 属于 `#main`，不受 sidebar 折叠影响）
- 按钮内容: `<span id="sidebar-toggle">&#9776;</span>` — HTML entity `☰` (hamburger)，零外部依赖
- CSS: `cursor:pointer; padding:0 8px; font-size:16px; color:var(--text-muted); user-select:none`
- 悬停: `color:var(--text-strong)`
- 点击切换 `document.body.classList.toggle('sidebar-collapsed')`
- 无图标切换逻辑 — `☰` 在任何状态下含义明确（"打开/关闭菜单"）
- 默认展开（无 `sidebar-collapsed` class）

**持久化**: `localStorage.setItem('zagent-sidebar-collapsed', '1')` 折叠时保存，展开时设 `'0'`
- 页面加载时读取 `localStorage.getItem('zagent-sidebar-collapsed')`，为 `'1'` 时自动加 class

### 2. 侧边栏美化

**修改**: `index.html` CSS `.sidebar-header`

- `#sidebar-header h1` 改为居中 `text-align:center`，字号 `--text-lg`
- 新增 `#sidebar-header .subtitle` 副标题行
- `.model` 移到底部（见第 3 项）

### 3. 模型切换功能

**修改**: `index.html` HTML + CSS + JS

- sidebar 底部新增 `#model-selector` 区域：
  - 显示当前模型名（从 session list 首条或 API 获取）
  - `<select>` 下拉列出所有可用模型，分组按 provider
- JS: `loadModels()` 调 `GET /api/model`，填充 `<select>`
- `onchange` 设置 `currentModel` 变量，新建 session 时传入
- CSS: `#model-selector` 固定于 sidebar 底部，`border-top`

**交互设计**:
- 无 session 时显示 "No model selected"，`<select>` 默认选中第一个可用模型
- 加载页面时自动调 `GET /api/model`，填充下拉
- 用户选择模型后，`currentModel` 更新；点 "New Session" 时 POST body 携带 `{model: currentModel}`
- Session 列表中每条 session 的 `model` 字段显示当前使用的模型名（已有）

**持久化**: `localStorage.setItem('zagent-model', currentModel)` 保存模型选择
- 页面加载时 `localStorage.getItem('zagent-model')` 恢复，优先于 API 默认值
- 无存储时取 API 返回的第一个模型

**降级**: `loadModels()` API 失败时
- localStorage 有缓存 → 单选项恢复上次模型
- 无缓存 → `<option>Default</option>`，后端回退 `config.default_model`
- 不阻塞 New Session 按钮

### 4. 会话栏最大宽度限制

**修改**: `index.html` CSS `#session-list`

- 当前 sidebar 已设 `min-width:180px;max-width:480px` (line 30)
- 但 session list 内文字无限制 → 加 `word-break:break-word;overflow-wrap:break-word`
- `.session .name` 加 `overflow:hidden;text-overflow:ellipsis;white-space:nowrap`

### 5. 用户消息右对齐 + 自适应宽度

**修改**: `index.html` CSS `.msg.user`

- 当前 `.msg.user { margin-left:auto; max-width:85% }` (line 49)
- 改为 `max-width:70%; width:fit-content; width:-moz-fit-content`
- 添加 `border-top-right-radius:0` 气泡效果

### 6. 系统消息 markdown 渲染 + 滚动条样式

**修改**: `index.html` CSS + JS

- `renderSystemPrompt()` 改为用 `marked.parse()` 渲染 markdown
- CSS: `.msg.system` 添加 overflow-y scrollbar 样式
  - `scrollbar-width:thin; scrollbar-color:var(--text-faint) transparent` (Firefox)
  - `::-webkit-scrollbar { width:6px }` `::-webkit-scrollbar-thumb { background:var(--text-faint); border-radius:3px }`

### 7. 工具卡片折叠 + markdown 渲染

**修改**: `index.html` CSS + JS (done 事件)

- 工具卡片默认折叠：只显示工具名行，点击展开输出区域
- 折叠/展开交互同 thinking block 模式：`.tool-card .output { display:none }` → `.tool-card.open .output { display:block }`
- 点击工具名行切换 `open` class
- done 事件: 对所有 tool-card 的 output 做 `renderMd()` 渲染（替换 textContent）
- tool-start 时仍用 textContent 流式追加（保持即时可见）

**CSS 新增**:
```css
.tool-card .output { display:none; margin-top:6px; border-top:0.5px solid var(--border-muted); padding-top:6px }
.tool-card.open .output { display:block }
.tool-card .name-row { cursor:pointer }
```

**JS 新增** (done 事件末尾):
```js
// markdown 渲染所有 tool 输出
var tools = asst.querySelectorAll('.tool-card');
tools.forEach(function(tc) {
  var out = tc.querySelector('.output');
  if (out) out.innerHTML = renderMd(out.textContent);
});
// >=3 个工具时显示全部展开/折叠按钮
if (tools.length >= 3) {
  var toggleAll = document.createElement('button');
  toggleAll.className = 'tool-toggle-all';
  toggleAll.textContent = 'Expand all';
  toggleAll.onclick = function() {
    var expand = toggleAll.textContent === 'Expand all';
    tools.forEach(function(tc) { tc.classList.toggle('open', expand); });
    toggleAll.textContent = expand ? 'Collapse all' : 'Expand all';
  };
  asst.insertBefore(toggleAll, tools[0]);
}
```

**CSS 新增** (toggle 按钮):
```css
.tool-toggle-all { padding:2px 10px; background:var(--bg-layer-02); border:0.5px solid var(--border-base); border-radius:var(--radius-sm); color:var(--text-muted); font-size:var(--text-xs); cursor:pointer; margin-bottom:4px }
.tool-toggle-all:hover { color:var(--text-strong); border-color:var(--border-focus) }
```

### 8. handler.zig: POST /api/session 支持 model 参数

**修改**: `handler.zig` `handleSessionCreate` (line 269-274)

- 当前硬编码 `ctx.config.default_model`
- 改为读取 POST body JSON，解析可选 `model` 字段
- `model` 存在 → 使用；缺失 → 回退 `config.default_model`
- 前端 `new-session-btn` 发送 `{"model": selectedModel}`

### 9. 新会话用 prompt 首句命名 + 修复 UUID 显示

**修改**: `handler.zig` `handlePrompt` (line 348-363) + `src/util/uuid.zig`

**根因**: `s.rename(session_id)` 把 session 名称设为 UUID，`isNumericId` 无法识别 UUID 格式（含 `-` 和 hex 字母），导致侧边栏直接显示 `f47ac10b-...`

**修复**:
1. `src/util/uuid.zig` 新增 `pub fn isUuid(s: []const u8) bool` — 精确 v4 检测：
   - 长度 36，短横位置 8/13/18/23，其余 hex
   - 第 14 位 = `'4'`，第 19 位 = `'8'/'9'/'a'/'b'`
   - 零误判风险（"Café-Paris-2024-event" 不会命中）
2. `handlePrompt` 新建 session 时，从 prompt 截取前 30 字符作为名称
3. 删除 `s.rename(session_id)`，改为直接设置文件路径（保持 UUID 文件名供 API 路由）
4. `handler.zig` 中 `isNumericId` → `uuid_mod.isUuid`，两处 display_name 调用同步更新

```diff
  // uuid.zig 新增
+ pub fn isUuid(s: []const u8) bool {
+     if (s.len != 36) return false;
+     const dash_positions = [_]usize{8, 13, 18, 23};
+     for (dash_positions) |pos| if (s[pos] != '-') return false;
+     if (s[14] != '4') return false;
+     if (s[19] != '8' and s[19] != '9' and s[19] != 'a' and s[19] != 'b') return false;
+     for (s, 0..) |c, i| {
+         if (i == 8 or i == 13 or i == 18 or i == 23) continue;
+         if (!std.ascii.isHex(c)) return false;
+     }
+     return true;
+ }

   // handler.zig handlePrompt
- try s.rename(session_id);
+ const title_len = @min(prompt.len, 30);
+ s.name = try ctx.allocator.dupe(u8, prompt[0..title_len]);  // 生命周期: flush() 期间有效, req_arena.deinit() 释放
+ const filename = try std.fmt.allocPrint(ctx.allocator, "{s}.jsonl", .{session_id});
+ s.path = try std.fs.path.join(ctx.allocator, &.{ ctx.sessions_dir, filename });

  // handler.zig display_name (两处)
- const display_name = if (isNumericId(s.name)) "New Session" else s.name;
+ const display_name = if (uuid_mod.isUuid(s.name)) "New Session" else s.name;
```

### 10. favicon 支持

**修改**: `handler.zig`

- 嵌入 `@embedFile("../../Logo.ico")` 作为 `FAVICON` 常量
- 新增路由 `GET /favicon.ico` → `handleFavicon`
- 返回 `content-type: image/x-icon`，二进制 ICO 数据
- 无 HTML 改动 — 浏览器自动请求 `/favicon.ico`

## 影响范围

- `src/frontends/web/index.html` — 7 项 CSS/HTML/JS 优化
- **`src/frontends/web/handler.zig`** — 3 项变更：`handleSessionCreate` model 参数 + `handlePrompt` 首句命名 + `/favicon.ico` 路由
- **`src/util/uuid.zig`** — 新增 `isUuid()` 判定函数
- 已有 API `GET /api/model` 可用，无需新增路由
- 编译后 `@embedFile` 自动嵌入新 HTML

## 交互流程

```
页面加载:
  loadModels() → GET /api/model → 填充 #model-selector 下拉
  localStorage.getItem('zagent-model') → 恢复模型选择 → 设 <select> 值
  localStorage.getItem('zagent-sidebar-collapsed') → 恢复侧边栏状态
  loadSessions() → 侧边栏会话列表

用户切换模型:
  下拉 onchange → currentModel = selected value

用户新建 session:
  New Session 按钮 → POST /api/session {model: currentModel}
  → handler.zig 解析 model 字段 → 返回 session JSON
  → 自动选中新 session → 输入框激活

用户折叠侧边栏:
  点击 ☰ 按钮 → body toggle 'sidebar-collapsed'
  → sidebar transform: translateX(-100%) 移出视口
  → 再次点击 → 移除 class → translateX(0) 恢复
```

## 验证

- `zig build` 编译通过
- 浏览器打开 `--web`，验证 10 项功能：
  1. ☰ 折叠/展开侧边栏，刷新保持状态
  2. h1 居中，sidebar 底部模型选择器
  3. 切换模型 → 新建 session 使用所选模型，刷新保持
  4. 超长 session 名截断
  5. 用户消息右对齐 + 气泡自适应宽度
  6. 系统消息 markdown 渲染 + thin 滚动条
  7. 工具卡片默认折叠，展开后 markdown 渲染，≥3 工具时显示全部展开/折叠按钮
  8. handler 解析 POST model 参数
  9. 新会话用 prompt 首 30 字命名，侧边栏不显示 UUID
  10. favicon 显示为 Logo
