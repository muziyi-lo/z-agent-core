# Phase 1a: 渲染层收敛 + V1 遗留串联 — 详细实施计划

> 从 PLAN-V2-ARCHITECTURE.md §C 展开为可执行步骤。Phase 1a = 架构重构（P1-1~P1-7）+ V1 遗留串联（P1-10~P1-12）+ 清理（P1-8/9/13）。

## A. 前置基线确认（源码 vs V1 文档）

| # | 基线项 | 源码状态 | 确认 |
|---|--------|---------|------|
| A1 | `agent.zig` import `render/cli.zig` + 调 `writeLabeled(.tool, ...)` | `agent.zig:7` `agent.zig:137` | 待移除 |
| A2 | `provider.zig` import `render/cli.zig` + 用 `PhaseWriter` | `provider.zig:5` `provider.zig:82` | 待移除 |
| A3 | 6 工具全部用 `display_writer.print` | 全 `tool/*.zig` 均有 | 待移除 |
| A4 | `renderLine`/`resetCodeBlock`/`session.load` 已实现+测试但无外部调用者 | cli.zig + session.zig 测试之外 0 匹配 | 待串联 |
| A5 | `session.popLast()` 已删除 | `session.zig` grep 0 匹配 | P1-13 已完成 |
| A6 | `agent.zig` 无 `session.flush()` | `agent.zig` 内 0 匹配 | FIX-01 已完成 |
| A7 | `runTurn` 签名 `(writer, phase_writer)` 无 `tool_display` 回调 | `agent.zig:74-78` | 待修改 |
| A8 | `ToolResult` / `ToolDisplay` / `RenderContext` 均不存在 | 全库 grep 0 匹配 | 待创建 |

## B. 执行顺序

```
P1-1 (types) ──→ P1-2 (render/cli) ──→ P1-3 (6 tools) ──→ P1-4 (registry)
                                                              ↓
                                          P1-5 (agent) ──→ P1-6 (provider)
                                                              ↓
                                                         P1-7 (App)
                                                              ↓
                                                         P1-9 (verify)

并行（不阻塞核心链）:
  P1-12(a) (renderLine 签名变更 + 兼容包装) ── 可与 P1-2 并行，先于 P1-10
  P1-10 (renderLine 流式串联 + LineBuffer) ── 依赖 P1-12(a) + P1-6 后/provider
  P1-12(b) (消除模块级 var + 旧签名包装) ── 依赖 P1-10
  P1-11 (/load 命令) ── 依赖 P1-7/App

已完成:
  P1-8  (plan-step9 文档清理) — 目标文件不存在，无操作
  P1-13 (popLast 删除) — session.zig 中已清除
```

## C. 逐步骤实施

### C1. P1-1: types.zig — 新增 ToolResult

**目标**：工具返回结构化结果，替代 `[]const u8` + `display_writer` 副作用。

**接口**：

```zig
// types.zig — 在 ToolContext 定义之后
//
// 内存所有权：三个字段均从 ctx.allocator（父分配器）分配。
// Agent 在渲染 + session dupe 后必须调用 deinit() 释放。
pub const ToolResult = struct {
    display_label: []const u8,       // e.g. "Read AGENTS.md [limit=30]"
    display_summary: ?[]const u8,    // e.g. "-> 3 matches". null = 多行内容，此时不分配内存
    session_content: []const u8,     // appended to session, long-lived

    /// Free all allocated fields. Call after rendering + session dupe.
    /// 使用 defer result.deinit(ctx.allocator) 确保释放。
    /// display_summary = null 时不会 free（未分配内存）。
    pub fn deinit(self: *ToolResult, allocator: std.mem.Allocator) void {
        allocator.free(self.display_label);
        if (self.display_summary) |s| allocator.free(s);
        allocator.free(self.session_content);
    }
};
```

**改动**：`types.zig` 追加约 20 行，无删除。

**验收**：`zig build check` 编译通过。

---

### C2. P1-2: render/cli.zig — ToolDisplay + writeToolLabelOpen/Close

**目标**：统一工具输出渲染层，消除每个工具独立写 display_writer 的散落逻辑。

**接口**：

```zig
// render/cli.zig — 在 PhaseWriter 定义之后

/// Cross-turn mutable state for rendering.
pub const RenderContext = struct {
    code_block_active: bool = false,
    colorize: bool,
    stdout_dead: bool = false,       // 终端断流标志，agent turn 间检查
};

/// Unified tool rendering. Holds reference to RenderContext for cross-turn state.
pub const ToolDisplay = struct {
    ctx: *RenderContext,

    /// Static callback adapter for ToolDisplayCb injection.
    /// Casts opaque context to *ToolDisplay, then delegates to render().
    pub fn renderCb(ctx: ?*anyopaque, writer: *std.Io.Writer, result: types.ToolResult) void {
        const self: *ToolDisplay = @ptrCast(@alignCast(ctx orelse return));
        self.render(writer, result);
    }

    /// Render a tool result to writer. Internally catches all errors — non-fatal.
    /// 标签前缀统一为 " 工具  "（标签 + 两个空格），由 writeToolLabelOpen/Close 控制 ANSI。
    /// EPIPE/BrokenPipe 时设置 ctx.stdout_dead = true，agent 在 turn 间检查终止循环。
    pub fn render(self: *ToolDisplay, writer: *std.Io.Writer, result: types.ToolResult) void;

    /// Write ANSI open label: " 工具  " with gray background
    fn writeToolLabelOpen(writer: *std.Io.Writer) void;

    /// Write ANSI reset + newline after label + content
    fn writeToolLabelClose(writer: *std.Io.Writer) void;
};
```

