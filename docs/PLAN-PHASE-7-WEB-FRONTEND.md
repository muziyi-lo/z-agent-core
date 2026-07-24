# Plan PHASE-7: Web 前端 (HTTP Server + Browser)

## 状态: 实施中 (SSE 流式端点已实现，Web UI 交互待完善)

## 前置依赖

| 阻塞者 | 状态 | 被阻塞 |
|--------|------|--------|
| 无 | — | — |

## 参考实现

| 报告 | 关键价值 |
|------|---------|
| `docs/zig-http-server-research.md` | Zig 0.16 从零构建 HTTP 服务器的 9 步渐进实现，最小 27 行可用。直接提供 TCP 监听 + 路由 + 并发代码 |
| `docs/opencode-web-impl-research.md` | SSE 事件流模型 (GET /api/event)、路由分组模式、OAuth 回调模式 |
| `docs/pi-vs-opencode-web-research.md` | pi-repos HTML 会话导出作为轻量替代方案（Phase 7B 降级路径） |

## 前置验证

### Zig 0.16 网络 API（已通过三份报告验证）

`zig-http-server-research.md` 提供了完整可运行代码，API 链路已验证：

```zig
// 最小 HTTP 服务器 (27 行, ep1/01-main.zig)
const addr = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", 8090);
var tcp_server = try addr.listen(io, .{ .reuse_address = true });
var recv_buffer: [4096]u8 = undefined;
var send_buffer: [1024]u8 = undefined;

while (true) {
    const stream = try tcp_server.accept(io);
    defer stream.close(io);
    var reader = stream.reader(io, &recv_buffer);
    var writer = stream.writer(io, &send_buffer);
    var server = std.http.Server.init(&reader.interface, &writer.interface);
    var request = server.receiveHead() catch continue;
    request.respond("hello", .{ .keep_alive = false }) catch continue;
}
```

之前的 `Io.netListenIp`/`Io.netAccept` API 猜测不准确。正确路径：`IpAddress.resolve()` → `.listen()` → `tcp_server.accept()` → `stream.reader()/writer()` → `http.Server.init()`。

### 路由 + 并发（可直接引用）

```zig
// ep3/01-route.zig — 线性路由表
pub const Route = struct {
    method: std.http.Method,
    path: []const u8,
    callback: *const fn (*Context) anyerror!void,
};

// ep2/03-group.zig — 并发连接
std.Io.Group.concurrent(io, handle_connection, .{io, stream});

// ep2/05-semaphore.zig — 背压
std.Io.Semaphore{ .permits = 100 };
```

### 为什么不是 PHASE-5 (webfetch)

webfetch 是工具（LLM 调用的能力），Web 前端是界面（用户交互的入口）。两者独立。Web 前端先行可以让后续工具测试体验更好。

## 不做

- 不修改 core/ 代码（回调合约不变）
- 不支持多用户并发（单用户 dev tool）
- 不实现 WebSocket（SSE 够用）
- 不替换 CLI 前端（两者并存，通过 `--web` 参数切换）

### 延后 (Phase 7.1/7.2)

| 项目 | 延后理由 |
|------|---------|
| Tab 多 session 切换 | 侧边栏点击切换够 v1。Tab 系统需 ~200 行 JS |
| 消息列表虚拟化 | 单 session <200 条无性能问题 |
| 侧面板（文件树/review） | 依赖 fs API，链路长 |
| 富文本输入 + @mention | contenteditable 跨浏览器兼容成本高 |
| 快捷键体系 | 20+ 快捷键是优化非阻塞 |
| CORS 头 | 127.0.0.1 同源无需；外部工具连接是 P3 需求 |
| SSE 断线重连 | 单页应用，刷新即重连 |
| 权限审批（交互式） | 须跨纤程双向通信，Group.concurrent 无内置 channel。v1 默认自动批准 |
| 提问/回答 API | 同权限审批——需跨纤程通信 |

### 明确排除

| 项目 | 理由 |
|------|------|
| 终端面板 | CLI 二进制就是终端，Web 里嵌终端是俄罗斯套娃 |
| 深色/浅色双主题 | 仅深色。编码工具 90%+ 用深色 |
| 动效系统 | v1 不需要，CSS transition 2 行足矣 |
| 提问/回答 API | zAgentCore 当前无对应 agent 层机制 |
| 文件浏览 API | 工具本身就是读文件，无需重复 |
| 国际化 | 单语言 |

## 问题

**现象**：当前仅有 CLI 前端（终端 ANSI 渲染）。长输出、多文件编辑、对话回溯在终端中体验受限。

**根因**：无 HTML 渲染层。Markdown→ANSI 只能做有限的视觉区分，无法展示富文本、代码高亮、工具执行面板。

## 概览

