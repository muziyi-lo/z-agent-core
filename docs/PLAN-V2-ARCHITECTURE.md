# V2: 架构收敛 — 从 V1 务实到 V2 清晰

> V1 的务实决策（agent import render、工具写 display_writer、provider import render）产生了 8+ 文件跨层的显示逻辑散落。V2 目标是收敛到单一渲染层 + 纯接口，为后续增量渲染 / tool stream / provider 多态铺路。

## A. V2 背景：V1 累积的技术债

| 偏差 | 位置 | V1 状态 | V2 目标 |
|------|------|---------|---------|
| agent import render | `agent.zig` import `render/cli.zig` | 直接调用 `writeLabeled(.tool, ...)` | agent 只传数据，渲染由 App 层回调注入 |
| provider import render | `provider.zig` import `render/cli.zig` | PhaseWriter 流式相位标注 | ProviderInterface 抽象 + PhaseWriter 回调 |
| 工具写 display_writer | 6 个工具模块 | 每个工具独立 print 头部 + 内容 | 工具退化为纯函数，返回结构化结果，渲染层统一输出 |
| 双写工具输出 | agent 打标签行 + 工具打内容行 | 两行，格式不一致 | 单行（单行工具）/ 标签+内容（多行工具），统一由渲染层处理 |
| 无 Provider 接口 | agent 直接 `import provider.zig` | `ChatFn` 函数指针 | `Provider` vtable interface |
| App.zig 持久化逻辑重复 | `processLine`/`singleTurn` 各有独立回滚代码 | 2 处 pre_count→truncateTo | 抽取辅助函数 |
| V1 遗留 API 未串联 | `renderLine`/`session.load`/`resetCodeBlock` 实现+测试通过但不可达 | 3 个 pub 符号无外部调用者 | Phase 1 串联 |
| 死代码 | `session.popLast()` 被 `truncateTo` 替代 | 零外部调用者 | Phase 1 删除 |

## B. V2 分阶段

### Phase 1a: 渲染层收敛 + V1 遗留串联

**目标**：所有终端输出经过 `render/cli.zig` 一个模块，agent 和工具不再直接写 Writer。只含架构重构和 V1 遗漏的串联，不含功能增强。

### Phase 1b: 渲染增强（功能增强，低风险独立交付）

**目标**：在收敛后的渲染层上叠加格式化能力——表格渲染、Markdown 流式输出、用量统计、流超时保护等。与 Phase 1a 可并行或分批发版，不阻塞核心收敛。

**V1 遗留**：V1 Step 7 集成审计发现以下已实现/已测试但未串联的模块：

| 符号 | 模块 | 已实现 | 已测试 | 串联状态 |
|------|------|--------|--------|---------|
| `renderLine()` | `cli.zig` | ✅ | ✅ 多 | ❌ stream 走 `writeRaw` 纯文本透传 |
| `session.load()` | `session.zig` | ✅ | ✅ 3 个 | ❌ 无 `/load` 命令 |
| `resetCodeBlock()` | `cli.zig` | ✅ | ✅ | ❌ 跨 turn 不重置，`renderLine` 接入后需配套 |

Phase 1 一并串联。

**改动清单**：

| 模块 | 改动 |
|------|------|
| `render/cli.zig` | 新增 `RenderContext`（封装 `code_block_active` 等跨 turn 状态）+ `ToolDisplay` 渲染器：`renderToolCall(writer, result)` 接管全部工具输出格式；`code_block_active` 从模块级 `var` 移入 `RenderContext`，消除全局可变状态 |
| `agent.zig` | 移除 `render` import + `writeLabeled` 调用；通过回调接收 `?ToolDisplayCallback` 实现解耦 |
| `types.zig` | 新增 `ToolResult` 结构化类型（替代纯字符串返回值 + display_writer 副作用） |
| `tool/read.zig` | 移除 `display_writer` 使用；`execute()` 返回 `ToolResult{ .display = ..., .content = ... }` |
| `tool/grep.zig` | 同上 |
| `tool/glob.zig` | 同上 |
| `tool/skill.zig` | 同上 |
| `tool/write.zig` | 同上 |
| `tool/bash.zig` | 同上 |
| `tool/registry.zig` | 更新 `ToolEntry.execute` 签名 → 返回 `ToolResult` |
| `App.zig` | 初始化 `ToolDisplay`，注入回调到 agent；替换散落的工具输出逻辑 |
| `io/provider.zig` | PhaseWriter 改为回调注入，移除 render import |

**关键接口**：