**render() 错误处理伪代码**：

```
pub fn render(self: *ToolDisplay, writer: *std.Io.Writer, result: types.ToolResult) void {
    writeToolLabelOpen(writer) catch |err| {
        if (err == error.BrokenPipe) self.ctx.stdout_dead = true;
        logToStderr("render label error: {s}", .{@errorName(err)});
        return;
    };
    // ... print display_label ...
    // ... print display_summary or content ...
    // ... writeToolLabelClose ... same catch pattern
}
```

Zig 0.16 `std.Io.Writer` 在终端/管道关闭时返回 `error.BrokenPipe`（`std/Io.zig:305` — `FileWriteStreaming.Error`），Windows 和 POSIX 统一为此错误名。catch 分支模式匹配后设置标志位，不向上传播——`render()` 签名 `void` 强制内部消化。

Agent 在每次工具轮次前检查 `render_ctx.stdout_dead`：

```
// agent.zig — 工具循环顶部
if (self.render_ctx.stdout_dead) {
    return RoundResult{ .new_message_count = new_msgs, .finish = .stop };
}
```

**显示规范**：

| 工具 | 标签格式 | display_summary | 行数 |
|------|---------|----------------|------|
| read (file) | ` Read <path> [limit=N, offset=M]` | null | 多行 |
| read (dir/empty/error) | ` Read <path>` | `[dir: N entries]` / `File is empty` / `Error: ...` | 单行 |
| grep | ` Grep <pattern> <path>` | `-> N matches` | 单行 |
| glob | ` Glob <pattern> <path>` | `-> N files` | 单行 |
| skill | ` Skill <name>` | `Loaded: {name}` | 单行 |
| write | ` Write <path>` | null | 多行 |
| bash | ` $ <command>` | null | 多行 |

```
伪代码:
  writeToolLabelOpen(writer)                    → " 工具  "
  writer.print(result.display_label, ...)       → "Read AGENTS.md [limit=30]"
  if result.display_summary |s|:                → "  -> 3 matches\n"
  else:                                         → "\n<content>"
  writeToolLabelClose(writer)                   → reset + \n
```

**代码块全局变量迁移**：将当前 `render/cli.zig` 顶层的 `var code_block_active` 移入 `RenderContext`。`renderLine()` / `resetCodeBlock()` 改为接收 `*RenderContext` 参数（或通过 ToolDisplay 间接访问）。Phase 1a 保持兼容包装，P1-12 完成最终消除。

**改动**：`render/cli.zig` 新增约 120 行。

**验收**：`zig test src/test.zig` 中原有 render 测试仍通过，新增 ToolDisplay 测试覆盖 6 种工具格式。

---

### C3. P1-3: 6 个工具模块 — execute() 返回 ToolResult

**目标**：工具退化为纯函数，不再写 display_writer。

**改动模式**（以 read.zig 为例，其余 5 个相同模式）：

```zig
// 改前
pub fn execute(ctx: types.ToolContext, args: []const u8) anyerror![]const u8 {
    // ... core logic ...
    ctx.display_writer.print("Read {path}\n", ...) catch {};
    return content;
}

// 改后
pub fn execute(ctx: types.ToolContext, args: []const u8) anyerror!types.ToolResult {
    // ... core logic (same) ...
    return types.ToolResult{
        .display_label = try std.fmt.allocPrint(ctx.allocator, "Read {s}", .{path}),
        .display_summary = summary,  // or null
        .session_content = content,
    };
}
```

**各工具 display_label + display_summary 规则**：

| 工具 | display_label | display_summary |
|------|--------------|----------------|
| read | `Read {path}` + 如有 limit/offset 追加 `[limit=N, offset=M]` | 目录 → `[dir: N entries]`，空文件 → `File is empty`，错误 → `Error: ...`，文件 → null |
| write | `Write {path}` | null |
| bash | `$ {command}` | null |
| grep | `Grep "{pattern}" {path}` | `-> N matches` |
| glob | `Glob {pattern} {path}` | `-> N files` |
| skill | `Skill {name}` | `Loaded: {name}` |

**注意**：`display_label` / `display_summary` / `session_content` 当前全部用 `ctx.allocator`（父分配器）分配。过渡方案见 §D2。各工具已有 `ctx.allocator` 参数，无需新增分配器。

**ToolContext 清理**：移除 `display_writer: *std.Io.Writer` 字段（同时更新 types.zig 和所有构造点）。

**改动**：每个工具约删减 20 行（移除 display_writer 调用 + 调整返回类型）。`types.zig` 的 `ToolContext` 移除 `display_writer` 字段。

**验收**：各工具独立测试通过，返回 `ToolResult` 字段内容正确。

---

### C4. P1-4: tool/registry.zig — ToolEntry.execute 签名更新

**目标**：注册表接口与工具新签名对齐。

```zig
// tool/registry.zig

pub const ToolEntry = struct {
    name: []const u8,
    description: []const u8,
    params: []const u8,
    execute: *const fn (ctx: types.ToolContext, args: []const u8) anyerror!types.ToolResult,
    //                                                    ^^^^^^^^^^^^^^^^^^^^ 改这里
};

// Registry.execute 返回类型同步改为 ToolResult
pub fn execute(self: Registry, ctx: types.ToolContext, name: []const u8, args_json: []const u8) anyerror!types.ToolResult;
```

**改动**：签名行约 3 处修改，~10 行。

**验收**：编译通过。

---

### C5. P1-5: core/agent.zig — ToolDisplayCb 回调注入

**目标**：agent 不再 import render，不再直接调 writeLabeled。

**注意**：本步骤是 **中间态**。P1-6 完成后 `phase_writer` 才从 `runTurn` 移除（改为 Provider.init() 注入）。