- **改动范围**：3 个新文件 + 1 行 `main.zig` 路由 + `build.zig` 不变
- **核心思路**：`std.http.Server` + `@embedFile` + 三个回调合约 = 单二进制 Web UI
- **降级路径**：Phase 7B — pi-repos 的 HTML 会话导出（自包含 `.html` + marked.js + highlight.js），无需 TCP 服务器，生成静态文件即可在浏览器中浏览

```
浏览器 (index.html)                Zig binary (frontends/web/server.zig)
──────────────────────             ─────────────────────────────────────
GET  /                    →       serve @embedFile("index.html")
POST /api/session/:id/prompt →    SS E流响应: agent.runTurn() → PhaseWriterCb 直写 response body
```

## 设计要点

### 0. 项目根目录

Web 服务端不与终端 CWD 绑定。三种设置方式，优先级从高到低：

| 优先级 | 方式 | 示例 |
|--------|------|------|
| 1 | CLI 参数 | `zig build run -- --web --root C:\my-project` |
| 2 | 环境变量 | `ZAGENT_ROOT=C:\my-project` |
| 3 | CWD 向上查找 | 从进程 CWD 向上查找 `.zagent/` 目录（与 CLI 一致） |

```zig
// src/frontends/web/server.zig
const project_root = if (root_arg) |r| r
    else if (init.environ_map.get("ZAGENT_ROOT")) |r| r
    else config_mod.findZagentRoot(allocator, io) orelse blk: {
        break :blk try std.Io.Dir.cwd().realPathAlloc(allocator, io);
    };
```

启动时在终端打印确认信息：
```
z-agent-core web server
  → http://localhost:8090
  → Project root: C:\my-project
  → Sessions: 3 found
```

**不支持运行时切换 project root。** 切换项目需要重启服务并传入新的 `--root`。这是单用户 dev tool 的合理简化——如果需要多项目，开多个终端窗口各启动一个实例。

### 1. TCP 服务端：并发连接 (Group.concurrent)

阻塞 `accept` 循环有致命缺陷——`agent.runTurn()` 阻塞 10-60s 期间，浏览器无法加载 favicon、SSE EventSource 无法重连、`/api/health` 无法响应。必须使用并发模型。

基于 `zig-http-server-research` ep2-03 + ep2-05：

```zig
const addr = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", 8090);
var tcp_server = try addr.listen(io, .{ .reuse_address = true });

var group: std.Io.Group = .{};
var semaphore: std.Io.Semaphore = .{ .permits = 100 };  // 最大并发连接

while (true) {
    const stream = try tcp_server.accept(io);
    try semaphore.acquire(io);
    try group.concurrent(io, handleConnection, .{ io, stream, &semaphore });
}
```

每个连接在独立纤程（fiber）中处理：

```
Fiber 1: handleConnection(favicon.ico)      → 返回 404          → 释放
Fiber 2: handleConnection(GET /)            → serve index.html  → 释放
Fiber 3: handleConnection(GET /api/session) → JSON 响应         → 释放
Fiber 4: handleConnection(POST /api/session/:id/prompt)
    ↓ agent.runTurn() [阻塞 30s]
    ↓ PhaseWriterCb → SSE write 直接写入 response body
    ↓ 持续推送 thinking/content/tool 事件
    ↓ agent 返回 → SSE done → 关闭连接
Fiber 5: handleConnection(GET /favicon.ico) → 返回 404（Fiber 4 阻塞期间正常响应）
```

- `agent.runTurn()` 只阻塞 Fiber 4，Fiber 5 不受影响
- SSE 流式推送在 Fiber 4 中同步完成——`PhaseWriterCb` 直接写 response body
- `Semaphore(100)` 防止连接数爆炸

### 2. 前端：单 HTML 文件

**布局：侧边栏 + 对话流**

```
┌─ Sessions ────────────┬──────────────────────────────────────┐
│ z-agent-core           │ 🤖 Assistant               14:32:01  │  ← 顶栏
│ DeepSeek V4 Pro        │                                      │
├────────────────────────┤ ▶ Thinking (14s)                     │
│ + New Session          │ ┌──────────────────────────────┐    │
│ ─────────────────      │ │ 用户想要一个 HTTP 服务器。    │    │
│ ● http-server    🔵    │ │ 需要先了解现有的网络 API...   │    │
│   12 messages          │ │ Zig 0.16 的 std.http.Server  │    │
│                        │ │ 需要 reader/writer 参数...   │    │
│ ○ fix-build-error      │ └──────────────────────────────┘    │
│   45 messages          │                                      │
│                        │ 我来帮你实现。首先让我看看            │
│ ○ learn-zig            │ 现有的网络代码...                     │
│   8 messages           │                                      │
│                        │ ▶ Tool: read                  0.3s   │
│                        │   src/io/provider.zig                │
│                        │   1-50 / 1264 lines                  │
│                        │                                      │
│                        │ ▶ Tool: bash                  2.1s   │
│                        │   zig build                          │
│                        │   ✓ Build OK                         │
│                        │                                      │
│                        │ 现在创建 server.zig...               │
│                        │                                      │
├────────────────────────┴────────────────────────────────────┤
│ > 输入...                                            [Send]   │
└──────────────────────────────────────────────────────────────┘
```

