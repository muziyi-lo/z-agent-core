# Step 7: App.zig -- CLI REPL 集成

> 串联所有模块：config → provider → tools → session → agent → render。实现最小 CLI REPL。

## A. 源码依据

| 源文件 | 用途 |
|--------|------|
| `projects/z-agent-core/src/main.zig` | `process.io` + `process.arena.allocator()` 入口 |
| `projects/z-agent-core/src/config.zig` | `Config.load()` / `findZagentRoot()` / `loadDotEnv()` / `resolveModel()` |
| `projects/z-agent-core/src/io/provider.zig` | `Provider.init()` / `chatCompletionStreaming()` |
| `projects/z-agent-core/src/tool/registry.zig` | `Registry` / `buildRegistry()` / `toTools()` |
| `projects/z-agent-core/src/core/session.zig` | `Session.init()` / `append()` / `messages()` / `flush()` / `list()` |
| `projects/z-agent-core/src/core/agent.zig` | `AgentLoop.init()` / `runTurn()` / `RoundResult` / `TurnFinish` |
| `projects/z-agent-core/src/render/cli.zig` | `init()` / `writeLabeled()` / `renderLine()` / `MessageType` / `C` |
| `projects/z-agent-core/src/types.zig` | `ToolContext` / `Message` / `Role` / `ProviderEntry` / `Model` |
| `projects/z-agent/src/App.zig:1-200` | z-agent CLI REPL 参考 (args解析/Session创建/REPL循环) |

## B. 模块设计

### B1. z-agent 减法

| 减法 | z-agent (不迁移) | z-agent-core V1 (替代) |
|------|-----------------|----------------------|
| 命令系统 | `/session`, `/model`, `/name`, `/clear`, 命令模板 | `/exit`, `/new`, `/name`, `/list`, `/help` |
| TUI 模式 | Tui struct, alt screen, mouse, raw mode | 不实现 -- CLI only |
| 权限系统 | permission.Permission, trust, ask_user | 不实现 -- V2 |
| 单次模式 | `--prompt`, `--agent`, `--readonly`, `--trust` | 仅 `--prompt` 单次模式, `--model` 选择 |
| 命令行参数 | 完整 CLI args 解析 (11+ flags) | `--prompt`, `--model` 两条 flags |
| session 管理 | session 持久化 / list / load / continue | Session 自动创建 + flush, `/list` 显示会话, `/name` 重命名 |
| 钩子 | hooks (session_start, session_end, etc.) | 不实现 |

### B2. 模块职责

```
main.zig
    ↑
App.zig              ← 串联所有模块, REPL 循环
    ↑
config.zig + provider.zig + registry.zig + session.zig + agent.zig + render/cli.zig
```

App.zig 调用所有模块, 但模块间不互相 import。App 是唯一的 orchestration 层。

### B3. 数据结构

```zig
pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    // stdout writer created locally in singleTurn/replLoop for buffer lifetime safety

    cfg: config.Config,
    provider: provider.Provider,
    registry: registry.Registry,
    tools: []types.Tool,
    session: session.Session,
    agent: agent_mod.AgentLoop,

    project_root: []const u8,
    project_context: ?[]const u8,
    single_prompt: ?[]const u8,
    session_dir: []const u8,
};
```

### B4. App.init() 流程

```
0. render.cli.init()                            → 启用 Windows VT (先于任何终端输出)
1. signal.init(io)                              → 注册 Ctrl+C 处理器 (OS-specific)
2. findZagentRoot(allocator, io)                → 获取 .zagent/ 目录
3. 读取 project_root/AGENTS.md → 缓存到 self.project_context (V1: 启动时读一次, /new 复用)
4. Config.load(allocator, project_root, io)     → 加载配置
5. loadDotEnv(allocator, project_root, io)      → 加载 .env
6. resolveModel(cfg, default_model)             → 解析 provider/model_id
7. 查找 provider entry                          → 获取 api_key_env
8. Provider.init(allocator, entry, model)       → 创建 Provider
9. buildRegistry()                              → 工具注册表
10. registry.toTools(allocator)                 → LLM tools 数组
11. Session.init(allocator, io, model_id)       → 创建 Session
12. 构造 system prompt + session.append         → 注入 system 消息
13. AgentLoop.init(...)                         → 创建 Agent
```

### B5. App.run() 流程