```zig
// core/agent.zig

// 新增：回调结构体（匹配 PhaseWriterCb 模式，ctx + fn 解耦类型依赖）
pub const ToolDisplayCb = struct {
    context: ?*anyopaque,
    render: *const fn (ctx: ?*anyopaque, writer: *std.Io.Writer, result: types.ToolResult) void,
};

// runTurn 签名变更：
//   Phase 1a 中间态（P1-5 后、P1-6 前）：仍带 phase_writer
//   Phase 1a 终态（P1-6 后）：phase_writer 移除此参数
pub fn runTurn(
    self: *AgentLoop,
    writer: *std.Io.Writer,
    tool_display: ?ToolDisplayCb,     // 新增：null = headless mode
    phase_writer: ?*anyopaque,        // P1-6 后移除
) !RoundResult;
```

**agent import render 移除**：

```zig
// 删除行
const render = @import("../render/cli.zig");

// runTurn 内部：原 writeLabeled 调用替换为回调
// 改前:
//     try render.writeLabeled(writer, .tool, tool_label);
// 改后:
//     if (self.tool_display) |cb| {
//         cb.render(cb.context, writer, tool_result);
//     }
```

**AgentLoop 新增字段**：

```zig
pub const AgentLoop = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    provider_ref: *provider_mod.Provider,
    tool_registry: registry_mod.Registry,
    session_ref: *session_mod.Session,
    max_tool_rounds: u32,
    project_root: []const u8,
    tool_display: ?ToolDisplayCb,           // 新增：{context, render} 结构体
    stdout_dead_ptr: *bool,                 // 新增：指向 RenderContext.stdout_dead，Agent 不 import render
};
```

**工具循环中检查**：

```zig
// agent.zig — 每次工具轮次前
if (self.stdout_dead_ptr.*) {
    return RoundResult{ .new_message_count = new_msgs, .finish = .stop };
}
```

`stdout_dead_ptr` 由 `App.init()` 注入 `&self.render_ctx.stdout_dead`。Agent 仅读取一个 bool，不依赖 `RenderContext` 类型定义。

**工具 ToolContext 变化**：agent 构造 ToolContext 时不再传 `display_writer`（P1-3 已移除该字段）。

```zig
// 改前:
// const tool_ctx = types.ToolContext{
//     .allocator = self.allocator,
//     .io = self.io,
//     .project_root = self.project_root,
//     .display_writer = writer,        // 删除
// };
// 改后:
const tool_ctx = types.ToolContext{
    .allocator = self.allocator,
    .io = self.io,
    .project_root = self.project_root,
};
```

**改动**：`agent.zig` 新增回调字段 + 修改 runTurn 签名 + 替换 writeLabeled 调用。约 30 行改。

**init 签名变更**：`AgentLoop.init` 从位置参数切换为结构体参数模式。原 init 为 7 个位置参数——改为接收单个 struct 参数，字段名与参数原名一致，新增 `tool_display`、`stdout_dead_ptr` 字段默认值为 null。P1-7 的 `init(.{ .field = val, ... })` 调用语法依赖此变更。

**验收**：agent 测试用 mock provider + mock tool_display 回调验证回调通路。

---

### C6. P1-6: io/provider.zig — PhaseWriter 回调注入

**目标**：provider 不再 import render，PhaseWriter 通过初始化注入。

**思路**：Provider 初始化时接收 `PhaseWriter` 回调接口，替代当前直接 import 类型做强制转换。

```zig
// io/provider.zig

// 删除 import:
// const render = @import("../render/cli.zig");

// 新增：PhaseWriter 回调接口（provider 不持有 render 类型）
pub const PhaseWriterCb = struct {
    context: ?*anyopaque,
    begin_phase: *const fn (ctx: ?*anyopaque, mtype: PhaseType) void,
    write_raw: *const fn (ctx: ?*anyopaque, bytes: []const u8) void,
    end_phase: *const fn (ctx: ?*anyopaque) void,
};

pub const PhaseType = enum { none, thinking, content };

pub const Provider = struct {
    config: Config,
    phase_writer: ?PhaseWriterCb,  // 新增：注入而非 import

    pub fn init(allocator: std.mem.Allocator, entry: types.ProviderEntry, model: *const types.Model, vendor_override: ?Vendor, io: std.Io, phase_writer: ?PhaseWriterCb) !Provider;
};
```

**迁移策略**：`App.zig` 在创建 Provider 时传入 `PhaseWriterCb` 包装器（将回调转发到 `render.PhaseWriter`），provider 不再直接 import render 类型。

**改动**：`provider.zig` 移除 render import，新增 PhaseWriterCb 类型，init 接受回调参数。`chatCompletionStreaming` 中原 `pw: *render.PhaseWriter` 改为 `pw: PhaseWriterCb`。

**runTurn 终态**：P1-6 完成后，`runTurn` 签名移除 `phase_writer` 参数。

**验收**：编译通过，provider 测试用 mock PhaseWriterCb。

---

### C7. P1-7: App.zig — 组装 ToolDisplay + rollbackTurn

**目标**：初始化 ToolDisplay，注入回调到 agent，统一回滚入口。

