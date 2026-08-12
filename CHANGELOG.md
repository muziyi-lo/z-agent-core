# Changelog

## [0.2.7] — 2026-08-12

### Added
- **消息 ID 模型**（`docs/0.2.7/PLAN-SESSION-SYSTEM-OPT.md` P1）:
  - `Message` 增 `id: u64` 单调递增（`Session._next_id` 分配），JSONL 序列化/解析支持；旧会话文件加载时一次性分配 id + 迁移写回（非正式版不兼容策略）
  - 会话操作按 id：`DELETE /message/:id`、`POST /truncate {message_id}`（revert 用，按位置截断保留系统提示词）、`POST /branch {message_id}`（`forkAt`，按 id 定位）
  - `(fork #N)` 自动命名（按基础标题扫描递增）；`sanitizeForkName` URL 安全化
  - SSE `session_ready` 携带新用户消息 `message_id`，前端按 id 绑定操作按钮
- **Web 前端消息操作栏增强**:
  - 用户消息操作栏 4 按钮（revert/copy/branch/delete），全部按消息 id 绑定 + `status-msg` 失败提示
  - revert 语义改为"截断 + 重新生成"；branch 从消息分叉（`(fork #N)` 自动命名 + 自动切换）
- **滚动状态机**（吸收 opencode `createAutoScroll`）: 用户离开底部暂停跟随、回底恢复、程序滚动防误判（mark 时间窗）、reload 保留滚动位置、嵌套滚动豁免
- **流式期间三层操作防护**: 前端 `isStreaming` 守卫 + `#messages.streaming` 灰显禁用 + 服务端 `agent_busy` 兜底（基于 `abort_map` 流式追踪）
- **分支关系（P2）**:
  - `Session.parent_id`：fork/branch 子会话记录来源会话，header 序列化/解析，列表与详情输出
  - **侧边栏分支树**：子会话按 parent_id 缩进渲染在父会话下 + 分支图标（`bi-git-branch`），**多代嵌套按层级递进缩进（28+14px/代）**；孤儿分支（父已删除）自动提升到顶层保证可达
  - **branch 自动重答（方案 B，对齐 pi-repos）**：fork 到边界消息之前，`branch` 响应回传 `boundary_content`，前端切换后自动重发 → 立即生成新答案，消除悬空/连续 user 消息
  - `GET /api/session/active`：返回最近更新会话，前端刷新后自动恢复
- **消息游标分页（P3）**:
  - `GET /api/session/:id?limit=N`：首屏最近 N 条 + `system` + `has_more`
  - `GET /api/session/:id/message?before=<msg_id>&limit=N`：向上翻页（按 id 定位位置）
  - **页边界不切工具序列**：分页起点回溯到非 tool 消息，assistant+tool 结果永不跨页拆分
  - 前端首屏最近 50 条 + 接近顶部滚动自动加载更早 + 滚动锚点恢复（顶部插入不跳位）
- **结构化错误**: `err_mod` 增 `message_not_found`（消息不存在返回 404 区分）
- **msg_count 精确化**：header 存真实消息数，list 优先读 header，缺字段数行兜底（替代 size/150 估算）
- **上下文压缩（P4）**:
  - `POST /api/session/:id/compact`：LLM 摘要历史 + 保留最近 20 条（页边界不切工具序列），写回 `[Compaction]` system 消息，系统提示词保留
  - `Session.replaceMessages` 保留 kept 消息 id；守卫 busy + 幂等（≤2 条返回 compacted:0）
  - 自动触发（agent 阈值监控）待后续
- **会话操作撤销（P5）**:
  - `UndoOp`（delete/truncate/branch）per-session LIFO 栈（cap 20，服务器持久分配器）
  - `POST /undo` 逆操作（消息恢复原位/重新追加/删 fork）+ `GET /history`
  - 前端 topbar `↶` undo 按钮；守卫 busy + 空栈 400

### Fixed
- **用户消息 delete 索引漂移**：按钮 index 用 DOM 计数，与服务端消息数组下标漂移（工具回合 N+2 条 vs N+1 元素）→ 删错/静默 400；改为按消息 id 操作根治
- **删除按钮流式会话不可见**：删除按钮创建被 `_msgId` 门控，改为总是创建 + 点击时守卫
- **fork 命名 `#` 进文件名**：`sanitizeForkName` 白名单化，`#` 被 URL 片段截断导致 session not found
- **Node 前端测试适配**：`test-loadsession-segments.mjs` 补滚动状态机全局 stub
- **`/api/session/active` 空态 404**：无会话时返回 `200 {id:null}`——前端初始化自动恢复不再报错
- **`/session/:id?limit=50` 大系统提示词 500**：分页 header 原用 `[1024]u8` 栈缓冲 bufPrint，系统提示词 >1KB（实测 1063B）溢出；改堆 `allocPrint`
- **highlight.js 重复高亮警告**：三处 `hljs.highlightAll()` 对全文档重复处理已高亮元素；改为 `highlightNewCode` 只高亮 `:not([data-highlighted])` 新元素

## [0.2.6] — 2026-08-11

### Added
- **Web 前端 DeepSeek 风格改造**（`docs/0.2.6/PLAN-DEEPSEEK-STYLE.md`，9 PR 分批）:
  - **token 体系重写**: 深色 `#151517` 底 + `#1B1B1C` 侧边栏 + 主色 `#3964FE`，浅色纯白 + 淡蓝气泡 `#EDF3FE`，对齐 DeepSeek 实测；新增 6 语义 token（`--msg-max-width`/`--sider-width`/`--bubble-radius`/`--bg-user-bubble`/`--bg-active`/`--bg-inline-code`）；清理 16 个死 token
  - **布局对齐**: sidebar 261px 无边框、消息区全宽滚动 + 内容限宽 840 居中、正文 15px/代码 12.5px、topbar flex 重排 + `#topbar-actions` 工具区
  - **组件视觉**: 用户气泡 22px 全圆角胶囊、工具卡片弱底无边框、思考块折叠卡 12px、代码块容器 12px、行内 code 深浅主题分色
  - **Bootstrap Icons**: 侧边栏切换 `bi-layout-sidebar`↔`bi-layout-sidebar-inset`（CSS 显隐）、用户消息操作栏 revert/copy/trash、代码块复制按钮；`biIcon()` 辅助函数
  - **侧边栏收起**: 改 `width:0` + `flex-basis:0` 让 main 占满，保留 240ms 动画；`aria-pressed` 状态
  - **发送/终止按钮合并**: 单 `#send-btn`，空闲显示发送 ✈、流式时切换红色 ✕ 终止（`setStreaming()`），对齐 DeepSeek
  - **输入框胶囊**: `#input-wrap` 24px 圆角容器 + 圆形 34px 按钮，textarea 透明无边框
  - **工作目录小字**: `#cwd-hint` 显示 `project_root`（`/api/health` 新增 `cwd` 字段，`escapeJsonDynamic` 转义）
  - **置顶分组（K16）**: `zagent-pinned` localStorage + `groupSessions()` 纯函数 + 📌 按钮，Pinned 组置顶
  - **⋮ 更多菜单（K17）**: 会话项 hover 显示 ⋮，菜单含 Rename/Pin/Delete，`closeAllMoreMenus()` + 全局点击关闭
  - **模型选择器迁移（M1-M4）**: 原生 select → topbar 胶囊按钮 + 弹出列表（✓ 高亮选中），`selectModel()` 提取，保留降级
  - **theme-btn 移顶栏**: 从侧边栏移到 `#topbar-actions` 圆形按钮，侧边栏收起时仍可切换
  - **代码块 banner（R1/R2）**: `decorateCodeBlocks()` 给代码块加语言标签 + 常驻复制按钮，全局事件委托
  - **`setTopbarTitle()`**: 修复 topbar 结构重排后 `textContent` 覆盖清掉 `#topbar-actions` 的问题（6 处替换）
  - **测试防护网扩展（PR4）**: 新增 `groupSessions`/`renderModelMenu`/`moreMenuAction`/`decorateCodeBlocks` 4 纯函数 + 4 测试文件，断言 37 → 82