| 区域 | 内容 | 说明 |
|------|------|------|
| 顶栏 | 版本号、模型名、当前 session 名 | 固定不滚动 |
| 侧边栏 (240px) | Session 列表 + 新建按钮 | 固定左侧，可折叠 |
| 对话区 | 时间线：用户消息 + 助手回复（含内联思考折叠 + 工具卡片） | 可滚动 |
| 输入栏 | textarea + Send 按钮 | 固定底部 |

**Session 管理 — CLI 命令到 UI 的一对一映射：**

| CLI 命令 | UI 操作 |
|----------|--------|
| `/list` | 侧边栏列表（自动显示） |
| `/load <id>` | 点击 session 名称切换 |
| `/new` | "+ New Session" 按钮 |
| `/fork <name>` | 活跃 session 右键 → Fork |
| `/name <name>` | 双击 session 名重命名 |

侧边栏条目：活跃 session 高亮 (●)、显示消息数、模型名。Fork 出的 session 自动刷新列表。

### 3. 对话组件

#### 3A. 思考内联折叠

```
▶ Thinking (14s)                    ← 折叠态：右箭头 + 耗时

▼ Thinking (14s)                    ← 展开态：下箭头
┌──────────────────────────────┐
│ 用户想要一个 HTTP 服务器。    │    ← plain text, dim color
│ 需要先了解现有的网络 API...   │
│ Zig 0.16 的 std.http.Server  │
│ 需要 reader/writer 参数...   │
└──────────────────────────────┘
```

思考内容流式追加——SSE 推送时实时展开并逐字显示，完成后自动折叠并显示耗时。用户可随时点击展开回顾。

#### 3B. 助手消息（流式）

```
┌────────────────────────────────────┐
│ 🤖 Assistant             14:32    │
│                                    │
│ ▶ Thinking (14s)                   │  ← 思考折叠
│                                    │
│ 我来帮你实现。首先让我看看...       │  ← 流式 marked.js 渲染
│                                    │
│ ▶ Tool: read                0.3s   │  ← 工具卡片
│   src/io/provider.zig              │
│   1-50 / 1264 lines                │
│                                    │
│ ▶ Tool: bash                2.1s   │
│   zig build                        │
│   ✓ Build OK                       │
│                                    │
│ 现在创建文件...                    │
└────────────────────────────────────┘
```

#### 3C. 工具卡片（可折叠）

与之前设计一致——8 种工具各有图标、折叠态显示摘要、展开态显示内容。工具卡片内联在对话流中，按时间顺序排列。

### 4. 配色与设计 Token 系统

中性灰基调，30+ 语义 token，6 个分层：

```
// 背景分层
--bg-deep:          #0c0c0f     // titlebar
--bg-base:          #18181b     // 主背景
--bg-layer-01:      #1f1f23     // 消息卡片
--bg-layer-02:      #27272a     // hover/选中
--bg-layer-03:      #2f2f33     // 输入框

// 文字层级
--text-strong:      #fafafa     // 标题
--text-base:        #d4d4d8     // 正文
--text-muted:       #a1a1aa     // 次要/思考文本
--text-faint:       #71717a     // 占位/禁用

// 语义色
--accent-base:      #60a5fa     // 蓝色强调（按钮/链接/活跃标记）
--accent-success:   #22c55e     // 绿色成功（工具完成 ✓）
--accent-warning:   #eab308     // 黄色警告（思考指示器）
--accent-error:     #ef4444     // 红色错误

// 边框
--border-base:      #2a2a2e
--border-muted:     #1f1f23
--border-focus:     #60a5fa

// Elevation
--elevation-raised:   0 1px 3px rgba(0,0,0,0.3)
--elevation-floating: 0 4px 12px rgba(0,0,0,0.4)

// 圆角
--radius-sm:   4px
--radius-md:   6px
--radius-lg:   10px
--radius-xl:   16px

// 语法高亮 (marked.js + highlight.js)
--syntax-keyword:    #c792ea
--syntax-string:     #c3e88d
--syntax-function:   #82aaff
--syntax-number:     #f78c6c
--syntax-variable:   #eeffff
--syntax-comment:    #546e7a
--syntax-type:       #ffcb6b
--syntax-operator:   #89ddff
--syntax-punctuation:#89ddff

// Diff
--diff-added:        #1b3b1b
--diff-removed:      #3b1b1b
```

**字体 + JS 库：全量 `@embedFile` 内联**

Google Fonts 和 cdnjs 在国内不可靠。全部资源编译进二进制，真零外部依赖：