```zig
// App.zig

pub const App = struct {
    // ... 现有字段 ...
    render_ctx: render.RenderContext,      // 新增
    tool_display: render.ToolDisplay,     // 新增
};

// init() 新增：
self.render_ctx = render.RenderContext{
    .colorize = render.hasColorize(),     // 读取模块级 colorize 标志
};
self.tool_display = render.ToolDisplay{ .ctx = &self.render_ctx };

// agent init 传入回调：
self.agent = agent_mod.AgentLoop.init(.{
    // ... 原有参数 ...
    .tool_display = .{
        .context = &self.tool_display,
        .render = render.ToolDisplay.renderCb,
    },
});

// 统一回滚：
pub fn rollbackTurn(self: *App, pre_count: usize) void {
    self.session.truncateTo(pre_count);
    self.render_ctx.reset();  // 清除 code_block_active 等状态
    // stdout_dead 检查 — 由 agent 在 turn 间检查 render_ctx.stdout_dead
}
```

**processLine / singleTurn 回滚统一**：

```zig
// 替换两处独立的 pre_count → truncateTo 为：
const pre_count = self.session.messages().len;
try self.session.append(.{ .role = .user, .content = line });

const result = self.agent.runTurn(...) catch |err| {
    if (err != error.OutOfMemory) {
        self.rollbackTurn(pre_count);
    }
    return err;
};
if (result.finish == .api_error or result.finish == .interrupted) {
    self.rollbackTurn(pre_count);
} else {
    try self.session.flush();
}
```

**改动**：`App.zig` 新增约 40 行。

**验收**：`zig build run -- --prompt "read README.md"` 端到端通过。

---

### C8. P1-8: 文档清理

确认 `docs/plan-step9-tool-display.md` 不存在：

```powershell
if (Test-Path "docs/plan-step9-tool-display.md") { Remove-Item "docs/plan-step9-tool-display.md" }
```

`PLAN-V2-ARCHITECTURE.md` 已包含原 step9 内容，无需额外操作。

---

### C9. P1-9: 全量验证

```powershell
zig build check    # 零警告
zig build test     # 全部通过
```

---

### C10. P1-10: V1 遗留 — provider writeRaw → renderLine 流式缓冲

**目标**：AI 输出 Markdown 流式渲染 — writeRaw 按行缓冲后调用 `renderLine()`。

**现有状态**：`provider.zig` 中 `pw.writeRaw(text)` 直接将 token 字节透传 stdout。`renderLine()` 已实现+测试但未被调用。

**方案**：在 `render/cli.zig` 中新增 `LineBuffer` 类型，封装行缓冲 + UTF-8 边界保护。provider 通过 PhaseWriterCb 传递原始 token，不关心字节细节。

```zig
// render/cli.zig — 新增 LineBuffer

/// Line-buffered writer that accumulates raw bytes and yields complete lines
/// for Markdown rendering. Handles multi-byte UTF-8 characters split across
/// chunks by holding incomplete sequences until the next chunk arrives.
pub const LineBuffer = struct {
    buf: std.array_list.Aligned(u8, null),
    allocator: std.mem.Allocator,        // 持有分配器，简化 feed/flush 签名
    render_ctx: *RenderContext,          // 用于 renderLine 新签名

    pub fn init(allocator: std.mem.Allocator, render_ctx: *RenderContext) LineBuffer;

    /// Feed raw bytes. Extracts complete lines and renders them via renderLine.
    /// Incomplete trailing UTF-8 sequences are kept in buffer for next feed.
    /// write_rendered callback receives a temporary slice — LineBuffer frees it
    /// after callback returns. Callback must NOT retain the slice pointer.
    pub fn feed(self: *LineBuffer, bytes: []const u8, write_rendered: *const fn (line: []const u8) void) !void;

    /// Flush remaining content as a final line (call at stream end).
    pub fn flush(self: *LineBuffer, write_rendered: *const fn (line: []const u8) void) !void;

    /// Clear pending buffer with capacity retention. Called on rollback.
    pub fn reset(self: *LineBuffer) void;
};
```

**init 实现**：

```zig
pub fn init(allocator: std.mem.Allocator, render_ctx: *RenderContext) LineBuffer {
    return .{
        .buf = std.array_list.Aligned(u8, null){},
        .allocator = allocator,
        .render_ctx = render_ctx,
    };
}
```

**reset 实现**：

```zig
pub fn reset(self: *LineBuffer) void {
    self.buf.clearRetainingCapacity();  // 保留已分配容量，避免重复分配
}
```

**UTF-8 边界保护 + 校验逻辑**（`feed` 内部）：

```
1. bytes 追加到 buf（用 self.allocator）
2. 扫描 buf 中的 \n：
   a. 提取 \n 之前的完整字节序列
   b. 检查序列末尾是否截断 UTF-8（用 std.unicode.utf8ByteSequenceLength 判断首字节预期长度）
   c. 若末尾字节不足一个完整码点：将不完整尾部留在 buf，仅提取之前的部分
   d. 调用 std.unicode.utf8ValidateSlice(line) 校验整行有效性
      — 无效时跳过该行（累积到下一行拼接后重试），不 panic
   e. 对有效行调用 renderLine(self.render_ctx, self.allocator, line)  → styled
      — 注意：P1-12 的 renderLine 签名变更在此直接使用新签名
   f. 用 defer self.allocator.free(styled) 确保回调后释放
   g. write_rendered(styled)  — 回调接收临时切片，不可保留引用
3. 无 \n 时所有内容留在 buf（可能是不完整行）
4. flush() 时将剩余内容强制作为一行输出（同样经过 UTF-8 校验 / renderLine）
```

**内存契约**：`renderLine` 返回的格式化字符串由 `LineBuffer.feed()` 用 `defer self.allocator.free(styled)` 释放。`write_rendered` 回调接收临时切片，必须同步使用，不可保留指针跨回调。

**注意**：P1-10 直接使用 `renderLine(self.render_ctx, ...)` 新签名（P1-12 的内容），因为 `LineBuffer` 已持有 `render_ctx`。P1-12 仅完成模块级 var 的最终消除，不改变签名。