```
if --prompt 单次模式:
    1. writeLabeled(stdout, .user, prompt)   // 单次模式无终端 echo，需显式显示
    2. session.append(Message{ .role=.user, .content=prompt })
    3. agent.runTurn(stdout, phase_writer)   // 流式输出到 stdout
    4. stdout.write("\n") catch {}
    5. session.flush()
    return

REPL 模式:
    初始化: PhaseWriter 包装 stdout（`var pw = render.PhaseWriter{ .inner = &stdout.interface };`）
    loop:
        1. writePrompt(&stdout)              // 蓝底 "用户 " 行内标签，无换行
        2. read line from stdin
        3. if empty: continue
        4. if /exit or /quit: break
        5. if /new: 重建 session + 重新注入 system prompt + 重建 agent, continue
        6. pre_count = session.messages().len        // 记录基线用于回滚
        7. session.append(Message{ .role=.user, .content=line })
        8. agent.runTurn(&stdout, &pw)               // 传 PhaseWriter 给 provider 做相位标签
        9. _ = stdout.write("\n") catch {}           // 强制换行: 确保下一轮 prompt 在新行
        10. if finish == .api_error: writeLabeled(.err, ...) + truncateTo(pre_count)
        11. if finish == .interrupted: writeLabeled(.warning, "interrupted") + truncateTo(pre_count)
        12. session.flush()                           // 唯一持久化点: truncateTo 后或正常 turn 结束
```

相比原设计变更:
- 步骤 1: `"> "` → `writePrompt(&stdout)` (蓝底白字标签，终端 echo 显示用户输入)
- 步骤 6: 移除 `writeLabeled(.user, line)` — prompt + 终端 echo 已显示用户输入，避免双重标签
- 步骤 7: 新增 `phase_writer` 参数，传给 agent → provider 做流式相位标注

### B6. runTurn 输出策略

**流式输出 (think/output)** 由 `io/provider.zig` 通过 `PhaseWriter` 控制：
- provider 收到 SSE `reasoning_content` delta → `pw.beginPhase(.think)` + `pw.writeRaw(text)`
- provider 收到 SSE `content` delta → `pw.beginPhase(.output)` + `pw.writeRaw(text)`
- `PhaseWriter` 在相位切换时自动注入/关闭 ANSI 标签（`思考` / `输出`），provider 只负责相位切换和裸写 token
- `io/provider.zig` import `render/cli.zig` 获取 `PhaseWriter` 类型 — 允许（`io/` 在 `render/` 上方，依赖方向合法）

**用户输入显示**：
- REPL 模式: `writePrompt()` 行内提示符（蓝底 "用户 " 标签 + 空格，无换行），终端 echo 显示输入内容。**不调用 `writeLabeled(.user, ...)`** 避免双重标签
- 单次模式: `writeLabeled(.user, prompt)` 显式显示（无终端 echo）

**工具调用显示**：
- agent 在执行工具前通过 `render.writeLabeled(writer, .tool, tool_label)` 输出同行标签（如 ` 工具 bash {"command":"..."}`）
- `ToolContext.display_writer` 指向 stdout (`writer`)，工具内部回显 `> command` 和输出结果直接可见
- `core/agent.zig` import `render/cli.zig` — V1 务实选择（agent 需要为工具调用生成标签，纯 App 层做不了因为工具在 agent.runTurn 内部执行）。V2 可考虑将工具标签移到 App 层或通过回调注入

**REPL 提示符**：
- `writePrompt(&stdout)` 输出蓝底白字 ` 用户 ` 标签 + 重置后的普通空格 (输入分隔符)
- 模板 ` 用户 ` 自带蓝底装饰空格，`{reset}` 后的显式空格确保标签区与输入区有清晰的普通背景色分隔

**PhaseWriter 传递链**:
```
App.zig:  var pw = PhaseWriter{ .inner = &stdout.interface };
          agent.runTurn(&stdout.interface, &pw)    → 传入 PhaseWriter

agent.zig:  pub fn runTurn(self, writer, phase_writer: ?*anyopaque)
            → 自身使用 writer (raw stdout)
            → phase_writer 转发到 provider

provider.zig:  pub fn chatCompletionStreaming(..., pw: *PhaseWriter)
               → pw.beginPhase(.think) / pw.beginPhase(.output) / pw.writeRaw(text)
```

### B7. 错误处理