| 资源 | 来源 | 大小 | 嵌入方式 |
|------|------|------|---------|
| Inter Variable woff2 | github.com/rsms/inter v4.0 | ~338KB | `@embedFile` → base64 `@font-face` |
| JetBrainsMono Variable ttf | github.com/JetBrains/JetBrainsMono v2.304 | ~296KB | 同上 |
| marked.js | 构建时从 cdnjs 下载 | ~20KB | `@embedFile` → `<script>` 内联 |
| highlight.js | 构建时从 cdnjs 下载 | ~100KB | 同上 |
| DOMPurify | 构建时从 cdnjs 下载 | ~25KB | 同上（XSS 防护——LLM 响应渲染前净化） |

**vendor 目录**（文件入 git 追踪）：
```
src/frontends/web/vendor/
├── inter.woff2
├── jetbrains-mono.ttf
├── marked.min.js
├── highlight.min.js
└── purify.min.js
```

字体在 `index.html` 中通过 base64 内联，JS 通过 Zig 编译期拼接：

```zig
// server.zig — 构造 HTML response 时注入
const html = try std.fmt.allocPrint(arena,
    \\<!DOCTYPE html>
    \\<html><head>
    \\<style>
    \\@font-face {{ font-family:'Inter'; src:url(data:font/woff2;base64,{s}) }}
    \\</style>
    \\<script>{s}</script>   // marked.js
    \\<script>{s}</script>   // highlight.js
    \\<script>{s}</script>   // DOMPurify (XSS sanitizer)
, .{ @embedFile("vendor/inter.woff2"), @embedFile("vendor/jetbrains-mono.ttf"), @embedFile("vendor/marked.min.js"), @embedFile("vendor/highlight.min.js"), @embedFile("vendor/purify.min.js") });
```

**二进制体积增加**：~819KB，可忽略。真正实现单文件、零网络依赖（仅 LLM API 需 curl）。

**XSS 防护**：marked.js 默认允许原始 HTML 通过——LLM 响应或工具输出中若包含 `<script>`、`<img onerror>` 等将直接执行。渲染前必须经 DOMPurify 净化：

```js
// index.html — 所有 LLM 输出渲染前必须净化
const clean = DOMPurify.sanitize(marked.parse(raw));
// DOMPurify 默认移除所有 script/event-handler/javascript: —— 白名单模式
```

marked.js 内置的 `sanitize: true` 已在新版中废弃（功能不完整），必须使用 DOMPurify 独立净化。

**排版：**

```css
--text-xs:     11px
--text-sm:     12px     /* 侧边栏、工具摘要 */
--text-base:   13px     /* 正文 */
--text-lg:     14px     /* 标题 */
--leading:     1.5
--weight-normal: 440
--weight-medium: 530
```

### 5. 状态流转

```
                         ┌─(重试)── 等待中 ──(SSE: thinking_start)──→ 思考中
                         │                                              │
    空闲 ──(POST prompt)─┤                              SSE: content_start
                         │                                              │
                         │                                              ↓
                         │                                          输出中
                         │                                              │
                         │                              SSE: tool_start
                         │                                              │
                         │                                              ↓
                         │                                          工具执行
                         │                                              │
                         │  ┌── SSE: done ─────────────────────────────┤
                         │  │                                           │
                         │  ↓                                           │
                         │ 空闲 ←── SSE: error ── 任意状态              │
                         │  ↑                                           │
                         │                           └── SSE: error (fatal) ── 任意状态          │
```

| 状态 | 触发 | 输入栏 | 对话区 | 退出条件 |
|------|------|--------|--------|---------|
| 空闲 | — | 可用 | 静止 | POST prompt |
| 等待中 | POST prompt 发送 | 禁用 + spinner | 占位 "..." | thinking_start / error |
| 思考中 | SSE thinking_start | 禁用 | 折叠区展开 + 流式追加 | content_start / error |
| 输出中 | SSE content_start | 禁用 | marked.js 流式渲染 | tool_start / done / error |
| 工具执行 | SSE tool_start | 禁用 | 追加工具卡片 (⏳) | SSE done / error |
| 错误 | SSE error (fatal) | 可用 | 红色错误卡片 | 用户手动重试 |

**错误分类与处理：**

| SSE 事件 | 触发条件 | 可重试? | UI 行为 |
|----------|---------|---------|---------|
| `event: error { code: "rate_limited" }` | 429 / API 限流 | 是 | 黄色 "Rate limited, retrying in Ns..." 消息，自动重试 |
| `event: error { code: "api_error" }` | LLM API 返回 5xx / 超时 | 是 | 黄色 "API error, retrying..." 消息，自动重试 |
| `event: error { code: "auth_error" }` | 401 鉴权失败 | 否 | 红色卡片 "Authentication failed. Check API key."，回退到空闲 |
| `event: error { code: "network_error" }` | 连接断开 | 是 | 黄色 "Connection lost, reconnecting..." |
| `event: tool_error { id, error }` | 工具执行异常 | — | 工具卡片显示 ✗ + 错误信息，agent 继续循环（LLM 可自修正） |