**依赖**：P1-6 后 provider 不接触 renderLine。`LineBuffer` 是 render/cli.zig 内部类型，由 App 层的 PhaseWriterCb 包装器使用。

**PhaseWriterCb 扩展**：

```zig
// io/provider.zig
pub const PhaseWriterCb = struct {
    context: ?*anyopaque,
    begin_phase: *const fn (ctx: ?*anyopaque, mtype: PhaseType) void,
    write_raw: *const fn (ctx: ?*anyopaque, bytes: []const u8) void,
    write_rendered: *const fn (ctx: ?*anyopaque, line: []const u8) void,  // 新增：renderLine 处理后的行
    end_phase: *const fn (ctx: ?*anyopaque) void,
};
```

App 层的 PhaseWriterCb 实现内部创建 LineBuffer + RenderContext，`write_raw` 将字节喂给 LineBuffer，`write_rendered` 输出 ANSI 格式化行。provider 层仍然只调 `begin_phase` / `write_raw` / `end_phase`，零感知。

**改动**：`render/cli.zig` 新增 LineBuffer（~70 行）+ `io/provider.zig` PhaseWriterCb 扩展（~5 行）+ `App.zig` PhaseWriterCb 包装器适配 write_rendered（~5 行）= 约 80 行。

**验收**：`zig build run -- --prompt "hello"` 输出带 ANSI 格式（标题/粗体/代码块），非纯 Markdown 文本。

---

### C11. P1-11: V1 遗留 — /load 命令

**目标**：REPL 中 `/load <name>` 恢复已保存会话。

**现有状态**：`session.load()` 已实现+测试，但无 REPL 命令。当前仅支持 `/exit /new /name /list /help`。

**改动**：

```zig
// App.zig — processLine 新增分支

if (std.mem.startsWith(u8, line, "/load ")) {
    const name = std.mem.trim(u8, line["/load ".len..], " \t");
    if (name.len == 0) {
        try render.writeLabeled(self.stdout_writer, .err, "Usage: /load <session-name>");
        return;
    }
    // 动态分配路径，避免栈溢出
    const path = try std.fs.path.join(self.allocator, &.{ self.session_dir, name });
    defer self.allocator.free(path);
    const load_path = try std.fmt.allocPrint(self.allocator, "{s}.jsonl", .{path});
    defer self.allocator.free(load_path);

    // 失败时不退出 REPL
    const new_session = session_mod.Session.load(self.allocator, self.io, load_path) catch |err| {
        try render.writeLabeled(self.stdout_writer, .err, "Cannot load session: {s}");
        return;
    };
    self.session.deinit();
    self.session = new_session;
    try self.resetAgent();
    try render.writeLabeled(self.stdout_writer, .success, "Loaded session: {s}");
}
```

**App 新增字段**：

```zig
pub const App = struct {
    // ... 现有字段 ...
    stdout_buf: [4096]u8,                    // 新增：stdout_writer 的缓冲区（非栈局部，防悬垂）
    stdout_file_writer: Io.File.Writer,      // 新增：持有 File.Writer 实例，避免 &temp.interface 悬垂指针
    stdout_writer: *std.Io.Writer,           // 新增：指向 self.stdout_file_writer.interface（稳定）
    render_ctx: render.RenderContext,        // 新增
    tool_display: render.ToolDisplay,        // 新增
    line_buffer: render.LineBuffer,          // 新增：P1-10 流式行缓冲
};
```

**init() 中初始化**：

```zig
// App.init() 内，render.cli.init() 之后：
self.stdout_buf = undefined;  // 占位，Writer.init 不读取内容
self.stdout_file_writer = Io.File.Writer.init(.stdout(), self.io, &self.stdout_buf);
self.stdout_writer = &self.stdout_file_writer.interface;  // 稳定指针：file_writer 由 App 持有
self.render_ctx = render.RenderContext{
    .colorize = render.hasColorize(),
};
self.tool_display = render.ToolDisplay{ .ctx = &self.render_ctx };
self.line_buffer = render.LineBuffer.init(self.allocator, &self.render_ctx);
```

**resetAgent 定义**：

```zig
// App.zig 辅助方法（/load 和 /new 共用）
fn resetAgent(self: *App) !void {
    self.agent = agent_mod.AgentLoop.init(
        self.allocator,
        self.io,
        &self.provider,
        self.registry,
        &self.session,
        self.cfg.max_tool_rounds,
        self.project_root,
        .{
            .tool_display = .{
                .context = &self.tool_display,
                .render = render.ToolDisplay.renderCb,
            },
        },
    );
}
```

**保留状态**：`self.project_root`、`self.cfg`（含 `max_tool_rounds`）、`self.provider`、`self.registry`、`self.render_ctx`（独立于 session）。
**重建状态**：`self.session`（已由调用方替换）、`self.agent`（新 session_ref）。

**/load 完整流程**：

```
1. self.session.deinit()                              ← 释放旧 session
2. self.session = Session.load(...)                    ← 加载 JSONL
3. try self.resetAgent()                               ← 重建 AgentLoop（新 session_ref）
4. render.writeLabeled(.success, "Loaded session: ...")
5. self.render_ctx.reset()                             ← 重置代码块状态（防御性）
```

**改动**：`App.zig` 约 30 行（含 resetAgent 定义 + /load 命令分支）。

**验收**：REPL 中 `/load <name>` 恢复会话，消息历史完整。

---

### C12. P1-12: V1 串联 — RenderContext 替代模块级全局变量

**目标**：消除 `render/cli.zig` 中模块级 `var code_block_active` 和 `var colorize`，移入 `RenderContext`。

**当前代码**：

