# Changelog

## [0.1.0] - 未发布

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

### Changed
- **ToolResult 字段重命名**：`display_label` → `action`，`display_summary` → `summary`（消除 display_ 对渲染职责的误导）
- **ToolResult 数据-展示分离**：移除 `action`/`summary` 字段，工具只返回 `session_content` + `err_msg`。`ToolDisplayCb.render` 改为接收 `tool_name` + `tool_args` + `had_error`，前端 `toolLabel()` 从 args JSON 提取显示文案
- **工具标签颜色**：`bg_bright_cyan`（低对比度）→ `bg_bright_magenta`（105m 紫底白字）
- **LLM 输出流式**：`LineBuffer.feed()` 尾部内容即时输出（不再等换行），typewriter 观感
- **DeepSeek 模型**：`deepseek-chat` + `deepseek-reasoner` 已于 2026/07/24 弃用，模板仅保留 v4-pro + v4-flash
- **配置模板**：`DEFAULT_TEMPLATE` 添加完整字段注释、`params_json` 格式说明、Ollama 添加示例、损坏恢复提示

### Refactored
- `documentation`：`CORE-FRONTEND.md`（前后端分离架构规范）、`PLAN-PHASE2.md`（Phase 2 实施规格）、`PLAN-TOOLRESULT-SPLIT.md`（数据-展示分离方案）
- `core/agent.zig`：移除 `tool_display` 死字段；`ToolDisplayCb.render` 不再传递 `ToolResult`
- 消除 `core/ → util/` 目录级 BIDIR（agent.zig 不再 import signal.zig）

### Tests
- agent.zig：新增 7 个 test block（hooks before blocks/allows、hooks after fires、abort before runTurn/abort resets、lifecycle on_turn_start/on_turn_end fires）
- **合计**：148 个 test block（+8 vs 0.0.1-alpha）

## [0.0.1-alpha] - 2026.07.10

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