### 6. 响应式：断点 768px

```
> 768px:  侧边栏 240px + 对话区 flex:1
≤ 768px:  侧边栏变为顶部汉堡菜单下拉
          对话区占满宽度
```

### 7. SSE 流式模型（start/delta/end 三段式）

参考 opencode 的 `GET /api/event` 事件设计——每个阶段有明确的 start → delta → end 生命周期：

| PhaseWriter 回调 | SSE 事件 | payload | 说明 |
|-----------------|----------|---------|------|
| `beginPhase(.thinking)` | `event: thinking_start` | `{}` | 思考开始 |
| `writeRaw(bytes)` | `event: thinking_delta` | `{"text":"..."}` | 流式追加 |
| `beginPhase(.content)` | `event: thinking_end` + `event: content_start` | `{"duration_ms":14000}` / `{}` | 思考结束 → 内容开始 |
| `writeRendered(line)` | `event: content_delta` | `{"text":"..."}` | 流式渲染 |
| (turn 结束) | `event: content_end` | `{}` | 阶段边界 |
| ToolDisplayCb begin | `event: tool_start` | `{"id":"call_xxx","name":"read"}` | 工具开始 |
| ToolDisplayCb result | `event: tool_end` | `{"id":"call_xxx","result":"...","duration_ms":300}` | 工具完成 |
| 工具出错 | `event: tool_error` | `{"id":"call_xxx","error":"..."}` | 工具失败 |
| API 出错 | `event: error` | `{"code":"...","message":"..."}` | 统一错误通道 |
| round 完成 | `event: done` | `{"usage":{"input":100,"output":50}}` | 携带 token 统计 |

**帧格式：**

```
event: thinking_start
data: {}

event: thinking_delta
data: {"text":"用户想要一个 HTTP 服务器..."}

event: thinking_end
data: {"duration_ms":14200}

event: content_start
data: {}

event: content_delta
data: {"text":"我来帮你实现。首先..."}
```

每个事件带 `type` 字段，前端单 `addEventListener` 分发，无需为每个事件类型注册独立监听器。

**回调接口参考**（来自 `src/io/provider.zig` 和 `src/core/agent.zig`，Web 前端不修改这些定义）：

```zig
// ── PhaseWriterCb (provider.zig:9-15) ──
// Provider 内部通过此回调报告思考/内容阶段进度。SSE 写入器作为 context 传入。
pub const PhaseWriterCb = struct {
    context: ?*anyopaque,     // → SSE 写入器指针
    begin_phase: *const fn (ctx: ?*anyopaque, mtype: PhaseType) void,
    write_raw: *const fn (ctx: ?*anyopaque, bytes: []const u8) void,
    write_rendered: *const fn (ctx: ?*anyopaque, line: []const u8) void,
    end_phase: *const fn (ctx: ?*anyopaque) void,
};

// ── ToolDisplayCb (agent.zig:33-45) ──
// agent.runTurn() 每次工具执行完毕时调用。SSE 写入器作为 context 传入。
pub const ToolDisplayCb = struct {
    context: ?*anyopaque,     // → SSE 写入器指针
    begin_tool: ?*const fn (ctx: ?*anyopaque, tool_name: []const u8) void = null,
    render: *const fn (
        ctx: ?*anyopaque,
        tool_name: []const u8,
        tool_args: []const u8,
        had_error: bool,
        err_msg: ?[]const u8,
        user_output: ?[]const u8,
        meta: types.ToolMeta,
    ) anyerror!void,
};

// ── PhaseType (provider.zig:7) ──
pub const PhaseType = enum { none, thinking, content };
```

**SSE 写入器传入方式**——两个回调共用同一模式：

