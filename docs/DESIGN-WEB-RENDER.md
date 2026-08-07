# Web 前端渲染结构设计

> **注意**：本文档描述的流式/消息渲染结构已被 parts 模型重构取代（v0.2.5，`docs/0.2.5/PLAN-STREAM-ORDER-PARTS.md`）——`index.html` 已拆分为 `app.css`/`app.js`，流式与 reload 统一为 segments 数据模型 + `renderAssistantMessage`。本文档保留作历史设计参考。

## 概述

z-agent-core Web 前端采用**实时交互 + 侧边栏会话管理**的单页布局。核心设计原则：

- **chronological 流式布局** — SSE 事件顺序到达，渲染结构保持时间线一致
- **声明式分层** — 每类内容有独立容器和视觉语言
- **localStorage 持久化** — 用户偏好（模型选择、侧边栏状态）跨会话保存
- **零外部图标依赖** — 所有图标使用 HTML entity（☰ ⚙ ▼）

**术语**:

| 术语 | 含义 |
|------|------|
| turn | 一轮用户→LLM 交互，含 1 条 user + N 条 assistant (+ tool) 消息 |
| 流式阶段 | SSE 持续接收 delta 事件期间 |
| done | SSE 最后一条事件，标记本轮交互完成 |
| 会话加载 | 浏览器刷新或切换 session 后重新获取 JSONL 数据渲染 |

## 整体布局

```
┌──────────────────────────────────────────────────┐
│  ☰ 当前会话名                                      │  ← #topbar
├──────────┬───────────────────────────────────────┤
│          │  ┌─ system prompt ──────────────────┐ │
│          │  │  (markdown, 折叠)                │ │
│  #sidebar│  └──────────────────────────────────┘ │
│          │                                       │
│  h1      │  ┌─ user msg ──────────────┐         │  ← 右对齐气泡
│  subtitle│  │  ...                     │         │
│          │  └──────────────────────────┘         │
│  ✚ New  │                                       │
│  Session│  ┌─ assistant msg ───────────────────┐ │
│          │  │  ... LLM 文本 (markdown) ...      │ │
│  session │  │  ┌ thinking ────────────────────┐ │ │
│   1      │  │  │ ▶ Thinking (3s)              │ │ │
│  session │  │  └──────────────────────────────┘ │ │  ← #messages
│   2      │  │  [Expand all]                    │ │ │
│  ...     │  │  ┌ tool-card: bash ─────────────┐ │ │
│          │  │  │ ▼ ⚙ bash                    │ │ │
│          │  │  │ ┌ output ──────────────────┐ │ │ │
│          │  │  │ │ (markdown)               │ │ │ │
│          │  │  │ └──────────────────────────┘ │ │ │
│ ──────── │  │  └──────────────────────────────┘ │ │
│ Model:   │  │  ─ usage: 1234↑ 567↓ 1801 total ─│ │
│ [select] │  │  (更多 LLM 文本)                   │ │
│          │  └───────────────────────────────────┘ │
├──────────┼───────────────────────────────────────┤
│          │  [___________________] [Send]          │  ← #input-bar
└──────────┴───────────────────────────────────────┘
```

## LLM 输出渲染结构

### renderMd() — Markdown 渲染函数

定义位置: `index.html` 脚本块内 (line ~379)

```javascript
function renderMd(content) {
  try {
    var raw = marked.parse(content || '');    // marked.js → HTML
    var clean = DOMPurify.sanitize(raw);       // XSS 净化
    return clean;
  } catch(e) { return esc(content || '').replace(/\n/g, '<br>'); }  // 降级: 纯文本 + <br>
}
```

| 阶段 | 处理链 | 降级行为 |
|------|--------|---------|
| 正常 | `marked.parse()` → `DOMPurify.sanitize()` | — |
| 异常 (marked/DOMPurify 崩溃) | `esc()` HTML 转义 + `\n→<br>` | 纯文本显示，不丢内容 |

调用点:
- `addMessage(role='assistant')` — done 后渲染完整 LLM 回复
- `addMessage(role='tool')` — 会话加载时渲染工具输出
- `renderSystemPrompt()` — 系统消息 markdown 渲染
- `done` 事件 — 工具卡片 `.output` 内容 markdown 渲染

