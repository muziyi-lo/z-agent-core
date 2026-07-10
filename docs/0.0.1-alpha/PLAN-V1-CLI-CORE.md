# z-agent-core V1 — CLI 核心循环

> 从 z-agent 的屎山经验中提炼：先建结构，后写代码。CLI only，不碰 TUI。

## A. 源码依据

| 文件 | 用途 |
|------|------|
| `zig/zig/lib/std/` | Zig 0.16.0 标准库 API 参考 |
| `projects/z-agent/src/agent.zig:974` | AgentLoop 状态机参考（去除 TUI/CaptureWriter 耦合） |
| `projects/z-agent/src/provider/openai_compat.zig:891` | OpenAI 协议 + curl 子进程 + SSE 流式解析（去除 TUI 日志耦合） |
| `projects/z-agent/src/session.zig:759` | 线形会话 append/flush（去除会话树/记忆系统） |
| `projects/z-agent/src/config.zig:1102` | TOML 解析 + zagentRoot 查找（去除权限系统耦合） |
| `projects/z-agent/src/tool/registry.zig:152` | 工具注册表 match/execute |
| `projects/z-agent/src/tool/{read,write,bash,grep,glob}.zig` | 工具实现参考 |
| `.opencode/learnings/LEARNINGS.md` | z-agent 开发过程全部踩坑记录 |

## B. 模块分层（依赖方向不可逆）

```
util/  render/       ← 底层——不 import 业务模块。render 是纯格式转换，不碰 core/io/tool
  ↑
tool/               ← 功能模块——依赖 util/，不碰 core/io/render
  ↑
core/  io/          ← 业务/IO——io 不依赖 core（V1: core/agent 直接依赖 io/provider，ProviderInterface 留 V2）
  ↑                  ← V1 务实: io/provider.zig import render/cli.zig 用于 PhaseWriter 流式相位标注
  ↑                  ← V1 务实: core/agent.zig import render/cli.zig 用于工具标签 writeLabeled（V2 应改为回调注入）
config.zig          ← 基础模块（根级）
  ↑
App.zig             ← 组装器——import 以上所有
  ↑
main.zig            ← 入口 ≤10 行
```

关键修正：`render/` 不在 `core/` 下方——因为 `core/agent.zig` 只接受 `*std.Io.Writer`，不 import render。render 是 App 层对 Writer 的 ANSI 包装，与 `core/` 互不依赖。

> V1 偏差: agent.zig 和 io/provider.zig 均 import render/cli.zig——前者用于工具执行标签（writeLabeled(.tool)），后者用于流式相位切换（PhaseWriter）。agent 的 render 依赖通过 `?*anyopaque` 指针传递给 provider，自身也直接导入 render 类型。V2 应通过回调注入消除这两个依赖，恢复纯 Writer 架构。

### 目录树（V1 全部文件）

```
src/
├── main.zig            # 入口
├── App.zig             # 组装器
├── types.zig           # 共享类型（Message/Tool/ProviderEntry/...）
├── config.zig          # 配置加载 + TOML 解析 + dotenv
├── toml.zig            # TOML 轻量解析器（从 z-agent 迁移）
├── core/
│   ├── agent.zig       # AgentLoop——主循环 + API 通信 + 流式输出
│   └── session.zig     # 线形会话——append/load/flush + 上下文监控
├── io/
│   └── provider.zig    # OpenAI-compat API 客户端
├── tool/
│   ├── registry.zig    # 工具注册表
│   ├── read.zig        # 读文件
│   ├── write.zig       # 写文件
│   ├── bash.zig        # 子进程执行
│   ├── grep.zig        # 内容搜索
│   ├── glob.zig        # 文件名查找
│   └── skill.zig       # 技能加载
├── render/
│   └── cli.zig         # CLI 美化——ANSI 彩色输出 + Markdown→终端
├── test.zig             # 测试入口（聚合所有模块的 test 声明）
└── util/
    ├── text.zig        # 字符串工具
    ├── path.zig        # 路径规范化 + 防穿越校验（resolvePath）
    └── signal.zig      # Ctrl+C 中断处理（原子标志，Windows SetConsoleCtrlHandler）
```

check-arch.mjs `--fail-on-any` 从第一天零容忍。

## C. 模块清单