```zig
// sse.zig — SSE 连接状态，作为 context 注入回调
const SseState = struct {
    writer: std.Io.FixedBufferStream([]u8).Writer, // 或直接持有 stream writer
    thinking_start_ms: i64,
};

fn createPhaseWriter(state: *SseState) PhaseWriterCb {
    return .{
        .context = state,
        .begin_phase = struct {
            fn cb(ctx: ?*anyopaque, phase: PhaseType) void {
                const s = @as(*SseState, @ptrCast(@alignCast(ctx.?)));
                switch (phase) {
                    .thinking => {
                        s.thinking_start_ms = std.time.milliTimestamp();
                        writeSseEvent(s.writer, "thinking_start", "{}");
                    },
                    .content => writeSseEvent(s.writer, "content_start", "{}"),
                    .none => {},
                }
            }
        }.cb,
        .write_raw = struct {
            fn cb(ctx: ?*anyopaque, bytes: []const u8) void {
                const s = @as(*SseState, @ptrCast(@alignCast(ctx.?)));
                writeSseEvent(s.writer, "thinking_delta", bytes); // JSON-escaped
            }
        }.cb,
        .write_rendered = struct {
            fn cb(ctx: ?*anyopaque, line: []const u8) void {
                const s = @as(*SseState, @ptrCast(@alignCast(ctx.?)));
                writeSseEvent(s.writer, "content_delta", line); // JSON-escaped
            }
        }.cb,
        .end_phase = struct {
            fn cb(ctx: ?*anyopaque) void {
                const s = @as(*SseState, @ptrCast(@alignCast(ctx.?)));
                const elapsed = std.time.milliTimestamp() - s.thinking_start_ms;
                const payload = std.fmt.bufPrint(&buf, "{{\"duration_ms\":{d}}}", .{elapsed}) catch return;
                writeSseEvent(s.writer, "thinking_end", payload);
            }
        }.cb,
    };
}
```

`ToolDisplayCb` 同理——`context` 指针传入 `SseState`，在 `.render` 回调中将工具结果序列化为 `event: tool_end` JSON payload。

### 8. 入口路由

```zig
// src/frontends/cli/main.zig — 新增
if (std.mem.eql(u8, arg, "--web")) {
    const web = @import("../web/server.zig");
    return web.main(process);  // project_root 通过 --root 参数传入
}
```

新增 `--root` 参数（可选，默认 CWD 向上查找 `.zagent/`）。

### 9. 降级路径：Phase 7B — HTML 导出

如果 TCP 服务端实现遇到阻塞问题，可降级为 pi-repos 的 HTML 导出模式：将 session 消息 + 工具结果渲染为自包含 `.html` 文件（嵌入 marked.js + highlight.js），用浏览器打开。无需 TCP 服务器，无需 SSE，功能等价。

## 实施

### 步骤 0: 准备 vendor 资源（前置）

`@embedFile` 在编译期读取文件，vendor 目录必须在 `zig build` 前就绪。

```powershell
# 创建目录
New-Item -ItemType Directory -Force -Path src/frontends/web/vendor

# Inter UI 字体 (v4+)
Invoke-WebRequest -Uri "https://github.com/rsms/inter/releases/latest/download/Inter-4.0.zip" -OutFile "$env:TEMP\Inter.zip"
Expand-Archive "$env:TEMP\Inter.zip" -DestinationPath "$env:TEMP\Inter"
Copy-Item "$env:TEMP\Inter\InterVariable.woff2" src/frontends/web/vendor/inter.woff2

# JetBrainsMono 字体
Invoke-WebRequest -Uri "https://github.com/JetBrains/JetBrainsMono/releases/latest/download/JetBrainsMono-2.304.zip" -OutFile "$env:TEMP\JetBrainsMono.zip"
Expand-Archive "$env:TEMP\JetBrainsMono.zip" -DestinationPath "$env:TEMP\JetBrainsMono"
Copy-Item "$env:TEMP\JetBrainsMono\fonts\variable\JetBrainsMono\[wght\].ttf" src/frontends/web/vendor/jetbrains-mono.woff2

# marked.js (minified)
Invoke-WebRequest -Uri "https://cdnjs.cloudflare.com/ajax/libs/marked/15.0.12/marked.min.js" -OutFile src/frontends/web/vendor/marked.min.js

# highlight.js (minified, core + common langs)
Invoke-WebRequest -Uri "https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.11.1/highlight.min.js" -OutFile src/frontends/web/vendor/highlight.min.js

# DOMPurify (minified)
Invoke-WebRequest -Uri "https://cdnjs.cloudflare.com/ajax/libs/dompurify/3.2.5/purify.min.js" -OutFile src/frontends/web/vendor/purify.min.js
```

> **注意**：字体文件建议手动下载并放入 vendor/，GitHub Release URL 可能随版本变化。JS 库固定 CDN 版本号以确保确定性构建。vendor/ 目录入 git 追踪（不 `.gitignore`）。

### 步骤 1: 创建 SSE 帧构造模块 `sse.zig`

**依赖**: `src/io/provider.zig` (PhaseWriterCb, PhaseType), `src/core/agent.zig` (ToolDisplayCb)
**被依赖**: `handler.zig`

- 1a: `SseState` struct — 持有 stream writer + thinking 计时器
- 1b: `writeSseEvent()` — 标准 SSE 帧格式：`event: <name>\ndata: <json>\n\n`
- 1c: `createPhaseWriter(state)` — 返回 PhaseWriterCb，6 个回调映射到 SSE 事件
- 1d: `createToolDisplay(state)` — 返回 ToolDisplayCb，render 回调序列化为 `tool_start`/`tool_end` JSON

### 步骤 2: 创建错误响应模块 `error.zig`