| 错误 | 处理 |
|------|------|
| 找不到 .zagent/ | print "Error: no project root found" + exit |
| Config 加载失败 | print "Error: invalid config: {msg}" + exit |
| API key 未设置 | print "Error: {env_var} not set" + exit |
| Provider init 失败 | print "Error: {msg}" + exit |
| runTurn 返回 api_error | writeLabeled(.err, msg), 不退出 REPL |
| runTurn 返回 interrupted | writeLabeled(.warning, "interrupted"), 不退出 REPL |

**runTurn 失败回滚**:
```
runTurn 失败时 user message 已 append 到 session（由 App 在 runTurn 前执行）。
Agent 内部可能在 api_error 前已执行 N 轮工具调用，将 N 条 assistant+tool 消息写入 session。

V1 策略:
  - App 在 append 用户消息前记录 pre_count = session.messages().len
  - session 提供 truncateTo(keep) 方法 → 截断消息列表到指定数量
  - runTurn 异常 (OutOfMemory 以外) → truncateTo(pre_count) + flush (回滚整个 turn)
  - result.finish == .api_error or .interrupted → truncateTo(pre_count) 回滚
  - result.finish == .stop or .max_rounds → 保留所有消息 + flush 持久化
  - 对比旧方案 popLast() 只移除用户消息：新方案 truncateTo(pre_count) 可清除 agent 产生的 orphan 消息
```

### B8. 命令行参数解析

仅支持两条 flags:

```
--prompt <text>    → 单次交互模式，交互后退出
--model  <spec>    → 覆盖配置中的 default_model ("provider/model_id")
```

参数解析在 `main.zig` 中完成（使用 Zig 0.16 的 `Args.Iterator.initAllocator`，需要 `process.gpa`），解析结果传参 `App.init()`。不引入 CLI 参数库。

**`--model` 字符串所有权**: 使用 `allocator.dupe(u8, val)` 创建 arena 拥有所有权的副本赋给 `cfg.default_model`。

### B9. stdin 读取

Zig 0.16 的 `Io.File.Reader` 提供 `takeByte()` 逐字节消费。

V1 使用逐字节循环 + 行缓冲 `ArrayList(u8)`，遇到 `\n` 返回。支持 4096 字节行上限，支持 backspace。

不使用 `reader.slice/readSliceAll`（流式 Reader 下 `readSliceAll` 会阻塞到 buffer 填满或 EOF，不适合逐行交互）。

```zig
fn readLine(reader: *Io.Reader, buf: *ArrayListAligned(u8, null), allocator: std.mem.Allocator) !?[]const u8 {
    buf.clearRetainingCapacity();
    while (true) {
        const byte = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => return if (buf.items.len > 0) buf.toOwnedSlice(allocator) else null,
            else => return err,
        };
        if (byte == '\n') return buf.toOwnedSlice(allocator);
        if (byte == '\b') {
            if (buf.items.len > 0) _ = buf.pop();
            continue;
        }
        if (buf.items.len >= 4096) return error.LineTooLong;
        try buf.append(allocator, byte);
    }
}
```

> Zig 0.16 的 `Io.Reader` 内部处理 `EINTR` 自动重试，不需要在应用层捕获 `error.Interrupted`。

### B10. 依赖方向 (更新)

```
main.zig → App.zig
              → config.zig          (types.zig, toml.zig)
              → io/provider.zig      (types.zig, render/cli.zig)  ← provider import render (允许)
              → tool/registry.zig    (types.zig)
              → core/session.zig     (types.zig)
              → core/agent.zig       (types.zig, io/provider, tool/registry, core/session, util/signal)
              → render/cli.zig       (纯格式, 无项目依赖)
```

**依赖规则**:
- `io/provider.zig` → `render/cli.zig` ✅ 允许 (io 在 render 上方)
- `core/agent.zig` → `render/cli.zig` ❌ 禁止 (agent 只接受 `*std.Io.Writer` 和 `?*anyopaque`)
- `render/cli.zig` → 任何业务模块 ❌ 禁止 (纯格式层)

## C. 接口设计

### C1. 提示词组装

V1 在 App 层构造 system prompt，在创建 session 后立即注入。

```
system prompt 结构:
  [BASE_PROMPT]
  <project_context>
```