```zig
// types.zig — 工具返回结构化结果
// 内存所有权：三个字段均由 ctx.allocator（父分配器）分配。
// Agent 渲染 + session dupe 后调用 ToolResult.deinit() 释放。
// Phase 3 流式工具可迁移到 Arena 分配简化生命周期。
pub const ToolResult = struct {
    display_label: []const u8,       // e.g. "Read AGENTS.md [limit=30]"
    display_summary: ?[]const u8,    // e.g. "-> 3 matches". null → 多行内容
    session_content: []const u8,     // appended to session, long-lived
};

// render/cli.zig — 统一工具渲染，持跨 turn 可变状态
pub const RenderContext = struct {
    code_block_active: bool = false,
    colorize: bool,
    stdout_dead: bool = false,  // 终端断流标志，agent turn 间检查终止循环
};

pub const ToolDisplay = struct {
    ctx: *RenderContext,
    pub fn render(self: *ToolDisplay, writer: *Io.Writer, result: ToolResult) void;
};

// core/agent.zig — 回调注入（签名为 void 强制内部消化所有错误）
pub const ToolDisplayCb = struct {
    context: ?*anyopaque,
    render: *const fn (ctx: ?*anyopaque, writer: *Io.Writer, result: ToolResult) void,
};

pub fn runTurn(
    self: *AgentLoop,
    writer: *Io.Writer,
    tool_display: ?ToolDisplayCb,  // null = no display (headless mode)
) !RoundResult;
```

> P1-6 完成后 `runTurn()` 移除 `phase_writer` 参数 — PhaseWriter 通过 Provider.init() 注入。
> 
> `ToolDisplay.render()` 签名 `void`：渲染错误内部 catch → stderr log。终端断连（EPIPE）通过 `RenderContext.stdout_dead` 标志位标记，agent 在 turn 间检查该标志终止循环 — 不走渲染回调传播，但 agent 能感知。
> 
> `ToolResult` 字段均由工具通过 `ctx.allocator`（父分配器）分配。Agent 渲染 + session dupe 后调用 `ToolResult.deinit()` 释放。未来 Phase 3 流式工具可改为 Arena 分配以简化生命周期管理。
> 
> `truncateTo` 回滚统一收口到 `App.rollbackTurn(pre_count)` 方法，内部同步调用 `render_ctx.reset()` — 消除人肉纪律依赖。Phase 3 流式工具使用独立 `ToolStreamCb` 回调类型，不影响 Phase 1 的同步批次接口。

**`ToolDisplay.render()` 显示格式规范**：

标签前缀统一为 ` 工具  `（标签 + 两个空格），由 `writeToolLabelOpen` / `writeToolLabelClose` 控制 ANSI。

| 工具 | 标签格式 | display_summary | 行数 | 示例 |
|------|---------|----------------|------|------|
| read (dir/空/错误) | ` Read <path>` | `[dir: N entries]` / `File is empty` / `Error: ...` | 单行 | ` 工具  Read src/  [dir: 12 entries]` |
| read (file) | ` Read <path>` / ` Read <path> [limit=N, offset=M]` | null | 多行 | ` 工具  Read AGENTS.md` 换行后文件内容 |
| grep | ` Grep <pattern> <path>` | `-> N matches` | 单行 | ` 工具  Grep "fn" src/  -> 3 matches` |
| glob | ` Glob <pattern> <path>` | `-> N files` | 单行 | ` 工具  Glob *.zig src/  -> 5 files` |
| skill | ` Skill <name>` | `Loaded: {name}` | 单行 | ` 工具  Skill zig-dev  Loaded: zig-dev` |
| write | ` Write <path>` | null | 多行 | ` 工具  Write src/foo.zig` 换行后内容 |
| bash | ` $ <command>` | null | 多行 | ` 工具  $ ls -la` 换行后 stdout/stderr |

> `display_summary: null` 时，标签行以换行结束，内容从下一行开始。非 null 时，`display_summary` 紧接标签行输出。

**`ToolDisplay.render()` 伪代码**：
```
1. writeToolLabelOpen(writer)                    → 输出 " 工具 "
2. writer.print(result.display_label, ...)       → 输出 "Read AGENTS.md [limit=30]"
3. if result.display_summary |s|:                → 输出 "  -> 3 matches\n"
4. else:                                         → 输出 "\n<content>"
5. writeToolLabelClose(writer)                   → reset + 换行
```

> 渲染器不再解析 args_json — 工具通过 `display_label` 字段自描述，消除渲染层与工具参数 schema 的隐式耦合。`ToolDisplay.render()` 错误为非致命：Writer 断流/分配失败时 log stderr 并跳过显示，不终止 turn。