### C1. `config.zig` — 配置系统（根级基础模块）
- TOML 解析：`config.toml` 含 `default_model`/`max_tokens`/`max_tool_rounds` + `[[providers]]` 表数组 + `[[models]]` 平铺表数组（toml.zig 不支持嵌套表数组 `[[providers.models]]`）
- `findZagentRoot()`: 从 CWD 向上查找 `.zagent/config.toml`
- 模板自动生成：首次运行若无配置文件则创建默认模板
- API key 只存变量名（`api_key_env = "DEEPSEEK_API_KEY"`），不存密钥值。实际读取由 provider.init() 负责
- `Model` 为结构化值对象（`id`/`name`/`provider`/`context_window`/`max_tokens`/`reasoning`/`input`），非字符串数组。`provider` 字段关联 `[[models]]` 到 `[[providers]]`，空值匹配所有 provider
- `Api` 为编译期枚举（`.openai_compat`），非字符串 `kind`
- `InputModality` 枚举预留（`.text` `.image`），V1 只用 text
- 去掉 z-agent 的：权限系统耦合、`ProviderEntry` 从 `provider/registry` 导入的循环、`kind` 字符串、`context_limit` 扁平化

### C2. `io/provider.zig` — OpenAI 兼容 API
- `chatCompletionStreaming()`: POST → SSE 流式读取 → token 回调
- curl 子进程：构建 JSON body → stdin pipe (`-d @-`) → stdout pipe
- SSE 解析：`std.json.Value` + `ignore_unknown_fields`（避免跨 provider 格式差异）
- 重试策略：指数退避（1s/2s/4s），仅 transient 错误（ApiError/Interrupted 不重试）
- DeepSeek 适配：`finish_reason: "tool_calls"` → 正常停止；`reasoning` 模型注入 `thinking` 字段
- 去掉 z-agent 的：TUI 日志写入、多 provider 注册表、debug 日志

### C3. `tool/registry.zig` — 工具注册表
- `Registry = struct { handlers: []ToolEntry, fn execute, fn toTools }`
- `execute(self, ctx, name, args_json)`: 按名称匹配并执行工具（match + execute 合并为单次调用）
- `toTools(self, allocator)`: 将注册表转换为 LLM tool definitions（`[]types.Tool`）
- `ToolContext` 传给每个工具，含 project_root（`.zagent/` 路径）、allocator、io、display_writer——避免工具层 import config
- 去掉 z-agent 的：注册表→App 回调模式（直接返回 `[]const u8`）

### C4. `tool/{read,write,bash,grep,glob,skill}.zig` — 工具实现
- 签名统一：`fn execute(ctx: ToolContext, args: []const u8) anyerror![]const u8`
- `ToolContext.project_root` 解决 skill.zig 加载 `.zagent/skills/` 的路径问题——无需重复 findZagentRoot
- `ToolContext.display_writer` 写工具执行确认消息（如 `Read src/main.zig`）
- `resolvePath()` 规范化 `..`/`.` 防路径穿越，校验结果不逃逸 project_root
| 工具 | 功能 | z-agent 去什么 |
|------|------|---------------|
| read | 按需读取、UTF-8 校验、二进制检测、目录浏览 | `renderResult` 格式化（交给 render/cli.zig） |
| write | 创建/覆写文件 | — |
| bash | 子进程执行 + output 截断 | 超时轮询（V2）、安全命令拦截（V2） |
| grep | 正则内容搜索 | — |
| glob | 文件名 glob 匹配 | — |
| skill | `.zagent/skills/*/SKILL.md` 加载（通过 ctx.project_root） | 路径锚定 hack |

### C5. `core/session.zig` — 线形会话
- `append(msg)` / `flush()` / `load(path)` / `list(dir)` / `rename(name)`
- JSONL 格式：每行 `{ "role", "content", "timestamp", "model", "tool_calls", "tool_call_id" }`。header 行含 session 元数据
- `append()` 自动填入 `timestamp`；assistant 消息自动填入 `model`
- 消息对关系由数组顺序隐式表达（`tool_call_id` 关联 tool↔assistant），无树结构
- **持久化栅栏**：每完成一个完整轮次后由 App 调用 `flush()`。Agent 仅操作 session 内存（append/truncateTo），不负责持久化。App 在 turn 结束后根据 result.finish 决定是 truncateTo 回滚还是 flush 持久化。V1 同步阻塞写
- 上下文估算：消息数 > 50 → stderr 告警（精确 token 计数 V2）
- 命名：`/name <name>` 命令重命名当前会话文件 + 更新 `self.name`。`/list` 列出所有已保存会话。`/help` 显示命令帮助。
- 去掉 z-agent 的：会话树、记忆系统、designer/session 联动

