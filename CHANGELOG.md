# Changelog

## [0.1.0] - 未完成

本版本标志着项目核心已经可用可以进行进一步的功能优化。

### Added
- Windows 应用图标（`src/Logo.ico` + `src/Logo.rc`，`build.zig` 通过 `addWin32ResourceFile` 嵌入）
- 版本号统一：`build.zig` 单一定义，通过 `build_options` 模块注入运行时，支持 `-Dversion=` 覆盖

## [0.0.1-alpha] - 2026.07.10

本版本为项目初始创建版本

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