```zig
// render/cli.zig — 当前存在的模块级全局变量
var colorize: bool = false;
var code_block_active: bool = false;
```

**改动**：

1. `render/cli.zig` 中 `code_block_active` 从模块级 var 改为 `RenderContext` 字段
2. `renderLine(allocator, line)` 改为 `renderLine(ctx: *RenderContext, allocator, line)`
3. `resetCodeBlock()` 改为 `RenderContext.reset()`
4. 保留兼容包装（可选）：模块级 `resetCodeBlock()` 转发到全局 RenderContext 实例

**rollbackTurn 集成**：

```zig
// App.zig
pub fn rollbackTurn(self: *App, pre_count: usize) void {
    self.session.truncateTo(pre_count);
    self.render_ctx.reset();       // 清除 code_block_active
    self.line_buffer.reset();      // 清空 LineBuffer 驻留字节（P1-10）
    // stdout_dead 由 RenderContext 内部维护
}
```

**改动**：`render/cli.zig` + `App.zig` 约 25 行。

**验收**：回滚后 `renderLine` 的代码块状态不污染下一 turn。

---

### C13. P1-13: V1 清理 — popLast 删除（已完成）

**源码状态**：`session.zig` 中 `popLast()` 已不存在（被 `truncateTo` 替代），对应的测试也已移除。**无需任何操作**。

---

## D. 横切关注点

### D1. 依赖方向变化

```
修改前 (V1 现状):          修改后 (Phase 1a 终态):
                           
agent → render             agent → (回调, 不 import)
  ↑                           ↑
tool → display_writer      tool → ToolResult (纯数据)
  ↑                           ↑
provider → render           provider → PhaseWriterCb (回调, 不 import)
  ↑                           ↑
App → 全部                  App → 全部 → render
                              ↑
                            main → App
```

关键变化：
- `agent.zig` 删除 `const render = @import("../render/cli.zig")`
- `provider.zig` 删除 `const render = @import("../render/cli.zig")`
- `types.ToolContext` 删除 `display_writer` 字段
- `App.zig` 是唯一 import render 的模块

### D2. ToolResult 生命周期与清理契约

**核心规则**：ToolResult 的三个字段均从 `ctx.allocator`（父分配器）分配。Agent 在渲染 + dupe 后必须调用 `ToolResult.deinit()` 释放全部字段，避免逐轮泄漏。

```
工具内部:
  ctx.allocator → allocPrint/dispose 分配 3 个字段
    ↓
  返回 ToolResult{ .display_label, .display_summary, .session_content }
    ↓
agent 工具调用循环:
  const result = try registry.execute(ctx, name, args);
  defer result.deinit(ctx.allocator);          ← ★ 确保清理

  if (self.tool_display) |cb| cb(writer, result);  // 回调渲染，不保留引用
  try self.session_ref.append(.{               // session.append 内部 dupe
      .role = .tool,
      .content = result.session_content,       // 原内容随 defer deinit 释放
      .tool_call_id = tc.id,
  });
  // result.deinit(ctx.allocator) 由 defer 执行
```

**释放细节**：

| 字段 | 分配器 | 释放时机 | 释放方式 |
|------|--------|---------|---------|
| `display_label` | `ctx.allocator` | 渲染回调返回后 | `defer result.deinit(ctx.allocator)` |
| `display_summary` | `ctx.allocator`（null 时不分配）| 同上 | 同上（null 分支不 free） |
| `session_content` | `ctx.allocator` | session.append dupe 后 | 同上 |

**错误安全**：Zig 的 `defer` 在正常返回和 `return error` 路径均执行。即使 session.append 失败，`defer result.deinit()` 仍会释放全部字段，不泄漏。

**对比原文稿**：~~"无需释放 display_label/display_summary — 等父分配器整体释放"~~ ❌ 这是泄漏。✅ 改为 `defer result.deinit(ctx.allocator)` 精确释放。

**过渡说明**：V1 工具通过 `ctx.allocator` 分配返回值的模式不变。ToolResult 字段暂时也用 `ctx.allocator`。未来（Phase 3 流式工具）可改为 Arena 分配，当前不引入 Arena 复杂性。

**已知限制**：工具 `execute()` 返回 `!ToolResult`（可错误）。若工具执行失败（如文件不存在、权限拒绝），`try` 在到达 `cb.render()` 前传播错误，**错误对用户不可见**——仅 App 层 catch 能记录。Phase 1a 保持此行为不变；Phase 2 应引入 `ToolResult{ .error = ... }` 变体由渲染层统一展示错误。

### D3. phase_writer 的渐进式移除策略

```
P1-5 后（中间态）:
  runTurn(writer, tool_display, phase_writer)
  — tool_display 已就绪，但 phase_writer 仍通过 opaque 指针传递

P1-6 后（终态）:
  Provider.init() 注入 PhaseWriterCb
  runTurn(writer, tool_display)        ← phase_writer 参数移除
  — provider 内部通过 self.phase_writer 访问渲染回调

迁移风险:
  P1-5 完成后但 P1-6 未完成时，phase_writer 仍必须存在。
  若中间态需测试，将 phase_writer 传为 null 即可（provider 无相位标签）。
```

## E. 测试计划

### 单元测试（按步骤）

