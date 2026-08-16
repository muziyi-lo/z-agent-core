# Plan N16-APPROVAL-PREVIEW: 工具审批 + 文件预览

## 状态: 待实施

## 前置依赖

| 阻塞者 | 状态 | 说明 |
|--------|------|------|
| 无 | — | REMAINING N16 自 P1。diff 高亮已由 N12（TOOL-CARD-TYPED）覆盖，本期做剩余两件 |

## 需求

REMAINING.md N16（P1，PARTS"高价值三件"剩余两件）：

1. **工具审批**：危险命令执行前确认（ApprovalModal，opencode 参考）
2. **文件/图片预览**：工具结果内联渲染（读文件/看图）

## 设计要点

### Part A — 工具审批

**拦截点**：`ToolHooks.before`（agent.zig:55-59、374-386）——返回非 null 阻止执行并 append tool 消息。审批 = hook 内阻塞等待用户决策。

**同步原语**：`Gate` 原子状态轮询（100ms），复用 abort 模式（agent.zig:98-113 原子标志 + `signal.setInterrupted()`）。**不用 `Io.Condition`**（依赖 io 事件循环，Web server 请求线程是普通 thread）。sleep 用 subcall.zig:63-65 先例（Win `kernel32.Sleep` / POSIX `std.c.nanosleep`）。

**新模块 `src/approval.zig`**（core 层，不 import frontends）：

```zig
pub const Mode = enum { never, risky, always };   // config approval_mode
pub const GateState = enum { pending, approved, denied, aborted };
pub const Gate = struct {
    state: std.atomic.Value(GateState),
    /// 轮询等待决议。check_abort 置位 → aborted；keepalive 每 ~1s 调用一次
    /// （返回 false = SSE 连接已断）→ aborted；timeout 超时 → denied。
    pub fn wait(self: *Gate, timeout_ms: u32, check_abort: *const fn () bool, keepalive: ?*const fn () bool) GateState;
    pub fn resolve(self: *Gate, allow: bool) void;  // 幂等
};
pub fn isRisky(mode: Mode, name: []const u8, args: []const u8) ?[]const u8; // 返回规则说明或 null
```

- `isRisky` 规则集（bash 危险命令模式扫描，不区分大小写）：
  - `rm -rf` / `rm -r -f`（含 `--recursive --force`）、`Remove-Item -Recurse`（`rmdir /s`、`del /f /s /q` 等同族）
  - `format`（format c: 等）、`diskpart`、`fdisk`、`mkfs`、`dd`（写设备）
  - `git push --force` / `git reset --hard` / `git clean -fdx`
  - `curl ... | sh` / `curl ... | bash`（管道执行）
  - `chkdsk /f`、`reg delete`、`sc delete`、`net user`（系统破坏类）
  - 规则判定只匹配 `command` 字段（bash 的 args.command），识别宽松（分词 + 关键 token 组合），**宁可漏报不可误报**（漏报=无保护但可用；误报=打断正常流程）
- `Mode` 语义：`never`=不审批；`risky`=仅 bash 危险命令；`always`=全部 9 工具。**默认 `risky`**（功能定位；用户可配 `never` 关闭）
- `wait` 超时：300s（5 分钟）未决议 → 超时当 denied（防 SSE 连接挂死）。等待循环每 100ms 检查：gate.state + `check_abort`（`signal.isInterrupted()`，与 agent.abort 联动）
- **SSE 断连生命周期**（审查补充）：审批等待期间连接无写入，断连（关页面/网络中断）无法被写失败路径感知 → 会挂到 300s 超时。修复：`wait` 的 `keepalive` 回调每 ~1s 写一次 SSE 注释帧（`: keepalive\r\n\r\n`，复用 SseWriter 函数指针包装），**写失败 = TCP 已断** → 回调返回 false → `wait` 立即返回 aborted。hook 收到 aborted 后调 `agent.abort()`（同 sse.zig 现有"写失败→abort"语义，agent.zig:109）终止整个回合（SSE 已断，结果无法送达，继续无意义）→ runTurn 走 interrupted 收尾。副作用：心跳同时防止代理超时关闭空闲 SSE 连接

**Web 集成**（handler.zig + server.zig）：

- 进程级 `approval_map: *StringHashMap(*approval.Gate)` + mutex（server.zig 定义，与 abort_map 同模式）
- `handlePrompt`（SSE）：组装 `ApprovalCtx`（sse_state/agent/approval_map/mode 指针）→ `agent.tool_hooks.before = approvalBeforeHook`
- `approvalBeforeHook(ctx, name, args)`：
  1. `approval.isRisky(mode, name, args)` 返回 null → 返回 null（放行，正常流程）
  2. 需要审批：id=`approval_{全局自增}` → gate 注册 map → 发 SSE `approval_required`（`{"id","name","args","rule"}`，用 sse.writer 直写 frame）→ `gate.wait(300_000, &checkAbort, &keepaliveAlive)` → 从 map 移除 → 结果：approved → null；denied/timeout → 拒绝消息 `"User denied this tool call ({rule}). Adjust your approach."`（tool 消息，模型可见）；**aborted（含 SSE 断连）→ 调 `agent.abort()` 后返回拒绝消息**（abort 终止回合，拒绝消息兜底）
- `POST /api/approval/:id` `{"allow":true|false}` → map 找 gate → `resolve` → 200；不存在 → 404。**无需通知机制**（agent 线程轮询 gate）
- 事件时序：`approval_required` 先于 `tool_start`（hook 在 beginTool 之前，agent.zig:374→403）；审批通过后工具卡片正常流式