### Fixed
- **用户消息 hover 菜单重叠**: `.msg-actions` 定位到气泡下方预留 margin，不覆盖气泡/相邻消息
- **思考内容无法选中复制**: `user-select:none` 从 `.thinking-block` 移到 header，`.content` 可选中
- **浅色主题行内 code 涂黑**: `--bg-inline-code` 浅色改 `rgba(13,13,13,0.06)`（对齐千问实测），深色保持 `#2C2C2E`
- **消息容器宽度**: 全宽滚动（空白区滚轮可滚），内容限宽居中，用户消息右缘对齐限宽容器
- **代码块复制含 "Copy" 文本**: `addCopyButton` 默认复制 `code` 内容而非 `pre.textContent`（含按钮文本）
- **`/model` slash 命令**: 引用已删除的 `#model-select`，改为触发 `#model-btn`

## [0.2.5] — 2026-08-06

### Added
- **system prompt 分块渲染**: `renderSystemBlocks` 按语义标签（`<env>`/`<project_context>`/`<available_skills>`）分块，统一 `<pre class="sys-block">` 保留原始缩进换行 + 左侧色条视觉分割（AGENTS.md 原样展示）；修复 env/skills 块被 marked 剥离导致换行折叠、模块无分割的问题
- **上下文拼装修复（CONTEXT-ASSEMBLY）**: system prompt `<available_skills>` 索引修复（读 SKILL.md 而非目录，修 IsDir bug）+ 按名排序 + 空态输出；env 块补 Model/Date/Git repo 三行（模型自我认知/当前日期/git 状态）；skill 目录配置化 `skills_dir`（默认 `.zagent/skills`，可指向任意工具技能目录）
- **frontmatter 解析统一**: 新增 `util/frontmatter.zig` 的 `parseField`（comptime 拼接零分配），统一 agent/skill 两处实现
- **bash 工具描述禁令**: `DO NOT use for file operations` + 专用工具映射表（glob/grep/read/edit/write）+ `workdir` 替代 `cd`
- **Web 停止按钮**: 输入栏 `#stop-btn`，流式期间启用，点击调 `POST /api/session/:id/abort`，含 `abortInFlight` 防重入（F11）
- **Web 模型切换生效**: 前端 `sendPrompt` 的 SSE URL 附带 `&model=`，后端 `handlePrompt` 读取并应用；新增 `Provider.setModel()` 在 runTurn 前把会话模型写入 provider config（base_url/api_key/model/vendor/compat/context_window 一并切换）
- **非法模型显式 400 + available_models**: 新会话模型解析失败返回 `{code, message, available_models}`，列出全部 `provider/model_id` 可选模型（LRN-20260811-001 修复的配套契约）
- **模型解析单一化（MODEL-RESOLVE）**: `createSession` 工厂统一 3 处建会话（`id_override` 复用前端 session id）；`resolveModelSpec`/`resolveSessionModel` 收敛模型决策点；`FrontendState` 进程级持有 `env_snapshot` + `dotenv`，请求期零 env/.env IO
- **SSE 异常关闭通知服务端**: `evtSrc.onerror` 复用 `abortPrompt()`，连接断开时 abort 服务端请求避免空跑（F16）
- **无会话直接输入**: 移除 `#prompt-input`/`#send-btn` 初始 disabled；无 `currentId` 时 `genUuidV4()` 生成会话 ID 走 SSE，服务端自动创建；`deleteSession` 后恢复可输入态（F10）
- **session_ready SSE 事件**: 服务端 `handlePrompt` 在 `is_new` 时回传 `{id, name}`（prompt 命名），`done` 帧并入 `session_id` 兜底（F10）
- **空会话落盘**: `handleSessionCreate` 立即写空 JSONL 文件（UUID 路径 + createDirPath），"New Session" 刷新不消失（F12）
- **模型切换提示**: 已有消息会话切换模型显示 "applies to new sessions only"（F14）
- **浅色主题 token 补全**: accent/state/diff/syntax/overlay/elevation 全量适配 + pre/thinking-block/code 深色适配（F3）

### Fixed
- **Web 模型下拉框初始为空 / 只显示一个模型** (`src/frontends/web/index.html`)
  - 根因 A: `loadModels()` 仅在 SSE done 回调调用，页面初始化只调 `loadSessions()`，首次打开时模型下拉为空 → 初始化同步调用 `loadModels()`
  - 根因 B: `loadSessions()` 在会话列表非空且模型下拉为空时，用 `list[0].model` 往 `#model-select` 插入单个 option → 删除该逻辑，模型列表统一由 `loadModels()` 管理（含 localStorage/Default 回退）
- **剪贴板非安全上下文失效**: `navigator.clipboard` 仅安全上下文可用，局域网 HTTP 下抛 TypeError 且无 catch → `copyText()` 特性检测 + `execCommand` 回退，5 处调用点统一（F1）
- **移动端侧边栏不可达**: `@media(max-width:768px)` 下无 `.open` 切换 + 残留 `sidebar-collapsed` 抵消 transform → 断点分派 + CSS `transform:none` 双保险（F2）
- **`loadSession` 无异常处理**: 会话被删时未捕获 rejection → try-catch 兜底（F13）
- **首运行会话目录缺失**: `handleSessionCreate`/`handlePrompt` 写文件前补 `createDirPath(.zagent/sessions)`
- **工具卡片 done 后消失 + thinking/工具穿插布局**: 根因 A — `tool_start` 挂 `contentDiv`，done 的 `updateMarkdownBlocks` 在无 markdown-key 时 `contentDiv.innerHTML = newHtml` 清空含工具卡片 → 改挂 `asst`；根因 B — `thinking_start` 去重把多阶段思考合并进单块、工具卡片位置不符时间线 → 去除重支持多 thinking 块 + `appendToAsst` 按事件序插入，asst 子元素忠实反映"思考→工具→内容"穿插（实测 思考1→内容→思考2→工具→思考3→工具组）