**BASE_PROMPT** (硬编码常量):
```
"You are z-agent-core, an interactive CLI agent that helps users with software engineering tasks."

**environment** (动态拼接):
```
从系统获取，拼接到 system prompt 尾部:
<env>
  Working directory: {cwd}
  Workspace root: {project_root}
  Platform: {os}
  Today's date: {YYYY-MM-DD}
</env>
```

实现: `std.process.currentPathAlloc(io, allocator)` + `builtin.os.tag` + 日期通过 `Io.Clock.Timestamp` 转换。

**project_context** (可选):
```
从 project_root/AGENTS.md 读取。
若文件存在但读取失败 (权限/编码): print warning + 跳过 project_context, 不退出。
```
<project_context>
{content}
</project_context>
```

**注入流程**:
```
App.init() 末尾:
  1. 构造 system_prompt = BASE_PROMPT
  2. 拼接 <env> 块 (cwd, project_root, os, date)
  3. 若 project_root/AGENTS.md 存在 → 读取 → 拼接 <project_context> 块
  4. session.append(Message{ .role=.system, .content=system_prompt })

(/new 命令时重新执行此流程)
```

**不注入的内容** (V1 限制):
- 不注入工具描述 (已通过 `tools` 参数传给 API，由 agent.runTurn 处理)
- 不注入 session 摘要 (V2 compact 时添加)
- 不注入用户自定义指令 (V2 通过 config 或 CLI flags)

### C2. App struct

```zig
pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    // stdout writer created locally in singleTurn/replLoop for buffer lifetime safety

    cfg: config.Config,
    provider: provider.Provider,
    registry: registry.Registry,
    tools: []types.Tool,
    session: session.Session,
    agent: agent_mod.AgentLoop,

    project_root: []const u8,
    project_context: ?[]const u8,  // AGENTS.md 内容缓存 (V1 启动时读一次)
    single_prompt: ?[]const u8,
    session_dir: []const u8,
};
```

### C3. init() -- 错误时触发 Exit

```zig
// init() return error on startup failures — main.zig catches and prints
// init() 内部调用 render.cli.init() 启用 ANSI
// 第一优先: 解析 --prompt / --model 参数
// 第二优先: findZagentRoot()
// 第三优先: 配置加载 (Config.load + loadDotEnv)
// 第四优先: Provider 创建 (依赖 resolveModel)
// 第五优先: Registry 构建 (buildRegistry + toTools)
// 第六优先: Session + Agent 创建
// 第七优先: 构造 system prompt + 注入 session
```

### C4. run() -- REPL 或单次模式

```zig
// if single_prompt != null: singleTurn() → flush → return
// else: replLoop()
//
// replLoop():
//   while true:
//     1. writePrompt(&stdout)                        // 蓝底 "用户 " 行内标签
//     2. read line from stdin (readLine helper)
//     3. if empty (EOF): break
//     4. if "/exit" or "/quit": break
//     5. if "/new": resetSession() (C6), continue
//     6. if "/name <name>": renameSession(), continue
//     7. if "/list": listSessions(stdout), continue
//     8. if "/help": showHelp(stdout), continue
//     9. pre_count = session.messages().len          // 记录基线
//     10. session.append(user_message)
//     11. result = agent.runTurn(&stdout, &pw)
//     12. if err (non-OOM): truncateTo(pre_count) + flush, return
//     13. _ = stdout.write("\n") catch {}            // 强制换行
//     14. if finish == .api_error: writeLabeled(.err, ...) + truncateTo(pre_count)
//     15. if finish == .interrupted: writeLabeled(.warning, ...) + truncateTo(pre_count)
//     16. session.flush()
```

### C5. deinit()

```zig
// 释放顺序: session.deinit() → cfg.deinit() → tools 释放
// process.arena (main.zig) 在 main 返回时自动释放，无需手动 deinit
//
// project_context 内存: 从 process.arena (App.allocator) 分配，与 App 生命周期一致。
//   → /new 时直接复用，无需重新分配
//   → 随 process.arena 在 main 返回时自动释放，App.deinit 无需单独处理
```

### C6. /new 辅助方法

```zig
fn resetSession(self: *App) !void {
    // 1. 销毁旧 session (含内部 Arena)
    self.session.deinit();
    // 2. 创建新 Session
    self.session = try session_mod.Session.init(self.allocator, self.io, self.cfg.default_model);
    // 3. 重新注入 system prompt (复用 self.project_context 缓存)
    try buildSystemPrompt(self.allocator, self.io, self.project_root, self.project_context, &self.session);
    // 4. 重建 AgentLoop (旧 agent 的 session_ref 已失效)
    self.agent = agent_mod.AgentLoop.init(...);
}
```