**依赖方向（V2 收敛后）**：

```
util/
  ↑
types.zig          ← 所有模块依赖
  ↑
config.zig  toml.zig
  ↑
tool/              ← 纯函数，不碰 Writer
  ↑
core/  io/         ← 业务/IO，不 import render
  ↑
render/cli.zig     ← 纯格式转换，import types
  ↑
App.zig            ← 组装 + 注入回调
  ↑
main.zig
```

### Phase 2: Provider 抽象（后续）

| 项 | 内容 |
|----|------|
| ProviderInterface | vtable 抽象（init / chat / modelSpec / deinit），agent 不 import 具体 provider 模块 |
| PhaseWriter 解耦 | PhaseWriter 通过回调注入，provider 不 import render |
| 多 provider 注册表 | 编译期 `ProviderEntry[]`，按 `api` 字段匹配 |
| HTTP 5xx 重试 | 对 429/502/503 指数退避重试 |
| Proxy 支持 | 配置 `proxy` 字段，curl `-x` 参数 |

### Phase 3: 工具增强（后续）

| 项 | 内容 |
|----|------|
| grep 递归 | `**` 递归目录搜索 |
| glob `**` 递归 | 完整 glob 递归匹配 |
| bash 超时 | 轮询超时 + kill 子进程 + `error.ToolTimeout` |
| ToolResult.stream | 增量渲染回调（长输出实时显示）。可考虑"事件流"架构：Agent/Tool 产出 `RenderEvent` union，`RenderEngine` 独立消费多路复用。Phase 1a 的 `ToolDisplayCb` 回调内部可适配为事件缓冲，回调签名无需修改 — 只需 `ToolDisplay.render()` 内部改为 push event → 延迟绘制，外部接口不变 |
| **Bash 安全（3a）** | 高优先级子集 — 命令替换检测 `$()` / `` ` `` / `${}`、换行注入、Shell 元字符（`;` `|` `&`）、反斜杠转义绕过、危险命令黑名单（sudo/eval/exec）、安全环境变量白名单 |
| **Bash 安全（3b）** | 完整 23 向量移植 — 参考 Claude Code `bashSecurity.ts`：IFS 注入、Unicode 空白、jq system()、控制字符、引号失同步、混淆参数、Zsh 特有危险命令（27 个）、随机盐占位符防注入、正则引擎 vs tree-sitter AST 回退 |

### Phase 4: 会话增强（后续）

| 项 | 内容 |
|----|------|
| Compaction | 消息压缩 + 摘要注入 |
| 精确 token 计数 | tiktoken 或 API usage 字段 |
| Memory 系统 | BM25 检索 + LLM 摘要 + 跨会话记忆 |
| Session 事务接口 | `commit(round)` / `rollback(round)` 替代 App 直接操作 `pre_count` + `truncateTo`，防止 App 侵入 Session 内部一致性 |

### Phase 5: Agent 增强（后续）

| 项 | 内容 |
|----|------|
| Permission 系统 | trust / ask_user / deny |
| Sub-agent delegation | task 工具 + result marker 通信 |
| 交互式配置模板 | 首次运行打印 TOML 预览 + 确认创建 |
| 自定义指令 | `.zagent/instructions.md` 或 CLI `--instructions` |

## C. Phase 1a 实施步骤

| Step | 内容 | 预估改动 | 验收 |
|------|------|---------|------|
| P1-1 | `types.zig`: 新增 `ToolResult{ display_label, display_summary, session_content }` | ~15 行 | 编译通过 |
| P1-2 | `render/cli.zig`: 新增 `ToolDisplay.render()` + `writeToolLabelOpen/Close` + 测试 | ~120 行 | `zig test src/test.zig` 通过 |
| P1-3 | 6 个工具模块: 修改 `execute()` 返回 `ToolResult`，移除 `display_writer` 使用 | 每个 ~20 行删减 | 编译 + 工具测试通过 |
| P1-4 | `tool/registry.zig`: `ToolEntry.execute` 签名改为返回 `ToolResult` | ~10 行 | 编译通过 |
| P1-5 | `core/agent.zig`: 接收 `tool_display` 回调，移除 `render` import + `writeLabeled` 调用 | ~30 行改 | agent 测试通过 |
| P1-6 | `io/provider.zig`: PhaseWriter 回调注入，移除 render import | ~15 行 | 编译通过 |
| P1-7 | `App.zig`: 初始化 `ToolDisplay`，注入回调到 agent；适配 `ToolResult` | ~40 行 | 端到端 `zig build run -- --prompt "read README.md"` |
| P1-8 | 删除 `plan-step9-tool-display.md`（内容已合并到本文档） | — | ✅ |
| P1-9 | `zig build test` 全量通过，`zig build check` 零警告 | — | 待实施 |
| P1-10 | 【V1 遗留】AI 输出 Markdown 流式渲染：`provider.zig` 的 `pw.writeRaw()` 改为按行缓冲 + `renderLine()` | ~50 行 | `zig build run -- --prompt "hello"` 输出带 ANSI |
| P1-11 | 【V1 遗留】`/load` 命令接入 `session.load()`：REPL 命令解析 + `agent` 重建 | ~20 行 | REPL 中 `/load <name>` 恢复会话 |
| P1-12 | 【V1 串联 + 事务收敛】`RenderContext` 替代模块级全局变量；`App.rollbackTurn(pre_count)` 统一回滚入口（truncateTo + render_ctx.reset + stdout_dead 检查），消除人肉同步纪律 | ~25 行 | 回滚后格式状态不污染下一 turn |
| P1-13 | 【V1 清理】删除 `session.popLast()` 死代码 + 对应 2 条测试 | ~20 行删减 | ✅ `zig build test` 通过 |

## C. Phase 1b 实施步骤

| Step | 内容 | 预估改动 | 验收 |
|------|------|---------|------|
| P1-14 | 【渲染增强】Markdown 表格渲染：参考 `projects/md2ansi/src/`（tokenizer + renderer，~550 行），移植到 `cli.zig`；CLI 无 TUI cell buffer，用独立版直接写 ANSI 路径 | ~300 行 | 表格输出含 Unicode 框线 + 列对齐 |
| P1-15 | 【V1 遗漏】`--help` CLI flag：`main.zig` 解析 `--help`，输出用法文本后 `exit(0)` | ~15 行 | `zig build run -- --help` 输出用法 |
| P1-16 | 【增强】DeepSeek 完整思考强度支持：`Model` 新增 `reasoning_effort`；`Message`/`ProviderResponse` 新增 `reasoning_content`，多轮工具调用回传 | ~80 行 | `zig build test` + 多轮工具调用不 400 |
| P1-17 | 【增强】`--model list` 从 API 拉取模型列表：Provider 新增 `listModels()`，DeepSeek 走 `GET {base_url}/models` | ~60 行 | `zig build run -- --model list` 输出列表 |
| P1-18 | 【增强】API 用量统计：`Usage` struct + SSE 捕获 + turn 结束显示 | ~60 行 | 每次 turn 结束显示 token 统计 |
| P1-19 | 【增强】curl 流读取超时：首 token 30s + chunk 间 10s | ~30 行 | 断流不挂死 |
| P1-17 | 【增强】`--model list` 从 API 拉取可用模型列表：Provider 新增 `listModels()`，内部按 vendor 分支 — DeepSeek 走 `GET {base_url}/models`，其他供应商默认返回 `not available for this provider`。解析 `{ data: [{id, owned_by}] }` 格式化输出 | ~60 行 | `zig build run -- --model list` 输出 DeepSeek API 返回的模型列表 |

## D. 验证

| 验证项 | 命令 | 通过标准 |
|--------|------|---------|
| 架构检查 | `node check-arch.mjs --fail-on-any` | 0 issue |
| 全量测试 | `zig build test` | 全部通过 |
| 编译检查 | `zig build check` | 零警告 |
| 端到端 | `zig build run -- --prompt "write test.txt"` | 多行内容正确 |
| 端到端 | `zig build run -- --prompt "hello"` | AI 输出含 ANSI 格式（标题/粗体/代码块），非纯 Markdown 文本 |
| 端到端 | `zig build run -- --prompt "grep fn in *.zig"` | 单行摘要正确 |
| 端到端 | `zig build run -- --prompt "read AGENTS.md"` | 工具输出格式符合目标 |

## E. V1 文档同步

| 文档 | 更新内容 |
|------|---------|
| `PLAN-V1-CLI-CORE.md` B 节依赖图 | 移除 agent/io import render 依赖线 |
| `PLAN-V1-CLI-CORE.md` C1/C3/C5/C6/C7 | 更新 ToolContext/agent/render 描述 |
| `plan-step3-tools.md` | ToolContext 移除 display_writer 字段 |
| `plan-step5-agent.md` | runTurn 签名新增 tool_display 参数 |
| `plan-step6-render.md` | 新增 ToolDisplay 节 |
| `plan-step7-app-integration.md` | 新增回调注入描述 |