| 步骤 | 测试 | 类型 |
|------|------|------|
| P1-2 | `ToolDisplay.render()` 覆盖全部 7 种工具格式 + `display_summary` null 分支 | 新增 |
| P1-2 | `ToolDisplay.render()` EPIPE 不 panic（mock writer 返回 error） | 新增 |
| P1-3 | 每个工具 `execute()` 返回 ToolResult 字段正确 | 修改现有测试 |
| P1-3 | 每个工具 `execute()` 不残留 display_writer 调用 | 修改现有测试 |
| P1-5 | Agent 回调通路：mock ToolDisplayCb 验证被调用次数/参数 | 新增 |
| P1-5 | Agent headless mode：`tool_display=null` 不 panic | 新增 |
| P1-6 | Provider mock PhaseWriterCb 验证 begin/write/end 序列 | 新增 |
| P1-10 | renderLine 缓冲：多块到达拼成完整行才渲染 | 新增 |
| P1-12 | `RenderContext.reset()` 后 code_block_active 归零 | 新增 |
| P1-12 | 模块级 var 全部移入 RenderContext（编译确认） | 新增 |
| P1-13 | 确认 `popLast` 符号不存在 | 已通过 |

### 集成测试

| 验证项 | 命令 | 通过标准 |
|--------|------|---------|
| 编译 | `zig build check` | 零警告 |
| 全量测试 | `zig build test` | 全部通过 |
| 架构检查 | `check-arch --fail-on-any` | 0 issue（agent/provider 不再 import render） |
| 端到端: hello | `zig build run -- --prompt "hello"` | AI 输出带 ANSI 格式 |
| 端到端: 工具 | `zig build run -- --prompt "read docs/PLAN-V2-ARCHITECTURE.md"` | 工具输出符合目标格式 |
| 端到端: 回滚 | `zig build run` 中 Ctrl+C | session 不残留 orphan 消息 |
| 回滚后格式 | 同上 | 回滚后下一 turn 代码块状态重置 |
| 错误: /load 无效 | REPL 中 `/load nosuch` | 输出错误信息 + 保留原会话 |
| 错误: UTF-8 无效 | 模拟非法字节序列喂入 LineBuffer | 跳过无效行，不 panic |
| 错误: EPIPE | 关闭 stdout 后执行工具 | agent 下一轮次检查 stdout_dead 终止 |
| 错误: 工具权限 | `zig build run -- --prompt "read /etc/shadow"` | 工具错误不崩溃，REPL 继续 |

## F. 验证命令

```powershell
# 每步后验证
zig build check
zig test src\test.zig --cache-dir .zig-cache

# Phase 1a 完成后全量
zig build check
zig build test
node ../../.opencode/skills/zig-dev/scripts/check-arch.mjs . --fail-on-any
zig build run
zig build run -- --prompt "hello"
zig build run -- --prompt "read src/main.zig"
```

## G. 文件改动总览

| 文件 | P1-1 | P1-2 | P1-3 | P1-4 | P1-5 | P1-6 | P1-7 | P1-10 | P1-11 | P1-12 | 合计 |
|------|:----:|:----:|:----:|:----:|:----:|:----:|:----:|:-----:|:-----:|:-----:|:----:|
| `src/types.zig` | +20 | | -3 | | | | | | | | **+17** |
| `src/render/cli.zig` | | +120 | | | | | | +70 | | +15 | **+205** |
| `src/tool/read.zig` | | | -20 | | | | | | | | **-20** |
| `src/tool/write.zig` | | | -20 | | | | | | | | **-20** |
| `src/tool/bash.zig` | | | -20 | | | | | | | | **-20** |
| `src/tool/grep.zig` | | | -20 | | | | | | | | **-20** |
| `src/tool/glob.zig` | | | -20 | | | | | | | | **-20** |
| `src/tool/skill.zig` | | | -20 | | | | | | | | **-20** |
| `src/tool/registry.zig` | | | | +10 | | | | | | | **+10** |
| `src/core/agent.zig` | | | | | +30 | | | | | | **+30** |
| `src/io/provider.zig` | | | | | | +15 | | +5 | | | **+20** |
| `src/App.zig` | | | | | | | +40 | +5 | +40 | +10 | **+95** |
| **净增行** | 20 | 120 | -120 | 10 | 30 | 15 | 40 | 80 | 40 | 25 | **+260** |

---

## H. 第三方审查采纳记录

| # | 建议 | 裁决 | 理由 |
|---|------|------|------|
| 1 | ToolResult 内存泄漏（display_label/summary 未释放） | **采纳** | 父分配器 process.arena 进程退出才释放，逐轮调用累积泄漏。已修正 D2 为 `defer result.deinit(ctx.allocator)` |
| 2 | SSE UTF-8 分片导致 renderLine 解析错误 | **采纳** | 新增 LineBuffer 类型，用 `std.unicode.utf8ByteSequenceLength`（Zig 0.16 `std/unicode.zig:28`）检测不完整序列 |
| 3 | stdout_dead 标志无落地实现 | **部分采纳** | 已补充 `error.BrokenPipe`（Zig 0.16 `std/Io.zig:313`）匹配伪代码 + agent turn 间检查 |
| 4 | /load resetAgent 未定义 | **采纳** | 已明确定义：保留 project_root/cfg/provider/registry，重建 session + agent |
| 5 | 推荐 defer 模式 | **采纳** | 已融入 D2：`const result = try ...; defer result.deinit(ctx.allocator);` |
| 6 | 推荐 LineBuffer 类型 | **采纳** | 已融入 P1-10：render/cli.zig 新增 `LineBuffer`，provider 层零感知 |
| 7 | 推荐 std.log 替代 stderr | **拒绝** | 项目约定 `Io.Writer` 显式 I/O 实现可测试性（V1 plan-step1-config §B8），`std.log` 不可拦截 |
| 8 | LineBuffer 回滚时未清缓冲区 | **采纳** | 新增 `LineBuffer.reset()` + `rollbackTurn` 中调用 |
| 9 | renderLine 返回字符串内存所有权不明 | **采纳** | 明确契约：`feed` 用 `defer allocator.free(styled)` 释放，`write_rendered` 接收临时切片不保留引用 |
| 10 | /load 栈缓冲区溢出风险 | **采纳** | `var load_path_buf: [1024]u8` → `std.fmt.allocPrint` + `defer allocator.free` |
| 11 | resetAgent stdout_writer 未定义 | **采纳** | App 新增 `stdout_writer: *std.Io.Writer` 字段，`init()` 中通过 `Io.File.Writer.init(.stdout(), io, &buf)` 初始化 |
| 12 | /load 无错误降级（try 直接崩溃） | **采纳** | `catch {}` 包裹 session.load，失败时输出错误 + 保留原会话，不退出 REPL |
| 13 | LineBuffer UTF-8 验证不完整 | **采纳** | feed 中提取行后调用 `std.unicode.utf8ValidateSlice`（`std/unicode.zig:231`），无效行跳过不 panic |
| 14 |     stdout_dead 传递：Agent 无法访问 RenderContext | **采纳** | AgentLoop 新增 `stdout_dead_ptr: *bool` 字段，由 App.init 注入 `&self.render_ctx.stdout_dead`（BrokenPipe 位于 `std/Io.zig:305`），Agent 不依赖 render 类型 |

