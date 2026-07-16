# Changelog

## [0.2.1] - 未完成

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
