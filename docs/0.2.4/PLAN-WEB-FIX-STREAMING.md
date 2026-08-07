# Plan WEB-FIX-STREAMING: SSE 流式 + 前端渲染修复

## 状态: 已完成

## 问题

| # | 现象 | 根因 |
|---|------|------|
| 1 | SSE 流式无输出 — spinner 一直转，无 thinking/content/tool 事件 | `SseWriter` 包装 `Io.Writer.Interface` 无 `flush`，SSE 帧被 4KB `send_buf` 缓冲不发 |
| 2 | 发送 prompt 后侧边栏不刷新 | 现象 1 导致浏览器未收到 `done` 事件 → `loadSessions()` 未调用 |
| 3 | 系统消息不显示（发送 prompt 后、或新会话打开后） | SSE 流不推送系统消息（`updateFirstSystem` 不经过回调），`done` 只调 `loadSessions()` 不调 `loadSession()` |

**现象 1 与 2 共享根因**，一次修复。**现象 3 独立根因**，同文档分步修。

## 概览

- **改动文件**：3 个（`sse.zig`、`handler.zig`、`index.html`）
- **改动性质**：修改
- **方案思路**：
  1. `SseWriter` 新增 flush 通道 → 每次 SSE 帧后立即刷 TCP
  2. `done` 帧携带 `first_message` 完整对象 → 前端声明式渲染

## 设计要点

### Fix A: SseWriter 新增 flush 通道

当前 `sseWriterFrom(&writer.interface)` 包装 `Io.Writer.Interface`，只有 `writeAll` 无 `flush`。改为包装 `Io.Writer`（有 `flush`），每次 SSE 帧写入后立即刷。

```zig
// sse.zig — SseWriter 新增字段
pub const SseWriter = struct {
    ctx: *anyopaque,
    writeAllFn: *const fn (*anyopaque, []const u8) anyerror!void,
    printFn: *const fn (*anyopaque, []const u8) anyerror!void,
    flushFn: *const fn (*anyopaque) anyerror!void,

    pub fn flush(self: SseWriter) !void {
        return self.flushFn(self.ctx);
    }
};

// sseWriterFrom — Child 变为 Io.Writer，新增 flush 闭包
.flushFn = struct {
    fn flush(p: *anyopaque) anyerror!void {
        const w: *Child = @ptrCast(@alignCast(p));
        try w.flush();
    }
}.flush,

// writeFrame / writeTextDelta — 每次写后
try self.w.writeAll(msg);
try self.w.flush();
```

```zig
// server.zig — `writer.interface` 即是 `Io.Writer`，有 flush，无需改动
var sse_w = sse.sseWriterFrom(&writer.interface);
```

### Fix B: 首条消息声明式渲染

`#messages` 顶部新增固定的 `#system-prompt` 容器（CSS sticky/独立定位），不在消息列表中混排。

新增 `renderSystemPrompt(content)` 函数作为唯一入口——接受文本内容，填充 `#system-prompt` 并显示。空内容则隐藏容器。

`loadSession()` 和 `done` 事件均调用此函数，渲染逻辑只有一处。

```html
<!-- index.html body -->
<div id="main">
  <div id="topbar">...</div>
  <div id="messages">
    <div id="system-prompt" style="display:none"></div>
    <!-- 消息流在下面 -->
  </div>
  ...
```

```js
function renderSystemPrompt(content) {
  var el = document.getElementById('system-prompt');
  if (!content) { el.style.display = 'none'; return; }
  el.className = 'msg system';
  el.textContent = content;
  el.style.display = '';
}
```

**`loadSession` 中调用**（已有循环加载消息的逻辑）：首条消息不加入 `addMessage` 循环，而是调用 `renderSystemPrompt`。`addMessage` 循环从 index 1 开始。

**`done` 事件中调用**：取 `d.first_message.content` 传给 `renderSystemPrompt`。

**CSS**：