注意: **流式阶段不使用** — content_delta 累积 `textContent`，done 后才换为 `renderMd()`。这是为了避免每次 delta 触发 markdown 重解析（性能 + 流式完整性）。

SSE 流式事件按顺序到达，每条消息（`msg.assistant`）内含多个子组件：

### 组件层次

```
div.msg.assistant
  ├── div (content)          ← content_delta 累积的 LLM 文本，done 后 markdown 渲染
  ├── div.thinking-block     ← thinking_start/delta/end
  │     ├── div.header       ← "▶ Thinking (3s)"
  │     └── div.content      ← 思考文本 (折叠，点击展开)
  ├── button.tool-toggle-all ← "Expand all / Collapse all" (≥2 个工具时显示)
  ├── div.tool-card          ← tool_start/delta/error
  │     ├── div.name-row     ← ▼ ⚙ tool-name spinner
  │     └── div.output       ← 工具输出 (done 后 markdown 渲染)
  ├── div.tool-card.error    ← tool_error
  │     ├── div.name-row     ← ▼ ⚙ tool-name
  │     └── div.output       ← 错误信息文本
  └── div.usage-footer       ← token 统计 + 模型名
```

### 流式阶段 vs done 阶段

| 阶段 | 文本内容 | 工具卡片 | 思考块 |
|------|---------|---------|--------|
| **流式** | `textContent` 追加 (即时可见) | `textContent` 追加 (open 状态，可见) | `textContent` 追加 (折叠，点击展开) |
| **done** | `innerHTML = renderMd()` (markdown) | `innerHTML = renderMd(output)` | 关闭 spinner，显示时长 |

### 会话加载渲染

加载已有会话时走 `addMessage()`。API 返回完整的消息结构（含 `reasoning_content`、`tool_calls`、`tool_call_id`、`usage`、`model`）。