## D. 新增/修改文件清单

| 文件 | 操作 | 内容 |
|------|------|------|
| `src/App.zig` | 重写 | 从 22 行 stub → ~300 行完整 CLI REPL。创建 PhaseWriter，传给 agent |
| `src/main.zig` | 修改 | 捕获 App.init error 输出用户友好信息 |
| `src/util/signal.zig` | 修改 | 新增 `init(io)` 注册 OS 级 Ctrl+C 处理器 |
| `src/core/session.zig` | 修改 | 新增 `popLast()` + `truncateTo()` 方法用于 runTurn 失败回滚 |
| `src/core/agent.zig` | 修改 | 新增 `phase_writer: ?*anyopaque` 参数传递给 provider |
| `src/io/provider.zig` | 修改 | `chatCompletionStreaming` 接受 `*PhaseWriter` 参数，调用 `beginPhase`/`writeRaw`/`endPhase` |
| `src/render/cli.zig` | 修改 | 新增 `PhaseWriter` 结构体 + `writePrompt` / `writeLabelBegin` / `writeLabelEnd` |
| `src/test.zig` | 不修改 | App.zig 无独立 test (集成测试在 .opencode/.tmp/) |

## E. 测试计划

| 测试 | 覆盖 | 类型 |
|------|------|------|
| `app: init finds root` | findZagentRoot 找到 .zagent/ | 集成 (手动) |
| `app: init loads config` | Config.load 正常加载 | 集成 (手动) |
| `app: init missing key error` | API key 缺失时友好退出 | 集成 (手动) |
| `app: single prompt` | --prompt 单次运行 | 集成 (手动) |
| `app: repl basic` | 输入一行 → 输出响应 → 继续 | 集成 (手动) |
| `app: repl /exit` | /exit 退出 | 集成 (手动) |
| `app: repl /new` | /new 重置会话 + 重建 agent | 集成 (手动) |
| `app: repl Ctrl+C` | 中断流式输出 → writeLabeled warning | 集成 (手动) |
| `app: repl EOF` | stdin 关闭时退出 | 集成 (手动) |
| `app: runTurn error rollback` | api_error 后 session 回滚到 pre_count (无 orphan 消息) | 集成 (手动) |
| `signal: init Windows` | SetConsoleCtrlHandler 注册 | 自动 (单元) |
| `session: popLast` | 移除最后一条消息 | 自动 (单元) |

> V1 测试以手动交互验证为主。Agent 的自动单元测试已在 Step 5 覆盖 (mock provider)。
> 未来补充脚本化集成测试。

## F. G7 对照表: Zig 0.16 stdlib API 验证

| # | 方案中的调用 | 源码/依据 | 匹配? |
|---|------------|----------|-------|
| 1 | `process.arena.allocator()` | `std/process.zig` | ✅ |
| 2 | `process.io` | `std/process.zig` | ✅ |
| 3 | `process.args` | `std/process.zig` | ✅ |
| 4 | `Io.File.stdout()` | `std/Io/File.zig` | ✅ |
| 5 | `Io.File.stdin()` | `std/Io/File.zig` | ✅ |
| 6 | `Io.Reader.takeByte()` | `Io/Reader.zig:1157` | ✅ |
| 7 | `Io.File.Writer.write()` | `std/Io/File.zig` | ✅ |
| 8 | `Config.load(allocator, root, io)` | `config.zig` | ✅ |
| 9 | `Provider.init(allocator, entry, model, io)` | `provider.zig:68` | ✅ |
| 10 | `Session.init(allocator, io, model)` | `session.zig` | ✅ |
| 11 | `AgentLoop.init(...)` | `agent.zig` | ✅ |
| 12 | `AgentLoop.runTurn(writer)` | `agent.zig` | ✅ |
| 13 | `buildRegistry()` | `registry.zig` | ✅ |
| 14 | `render.cli.init()` | `render/cli.zig` | ✅ |
| 15 | `writeLabeled(writer, mtype, text)` | `render/cli.zig` | ✅ |
| 16 | `signal.init(io)` 注册 Ctrl+C | `util/signal.zig` (新增) | ✅ |
| 17 | `session.popLast()` | `core/session.zig` (Step 7 新增) | ✅ |
| 18 | `session.truncateTo(keep)` | `core/session.zig` (Step 8 新增) | ✅ |
| 19 | `SetConsoleCtrlHandler` (Windows) | `ansi.zig:46` callconv(.winapi) | ✅ |
| 20 | `std.time.epoch.EpochSeconds` 日期 | `std/time.zig` | ✅ |
| 21 | `std.process.currentPathAlloc(io, allocator)` | `std/process.zig` | ✅ |