### Changed
- **复制按钮重构**: `addCopyButton()` 公共函数替代两处重复代码块复制逻辑 + bash Copy cmd 统一走 `copyText`（F5）
- **发送时用户消息索引**: `sendPrompt` 传计算 index（DOM 计数），流式期间禁删消息防 index 漂移（F9）
- **grep 分组摘要**: `N matches` → `N calls`（语义为调用次数）（F6）
- **topbar 初始文案**: "Select a session to start" → "z-agent-core"（F15）
- **下拉框 a11y**: `aria-label="Model"` + `:focus-visible` 焦点环（F4/F8）
- **`buildDonePayload`**: 新增 `session_id` 参数，done 帧携带会话 ID

### Added (2026-08-07)
- **API Key 空值视为未设 + `.env` 回退生效** (`docs/0.2.5/PLAN-FIX-APIKEY-ENV.md`): 新增 `config.resolveApiKey`（进程 env → .env 回退、空值/缺失返回 `ApiKeyNotSet`），`Provider.init` 改为接收已解析 key（不再读环境变量）；`loadDotEnv` 对格式错误行逐行 warning + 行号（无 `=`/空 key/未闭合引号）
- **system prompt `<env>` 块补 Shell/Arch**: 两处 `buildPromptString`（`agent.zig` 核心 + `App.zig` CLI）新增 `Shell: pwsh (PowerShell 7)|sh` 与 `Arch:`，模型据此写对命令语法（实测 `echo %date%` 在 PowerShell 下不展开）

### Refactored
- **Web 前端 parts 模型重构** (`docs/0.2.5/PLAN-STREAM-ORDER-PARTS.md`): `index.html` 拆分为结构 + `app.css`/`app.js`（`handler.zig` 双 marker 注入）；引入 segments 数据模型 + 统一 `renderAssistantMessage`，流式与 reload 双轨合一（根治内容顺序/工具卡片/双轨不一致 DOM bug 类）；`buildSegment`/`ensureTextSegment` 段级精确更新；Node 测试 37 断言
- **斜杠命令体系** (`docs/0.2.5/PLAN-SLASH-COMMANDS.md`): 核心命令注册表 (`src/command.zig`，args_hint 枚举编译期生成) + CLI dispatch + Web `GET`/`POST /api/command`（fork/reset 获 Web 入口，非流式 JSON 信封）+ Web slash popover（`/` 列表/过滤/键盘导航/CSS hover）

### Fixed
- **system prompt `<env>` 块 Web 显示无换行**: `marked` 直通 `<env>` + `DOMPurify` 剥标签后换行仍在 DOM，浏览器 `white-space: normal` 折叠 → `.msg.system` 加 `white-space: pre-line`

## [0.2.4] — 2026-08-06

### Added
- **Web 并发请求**: 线程模型实现多连接并行 (`docs/0.2.4/PLAN-WEB-CONCURRENT.md`)
  - `server.zig`: 主线程 accept → `std.Thread.spawn` + detach，独立 arena/buffer/agent 每连接
  - worker arena 复制 provider config 字符串 (base_url/model/api_key/model_params) + project_root，断开对 `FrontendState` 的依赖
  - `active_threads` 原子计数器 + 主线程退出 30s 超时兜底
- **POST /api/session/:id/abort**: 中断运行中的 LLM 请求
  - `handleAbort`: 通过 `abort_map` (session_id → AgentLoop) 跨线程查找，mutex 锁内调用 `agent.abort()`
  - `handleConnection` 注册最早 defer 作为兜底清理：即使 `handlePrompt` panic 也能从 `abort_map` 移除
- **SSE 连接断开检测**: `SseState.agent` 字段注入 → 所有 SSE write 失败处调用 `agent.abort()` 终止推送
- **Web 前端优化**: 14 项体验改进 (`docs/0.2.4/PLAN-WEB-OPT.md`)
  - Vendor JS 内联注入: `marked.js` + `highlight.js` + `DOMPurify` 编译期嵌入 HTML，Markdown 渲染 + 代码语法高亮 + XSS 净化
  - 字体注入: Inter + JetBrainsMono base64 内联 @font-face
  - 用户消息气泡右对齐 (max-width 85%)
  - 侧边栏拖拽 resize (180-480px)
  - 多行输入: Shift+Enter / Ctrl+Enter 换行
  - 代码块复制按钮 (hover 显 Copy, clipboard API)
  - CSS Token 扩展 (14→30+ 变量: overlay/elevation/state/diff/transition)
  - 工具卡片视觉升级 (边框 + 圆角 + hover 过渡)
  - 消息删除按钮 (hover × → confirm modal → DELETE API)
  - 会话删除自定义 confirm modal (替代浏览器 confirm)
  - 用量页脚: done 事件携带 usage + model, 消息底部显示 token 统计
  - 流式 Markdown: 流式阶段累积 rawContent, done 时 marked.parse + DOMPurify + highlightElement
  - :focus-visible 可访问性 + prefers-reduced-motion
- **Session.removeMessage()**: 原子重写 JSONL 删除指定索引消息
- **DELETE /api/session/:id/message/:index**: 单条消息删除端点
- **SSE 流式实时推送**: `SseWriter` 新增 `flushFn` + `flush()` 方法，每次 SSE 帧写入后立即 flush TCP 缓冲 (`docs/0.2.4/PLAN-WEB-FIX-STREAMING.md`)
- **done 事件首条消息**: `buildDonePayload` 新增 `first_message` 字段，携带完整 session 首条消息 JSON，前端 `done` 事件直接渲染
- **系统消息声明式渲染**: `#system-prompt` 独立容器 + `renderSystemPrompt()` 函数，`loadSession` 和 `done` 事件共用同一入口
- **服务器日志模块**: `src/util/log.zig` — 结构化 `key=value` 输出，5 级，毫秒时间戳，线程/请求 ID (`docs/PLAN-LOGGING-MODULE.md`)