| role | 渲染方式 | 结构 |
|------|---------|------|
| `user` | `textContent` (pre-wrap) | `div.msg.user` (右对齐气泡) |
| `assistant` | `renderMd(content)` | `div.msg.assistant` (markdown + code copy + hljs 高亮) |
| `tool` | `renderMd(content)` | `div.tool-card.open` (▼ ⚙ tool + markdown output，点击折叠) |
| `system` | `renderMd(content)` | `div.msg.system` (#system-prompt 容器) |

**已知 gap**: API 已返回 `reasoning_content`/`tool_calls` 字段 (P0)，但 `addMessage` 尚未消费 — assistant 消息的思考块和工具调用骨架未从 API 数据重建。见 G1/G2。

**`formatMessageJson`** (`handler.zig:527`) 当前序列化字段: `role`、`content`、`reasoning_content` (可选)、`tool_calls` (可选, `[{id,name,arguments}]`)、`tool_call_id` (可选)、`usage` (可选, `{input,output,total,cache_hit,cache_miss}`)、`model` (可选)。

## 交互设计

### 1. 侧边栏

| 交互 | 触发 | 效果 |
|------|------|------|
| 折叠/展开 | 点击 ☰ 按钮 | `body.toggle('sidebar-collapsed')` → `translateX(-100%)` 移出视口 |
| 宽度调节 | 拖拽 `#resize-handle` | `mousemove` 实时设置 `sidebar.style.width` (180-480px) |
| 持久化 | 折叠时写 `localStorage` | 刷新后恢复上次折叠状态 |

**宽度调节架构**: JS + CSS 互补

```
职责分离:
  JS (mousemove handler)     → 改变容器宽度 (style.width)
  CSS (@container 查询)      → 根据宽度自适应内部样式 (字号/显隐/间距)
```

JS 只做一件事：`sidebar.style.width = clamp(180, e.clientX, 480) + 'px'`。
CSS 对宽度变化自动响应，无需 JS 手动计算:

```css
#sidebar { container-type: inline-size; }

@container (max-width: 220px) {
  .session .meta { display: none; }          /* 窄屏隐藏元信息 */
  #model-selector select { font-size: 10px; }
}

@container (max-width: 190px) {
  #sidebar-header h1 { font-size: 12px; }
  .session .name { font-size: 10px; }
  #new-session-btn { font-size: 10px; padding: 6px; }
}
```

**已实现**: JS 拖拽 (index.html:181-195)
**待实现**: @container 自适应样式

**浏览器兼容性** (`container-type` / `@container`):

| 平台 | 最低版本 | 发行日期 |
|------|---------|---------|
| Chrome / Edge | 105 | 2022-08 |
| Firefox | 110 | 2023-02 |
| Safari | 16.0 | 2022-09 |
| Safari iOS | 16.0 | 2022-09 |

覆盖全球 **~94%** 用户 (caniuse 2025)。**可接受阈值: ≥90%** — 低于 90% 需加 polyfill 或 JS fallback。当前 94% 达标。不支持时优雅降级：sidebar 保持固定样式，核心拖拽功能不受影响。

### 2. 模型选择器

| 交互 | 触发 | 效果 |
|------|------|------|
| 加载模型列表 | 页面加载 | `GET /api/model` → 填充 `<select>` |
| API 失败降级 | `catch` | localStorage 缓存 → "Default" 回退 |
| 切换模型 | `<select>` onchange | 更新 `currentModel`，写 localStorage |
| 新建 session | "New Session" 按钮 | `POST /api/session {model: currentModel}` |
| 持久化 | onchange 时写 localStorage | 刷新后恢复上次选择 |

**设计理由**: 模型选择是"新建 session 的偏好"，与已有 session 的模型独立（每个 session 有自己的 model 字段）。

### 3. 思考块

| 交互 | 触发 | 效果 |
|------|------|------|
| 折叠/展开 | 点击 thinking-block | `classList.toggle('open')` |
| 初始状态 | 流式到达 | 默认折叠 (max-height:300px) |
| 时长显示 | thinking_end | "▶ Thinking (3s)" |

### 4. 工具卡片

| 交互 | 触发 | 效果 |
|------|------|------|
| 折叠/展开 | 点击 `.name-row` | `classList.toggle('open')` |
| 初始状态 | 流式到达 | **open** (可见)，done 后保持 open |
| 全部展开/折叠 | 点击 Expand all 按钮 | 遍历所有 tool-card 切换 `open` |
| 按钮文本切换 | 展开/折叠时 | "Expand all" ↔ "Collapse all" |
| 可见指示器 | ▼ 图标 | 展开: 0° / 折叠: -90° 旋转 |
| 错误工具 | tool_error 事件 | 红色边框 + 输出区显示错误信息 |

**设计理由**: 流式时默认展开 — 用户正在等工具执行结果，不应隐藏。done 后保持展开 — 避免"需要点开才看到"的困惑。Expand all 提供批量折叠。

**Expand all 出现条件**: 工具卡片 ≥2 个，且仅在流式 assistant 消息 (done 事件) 中创建。会话加载视图不创建 toggle-all — 加载视图的工具卡片各自独立，无统一控制点。

**点击行为**: 点击 name-row → toggle open；点击 `.output` 内部 → 不折叠（允许选中/复制输出内容）

### 5. 系统消息

| 交互 | 触发 | 效果 |
|------|------|------|
| 折叠/展开 | :hover | `max-height:60px` → `max-height:none` |
| 初始状态 | 加载时 | 默认折叠 (`max-height:60px`) |

### 6. 消息操作

| 交互 | 触发 | 效果 |
|------|------|------|
| 删除消息 | 点击 × 按钮 (hover 显) | confirm modal → `DELETE /api/session/:id/message/:index` → 重新加载会话 |
| 代码块复制 | 点击 Copy 按钮 (hover 显) | `navigator.clipboard.writeText()` → "Copied!" 1.5s |

### 7. 会话管理

| 交互 | 触发 | 效果 | 细节 |
|------|------|------|------|
| 新建会话 | 点击 "New Session" 按钮 | `POST /api/session {model: currentModel}` → 返回 id+name → 自动选中 | 按钮始终可用，不依赖已有 session |
| 会话改名 | **双击**会话名 | 原地出现 `<input>`，Enter 或 blur 提交 → `PATCH /api/session/:id {name}` | Esc 取消；空名不提交；成功后刷新 sidebar 列表 |
| 会话删除 | 点击 × 按钮 (hover 显) | confirm modal → `DELETE /api/session/:id` → 成功后：若为当前会话则清空消息区并禁用输入；刷新 sidebar | confirm modal 支持 Esc 关闭 + 点击遮罩关闭 |

### 8. 输入

| 交互 | 触发 | 效果 |
|------|------|------|
| 发送消息 | Enter (无 Shift/Ctrl) | 读取 textarea → `sendPrompt()` |
| 换行 | Shift+Enter / Ctrl+Enter | 不影响发送 |
| 自适应高度 | input 事件 | `this.style.height = min(this.scrollHeight, maxH) + 'px'` (maxH 由 CSS `max-height:min(6lh,25vh)` 确定) |
| 发送后重置 | sendPrompt 开头 | `inp.style.height = ''` 恢复单行 |

**尺寸分级**:

```
初始:     1 行 (40px)             ≈ 80 个字符可见
展开:     auto → scrollHeight     JS 动态调整
最大:     min(6em, 25vh)          ≈ 120px 或视口高度的 1/4
溢出:     超 max-height 后        overflow-y:auto 纵向滚动
```

**设计理由**: 
- `40px` 起始不占空间，类似聊天框习惯
- `scrollHeight` 自动扩展减少滚动操作
- `min(6em, 25vh)` 上限防止输入框过大挤压消息区；`em` 适配字号，`vh` 适配屏幕
- 发送后重置 `''` 恢复默认高度

**CSS 调整** (当前 → 建议):
```diff
- min-height:40px; max-height:200px
+ min-height:1lh; max-height:min(6lh, 25vh)
```
(使用 `lh` 单位 — line height，Chrome 109+/Firefox 110+/Safari 16.4+)

### 9. 滚动行为

| 场景 | 行为 | 实现 |
|------|------|------|
| 新消息到达 (流式) | 自动滚到底部 | `scrollToBottom(msgs)` — 距底 <50px 时滚底，否则不滚 |
| 用户手动上滚 | 不自动跳底 | **已实现**: `isNearBottom()` 检测 (P3-1) |
| 会话切换 | 滚到底部 | `loadSession()` 结尾隐式 (元素追加后浏览器自然定位) |
| 输入框聚焦 | 无滚动 | textarea 高度自适应，不触发 #messages 滚动 |

### 10. SSE 连接生命周期

| 事件 | 行为 |
|------|------|
| 新请求 | 关闭上一个 `evtSrc`（如果存在）→ 新建 `EventSource` |
| done 事件 | `evtSrc.close()` → `evtSrc = null` → 恢复 Send 按钮 |
| onerror | `evtSrc.close()` → 恢复 Send 按钮 → 移除 spinner |
| 副作用 | SSE 断开时 `send-btn` 和 `prompt-input` 恢复可用 |

## API 契约

所有 API 基路径: `/api`

### 会话管理

| 方法 | 路径 | 请求体 | 响应 | 说明 |
|------|------|--------|------|------|
| GET | `/api/session` | — | `[{id, name, model, msg_count, timestamp}]` | 会话列表，name 为 UUID 时替换为 "New Session" |
| POST | `/api/session` | `{model?}` | `{id, name:"New Session", model}` | 新建会话；model 可选，默认 `config.default_model` |
| GET | `/api/session/:id` | — | `{name, model, messages:[{role,content,...}]}` | 完整会话数据 |
| PATCH | `/api/session/:id` | `{name}` | `{status:"renamed"}` | 重命名会话；name 为空时忽略 |
| DELETE | `/api/session/:id` | — | `{status:"deleted"}` | 删除会话 JSONL 文件 |

### 消息

| 方法 | 路径 | 请求体 | 响应 | 说明 |
|------|------|--------|------|------|
| DELETE | `/api/session/:id/message/:index` | — | `{status:"deleted"}` | 删除指定索引消息，原子重写 JSONL |
| POST | `/api/session/:id/prompt?prompt=...` | — | SSE stream | 发送 prompt 并启动 SSE 流式响应 |

### 模型 & 状态

| 方法 | 路径 | 响应 | 说明 |
|------|------|------|------|
| GET | `/api/model` | `[{id, name, provider, context_window}]` | 所有可用模型 |
| GET | `/api/provider` | `[{name, api, base_url, models}]` | 所有 provider 配置 |
| GET | `/api/health` | `{status:"ok"}` | 健康检查 |
| POST | `/api/session/:id/abort` | `{status:"aborted"}` | 中断运行中的 LLM 请求 |

### 静态资源

| 路径 | 说明 |
|------|------|
| `/` | HTML 主页 (动态注入内联字体 + vendor JS) |
| `/favicon.ico` | Logo ICO 文件 (`@embedFile`) |

## 美术设计

### 色彩系统 (深色主题)

CSS 变量定义位置: `index.html` `<style>` 块 `:root{}` 伪类 (line 10-28)。所有组件色值引用变量，无硬编码色号。

```
--bg-deep:    #0c0c0f   最深层（sidebar 背景）
--bg-base:    #18181b   主背景
--bg-layer-01:#1f1f23   次级层
--bg-layer-02:#27272a   卡片层
--bg-layer-03:#2f2f33   输入框层
--text-strong:#fafafa   强调文本
--text-base:  #d4d4d8   正文
--text-muted: #a1a1aa   次级文本
--text-faint: #71717a   最淡文本
--accent-base:#60a5fa   主色 (链接/焦点/手风琴)
--accent-success:#22c55e  成功
--accent-warning:#eab308  警告
--accent-error:#ef4444    错误
--border-base:#2a2a2e   主边框
--border-muted:#1f1f23  淡边框
--border-focus:#60a5fa  聚焦边框
```

### 字体

| 用途 | 字体 |
|------|------|
| UI 界面 | Inter, system-ui, sans-serif |
| 代码 | JetBrainsMono, monospace |
| 字号体系 | 11px / 12px / 13px / 14px |

### 动画

| 元素 | 动画 | 时长 |
|------|------|------|
| 侧边栏折叠 | `transform` | 240ms cubic-bezier(0.22,1,0.36,1) |
| 工具折叠图标 | `rotate` | 120ms |
| hover 过渡 | `background/color/border-color` | 120ms |
| spinner | `rotate` | 0.8s linear infinite |

### 特殊效果

| 元素 | 效果 |
|------|------|
| 用户消息气泡 | 右对齐 + `width:fit-content` + `border-top-right-radius:0` |
| 代码块 | 深色背景 + hover 显示 Copy 按钮 |
| 工具错误卡片 | `border-color:var(--accent-error)` 红色边框 |
| thinking 块 | 深色背景 + `cursor:pointer` |
| spinner | 4px 圆环旋转，色彩分层（muted + accent） |
| 滚动条 (Firefox) | `scrollbar-width:thin; scrollbar-color:var(--text-faint) transparent` |
| 滚动条 (WebKit) | 6px 宽，圆角 3px |
| 可访问性 | `:focus-visible` 蓝色 outline 2px |
| 减少运动 | `prefers-reduced-motion:reduce` 禁用所有动画 |

### name-row 视觉构成

```
  ▼  ⚙  bash  ⟳
  │  │   │    │
  │  │   │    └─ spinner (流式阶段)
  │  │   └────── 工具名 (e.g. "bash", "read")
  │  └────────── 工具标签 (⚙ 齿轮)
  └───────────── 折叠指示器 (▼ 展开 / ▶ 折叠)
```

专用 CSS token 色：
- `.tool-label`: `var(--text-faint)` (淡灰)
- `.toggle-icon`: `var(--text-faint)` (淡灰), `transform` 旋转
- `.name`: `var(--accent-base)` (蓝色，仅 tool-start 流式阶段；error 时为 `var(--accent-error)` 红色)

## 开发路线

### 已实现

| 功能 | 文件 | 状态 |
|------|------|------|
| 侧边栏折叠 (`translateX`) + localStorage | index.html | ✅ |
| 模型下拉选择器 + localStorage + 降级 | index.html | ✅ |
| 会话名 ellipsis 截断 | index.html | ✅ |
| 用户消息 fit-content 气泡 | index.html | ✅ |
| 系统消息 markdown + thin 滚动条 | index.html | ✅ |
| 工具卡片折叠 + markdown + ▼ 指示器 + Expand all | index.html | ✅ |
| tool_error SSE 含 name 字段 | sse.zig | ✅ |
| tool_output >8KB 分块发送 (防 abort) | sse.zig | ✅ |
| POST /api/session 支持 model 参数 | handler.zig | ✅ |
| handlePrompt 首句命名 + UUID 检测 | handler.zig + uuid.zig | ✅ |
| /favicon.ico 路由 | handler.zig | ✅ |
| `formatMessageJson` 补全 thinking/tool_calls/usage/model 字段 | handler.zig | ✅ (P0, 消灭 reload 后 thinking+tool 数据丢失) |
| `highlight.js` 语法高亮激活 | index.html | ✅ (P0, done 事件 + addMessage 均调用 hljs.highlightAll) |
| `renderTool` SSE 输出前置工具参数代码块 | sse.zig | ✅ (P0, tool_args 非空/非 {} 时以 ```input 显示) |
| `addMessage` 重建 thinking + 工具名匹配 | index.html | ✅ (P2-1) |
| ToolRegistry + bash Copy cmd 按钮 | index.html | ✅ (P2-2) |
| SSE `tool_meta` 事件 + `serializeMeta` | sse.zig | ✅ (P2-3, ToolMeta 结构化发送: exit_code/byte_count/match_count等) |
| 滚动中断检测 `isNearBottom` + `scrollToBottom` | index.html | ✅ (P3-1, 距底 <50px 才自动滚底) |
| 日志本地时间 (Windows GetLocalTime) | util/log.zig | ✅ |
| --port / --address CLI 参数 + LAN IP 解析 | server.zig + cli/main.zig | ✅ |
| CSS 浅色主题 (☀/☾ 按钮 + localStorage) | index.html | ✅ (P4 G13) |
| markdown 块容器 (`data-markdown-key` + hash + 增量更新) | index.html | ✅ (P4 G4 Step 1) |
| renderMd LRU 缓存 200 条 | index.html | ✅ (P4 G14) |

### 待实现

| 优先级 | 功能 | 涉及文件 | 说明 |
|--------|------|---------|------|
| **高** | **@container 响应式** | index.html | `#sidebar{container-type:inline-size}`；窄屏自动隐藏 `.meta`、缩放字号（见 §1） |
| **低** | **输入框响应式高度** | index.html | 改用 `lh` + `vh` 单位：`min-height:1lh; max-height:min(6lh,25vh)` |
| **低** | **输入历史** (上下箭头) | index.html | `inputHistory[]` 栈，ArrowUp 回溯已发送 prompt |
| **低** | **导出对话** | handler.zig | `GET /api/session/:id/export` → JSONL 下载 |
| **低** | **多会话标签页** | index.html | 同时打开多个 session，标签页切换 |
| **低** | **消息编辑** | index.html + handler.zig | 双击 user/assistant 消息 → inline 编辑 → `PATCH /api/session/:id/message/:index` |

已完成移除项: G7 滚动中断(P3-1)、G13 主题系统(P4)、ToolMeta 透传(P2-3)、工具名加载(P2-1)。
                                                                                (本页工具卡片加载工具名伪代码已在 P2-1 实现，不再重复)

## 设计差距分析（对照 opencode 评审）

> 来源: `docs/web-render-design-review-guide.md` §3
> 状态: 已识别·待设计 → 将在后续版本 DESIGN-WEB-RENDER.md 修订时细化

| 差距 | 严重度 | 现状 | 方向 |
|------|--------|------|------|
| **G1/G2** Part 化数据模型 | 高 | 扁平 `{role,content}`，reload 后 thinking/tool_calls 前端未恢复 | 两阶段: 近期用 `tool_call_id` 前端关联重建 (纯前端); 长期考虑 Part 事件流 (后端+前端) |
| **G4** markdown 全量 innerHTML | 高 | done 时整体替换，滚动/选区丢失 | 块级增量：`data-markdown-key` + hash 对比，按块更新 |

**G4 迁移路径** (从当前 `innerHTML = renderMd()` → 块级增量):

```
当前: contentDiv.innerHTML = renderMd(rawContent)   // 全量替换

Step 1 — 块容器:
  contentDiv.innerHTML = renderMdBlocks(rawContent)  // 返回每块带 data-markdown-key
  renderMdBlocks() 把 marked.lexer 的 token 按 block 分组:
    <div data-markdown-key="b0" data-markdown-hash="a1b2c3"><p>段落1</p></div>
    <div data-markdown-key="b1" data-markdown-hash="d4e5f6"><pre><code>...</code></pre></div>

Step 2 — 增量更新:
  function updateMarkdown(container, newBlocks) {
    var existing = container.querySelectorAll('[data-markdown-key]');
    newBlocks.forEach(function(block) {
      var el = container.querySelector('[data-markdown-key="' + block.key + '"]');
      if (el && el.dataset.markdownHash === block.hash) return;  // 跳过不变块
      if (el) { el.outerHTML = block.html; }                     // 替换变块
      else { container.appendChild(createBlockEl(block)); }       // 追加新块
    });
  }

Step 3 — 流式应用:
  done 事件: noopBlocks + liveBlocks = marked.lexer(rawContent)
  const blocks = stableProjection(noopBlocks, liveBlocks)
  updateMarkdown(container, blocks)
  只重建末尾 live block，已完成块保持不动
```

关键收益: Stream 阶段不再闪烁重建已完成的段落/代码块；`hljs.highlightElement()` 只对新增代码块调用。需引入轻量 `marked.lexer` (已随 marked.js 内置)。
| **G5** 语法高亮缺失 | 中高 | `highlight.min.js` 注入但从未调用 (已修复 P0) | — |
| **G3** `formatMessageJson` 字段缺失 | 高 | 只序列化 role+content (已修复 P0) | — |
| **G6** `tool_args`/`ToolMeta` 丢弃 | 中高 | `_ = tool_args; _ = meta;` (P0 已传 `tool_args`) | `ToolMeta` 结构化发送: exit code / line count / file count |
| **G7** 滚动中断检测 | 中 | ✅ P3-1 已实现: `isNearBottom()` 距底 50px, `scrollToBottom()` 条件滚底 | — |
| **G8** 工具视图未类型化 | 中 | 所有工具共用一个 `.tool-card` | ToolRegistry 模型: bash→代码块, edit→diff, read→文件内容 |
| **G9** 上下文工具不分组 | 中 | read/grep/glob 各自独立卡片 | 连续上下文工具合并为折叠组 "Gathering context" |

**G8 类型化工具视图** (前端设计):

```
ToolRegistry = {
  bash:     BashToolCard,    // pre/code + "Copy command" 按钮 + stripAnsi
  read:     ReadToolCard,    // 文件路径 + 行数 + offset/limit 标注
  write:    WriteToolCard,   // 文件路径 + 写入字节数 + "Open file" 链接
  edit:     EditToolCard,    // oldString→newString diff 预览
  grep:     GrepToolCard,    // 模式 + 匹配数 + 文件列表
  glob:     GlobToolCard,    // 模式 + 匹配数 + 文件列表
  skill:    SkillToolCard,   // skill 名 + 加载状态
  default:  ToolCard         // 当前通用卡片 (兜底)
}
```

卡片结构 (bash 示例):
```html
<div class="tool-card tool-bash open">
  <div class="name-row">
    <span class="toggle-icon">▼</span>
    <span class="tool-label">⌨</span>          <!-- 每工具专属图标 -->
    <span class="name">bash</span>
    <button class="copy-cmd">Copy cmd</button>  <!-- 复制命令原文 -->
    <span class="spinner"></span>
  </div>
  <div class="tool-meta">exit: 0 | 1.2s</div>   <!-- ToolMeta: exit code, duration -->
  <div class="output"><pre><code>...</code></pre></div>
</div>
```

数据源: `sse.zig renderTool` 发送的 `ToolMeta` (types.zig:56-103) 含: `bash.exit_code`, `read.file_path/bytes/lines`, `edit.file_path`, `grep.matches/file_count`, `write.file_path/bytes_written`。

**G9 上下文工具分组** (前端设计):

```
连续 2+ 个 read/grep/glob → 合并为:
  ┌─ Gathering context ────────────────────────┐
  │  read: 2 files  ·  grep: 3 matches  ·  glob: 5 files  │
  │  ┌ read: docs/foo.md ──┐                   │
  │  │ (markdown)          │                   │
  │  └─────────────────────┘                   │
  │  ┌ grep: "function" ──┐                    │
  │  │ 3 matches in 2 files│                   │
  │  └─────────────────────┘                   │
  └────────────────────────────────────────────┘
```

实现: `loadSession()` / `sendPrompt()` 中检测连续 tool 消息 → 包装为 `.context-tool-group` 容器，内部工具卡片保持各自类型化视图。分组条件: 连续 ≥2 个且均为 read/grep/glob 之一。
| **G10** thinking 无 markdown/占位 | 低中 | 纯文本 textContent | thinking 内容 markdown 化 + TextShimmer 占位 "Thinking…" |
| **G11** 消息操作仅删/复制 | 低 | 无 revert/meta | 每条消息显示 agent·model·时长·中断标记 |
| **G12** 无 compaction 分隔/diff 汇总 | 低 | 压缩无 UI 表示 | MessageDivider 分隔线 + turn 文件 diff 汇总 |
| **G13** 主题系统 | 低 | 文档已列高优待实现 (P4 长期) | light-dark() 双主题 token |
| **G14** 虚拟化/缓存 | 低 | 无 | 超大工具输出延迟挂载 + markdown LRU 200条 |

### 迁移路线

| 阶段 | 事项 | 对应差距 |
|------|------|---------|
| **P0 已完成** | `formatMessageJson` 补全字段；`hljs.highlightAll()` 激活；`tool_args` 透传 | G3, G5, G6 |
| **P1 当前** | 本设计文档完善 + 审查对齐 | — |
| **P2 近期** | Part 化数据模型 · 前端 rolling 恢复 (reload 后重建 thinking + tool_calls 骨架) | G1, G2 |
| **P2 已完成** | 工具卡片类型化 (ToolRegistry 7种) · 上下文工具分组折叠 · ToolMeta 结构化发送 | G8, G9, G6 |
| **P3 中期** | 滚动中断检测 (三路检测+阈值) · thinking markdown 化 · 消息 meta (agent/model/时长) | G7, G10, G11 |
| **P4 长期** | markdown 块级增量 (替代整体 innerHTML) · compaction 分隔 · diff 汇总 | G4, G12 |
| **P4 已完成** | 主题系统 (☀/☾) · 虚拟化/markdown LRU | G13, G14 |

### 参考文件索引 (opencode 侧)

| 文件 | 作用 | 对应差距 |
|------|------|---------|
| `packages/session-ui/src/context/data.tsx` | 归一化 store: session/message/part | G1/G2 |
| `packages/session-ui/src/components/message-part.tsx` | PART_MAPPING + ToolRegistry + PacedMarkdown + ContextToolGroup | G1/G4/G8/G9/G10/G11 |
| `packages/session-ui/src/components/session-turn.tsx` | turn 分组 + compaction/interrupted divider | G2/G10/G12 |
| `packages/session-ui/src/components/markdown.tsx` | 分块 markdown + morphdom 增量 | G4/G5 |
| `packages/session-ui/src/components/markdown-stream.ts` | 流式文本投影 (full/live/code blocks) | G4 |
| `packages/session-ui/src/components/basic-tool.tsx` | 通用工具折叠卡: title/subtitle/args + defer 延迟挂载 | G6/G8/G14 |
| `packages/session-ui/src/components/tool-error-card.tsx` | 错误结构化 (subtitle/body) + 复制 | G8 |
| `packages/ui/src/hooks/create-auto-scroll.tsx` | 滚动中断检测完整实现 (wheel+scroll+selection) | G7 |
| `packages/app/src/pages/session/timeline/message-timeline.tsx` | 虚拟化 timeline (行 reconciliation) | G14 |