```css
#system-prompt { border-bottom: 1px solid var(--border-muted); margin-bottom: 8px; }
.msg.system { background: var(--bg-layer-01); font-size: var(--text-xs); color: var(--text-muted); max-height: 60px; overflow-y: auto; cursor: pointer; padding: 8px 16px }
.msg.system:hover { max-height: none }
.msg.system::before { content: 'System prompt'; display: block; font-weight: 600; margin-bottom: 4px; color: var(--text-faint) }
```

## 实施

### 步骤 1: sse.zig — SseWriter 新增 flush 通道

**文件**: `src/frontends/web/sse.zig`

`SseWriter` +1 字段 +1 方法；`sseWriterFrom` 新增 flush 闭包生成；`writeFrame`/`writeTextDelta` 每次写后 `self.w.flush()`。

### 步骤 2: handler.zig — done 事件新增 first_message 字段

**文件**: `src/frontends/web/handler.zig`

`buildDonePayload` 新增 `allocator` 参数；取 `msgs[0]` 调用 `formatMessageJson` → 嵌入 done 帧。

### 步骤 3: index.html HTML + CSS — `#system-prompt` 容器

**文件**: `src/frontends/web/index.html`

`#messages` 顶部新增 `<div id="system-prompt">` 固定容器 + CSS 规则。

### 步骤 4: index.html JS — `renderSystemPrompt` 函数 + 两处调用

**文件**: `src/frontends/web/index.html`

新增 `renderSystemPrompt(content)` 函数；`loadSession` 首条消息走此函数，`addMessage` 循环从 index 1 起；`done` 事件从 `d.first_message.content` 调用。

## 验证

```powershell
zig build
zig test src/test.zig --cache-dir .zig-cache 2>&1 | Select-String "sse:"
```

| 测试场景 | 预期 |
|----------|------|
| `zig test` sse 模块 | writeFrame/beginPhase 测试通过 |
| 浏览器发送 prompt | 实时看到 thinking_delta → content_delta → tool_delta 事件流 |
| `done` 事件 | Markdown 渲染 + 用量页脚 + 侧边栏刷新 + 系统消息出现在 `#system-prompt` |
| 新会话打开（空白对话） | `#system-prompt` 显示系统提示（loadSession 填充） |
| 连续发送两条 prompt | `renderSystemPrompt` 只接收 content，不重复 DOM 节点 |
| 刷新页面点侧边栏 | 消息完整渲染，`#system-prompt` 正确填充 |

### 实施中发现的额外问题：writeFrame 缓冲溢出

`sse.zig` `writeFrame` 栈缓冲仅 `[512]u8`。含 `first_message` 的 done 帧 JSON 2000+ 字节，格式化后超过 `bufPrint` 限制 → `NoSpaceLeft` → 500 覆盖 SSE 流。修复：缓冲加大到 `[4096]u8`。

## 波及

| 文件 | 改动 | 破坏性 |
|------|------|--------|
| `src/frontends/web/sse.zig` | SseWriter +1 字段 +1 方法；sseWriterFrom +1 闭包；writeFrame/writeTextDelta +1 行 flush | 否 |
| `src/frontends/web/handler.zig` | buildDonePayload 新增 allocator 参数 + first_message 字段（复用 formatMessageJson） | 否 |
| `src/frontends/web/index.html` | HTML +1 容器；CSS +1 规则；JS `renderSystemPrompt` + `loadSession`/`done` 两处调用 | 否 |

## 后续



| 待办 | 状态 |
|------|------|
| JSON 模块抽取 — 统一 `jsonEscapeBuf`/`escapeJsonDynamic`/手写拼 JSON 为单一 API | 未排期 |
| `formatMessageJson` 补充 `tool_calls`/`reasoning_content` 字段 — 空 tool_calls 消息当前不显示 | 未排期 |
| `escapeJsonDynamic` 补充完整控制字符转义（NUL、ESC 等） | 未排期 |