### Changed
- `handler.zig` `serveIndex`: 动态构造 HTML 响应, 注入 @embedFile 资源
- `handler.zig` `handlePrompt` done 事件: 新增 `usage` + `model` 字段
- `handler.zig` DELETE 路由: 支持 session 删除 + 消息删除子路由
- `handler.zig` Context: 新增 `abort_map` + `abort_mutex` + `current_abort_session` 字段
- `handler.zig` `handlePrompt`: runTurn 前在 mutex 内注册 `abort_map`，defer 清理 + 置 null `current_abort_session`
- `sse.zig` `SseState`: 新增 `agent` 字段；8 处 SSE write 失败 `catch {}`/`try` 改为调用 `agent.abort()`
- `core/agent.zig` `abort()`: `_aborted` 改为 `std.atomic.Value(bool)` (`.store(true, .release)`) + 新增 `signal.setInterrupted()` 桥接 provider 中断检测
- `core/agent.zig` `finishTurn`: `.interrupted` 时 `.store(false, .release)` 重置原子标志 + `signal.reset()` 清除全局中断
- `core/agent.zig`: 新增 `_aborted_bool` 字段供 ToolContext.abort_target 兼容（原子类型不能直接作为 `*bool`）
- `io/provider.zig`: 删除两处 `child.kill(io)` 的 `builtin.os.tag != .windows` 守卫 — Windows 上中断/Ctrl+C 现在也强制终止 curl 子进程
- `io/provider.zig`: `child.kill(io)` 移除 `catch {}` — Zig 0.16 中 kill 返回 void
- `sse.zig` `SseWriter`: 新增 `flushFn` 字段 + `flush()` 方法；`sseWriterFrom` 生成 flush 闭包
- `sse.zig` `writeFrame`/`writeTextDelta`: 每次写后调用 `self.w.flush()`
- `sse.zig` `writeFrame`: 栈缓冲 512 → 4096 — 修复 done 帧含系统消息时 `NoSpaceLeft` 导致 500
- `handler.zig` `buildDonePayload`: 新增 `allocator` 参数 + `first_message` 字段
- `handler.zig` `handlePrompt`: SSE 头后显式 `sw.flush()` + done 帧降级兜底（payload 过大时仅发 `new_messages`）
- `handler.zig` Context: 新增 `thread_id` + `request_id` 字段
- `server.zig`: 新增 `next_thread_id`/`next_request_id` 原子计数器 + `log.init()` 初始化
- `server.zig`: 移除 `printStderr`/`printStderrFmt`，替换为 `log.*` 调用
- `server.zig`: 新增 `--port <port>` / `--address <ip>` 参数，支持自定义 Web 监听地址和端口
- `server.zig`: 绑定 `0.0.0.0` 时自动解析本机主机名，日志额外显示局域网访问 URL (`lan=http://...`)
- `cli/main.zig`: 帮助文本新增 `--port` / `--address` 说明
- `util/log.zig`: 日志时间戳从 UTC 改为本地时间 (Windows: `kernel32.GetLocalTime`, POSIX: 保留 UTC 回退)
- `index.html`: 侧边栏折叠 (`transform:translateX(-100%)`) + localStorage 持久化 (`☰` 按钮在 topbar 始终可见)
- `index.html`: h1 居中 + 副标题行, 模型选择器移至 sidebar 底部 (`#model-selector`)
- `index.html`: 模型下拉切换 (调 `GET /api/model`) + localStorage 持久化, API 失败时降级到缓存
- `index.html`: 会话名超长截断 (`text-overflow:ellipsis`), 用户消息自适应宽度气泡 (`fit-content`)
- `index.html`: 系统消息 markdown 渲染 (`marked.parse`) + thin 滚动条 (Firefox + WebKit)
- `index.html`: 工具卡片默认折叠 + done 后 markdown 渲染 + ≥3 工具时显示全部展开/折叠按钮
- `handler.zig`: `handleSessionCreate` 支持 POST body `model` 参数 (可选, 默认 `config.default_model`)
- `handler.zig`: `handlePrompt` 新建 session 用 prompt 首 30 字符命名 + 修复侧边栏 UUID 显示
- `handler.zig`: 新增 `GET /favicon.ico` 路由 (返回 `@embedFile("../../Logo.ico")`)
- `uuid.zig`: 新增 `isUuid()` 精确 v4 检测 (长度36, 短横位置, 版本位4, 变体位8/9/a/b)

### Added (P0+P2 — 渲染数据增强)
- `handler.zig` `formatMessageJson`: 补全 `reasoning_content`/`tool_calls`/`tool_call_id`/`usage`/`model` 字段 — 消灭 reload 后 thinking+tool 数据丢失 (G3)
- `index.html` `addMessage`: 重建 thinking 块 (markdown) + tool_call_id 匹配工具名 (G1/G2/P2-1)
- `index.html` ToolRegistry: bash 专属 Copy cmd 按钮 + 类型化扩展点 (P2-2)
- `sse.zig` `renderTool` + `serializeMeta`: `tool_meta` SSE 事件发送 ToolMeta (exit_code/byte_count/match_count 等) (P2-3)
- `index.html`: `hljs.highlightAll()` 激活语法高亮 (done 事件 + addMessage) — 消灭死代码 (G5)
- `sse.zig` `renderTool`: 工具参数 `tool_args` 前置为 ```input 代码块 (P0)

### Added (G8/G9/G11 — 工具视图 + 消息操作)
- `index.html` ToolRegistry: read/write/edit/grep/glob/skill 群类型化视图 (图标 + meta) (G8)
- `index.html` `wrapContextToolGroups`: 连续 read/grep/glob ≥2 自动合并为折叠组 (G9)
- `index.html` MessageAction: user 消息 hover 显 revert/copy/× 操作栏 (G11)
- `sse.zig` `serializeMeta`: 补全 write.existed/grep.truncated/glob.truncated/bash.truncated 字段
- `index.html`: 新增 `#system-prompt` 容器 + `renderSystemPrompt()` + CSS；`done` 事件渲染系统消息

### Known Gaps（下版候选）
- Web 端 `PATCH /api/session/:id/fork`、`/reset` 端点待实现（承自 v0.2.3）
- CLI `/delete <id>` 命令待实现
- `.zagent/sessions` 路径 4+ 处硬编码待常量化
- 会话列表分页、侧边栏 DOM diff、Web CRUD 冒烟测试（见 `docs/PLAN-FUTURE-SESSION-IMPROVEMENTS.md`）

## [0.2.3] — 2026-07-30

### Added
- **Web 前端 MVP**: `src/frontends/web/` — 基于 `std.http.Server` + `@embedFile` 的单二进制 Web UI
  - `server.zig`: TCP 监听 + `--web` / `--root` 入口，项目根目录三级解析 (CLI参数/环境变量/CWD查找)
  - `handler.zig`: 线性路由分发，10 个 RESTful 端点 (health/model/provider/session CRUD)，per-request arena 防泄漏
  - `sse.zig`: SSE 帧构造 + `PhaseWriterCb`/`ToolDisplayCb` 回调映射 (9 tests)
  - `error.zig`: 统一 JSON 错误响应 (`{error:{code,message}}`, 5 种 ErrorCode)
  - `api_types.zig`: 请求/响应 struct
  - `index.html`: 侧边栏 + 对话流单页 Web UI
  - `vendor/`: Inter/JetBrainsMono 字体 + marked.js + highlight.js + DOMPurify (~819KB, @embedFile 内联)