**依赖**: `std.http.Server`
**被依赖**: `handler.zig`

- 2a: `ApiError` struct — `{ "error": { "code": "...", "message": "..." } }`
- 2b: `respondError()` — 写入 JSON 错误 + 正确 HTTP 状态码

### 步骤 3: 创建共享类型模块 `api_types.zig`

**依赖**: `src/types.zig`
**被依赖**: `handler.zig`

请求/响应 struct 定义，与路由 handler 共享。

### 步骤 4: 创建路由处理模块 `handler.zig`

**依赖**: `sse.zig`, `error.zig`, `api_types.zig`, `src/core/agent.zig`, `src/core/session.zig`, `src/config.zig`
**被依赖**: `server.zig`

- 4a: `Route` struct + 线性路由表（10 个端点）
- 4b: 静态路由：`/` (serve index.html), `/api/health`, `/api/model`, `/api/provider`
- 4c: Session CRUD：list/create/get/patch/fork/reset
- 4d: SSE prompt：手动写 HTTP 头 `Content-Type: text/event-stream` → 创建 SseState → 调用 `agent.runTurn()` → PhaseWriterCb/ToolDisplayCb 直写 SSE 帧

### 步骤 5: 创建 TCP 服务入口 `server.zig`

**依赖**: `handler.zig`, `src/frontends/cli/App.zig` (agent 初始化), `src/config.zig`
**被依赖**: `src/frontends/cli/main.zig` (路由)

- 5a: `main(process)` — 解析 `--root` / env / CWD 查找 project root
- 5b: 加载 config, 创建 provider, init agent
- 5c: TCP 监听循环：`IpAddress.resolve` → `listen` → `Group.concurrent` + `Semaphore(100)` + `handleConnection`
- 5d: `handleConnection` — reader/writer → `http.Server.init` → 路由分发

### 步骤 6: 创建前端单页 `index.html`

**依赖**: 无（编译期嵌入，运行时由 server.zig 返回）
**改动**: ~700 行 HTML+CSS+JS — 侧边栏 + 对话流 + SSE EventSource + 工具卡片

### 步骤 7: CLI 入口路由

**文件**: `src/frontends/cli/main.zig`
**改动**: 新增 `--web` + `--root` 参数 → 路由到 `web/server.zig`

### API 路由参考（步骤 4 handler.zig 中实现）

| 方法 | 路径 | 处理 |
|------|------|------|
| GET | `/` | serve `@embedFile("index.html")` |
| GET | `/api/health` | `{ "status": "ok" }` |
| GET | `/api/model` | config 模型列表 → JSON |
| GET | `/api/provider` | config 提供商列表 → JSON |
| GET | `/api/session` | session 列表 → JSON |
| POST | `/api/session` | 新建 session |
| GET | `/api/session/:id` | session 详情 + 消息列表 |
| PATCH | `/api/session/:id` | 重命名 / 切换模型 |
| POST | `/api/session/:id/fork` | fork session |
| POST | `/api/session/:id/prompt` | **SSE 流**：绕过 `respond()`，手动写 `HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: keep-alive\r\n\r\n` 到 stream writer，然后 PhaseWriterCb + ToolDisplayCb 直写 SSE 帧 |
| POST | `/api/session/:id/reset` | 重置 session |

**权限审批（延后到 Phase 7.1）：**
Web v1 工具默认自动批准（等价的 CLI `--allow-tools` 行为）。交互式审批需要纤程间双向通信，Phase 7.1 通过 `std.Io.Mutex` + 共享状态实现。

## 验证

```powershell
zig build
zig build run -- --web
zig build run -- --web --root C:\my-project
# 打开 http://localhost:8090
```

| 测试场景 | 预期结果 |
|----------|----------|
| `zig build run -- --web` | 启动成功，从 CWD 向上查找 `.zagent/`，打印 project root + 已找到 session 数 |
| `zig build run -- --web --root <path>` | 启动成功，使用显式 project root |
| 浏览器 GET / | 返回 index.html，侧边栏显示已有 session 列表 |
| 点击 "+ New Session" | POST /api/session → 创建新 session，侧边栏刷新，对话区清空 |
| 点击 session 名称 | GET /api/session/:id → 加载消息历史，对话区渲染 |
| POST /api/session/:id/prompt | **返回 SSE 流**。PhaseWriterCb 直写 response body，thinking_start → content_delta → tool_start/end → done |
| `GET /api/health` | `{ "status": "ok" }` |
| `GET /api/model` | 模型列表 JSON，含 id/name/provider/context_window |
| 非法 JSON body | `400 { "error": {"code":"bad_request","message":"..."} }` |
| SSE `thinking_start` → `thinking_delta` × N → `thinking_end` | 思考区流式展开 → 完成自动折叠 + 显示耗时 |
| SSE `tool_start` → `tool_end` | 工具卡片先 ⏳ → 完成后 ✓ + 耗时 |
| SSE `error` 事件 | 对话区显示红色错误卡片 |
| SSE `done` 事件 | 携带 `usage` token 统计，输入栏恢复可用 |
| 侧边栏 session 双击 | PATCH /api/session/:id → 重命名 |
| 右键 session → Fork | POST /api/session/:id/fork → 新 session 出现在列表 |
| SSE `error (rate_limited)` | 黄色消息 + 自动重试指示器 |
| SSE `error (auth_error)` | 红色卡片 + 输入栏恢复可用 |