| 15 | stdout_writer 缓冲区的栈悬垂 | **采纳** | `var obuf: [4096]u8` 局部变量 → App 结构体字段 `stdout_buf: [4096]u8` |
| 16 | LineBuffer 分配器未持有 | **采纳** | LineBuffer 新增 `allocator: std.mem.Allocator` 字段 + `init()` 构造函数，feed/flush 签名不再传 allocator |
| 17 | renderLine 签名变更顺序依赖 | **采纳** | LineBuffer 通过 `self.render_ctx` 直接使用 P1-12 新签名 `renderLine(self.render_ctx, self.allocator, line)`，P1-10 不阻塞 P1-12 |
| 18 | LineBuffer.reset() 实现 | **采纳** | 使用 `buf.clearRetainingCapacity()` 保留容量 |

## I. 实施顺序精炼

基于第三方审查对步骤依赖的分析，调整 P1-10/P1-12 的执行顺序：

```
原顺序:  P1-2 → P1-10 → P1-12  (renderLine 签名变交叉引用)
精炼后: P1-2 → P1-12(a) → P1-10 → P1-12(b)

P1-12(a): 先修改 renderLine 签名，新增兼容包装
P1-10:    LineBuffer 直接使用新签名
P1-12(b): 最终消除模块级 var + 旧签名包装
```

P1-12(a) 与 P1-2 无冲突，可并行实施。LineBuffer 的 `init()` 在 P1-2（ToolDisplay）中一并实现。

## J. Zig 0.16 stdlib API 验证表

本计划引用的全部 stdlib API 及验证状态（按 design-checklist.md G7 要求）：

| 引用 | 文件:行 | API | ✅/⚠️/❌ | 说明 |
|------|---------|-----|---------|------|
| `error.BrokenPipe` | `std/Io.zig:305` | `FileWriteStreaming.Error` | ✅ | POSIX/Windows 统一错误名 |
| `utf8ByteSequenceLength` | `std/unicode.zig:28` | `fn(first_byte: u8) !u3` | ✅ | 参数/返回值均正确 |
| `utf8ValidateSlice` | `std/unicode.zig:231` | `fn(input: []const u8) bool` | ✅ | 参数/返回值均正确 |
| `std.Io.Writer` | `std/Io.zig:42` | Writer 类型别名 | ✅ | 全路径 `std.Io.Writer` 有效 |
| `Io.File.Writer.init()` | `std/Io/File/Writer.zig:36` | `fn(file, io, buffer) Writer` | ✅ | 返回 Writer 按值；需存入 struct 字段防悬垂 |
| `Io.File.Writer.interface` | `std/Io/File/Writer.zig:19` | `Io.Writer` 字段 | ✅ | 指针仅在 File.Writer 存活时有效 |
| `Io.File.stdout()` | `std/Io/File.zig:91` | `fn() File` | ✅ | 返回 stdout 文件句柄 |
| `std.array_list.Aligned` | `std/array_list.zig` | `Aligned(T, alignment)` | ✅ | 非弃用替代 `ArrayListAligned` |
| `std.unicode.Utf8View` | `std/unicode.zig` | UTF-8 迭代器 | ⚠️ | P1-10 不使用，但可作为备选方案 |
| `std.Io.Mutex` | `std/Io.zig:1613` | `Mutex` 类型 | — | 本阶段不涉及，仅为 AGENTS.md 陷阱对照 |
| `std.Random.DefaultPrng` | `std/Random.zig:13` | PRNG 初始化 | — | 本阶段不涉及 |
| `Io.sleep()` | `std/Io.zig:2478` | `fn(io, duration, clock)` | — | 本阶段不涉及 |
| `std.process.Environ` | `std/process/Environ.zig` | 环境变量访问 | — | 本阶段不涉及 |

**设计时陷阱对照** (AGENTS.md pitfall table):
- `ZIG-METHOD` — 模块级 fn 不为 struct 方法：ToolDisplay.renderCb 为 struct 成员，ToolDisplayCb 为 struct 类型，均无此问题
- `ZIG-016-MUTEX` — `std.Thread.Mutex` 已移除 → 本阶段不涉及
- `ZIG-016-RANDOM` — `std.crypto.random` 已移除 → 本阶段不涉及
- `ZIG-016-SLEEP` — `std.time.sleep` 不存在 → 本阶段不涉及
- `ZIG-016-ENV` — `std.process.getEnvMap` 已移除 → 本阶段不涉及