- **CLI**: `--web` 启动 Web 前端, `--root <path>` 指定项目根目录, `--help` 更新
- **Web 会话管理 CRUD 补齐**:
  - `Context.sessions_dir` 字段 — 消除多 handler 重复路径构造
  - `Session.deleteFile(io, path)` — 核心层文件删除（与 `load` 参数模式对齐）
  - `PATCH /api/session/:id` — 重命名端点，读取 JSON body，调用 `session.rename()` + `flush()`
  - `DELETE /api/session/:id` — 删除端点，含路径穿越防护
  - `isValidSessionId()` — 拒绝含 `.` `/` `\` 的 session ID（路径穿越防护，GET/PATCH/DELETE 全覆盖）
  - **前端双击重命名** — 双击会话名 → input 编辑 → PATCH 提交 → 错误恢复（DOM 不卡死）
  - **前端删除按钮** — × 按钮，确认后 DELETE + 清空对话区
  - **新建会话去重** — 已有空会话（name="New Session", msg_count=0）时复用
  - **前端时间分组** — Today / Yesterday / This Week / Older 四组 CSS 时间窗口（DST 安全）
  - **空会话列表提示** — 无会话时显示 "No sessions yet"
  - **新建按钮修复** — `sess.status === 'created'` → `sess.id` 判断
  - **系统提示词归位核心层** — `AgentLoop.runTurn()` 自动注入完整 system prompt（身份 + AGENTS.md + skills），Web/CLI 双前端统一。`SystemPromptCb` 简化为仅追加交互模式提示
  - **UUID v4 会话 ID** — `src/util/uuid.zig`，`handleSessionCreate` 改用随机 ID 替代时间戳
  - **核心层安全校验** — `Session.isValidId()` 路径穿越防护，拒绝 `.` `/` `\`；`DEFAULT_SESSION_NAME/FILENAME` 常量化
- **测试**: +9 SSE 测试 + 3 error 测试 (via test.zig)
- **合计**: 197 test blocks (196 pass, 1 pre-existing fail)

### Fixed
- **CLI 静默退出**: `main.zig` 初始化错误 `catch return` 无任何输出，改为调用 `reportInitError` 输出原因到 stderr
- **错误处理 DRY**: 新增 `init.zig` `reportInitError()` 统一出口，CLI 和 Web 双前端共用，消除手写复制
- **3 处 `catch unreachable` 潜在 crash**: `session.zig` 时间戳格式化 OOM、`App.zig` 模型解析失败两次调用，改为 `try` 或 `return error`
- **8 处静默吞错**: `.env` 加载失败、`session.flush` 失败（Web ×2）、JSONL 行损坏、SSE 解析错误、`bufPrint` 溢出、`flush` 警告截断、`openDir` 权限错误 — 均新增 stderr 诊断
- **会话加载 500 错误**: `formatMessageJson` 固定 1024 字节缓冲区溢出（系统消息 2000+ 字符）→ `escapeJsonDynamic` arena 动态分配
- **幽灵错误名 `error.SessionNotFound`**: 3 处 handler 检查的错误从未被任何模块返回 → `error.FileNotFound` + `error.InvalidSessionId`
- **`{d}` 对有符号整数加 `+` 前缀**: `epochToISO8601` 中 `i64` 强转 `u32` 后格式化，修复时间戳往返解析失败
- **合计**: 11 处错误处理加固，0 处静默吞错回归

### Known Gaps
- 并发连接 (Group.concurrent) 降级为顺序 accept，MVP 单用户无需求
- `PATCH /api/session/:id/fork`, `/reset` 待实现

## [0.2.2] — 2026-07-23

### Added
- **协议适配层**: types.zig 新增 ModelCompat/Override、ThinkingFormat(7种)/ThinkingLevel(7级)/MaxTokensField、detectCompat() URL 启发式推断
- **兼容 7 种 thinking JSON 格式**: thinking_object(DeepSeek)、reasoning_effort(OpenAI)、enable_thinking_bool(Qwen)、thinking_parameters(Aliyun)、thinking_with_budget(Anthropic)、thinking_config_object(Gemini)、none
- **CLI + REPL 思考强度**: `--thinking <level>` 参数 + `/thinking` REPL 命令 (none/minimal/low/medium/high/xhigh/max)
- **reasoning_content 独立字段**: Message + ProviderResponse 新增 `reasoning_content: ?[]const u8`，SSE 分离 reasoning_buf + session 序列化/反序列化
- **buildJsonBody 条件回传**: DeepSeek compat 模式下 tool-call 回合才回传 reasoning_content
- **system prompt 前缀稳定**: spRebuild 冻结 (_env_changed 标志) + buildPromptString 移除日期/CWD
- **/load 完整回放渲染**: 思考→内容相位管线 + Markdown→ANSI 渲染
- **bash 工具增强**: ANSI escape 过滤 (0x1B[..m) + `"(no output)"` + `"Command exited with code N."` + workdir 参数
- **错误分类**: isAuthError/isHtmlError/isStreamOptions400Error 基于体内容匹配（不依赖 HTTP 状态码）
- **stream_options 400 自动回退**: 内部一次重试，!declined 守卫防无限循环
- **/list 显示 session ID**: 三列格式 `{id} "{name}" {model}`，可直接 `/load <id>`
- **single-shot 交互提示**: buildPromptString 新增 `single_shot` 参数，单次模式向 `<env>` 块注入 "no user interaction possible" 提示
- **测试**: +10 个 buildJsonBody compat 测试、+6 个 types detectCompat 测试、+4 个 config compat 测试、+3 个 bash 工具测试、+2 个 single-shot 提示测试、+4 个 edit 工具测试 (via test.zig)
- **合计**: 185 个 test block（184 pass, 1 pre-existing fail）

### Changed
- **流式相位**: 单 in_content_phase → thinking_started/text_started 双独立标志（修复 Qwen 闪烁 + 支持交错式推理）
- **错误处理**: 增强溢出检测（usage+长度双估计 + 20K 预留缓冲）、classifyError 5 类体内容匹配、isRetryableBody/isRetryableError 扩增
- **DEFAULT_TEMPLATE**: params_json → [models.compat] 子表 + thinking_level 顶层键
- **Config**: 新增 resolveCompat() 合并函数、parseThinkingFormat/parseMaxTokensField 枚举解析
- **lookupModel**: 倒序遍历替代正序 for，重复 (provider, id) 条目后写覆盖前写
- **/ 命令输出标签**: /help、/list、/name、/new 输出统一使用 render.writeLabeled 添加彩色标签

### Fixed
- 标签统一: labelColor() 单一事实来源
- ANSI dim 污染: 6 个标签函数防御性前置 `C.reset`
- /list 与 /load 不一致: /list 新增 ID 列
- render.zig format 字符串参数数量: writeLabelBegin 补齐格式说明符
- ANSI 行尾冗余 C.reset: renderLine 移除代码块/标题/引用块/行内格式末尾的 C.reset
- Windows 盘符大小写: normalize() 盘符统一转大写
- **FIX-1**: `build.zig` check-arch.mjs 路径 `../../` → `../`；AGENTS.md 路径和行数描述修正；REMAINING.md 标记 PHASE-3/4 完成；PLAN-PHASE-3/4-COMPAT/CACHE 状态头更新；edit.zig 加入 test.zig；清理空目录 src/crash-test.zig/
- **FIX-2**: `build.zig` 删除 check step (Node.js 依赖) 和 test step (GPA 死锁)；60 行 → 30 行；README.md/AGENTS.md 命令描述更新；zig-dev skill 移除 build.zig 集成模板

### Refactored
- **skill-forge v0.2.1 → v0.2.2**: P0 自检 + 审查清单新增跨工具链耦合检测
- **zig-dev v1.0.1 → v1.0.2**: 移除 project-layout.md/setup.md/SKILL.md/test-pattern.md 中的 build.zig 集成模板

## [0.2.1] — 2026-07-20

### Added
- **OPT-6: 用量数据显示增强**
  - `types.zig`：`TokenUsage` 新增 `cache_hit`、`cache_miss`（`?u32` nullable）
  - `io/provider.zig`：SSE `usage` 解析缓存命中等字段，`if (usage) |*u|` 守卫避免空指针
  - `core/session.zig`：JSONL 序列化/反序列化缓存字段，`null` 省略、`0` 显式写入、加载缺失回 `null`
  - `frontends/cli/App.zig`：新用量显示格式——动态单位 K/M、缓存命中率、上下文窗口占比、中断回合跳过
  - `formatToken()`：栈缓冲零堆分配 token 数格式化

### Fixed
- `context_window` 从 131072 修正为 DeepSeek V4 官方规格 1000000
- `validateConfig` 增加友好 stderr 错误消息，指明具体 provider/model 问题；`main.zig` 捕获全部 config 错误避免栈回溯

## [0.2.0] 

进行了运行时健壮性改进，CLI 可以简单使用

### Added
- **OPT-5: 运行时稳定性（P0-2）API 重试增强**
  - `io/provider.zig`：重试次数 3→5，退避 500ms→1s→2s→4s→8s；错误分类（`isRetryableError`/`isRetryableBody` 检测 rate limit/503 → `error.ApiRateLimited` 可重试）；PhaseWriter 替代 stderr 输出重试状态
  - `io/provider.zig`：新增 `containsIgnoreCase` 辅助函数用于 case-insensitive 错误分类
- **OPT-5: 运行时稳定性（P0-1）上下文压缩**
  - `tool/compact.zig`：全新 compact 工具——API 摘要生成 + session 消息替换（保留 system prompt + 最近 N 条 + 摘要）
  - `core/agent.zig`：`runTurn` 入口累计 token 检查（超出 context_window 85% 阈值时注入系统警告）
  - `core/session.zig`：新增 `updateFirstSystem()` 方法（替换/前插 system 消息）
- **OPT-5: 运行时稳定性（P1-3）死循环检测**
  - `core/agent.zig`：StormBreaker — FIFO 队列（容量 5）记录工具调用 `{name, args_hash}`；连续 3 次相同追加 system 警告
- **OPT-5: 运行时稳定性（P1-4）工具上下文增强**
  - `types.zig`：`ToolContext` 新增 `messages`、`session_ref`、`provider_ref` 字段（anyopaque 避免循环依赖）
- **OPT-5: 运行时稳定性（P1-5）每步重组系统提示**
  - `core/agent.zig`：新增 `SystemPromptCb` 回调；`runTurn` 入口调用 `system_prompt.rebuild()`
  - `core/session.zig`：新增 `updateFirstSystem()` 方法
  - `frontends/cli/App.zig`：`buildSystemPrompt` 改为 `buildPromptString` 返回字符串；通过回调注册替代 init 时一次性构建
- **OPT-3: 工具输出结构化（ToolMeta）**
  - `types.zig`：新增 `ToolMeta` union（write/read/grep/bash/glob/skill/edit 共 7 个 variant + none）；`ToolResult` 新增 `meta` 字段
  - `tool/registry.zig`：集中 `parseFromSlice`（工具接收 `std.json.Value` 替代原始 JSON 字符串）；`ToolEntry` 新增 `validate` 回调
  - `tool/edit.zig`：全新 edit 工具——oldString→newString 精确替换 + diff 预览 + replaceAll 开关 + 多处匹配保护
  - `frontends/cli/render.zig`：`toolMetaLabel()` 从 meta 构建标签，meta.none 回退 `labelFromValue`
  - `core/agent.zig`：`ToolDisplayCb.render` 新增 `err_msg` + `meta` 参数；render 错误降级（catch {} 继续）；工具错误路径也走 display；新增 `begin_tool` 回调
  - `core/agent.zig`：`RoundResult` 新增 `error_msg: ?[]const u8`，API 错误显示实际原因而非通用标签

### Changed
- **OPT-3: 工具增强**
  - `tool/read.zig`：offset 超界报错、分页元数据（next_offset）、单行截断 2000 字符、扩展名黑名单 33 项、全文件 UTF-8 校验、limit=0 仅返元信息
  - `tool/write.zig`：`meta.write` 填 existed/new_lines/byte_count
  - `tool/bash.zig`：`meta.bash` 填 exit_code/byte_count/truncated/command；MAX_OUTPUT 50KB→512KB；stderr 加 `[stderr]` 前缀；二进制输出检测（>30% 控制字符替换为摘要）
  - `tool/grep.zig`：`meta.grep` 填 match_count/files_scanned/truncated；path 改为可选（默认 project_root）`GrepResult` 结构化返回
  - `tool/glob.zig`：`meta.glob` 填 pattern/file_count/truncated
  - `tool/skill.zig`：`meta.skill` 填 name/file_count
  - 全部工具：删除内部 JSON 解析模板（每工具 -10 行）；`execute(ctx, args: Value)` 替代 `execute(ctx, args: []const u8)`

### Fixed
- **OPT-3.1: Bug 修复**
  - `tool/edit.zig`：`buildDiff()` 字节截断可能切碎多字节 UTF-8 → `truncateUtf8()` 回退到码点边界
  - `tool/bash.zig`：二进制输出垃圾字节撑爆终端 → 检测后替换为 `[binary output: N bytes]`
  - `frontends/cli/render.zig`：路径标签字节截断 `zig-regex\d` 误导 → `truncatePath()` 左截断 `...tail`
  - `frontends/cli/render.zig`：bash user_output 控制字符乱码 → 打印前过滤 `\x00-\x08` 等

### Refactored
- `frontends/cli/render.zig`：`LineBuffer` 新增 `raw_mode` 字段，思考内容跳过 Markdown 渲染（I1）
- `frontends/cli/render.zig`：`MessageType` 新增 `usage`，`writeLabeled(.usage)` 显示 token 统计
- `frontends/cli/App.zig`：每轮结束后显示 token 用量（输入/输出/累计/窗口上限）

## [0.1.0] 

本版本引入前后端分离架构、回调 API 清理和核心功能增强。

### Added
- **Phase 2 核心 API**
  - `core/agent.zig`：`ToolHooks`（before/after 工具拦截）、`abort()` 取消方法、`LifecycleCb`（on_turn_start/end）
  - `core/agent.zig`：`finishTurn()` 统一退出点（生命周期回调 + abort 重置）
  - `core/agent.zig`：`agent.abort()` 替代全局 `signal.isInterrupted()`，解除 `core/ → util/` BIDIR
  - `core/session.zig`：`writeTo()` 方法（temp+rename 原子写入，供 /fork 使用）
  - `core/session.zig`：`TokenUsage` JSONL 序列化/反序列化（input/output/total）
  - `types.zig`：`TokenUsage` struct（input/output/total）、`ApiEndpoint` struct（base_url/api_key/model）
  - `types.zig`：`ToolContext` 新增 `api_endpoint` + `abort_target` 字段
  - `types.zig`：`ProviderResponse` + `Message` 新增 `usage: ?TokenUsage` 字段
  - `io/provider.zig`：SSE [DONE] 帧 TokenUsage 解析（`parseFromSliceLeaky(Value, ...)` 安全访问）
  - `frontends/cli/App.zig`：Ctrl+C → `agent.abort()` 桥接（Solution A: App 层轮询 + signal.reset）
  - `frontends/cli/App.zig`：`/fork <name>` REPL 命令（原子写入 + 自动切换 + 文件名消毒）

### Changed
- **Phase 0 & 1: 前后端分离**
  - CLI 文件从 `src/App.zig`, `src/main.zig`, `src/render/cli.zig` 移至 `src/frontends/cli/`
  - `src/main.zig` 改为 4 行 shim 入口（Zig 0.16 module root 约束）
  - `ToolDisplayCb.render` 移除 `*Io.Writer` 参数，返回 `!void`（`writer` 移至 `ToolDisplay.writer` 上下文）
  - `TurnFinish` 新增 `render_error` 枚举值
  - `stdout_dead_ptr` 全局标志已移除（由 `render_error` 替代）
- **Phase 0D: 模型注册表**
  - `Model.reasoning: bool` → `params_json: ?[]const u8`（TOML 配置 JSON 片段，Provider 盲拼）
  - `io/provider.zig`：`buildJsonBody()` 无条件拼接 `model_params`，不再硬编码 thinking
  - `.zagent/config.toml`：`reasoning = true` → `params_json = "\"thinking\":{\"type\":\"enabled\"}"`
- **Agent 中断机制**
  - `core/agent.zig`：移除 `signal` import（零 BIDIR），`_aborted` 替代 `signal.isInterrupted()`
  - `util/signal.zig`：保持不变；App 层桥接信号到 agent.abort()
- **工具标签统一**：`frontends/cli/render.zig` `labelFromValue` 所有 6 个工具统一显示工具名前缀（`Read`/`Write`/`$`/`Grep`/`Glob`/`Skill`），grep/glob 同时显示 pattern + path

### Fixed
- `io/provider.zig`：`params_json = ""` 空字符串导致 JSON 双逗号 `,,` 非法请求体（加 `len > 0` 守卫）
- `io/provider.zig`：TokenUsage SSE 解析 `.?` 不安全访问 → `if` 链安全读取
- `core/session.zig`：TokenUsage JSONL 反序列化 `.?` → `if` 链安全读取
- `core/agent.zig`：`LifecycleCb.on_turn_end` 在 `try` 错误路径不触发 → 加 `errdefer`
- `frontends/cli/render.zig`：`ToolDisplay.render` null summary fallthrough 打印 `session_content` 全文 → 移除 else 分支
- `frontends/cli/App.zig`：`processLine` 双重 flush（错误路径 flush 截断的 session）→ 删除多余 flush
- `frontends/cli/App.zig`：`sanitizeForkName` 缺少 `errdefer buf.deinit()` → 已添加
- `tool/bash.zig`：`action` 字段包含完整命令字符串（可能极长）→ 截断到 60 字符
- `tool/grep.zig, write.zig, glob.zig, skill.zig`：`summary` 错误路径 echo raw `args_json` → 改为 null

- **Frontend 显示间隙**（PLAN-OPT-2-DISPLAY-GAPS.md）
  - `frontends/cli/render.zig`：`labelFromValue` grep/glob 同时显示 pattern + path（`Grep "pattern" path` / `Glob pattern [path]`）
  - `frontends/cli/render.zig`：所有 6 个工具的标签统一显示工具名前缀（`Read`/`Write`/`$`/`Grep`/`Glob`/`Skill`）
  - `core/agent.zig`：达到 `max_tool_rounds` 时向 session 追加 system 消息告知 LLM 约束
  - `frontends/cli/App.zig`：`processLine` + `singleTurn` 中添加 `.max_rounds` 警告显示
  - `types.zig`：`ToolResult` 新增 `user_output: ?[]const u8` 字段（零拷贝借用视图，deinit 不释放）
  - `frontends/cli/render.zig`：`ToolDisplay.render` 打印 `user_output`（非 null 时）
  - `tool/bash.zig`：设置 `.user_output` 为前 4096 字节输出；删除死代码 `shortCmd`
  - `tool/bash.zig`：`MAX_USER_OUTPUT = 4096` 命名常量替代魔数

### Changed
- **ToolResult 字段重命名**：`display_label` → `action`，`display_summary` → `summary`（消除 display_ 对渲染职责的误导）
- **ToolResult 数据-展示分离**：移除 `action`/`summary` 字段，工具只返回 `session_content` + `err_msg`。`ToolDisplayCb.render` 改为接收 `tool_name` + `tool_args` + `had_error`，前端 `toolLabel()` 从 args JSON 提取显示文案
- **工具标签颜色**：`bg_bright_cyan`（低对比度）→ `bg_bright_magenta`（105m 紫底白字）
- **LLM 输出流式**：`LineBuffer.feed()` 尾部内容即时输出（不再等换行），typewriter 观感
- **DeepSeek 模型**：`deepseek-chat` + `deepseek-reasoner` 已于 2026/07/24 弃用，模板仅保留 v4-pro + v4-flash
- **配置模板**：`DEFAULT_TEMPLATE` 添加完整字段注释、`params_json` 格式说明、Ollama 添加示例、损坏恢复提示

### Refactored
- `documentation`：`CORE-FRONTEND.md`（前后端分离架构规范）、`PLAN-PHASE2.md`（Phase 2 实施规格）、`PLAN-OPT-1-TOOLRESULT-SPLIT.md`（数据-展示分离方案）、`PLAN-OPT-2-DISPLAY-GAPS.md`（前端显示间隙修复方案）、`REMAINING.md`（剩余工作跟踪）
- `core/agent.zig`：移除 `tool_display` 死字段；`ToolDisplayCb.render` 不再传递 `ToolResult`
- 消除 `core/ → util/` 目录级 BIDIR（agent.zig 不再 import signal.zig）
- 文档同步：`CORE-FRONTEND.md` ToolDisplayCb 签名更新为当前解构参数；`PLAN-PHASE2.md` 修正 6 处过时行号引用；`render.zig` 移除 `stdout_dead` 残留注释
- `tool/bash.zig`：移除死代码 `shortCmd`（工具不再构建 action/summary 字符串）

### Tests
- agent.zig：新增 7 个 test block（hooks before blocks/allows、hooks after fires、abort before runTurn/abort resets、lifecycle on_turn_start/on_turn_end fires）
- **合计**：148 个 test block（+8 vs 0.0.1-alpha）

## [0.0.1-alpha]

基础核心完成

### Added
- 项目脚手架：`main.zig`、`App.zig`、`build.zig`（编译 + `check-arch` 集成）
- `types.zig`：共享类型定义（Message、Role、ToolCall、Tool、ToolContext、Model、ProviderEntry、Api、InputModality）
- `util/signal.zig`：Ctrl+C 原子标志 + `init(io)` Windows `SetConsoleCtrlHandler` 注册
- `util/text.zig`：trim 工具函数
- `util/path.zig`：`resolvePath()` 路径规范化 + 防穿越校验
- **Step 1** — 配置系统
  - `toml.zig`：从 z-agent 迁移轻量 TOML 解析器（12 个内置 test）
  - `config.zig`：Config 加载 + ArenaAllocator 所有权模型 + 模板自动生成
  - `config.zig`：`findZagentRoot()` 向上遍历查找 `.zagent/config.toml`
  - `config.zig`：`loadDotEnv()` 解析 `.zagent/.env`
  - `config.zig`：`resolveModel()` "provider/model_id" 查找
  - `config.zig`：`validateConfig()` 全字段校验
- **Step 2** — OpenAI 兼容 API 客户端
  - `io/provider.zig`：Provider 客户端 + curl 子进程 + SSE 流式解析 + 指数退避重试
  - `io/provider.zig`：`buildJsonBody()` 手动 JSON 构建含 `appendEscapedJsonString` 安全转义
  - `io/provider.zig`：DeepSeek vendor 自动检测 + `thinking` 推理字段注入
  - `io/provider.zig`：Windows 适配（`kernel32.Sleep`、`child.kill` ZIG-WIN-001 守卫）
- **Step 3** — 工具系统
  - `tool/registry.zig`：Registry + `buildRegistry()` + `toTools()` 注册表
  - `tool/read.zig`：文件读取（UTF-8/Binary 检测、目录浏览、offset/limit、路径穿越校验）
  - `tool/write.zig`：文件创建/覆写（自动创建父目录、内容大小限制）
  - `tool/bash.zig`：子进程执行（stdin pipe + stdout 截断）
  - `tool/grep.zig`：正则内容搜索（行号+上下文）
  - `tool/glob.zig`：文件名 glob 匹配
  - `tool/skill.zig`：`.zagent/skills/*/SKILL.md` 加载
- **Step 4** — 线形会话
  - `core/session.zig`：Session + init/load/append/flush/rename/deinit/list + `popLast()` 回滚
  - `core/session.zig`：Arena 统一内存管理 + errdefer 泄漏保护
  - `core/session.zig`：JSONL 序列化/反序列化（header 行 + 消息行 + null 字段省略）
  - `core/session.zig`：>50 条消息 stderr 告警 + `rename` 碰撞 `-n` 后缀处理
- **Step 5** — Agent 单轮执行引擎
  - `core/agent.zig`：AgentLoop 状态机 + Mock ChatFn 注入（5 个 test）
- **Step 6** — CLI 渲染
  - `render/cli.zig`：ANSI Color + `writeLabeled()` + `renderLine()` Markdown→ANSI
  - `render/cli.zig`：`visibleWidth()` CJK 检测 + Windows VT 启用（extern "kernel32"）
- **Step 7** — CLI REPL 集成
  - `App.zig`：CLI REPL（325 行）— `buildSystemPrompt()` + `readLine()` + 单次/REPL 双模式
  - `App.zig`：`/exit` `/quit` `/new` 命令 + runTurn 失败回滚（popLast + writeLabeled）
  - `app.deinit()`：session→cfg→project_context→tools→session_dir 全量释放
  - `main.zig`：Zig 0.16 `Args.Iterator` 参数解析 + 错误处理
  - `src/Logo.ico` + `src/Logo.rc`：Windows 应用图标（`build.zig` 通过 `addWin32ResourceFile` 嵌入）

### Changed
- 无 `.zagent/` 目录时自动以 CWD 为 project_root 并创建默认模板（原为报错退出）
- 默认模板精简：移除 openai provider + gpt-4.1 model，仅保留 deepseek
- `App.init()`：`findZagentRoot` 返回 null 时回退到 CWD
- `config.zig`：启动横幅改为 `z-agent-core v{VERSION} | {ModelDisplay} | {Provider}`
- `config.zig`：两个 banner 输出点加入 `flush()` 解决 stderr 缓冲区丢失
- 版本号统一：`build.zig` + `types.zig` 同步为 `0.0.1-alpha`
- `config.zig`：测试 `findZagentRoot` 断言修正（项目自身有 `.zagent/`，basename 为 `z-agent-core` 而非 `ZigWorkspace`）
- `types.zig`：`Tool.execute` 签名统一为 `fn(ctx: ToolContext, args)`
- `types.zig`：`Model` 新增 `provider: []const u8` 字段（支持平铺 `[[models]]` 格式）
- `types.zig`：新增 `ProviderResponse` + `FinishReason` 类型
- `types.zig`：`Message.tool_calls` 类型改为 `?[]const ToolCall`
- `types.zig`：`Message` 新增 `timestamp: i64` + `model: ?[]const u8` 字段
- `types.zig`：新增 `SessionInfo` struct
- `render/cli.zig`：Windows API 声明从 `std.os.windows.kernel32` 迁移到 `extern "kernel32"`

### Tests
- toml.zig：12 个 test block
- config.zig：22 个 test block
- provider.zig：11 个 test block
- session.zig：17 个 test block（含 popLast ×2）
- agent.zig：5 个 test block
- registry.zig：3 个 test block
- read.zig：6 个 test block
- write.zig：4 个 test block
- bash.zig：2 个 test block
- grep.zig：2 个 test block
- glob.zig：2 个 test block
- skill.zig：2 个 test block
- signal.zig：3 个 test block（含 init test）
- render/cli.zig：23 个 test block
- text.zig：2 个 test block
- path.zig：10 个 test block
- **合计**：140 个 test block