## 风险

| 风险 | 概率 | 缓解 |
|------|------|------|
| `std.http.Server` 的 `respondStreaming` API 在 0.16 中未验证 | 中 | 绕过 `respond()`：手动写原始 HTTP 头（`HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: keep-alive\r\n\r\n`）到 stream writer，然后直接写 SSE 帧。不依赖 `respondStreaming`，降级路径 Phase 7B HTML 导出 |
| `@embedFile` 资源过大 | 极低 | HTML ~700 行 ≈ 16KB；vendor 文件 ~819KB（字体+JS），总计 <850KB |
| `Group.concurrent` 纤程调度与 agent 的 arena allocator 冲突 | 中 | agent 使用的 arena 可能跨纤程共享——需验证每个连接独立分配器 |
| SSE 连接断开 → fiber 泄漏 | 中 | 浏览器关闭/导航离开时 EventSource 断开，但 `agent.runTurn()` 仍在 fiber 中运行直到 LLM 超时（最长 300s）或完成。缓解：web handler 检测连接断开后调用 `agent.abort()` 释放 fiber；或在 `Group.concurrent` fiber 入口注入 Io deadline |
| HTTP 响应不设 Content-Security-Policy | 低 | 127.0.0.1 绑定 + 单 HTML 文件，攻击面极小。DOMPurify 净化已阻断脚本注入。若后续开放外部访问，必须加 `Content-Security-Policy: default-src 'self'; script-src 'self'` |

## 波及

| 文件 | 改动 | 破坏性? |
|------|------|----------|
| `src/frontends/web/server.zig` | 新建 — TCP 监听 + accept 循环 | 否 |
| `src/frontends/web/api_types.zig` | 新建 — 请求/响应 struct, SSE 事件 enum | 否 |
| `src/frontends/web/handler.zig` | 新建 — 路由表 + 业务逻辑 | 否 |
| `src/frontends/web/sse.zig` | 新建 — SSE 帧构造 + PhaseWriterCb 映射 | 否 |
| `src/frontends/web/error.zig` | 新建 — 统一 JSON 错误响应 | 否 |
| `src/frontends/web/index.html` | 新建 — 侧边栏 + 对话流 Web UI (~700 行) | 否 |
| `src/frontends/web/vendor/` | 新建 — 字体 + marked.js + highlight.js + DOMPurify (~819KB) | 否 |
| `src/frontends/cli/main.zig` | 新增 `--web` + `--root` 参数 | 否 |
| `build.zig` | 无需改动 | 否 |

## 偏差（实施 vs 计划）

| # | 计划 | 实施 | 原因 |
|---|------|------|------|
| 1 | `Group.concurrent` 并发连接 | 顺序 `accept` (ep1 模式) | 0.16 `Group.concurrent` API 签名不确定，MVP 单用户场景无并发需求 |
| 2 | `respondStreaming` SSE 流式 | SSE 端点已实现 — `sse.SseWriter` 函数指针表桥接 `Io.net.Stream.Writer.interface` | 使用 `writer.interface` + `sseWriterFrom()` factory 函数 |
| 3 | handler 使用 long-lived arena | Per-request arena (`handleRequest` 入口创建) | 审查发现原设计内存泄漏：server-lifetime arena 不释放请求分配 |
| 4 | `Session.sessionsDir()` | `std.fs.path.join(project_root, ".zagent", "sessions")` | Session 无此方法，直接构造路径 |
| 5 | `ArrayList(writer).init()` | `ArrayListAligned(u8,null).empty` + `bufPrint` + `appendSlice` | 0.16 ArrayList API 变更 |
| 6 | URL 参数 `request.url().path` | `request.head.target` 直接解析 | 0.16 Request API 无 `.url()` 方法 |
| 7 | `session.id` 返回给前端 | Session 无 id 字段，用 `session.name` 替代 | SessionInfo 有 `id`，Session 无 |

## 术语

| 术语 | 含义 |
|------|------|
| SSE | Server-Sent Events，HTTP 长连接单向推送，浏览器 `EventSource` API |
| HTML 导出 (Phase 7B) | pi-repos 模式 — 将 session 渲染为自包含 `.html` 文件，无需 TCP 服务器 |
| Route 路由表 | ep3 模式 — `[]Route` 数组，线性扫描匹配 method + path |