**前端**（app.js + index.html）：

- `#approval-modal`（modal-overlay 模式，confirmModal 先例）：消息区（工具名 + 危险规则）+ 参数 `<pre>` + Cancel/Allow 按钮
- `approvalModal(detail)` Promise：Allow → `POST /api/approval/:id {allow:true}`；Cancel/Escape/遮罩 → `{allow:false}`
- **竞态处理（审查补充）**：Gate 超时/断连被清理后用户才点 Allow → POST 404。Allow 分支捕获**非 2xx 响应**（404 或 500）→ 视为"审批已超时/已失效"：提示（`showStatus` 或 Modal 内换文案"This approval expired — the tool call was auto-denied"）并关闭 Modal，**不 resolve 为 allow**。已超时的 tool 消息后续会以 denied 形式出现在会话中，前端无需重发
- **断连联动**：SSE `evtSrc.onerror`（app.js:1592 现有路径）→ 关闭当前审批 Modal（若有）+ 清 pending 状态——服务端已因 keepalive 写失败 abort，Modal 残留会误导用户
- SSE listener `approval_required`：解析 detail → 弹 Modal。同一时刻仅一个审批（SSE 串行单工具流）；若有旧 pending Modal 则先拒绝再弹新的
- 工具卡片流式期出现 pending 态（`tool_start` 到达后正常，审批在 tool_start 前——卡片此时尚未创建，无特殊渲染需求）

**CLI 端**：本期不做（ApprovalModal 是 Web 组件）。CLI 同步 stdin 确认留待后续（REMAINING 备注）。

### Part B — 文件/图片预览

**后端** `GET /api/preview?path=<相对 project_root>`：

- 路径解析：复用 `util/path.resolvePath`（防穿越，与 read 工具同源）
- 文本：读文件（≤`types.FILE_READ_LIMIT` 64KB 守卫 + 超限截断 `truncated:true`）→ `{name, kind:"text", content, truncated}`（jsonw.escapeAlloc 转义）
- 图片：扩展名白名单（png/jpg/jpeg/gif/webp/svg）+ `util/text.isBinary` → base64 → `{name, kind:"image", data_url:"data:image/<ext>;base64,..."}`（≤5MB 守卫，超限 `kind:"too_large"`）
- 错误：参数缺失/路径越界 → 400；文件不存在/目录 → 404

**前端**：

- `#preview-modal`（modal-overlay）：标题（文件名）+ 正文（文本 `<pre>` textContent / 图片 `<img>`）+ Close
- `previewModal(path)`：`fetch(/api/preview?path=...)` → 渲染
- 挂载点：read 卡（meta.path）、edit 卡（meta.path）→ ToolRegistry 类型化视图加 Preview 按钮（card-head 或 tool-meta 区，`data-path`）
- webfetch/grep 卡不挂（无本地路径语义）

## 实施

| 文件 | 改动 |
|------|------|
| `src/approval.zig`（新增） | Mode/GateState/Gate（wait/resolve）+ isRisky 规则集 + 单测 |
| `src/config.zig` | `approval_mode` 字段（默认 risky）+ TOML 解析 + 模板注释 |
| `src/frontends/web/server.zig` | 进程级 approval_map + mutex（abort_map 同模式） |
| `src/frontends/web/handler.zig` | approvalBeforeHook + ApprovalCtx + `POST /api/approval/:id` + `GET /api/preview` + 路由（POST 分支 / GET 分支） |
| `src/frontends/web/app.js` | `approval_required` listener + approvalModal + previewModal + Preview 按钮（ToolRegistry read/edit 分支） |
| `src/frontends/web/index.html` | `#approval-modal` + `#preview-modal` 结构 |
| `src/frontends/web/app.css` | 复用 modal-overlay；approval 详情 pre / preview 正文样式 |

测试（Zig：新增 approval 单测；前端：15 文件不变，modal 为 DOM 交互走浏览器实测）：

- `isRisky`：bash 危险命令各规则命中（rm -rf/Remove-Item -Recurse/git push --force/curl|sh 等）+ 安全命令不误报（rm file、git push、Remove-Item 单文件）+ 非 bash 工具在 risky 模式不审 + always 模式全审 + never 全不审
- `Gate`：初始 pending、resolve(true/false) 后状态、重复 resolve 幂等、wait 超时返回 denied、check_abort 置位返回 aborted、**keepalive 返回 false 立即 aborted（断连语义）、keepalive 周期性调用次数正确**
- 前端竞态（浏览器实测）：审批 Modal 打开 → 等待 300s（或人工缩短验证）超时 → 点 Allow → 提示 "expired" 且无二次请求副作用；断连 → Modal 自动关闭

## 验证

- `zig test src/test.zig --cache-dir .zig-cache` → All 325+N tests passed
- `zig build` + `zig build -Doptimize=ReleaseSafe`（含函数指针改动，强制）
- `node tests/frontend/run-tests.mjs` → All 15 file(s) passed
- 实机（Web）：`approval_mode=risky` → 诱导 bash `rm -rf` → ApprovalModal 弹出 → Allow 执行正常流式 / Deny 出现拒绝 tool 消息且模型继续；`never` 模式无弹窗；预览：read 卡 Preview 打开文本文件、图片文件以 `<img>` 渲染、越界路径 400