### C6. `core/agent.zig` — 单轮执行引擎
- `AgentLoop` 状态机：接收单轮用户输入 → LLM → 工具调用循环 → 返回结构化结果
- 不持有循环控制权——`App.zig` 的 REPL 是真正的循环。App 将 user message append 到 session 后调用 `runTurn(writer) RoundResult`，agent 从 session 读取消息
- 工具轮次上限：`max_tool_rounds`（配置，默认 10）
- 每轮开始前检查 `util/signal.zig` 的中断标志，Ctrl+C 安全退出当前 turn
- **输出解耦**：接受 `*std.Io.Writer` 写字节流 + `?*anyopaque` 透传 PhaseWriter 给 provider
- V1 已知权衡：直接 import `io/provider.zig`（无抽象接口）+ `render/cli.zig`（仅用于 writeLabeled 工具标签输出，V2 改为回调注入）。ProviderInterface 留到 V2
- 去掉 z-agent 的：TUI/ChunkQueue 耦合、CaptureWriter、compact
- 第三方建议 A（Writer 解耦）：Agent 不 import render——V1 已偏离（writeLabeled），V2 完全解耦
- 第三方建议 B（交互式配置模板）：V2——首次运行打印 TOML 预览再确认创建，V1 直接写磁盘
- 第三方建议 C（工具增量渲染）：V2——ToolResult.stream 回调，V1 复杂度不值得

### C7. `render/cli.zig` — CLI 美化
- **不是 agent 的依赖，是 App 层对 Writer 的包装**
- 输出 Markdown/JSON → ANSI 转换函数，由 App 在写入终端前调用
- ANSI 基础常量（color/bold/reset）
- `visibleWidth()` — CJK 字符宽度检测（从 z-agent 提取）
- Markdown→ANSI 基础：标题/代码块/列表/粗斜体/链接
- 不实现：表格渲染、图片渲染（md2ansi 的完整引擎太大了）
- 第三方建议 C（工具增量渲染）：V2 考虑 ToolResult.stream 回调，V1 复杂度不值得

## D. 接口设计

### D1. 入口纪律
```zig
// main.zig — 入口，解析 --prompt/--model 后委托 App
pub fn main(process: std.process.Init) !void {
    const allocator = process.arena.allocator();
    const io = process.io;
    // --prompt / --model 参数解析（约 35 行）
    var app = try App.init(allocator, io, single_prompt, model_override);
    defer app.deinit();
    app.initAgent();
    try app.run();
}
```

### D2. App.init(allocator, io, single_prompt, model_override) 职责

串联所有模块，不持有循环控制权。实际步骤（按执行顺序）：
1. `render.cli.init()` — 启用 Windows VT，设置 colorize 标志
2. `signal.init(io)` — 注册 Ctrl+C 处理器
3. `findZagentRoot(allocator, io)` — 从 CWD 向上查找 `.zagent/`；未找到则回退到 CWD 作为 project_root
4. 读取 `project_root/AGENTS.md` → 缓存到 `self.project_context`
5. `Config.load(allocator, project_root, io)` — TOML 解析 + 模板生成
6. `loadDotEnv(allocator, project_root, io)` — 加载 `.env`
7. `resolveModel(&cfg, default_model)` — 解析 `provider/model_id`
8. 查找 `providers[]` 中匹配的 provider entry
9. `Provider.init(allocator, entry, model, null, io)` — 创建 API 客户端
10. `buildRegistry() + registry.toTools()` — 工具注册表
11. `Session.init(allocator, io, model_id)` — 创建会话
12. `buildSystemPrompt(...)` — 注入 system 消息（含环境 + AGENTS.md）
13. 返回 App 实例（agent 由 `initAgent()` 单独创建，避免自引用指针问题）

`initAgent()` 在 `run()` 前调用，绑定 session 指针到 AgentLoop。

### D3. 依赖流向
`util/` 不 import 项目模块。`io/` 不 import `core/`。`core/` 不 import `ui/`（本次无 ui/）。

### D4. ToolContext（工具执行上下文）
```zig
// types.zig
pub const ToolContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,           // .zagent/ 根目录
    display_writer: *std.Io.Writer,    // 工具确认消息输出目标
};
```
所有工具的 `execute(ctx: ToolContext, args: []const u8)` 通过 ctx 获取路径，不 import config。

### D5. Agent turn 接口（App ↔ Agent 的合约）

```zig
// core/agent.zig
pub const RoundResult = struct {
    new_message_count: usize,    // 本轮追加到 session 的消息数
    finish: TurnFinish,
};

pub const TurnFinish = enum {
    stop,           // LLM 正常停止
    max_rounds,     // 达到 max_tool_rounds 上限
    interrupted,    // Ctrl+C
    api_error,      // API 调用失败（可恢复，不退出 REPL）
};

/// 执行一轮对话。User message 已由 App 预先 append 到 session。
/// writer: raw stdout writer（工具标签 + 流式输出共用）。
/// phase_writer: opaque PhaseWriter 指针，透传给 provider 做流式相位标签。
/// V1 务实：agent import render/cli.zig 用于 writeLabeled，phase_writer 通过 ?*anyopaque 避免 agent 持有 PhaseWriter 类型。
/// App 驱动循环：append user msg → runTurn → 检查 result → 决定下一步
pub fn runTurn(
    self: *AgentLoop,
    writer: *std.Io.Writer,
    phase_writer: ?*anyopaque,
) !RoundResult;
```