## G. 行数（实际）

| 文件 | 行数 |
|------|------|
| `src/App.zig` | 425 (实现, Step 8 追加 /name /list /help + truncateTo 回滚) |
| `src/main.zig` | 35 |
| `src/util/signal.zig` | 57 (+27 init 注册) |
| `src/core/session.zig` | 935 (+60 popLast + truncateTo + 4 测试) |
| **合计** | ~416 |

## H. 设计注释与 V1 已知限制

- **不实现 TUI** -- 纯 CLI line-buffered REPL。无 alt screen, mouse, raw mode。
- **不实现复杂命令** -- `/exit`, `/new`, `/name`, `/list`, `/help` 五条命令。不实现 `/session`, `/model`, `/load`, `/compact`, 命令模板。
- **不实现 session 持久切换** -- V1 单一 session。`/new` 关闭旧 session 创建新的。
- **不实现 compact** -- 上下文超出时无压缩，runTurn 可能因 max_tool_rounds 截断。
- **不实现 hooks** -- 无 session_start, session_end 等钩子。
- **stdin 读取逐字符** -- 参考 z-agent `Cli.readline()` 的逐字符循环，比 `reader.line()` 更可预测。支持 backspace 和 Ctrl+C。
- **runTurn 返回错误不退出** -- api_error 和 interrupted 显示错误标签后继续 REPL。只有 startup 阶段错误才会 exit。
- **参数解析最小化** -- 仅 `--prompt` 和 `--model`，用简单 `process.args` if-else 解析。不引入 argument parser 库。
- **单次模式** -- `--prompt` 时运行一次 turn，不进入 REPL。适合脚本集成。
- **工具调用输出** — agent 通过 `render.writeLabeled(writer, .tool, tool_label)` 输出同行标签（如 ` 工具 bash {"command":"..."}`）。`display_writer` 指向 stdout 使工具回显直接可见。`core/agent.zig` import render（V1 务实决策，因工具在 agent.runTurn 内部执行，纯 App 层无法介入）。
- **流式输出标签 (PhaseWriter)** -- App 层创建 `PhaseWriter` 包装 stdout，以 `?*anyopaque` 通过 agent 传给 provider。provider import `render/cli.zig` 获取 `PhaseWriter` 类型，调用 `beginPhase(.think)` / `beginPhase(.output)` 在 SSE delta 类型切换时自动注入 ANSI 标签。这取代了原设计的"裸写 raw token"方案，但通过 PhaseWriter 封装保持了 provider 层只操作抽象接口、不直接拼接 ANSI 的底线。
- **用户输入显示** -- REPL 模式用 `writePrompt()` 行内蓝底标签 + 终端 echo 显示。不调用 `writeLabeled(.user, ...)` 避免双重标签。单次模式用 `writeLabeled(.user, prompt)` 显式回显。
- **runTurn 失败回滚** -- 失败时 App 调用 session.truncateTo(pre_count) 回滚整个 turn（含 user 消息 + agent 可能产生的 orphan assistant/tool 消息）。对比旧方案 popLast() 只移除 user 消息更安全。pre_count 在 append 用户消息前记录。
- **AGENTS.md 缓存** -- init 时读取一次缓存到 App.project_context，/new 时复用，无需重复磁盘 I/O。
- **Ctrl+C 全局注册** -- signal.init(io) 在 App.init() 开头注册 OS 级处理器，runTurn 内循环检测 isInterrupted()。
- **/new 重建 agent** -- 因 AgentLoop 持有 session 指针，/new 必须同步重建 AgentLoop。通过 resetSession() 辅助方法完成 session 销毁 → 重建 → agent 重建。
- **内存所有权** -- Config/Session 各自拥有内部 Arena。deinit 顺序: session.deinit() → cfg.deinit()。顶层 process.arena (main.zig) 自动释放。