## E. 验证计划

| 步骤 | 验证命令 | 通过标准 |
|------|---------|---------|
| 每步后 | `zig build check` | 编译通过 + check-arch 0 issue |
| 每步后 | `zig test src/test.zig --cache-dir .zig-cache` | 全部通过 |
| Step 2 后 | `zig build run -- --help` | 输出用法 |
| Step 5 后 | `zig build run -- --prompt "hello"` | 端到端 API 调用成功 |
| 全程 | `check-arch --fail-on-any` | 0 issue 0 warning |

## F. 失败路径

| 场景 | 行为 |
|------|------|
| `.zagent/` 目录不存在（含 config.toml） | 以 CWD 为 project_root，自动创建 `.zagent/config.toml` 全量注释模板，输出 `config created` 提示后继续启动 |
| API key 环境变量未设置 | 错误信息含变量名 + 提示设置 |
| curl 子进程 crash | `result.term` 检查 → 重试 → 失败则返回 `error.ApiError` |
| SSE 流中断 | 已接收的 token 保留，追加 `[stream interrupted]` 标记 |
| 工具执行超时 | V1 阻塞等待（bash），V2 超时轮询 + `error.ToolTimeout` |
| 消息数过多（>50） | stderr 告警 `session: 52 messages, context may overflow` |
| Ctrl+C 中断 | `util/signal.zig` 设置原子标志 → agent.runTurn() 返回 `finish=.interrupted` → App 调用 `session.truncateTo(pre_count)` 回滚当前轮次 → `session.flush()` 持久化回滚后状态。 |

## G. 方案完整性

- [x] G1 字段追到实际定义：`types.zig` 的 Message/Tool/ToolCall/ToolContext/Model/ProviderEntry/Api/InputModality 已定义
- [x] G2 调用签名一致：Provider 签名从 z-agent 的 `openai_compat.zig:891` 确认
- [x] G3 数据流贯通：config → provider → agent → session → stdout
- [x] G4 现有设施复用：`util/text.zig` 已创建，trim 已实现
- [x] G5 交互边界：空配置、缺 key、空响应均已覆盖
- [x] G6 接口类型：上方 D 节已声明
- [x] G7 假设点：所有"从 z-agent 去什么"标注到具体文件名
- [x] G8 独立可实施：9 个 Step（含 Step -1 基础设施）按依赖顺序排列，每步有独立验证

## 执行步骤

| Step | 模块 | 从 z-agent 迁移 | 新建 | 预估行数 |
|------|------|----------------|------|---------|
| -1 | `types.zig` + `main.zig`(骨架) + `test.zig`(骨架) + `util/text.zig` | — | 共享类型 + 入口骨架 + 测试聚合 + trim 工具 | ~80 |
| 0 | `util/signal.zig` | — | Ctrl+C 原子标志 | ~50 |
| 1 | `config.zig` + `toml.zig` | config.zig TOML 解析 | 去权限 + 模板简化 + Model 解析 + 校验 + 启动反馈 | ~970 |
| 2 | `io/provider.zig` | openai_compat.zig 核心 | 去 TUI + 单 provider + SSE Value 解析 + retry stderr | ~745 |
| 3 | `tool/` 全链 (详见 docs/plan-step3-tools.md) | registry + 6 工具 | ✅ 已完成。去回调 + 去 render + ToolContext + resolvePath | ~1511 |
| 4 | `core/session.zig` (详见 docs/plan-step4-session.md) | session.zig 线形部分 | ✅ 已完成。去树 + 去记忆 + Arena 统一分配 + 消息对 + 时间戳/model | ~848 |
| 5 | `core/agent.zig` | agent.zig AgentLoop | ✅ 已完成。去 TUI/CaptureWriter + 信号检查 + mock ChatFn 测试 | ~517 |
| 6 | `render/cli.zig` | ansi.zig + render 基础 | ✅ 已完成。精简 Markdown→ANSI + Windows VT 启用 | ~750 |
| 7 | `App.zig` 连线 | — | ✅ 已完成。REPL 循环 + 命令解析 (/exit /new /name /list /help) + 信号初始化 + truncateTo 回滚 + 输出管道组装 | ~425 |
| 8 | 审查修复 (详见 docs/plan-step8-fix-audit.md) | — | ✅ 已完成。持久化栅栏 agent→App + truncateTo 回滚 + /name /list /help 命令 | ~50 |
