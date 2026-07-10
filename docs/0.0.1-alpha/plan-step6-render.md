# Step 6: render/cli.zig -- CLI 美化层

> 纯格式模块，不 import core/io/tool。App 层调用它给 Writer 加 ANSI 包装。精简 Markdown->ANSI 基础。

## A. 源码依据

| 源文件 | 用途 |
|--------|------|
| `projects/z-agent/src/ansi.zig:5-17` | ANSI Color 常量定义 (Color struct + C 实例) |
| `projects/z-agent/src/ansi.zig:85-97` | `shouldColorize()` / `supportsColor()` 颜色检测 |
| `projects/z-agent/src/ansi.zig:99-110` | `enableWindowsVT()` Windows 终端 VT 处理 |
| `projects/z-agent/src/render/MessageRenderer.zig:7-24` | Msg 联合类型设计参考 |
| `projects/z-agent/src/tui/InputLine.zig:317-328` | CJK 字符宽度检测 (isWideChar) |
| `projects/z-agent/src/md2ansi/` | Markdown->ANSI 渲染参考 (V1 只取基本模式：标题/代码块/粗斜体/列表/链接/行内代码) |

## B. 模块设计

### B1. z-agent 减法

| 减法 | z-agent (不迁移) | z-agent-core V1 (替代) |
|------|-----------------|----------------------|
| TUI 基础设施 | alt screen, mouse tracking, raw mode, cursor control, readLine, readByteRaw | 不实现 -- CLI only |
| 颜色初始化 | `ansi.init()` 调用 Windows API 启用 VT + 设置 console mode | 简化为 `init()` 仅启用 Windows VT |
| MessageRenderer | 联合类型 Msg 含 16 种变体 (tool_call, compression, permission_confirm...) | V1 不需要 -- agent 直接写 Writer，App 层决定是否包装 |
| md2ansi 完整引擎 | 表格渲染、图片渲染、复杂嵌套行内格式 | 基础 Markdown 行级识别：标题/代码块/粗斜体/列表/行内代码/链接 |
| 颜色检测 | `shouldColorize()` 含 libc `isatty` + `getenv("NO_COLOR"/"TERM")` | `init()` 内部检查 NO_COLOR + Windows VT 状态，设置模块级标志。`writeLabeled`/`renderLine` 内部自动遵守，App 无需每处判断 |

### B2. 模块职责

```
render/cli.zig:
  - ANSI 颜色常量 (Color struct, 含背景色)
  - Windows VT 初始化 (init)
  - CJK 字符宽度检测 (visibleWidth)
  - 标签消息写入 (writeLabeled)
  - 行级 Markdown->ANSI 转换 (renderLine)
```

`render/cli.zig` 不 import `core/`、`io/`、`tool/` -- 是纯格式层。App.zig 负责调用 `init()` 启用 VT，然后可选地将 Writer 包装为 ANSI Writer。

### B3. 数据结构

```zig
/// ANSI SGR color constants.
pub const Color = struct {
    reset:    []const u8 = "\x1b[0m",
    green:    []const u8 = "\x1b[32m",
    yellow:   []const u8 = "\x1b[33m",
    red:      []const u8 = "\x1b[31m",
    bold:     []const u8 = "\x1b[1m",
    dim:      []const u8 = "\x1b[2m",
    cyan:     []const u8 = "\x1b[36m",
    blue:     []const u8 = "\x1b[34m",
    magenta:  []const u8 = "\x1b[35m",
    white:    []const u8 = "\x1b[37m",
    bright_black: []const u8 = "\x1b[90m",
    bg_blue:  []const u8 = "\x1b[44m",
    bg_gray:  []const u8 = "\x1b[100m",
    bg_green: []const u8 = "\x1b[42m",
};

pub const C: Color = .{};

/// Semantic message type for label + body rendering.
pub const MessageType = enum {
    user,       // blue bg + white label "用户"   + white body
    think,      // gray bg + white label "思考"   + gray body (\x1b[90m)
    tool,       // gray bg + white label "工具"   + gray body (\x1b[90m)
    output,     // green bg + white label "输出"  + normal body
    err,        // red body, no bg label
    warning,    // yellow body, no bg label
    success,    // green body, no bg label
};
```

### B4. 公共接口

```zig
/// Enable Windows VT + set colorize flag (checks NO_COLOR, VT state).
/// Call once in App.init(). All render functions automatically respect colorize state.
pub fn init() void;

/// Count visible columns, CJK characters = 2, ASCII = 1.
/// V1 limitation: hand-written CJK ranges; Zig 0.16 lacks utf8CodepointSequenceWidth.
pub fn visibleWidth(s: []const u8) usize;

/// ─── 一次性标签消息 ───

/// Write a complete labeled message (label + text on same line, trailing newline).
/// For non-streaming use: user input echo, tool labels, errors, warnings.
/// Output (color): {bg}{white} LABEL {reset}{body_color}{text}{reset}\n
pub fn writeLabeled(writer: *std.Io.Writer, mtype: MessageType, text: []const u8) !void;

/// Write styled REPL prompt prefix without trailing newline.
/// Output (color): {bg}{white} 用户 {reset} (terminal echoes user input after this)
pub fn writePrompt(writer: *std.Io.Writer) !void;

/// ─── 流式相位追踪 (PhaseWriter) ───

/// Phase-aware writer wrapper. Provider writes raw content through this;
/// it injects ANSI label headers/footers on content-type transitions.
/// App.zig creates and owns it; passed to provider via agent as opaque pointer.
pub const PhaseWriter = struct {
    inner: *std.Io.Writer,
    phase: enum { none, thinking, content } = .none,

    /// Switch to a new content phase. Writes label header on first
    /// content of each type, closes previous label if transitioning.
    pub fn beginPhase(self: *PhaseWriter, mtype: MessageType) !void;

    /// Close current phase (writes reset + newline). Call at end of stream.
    pub fn endPhase(self: *PhaseWriter) !void;

    /// Write raw bytes directly (no label injection). Used for streaming
    /// content tokens between beginPhase / endPhase calls.
    pub fn writeRaw(self: *PhaseWriter, bytes: []const u8) !void;

    /// Get underlying writer for non-phase-aware consumers (agent, App).
    pub fn innerWriter(self: *PhaseWriter) *std.Io.Writer;
};

/// ─── Markdown 渲染 ───

/// Render one line of Markdown text with ANSI styling.
/// Internally checks colorize flag; no color → plain text.
/// Returns allocator-owned styled string; caller must free.
/// LIMITATION: line-level only — cross-line syntax (**bold across\nlines**) not supported.
pub fn renderLine(allocator: std.mem.Allocator, line: []const u8) ![]const u8;

/// Reset internal code block state (call at start of each turn for safety).
/// renderLine also auto-detects code block boundaries internally — reset is belt-and-suspenders.
pub fn resetCodeBlock() void;
```

接口契约：
- `init()` 一次性设置颜色开关（NO_COLOR + Windows VT 状态）。App 只需调用一次。
- **一次性标签** (`writeLabeled`)：用于非流式场景——用户输入回显、工具标签、错误/警告。标签和正文同行显示。
- **流式标签** (`PhaseWriter`)：用于 provider 的 SSE 流式输出。provider 调用 `beginPhase(.think)` / `beginPhase(.output)` 在内容类型切换时注入标签头。`writeRaw` 写入流式 token 字节。`endPhase` 在流结束时收尾。PhaseWriter 封装了 `writeLabelBegin`/`writeLabelEnd` 的低级 ANSI 拼接。
- **REPL 提示符** (`writePrompt`)：行内标签，不带换行。模板 ` 用户 ` 自带蓝底装饰空格，`{reset}` 后跟显式空格作为输入分隔符。
- **Markdown 渲染** (`renderLine`)：`writeLabeled` 和 `renderLine` 走独立路径。`renderLine` 返回 allocator 分配的字符串，调用方负责 free。

标签渲染效果示例：
```
 用户  read src/main.zig              → 蓝底白字标签 + 白色正文 (同行)
 思考  analyzing requirements...      → 灰底白字标签 + 灰色正文 (同行, 流式)
 工具  Read "C:/Project/read.md" [limit=30]
                                       → 灰底白字标签 + 灰色正文 (同行)
 输出  Result: file contents          → 绿底白字标签 + 正常正文 (同行, 流式)
```

`err`/`warning`/`success` 不设背景标签，仅彩色字 + 前缀：
```
ERROR  API key not set                → 红字
WARN   context may overflow           → 黄字
OK     session saved                  → 绿字
```

### B5. Markdown 行级识别规则

按优先级：

| 优先级 | 模式 | 样式 | 示例 |
|--------|------|------|------|
| 1 | `^(#{1,6}) ` 开头 | heading (bold+cyan) | `## Title` -> `\x1b[1m\x1b[36m## Title\x1b[0m` |
| 2 | 在代码块内 (` ``` ` 包围) | code (dim) | 保持原样，dim 着色 |
| 3 | `^> ` 开头 | dim | `> quote` -> dim |
| 4 | `^[*\-+] ` 开头 | 保持原样 (无额外样式) | `- item` -> `  - item` |
| 5 | `[text](url)` 链接 | 先提取为占位符，最后替换为 blue 文本 | `[click](url)` -> `\x1b[34mclick\x1b[0m` |
| 6 | 行内 `**text**` | bold 包裹 | `**hello**` -> `\x1b[1mhello\x1b[0m` |
| 7 | 行内 `*text*` | bold 包裹 | `*hi*` -> `\x1b[1mhi\x1b[0m` |
| 8 | 行内 `` `code` `` | dim 包裹 | `` `foo` `` -> `\x1b[2m foo \x1b[0m` |

处理顺序：**先提取链接** `[text](url)` → 替换为占位符 → 处理粗体/代码（规则 6-8，按优先级）→ 占位符还原为蓝色链接文本。此顺序确保 `[**bold**](url)` 和 `` [`code`](url) `` 中链接样式不丢失。

规则 6-8 在行内多次匹配（非贪婪），替换全部出现。规则 6 优先于 7（`**` 先匹配，避免被 `*` 误匹配）。

代码块状态自动检测：`renderLine` 内部遇到以 `` ``` `` 开头的行时：若不在代码块中则进入，若已在代码块中则退出。`resetCodeBlock()` 提供显式重置作为安全网。V1 限制：模块级静态变量，单线程同步足够。

### B6. 设计注释与 V1 已知限制

- **不实现表格/图片** -- 完整 md2ansi 引擎 ~2000 行，V1 不值。LLM 流式输出 95% 是文本+代码块+列表。
- **`renderLine` 跨行不支持** -- 纯行级识别，`**跨行 bold**` 片段会断裂。V2 考虑行间状态机。
- **代码块状态自动检测** -- `renderLine` 内部幂等检测 `` ``` `` 边界，`resetCodeBlock()` 作为安全网保留。V1 单线程同步足够。
- **链接优先提取** -- `[text](url)` 先转换为占位符，再处理内联粗体/代码，最后还原。避免 `[**bold**](url)` 样式丢失。
- **`visibleWidth` 手写 CJK 范围** -- Zig 0.16 无 `utf8CodepointSequenceWidth` API，手写范围是唯一可行方案。V2 升级 stdlib 后替换。
- **`renderLine` 用 allocator 而非 Writer** -- 测试中可 assert 输出字符串。App 层拿到字符串后 `writer.print("{s}\n", .{rendered})` 写入。
- **颜色开关自动化** -- `init()` 一次性检查 NO_COLOR + Windows VT 状态，设置模块级标志。`writeLabeled`/`renderLine` 内部检查标志，App 无需每处写 `if`。NO_COLOR 存在时全部输出纯文本。
- **背景标签实现** -- `writeLabeled` 内部拼接 `{bg}{white} LABEL {reset}{body_color}{text}{reset}\n`，标签固定宽度左对齐。
- **接口分离** -- `writeLabeled` 接受纯文本正文，`renderLine` 产出带 ANSI 的字符串。两者不混用。
- **PhaseWriter 流式相位追踪** -- 为了解决 `writeLabeled` 无法用于流式输出的问题（文本分块到达，无法预知全文），引入 `PhaseWriter` 结构体。provider 调用 `beginPhase(mtype)` 切换内容类型，PhaseWriter 自动注入/关闭 ANSI 标签。`writeRaw` 在相位间透传原始 token 字节。PhaseWriter 内部封装了 `writeLabelBegin`/`writeLabelEnd` 的低级拼接，对外暴露语义化接口。**依赖方向**：`io/provider.zig` import `render/cli.zig` 获取 PhaseWriter 类型（允许——io/ 在 render/ 上方），`core/agent.zig` 不 import render（通过 App 以 `?*anyopaque` 传递 PhaseWriter 指针）。
- **`writePrompt` REPL 专用** -- 与 `writeLabeled` 分离：`writeLabeled(.user, text)` 是一次性消息回显（标签+文本+换行），`writePrompt` 是行内提示符（标签+空格，无换行）。REPL 模式下不调用 `writeLabeled(.user, ...)`——prompt + 终端 echo 已显示用户输入，避免双重用户标签。

## C. 接口设计

### C1. init()

```zig
/// On Windows: enable virtual terminal processing on stdout.
/// Sets internal colorize flag: false if NO_COLOR env var is set,
/// or if Windows VT enabling failed (piped/redirected).
/// On other platforms: NO_COLOR check only.
/// Call once in App.init(). All render functions internally check colorize flag.
pub fn init() void;
```

### C2. visibleWidth()

```zig
/// Count visible display columns. CJK/wide chars count as 2, ASCII as 1.
/// V1 limitation: hand-written Unicode range; Zig 0.16 lacks codepoint width API.
pub fn visibleWidth(s: []const u8) usize;
```

用于 App 层终端宽度计算。从 z-agent 的 `isWideChar()` 逻辑提取：判断 Unicode 码点是否在 CJK/全角范围 (U+1100~U+115F, U+2E80~U+9FFF, U+A000~U+A4CF, U+AC00~U+D7AF, U+F900~U+FAFF, U+FE30~U+FE6F, U+FF01~U+FF60, U+FFE0~U+FFE6, U+1F300~U+1F64F, U+20000~U+2FFFF)。

### C3. writeLabeled()

```zig
/// Write a labeled message with background color tag + trailing newline.
/// Output: {bg}{white} LABEL {reset}{body_color}{text}{reset}\n
/// mtype: user (blue bg), tool/think (gray bg), output (green bg),
///        err/warning/success (no bg, colored text only).
pub fn writeLabeled(writer: *std.Io.Writer, mtype: MessageType, text: []const u8) !void;
```

App 层用法示例：
```zig
// 用户输入回显
try writeLabeled(writer, .user, "read src/main.zig");
// -> \x1b[44m\x1b[37m 用户 \x1b[0m read src/main.zig

// 工具调用 (gray text body)
try writeLabeled(writer, .tool, "Read \"C:/Project/read.md\" [limit=30]");
// -> \x1b[100m\x1b[37m 工具 \x1b[0m\x1b[90m Read "C:/Project/read.md" [limit=30]\x1b[0m

// 思考内容 (gray text body)
try writeLabeled(writer, .think, "analyzing requirements...");
// -> \x1b[100m\x1b[37m 思考 \x1b[0m\x1b[90m analyzing requirements...\x1b[0m

// LLM 流式输出
try writeLabeled(writer, .output, chunk);
```

### C4. renderLine()

```zig
/// Render one Markdown line. Returns allocator-owned styled string.
/// Handles code block state internally. Caller must call resetCodeBlock()
/// at end of turn to reset code block tracking.
pub fn renderLine(allocator: std.mem.Allocator, line: []const u8) ![]const u8;

/// Reset internal code block state (call at start/end of each turn).
pub fn resetCodeBlock() void;
```

### C5. 依赖方向

```
types.zig
    ↑
util/text.zig
    ↑
render/cli.zig       ← 纯格式层，不 import core/io/tool
    ↑
App.zig              ← 调用 init() + 按需包装 Writer
```

## D. 新增/修改文件清单

| 文件 | 操作 | 内容 |
|------|------|------|
| `src/render/cli.zig` | 新建 | Color + MessageType + init + visibleWidth + writeLabeled + renderLine (~280 行) |
| `src/test.zig` | 修改 | 添加 `_ = @import("render/cli.zig");` |
| `src/App.zig` | 不修改 (Step 7) | Step 7 连线时集成 |

## E. 测试计划

| 测试 | 覆盖 |
|------|------|
| `render: Color constants` | ANSI 转义码正确值 (含 bright_black/bg_blue/bg_gray/bg_green/white) |
| `render: visibleWidth ASCII` | 纯 ASCII 返回长度 |
| `render: visibleWidth CJK` | 中文字符=2, 英文=1 混合 |
| `render: writeLabeled user` | 蓝底白字 "用户" 标签 + 白色正文 |
| `render: writeLabeled tool` | 灰底白字 "工具" 标签 + 灰色正文 |
| `render: writeLabeled think` | 灰底白字 "思考" 标签 + 灰色正文 |
| `render: writeLabeled output` | 绿底白字 "输出" 标签 + 正常正文 |
| `render: writeLabeled err` | 红字 error (无背景标签) |
| `render: writeLabeled warning` | 黄字 warning (无背景标签) |
| `render: writeLabeled success` | 绿字 checkmark + 正文 |
| `render: writePrompt` | 行内蓝底标签 + 空格，无换行 |
| `render: PhaseWriter beginPhase` | 相位切换时自动注入/关闭 ANSI 标签 |
| `render: PhaseWriter writeRaw` | 裸写 token 不附加标签 |
| `render: renderLine heading` | `## Title` -> bold+cyan |
| `render: renderLine code block` | ``` 内文本 -> dim |
| `render: renderLine bold` | `**bold**` -> ANSI bold 包裹 |
| `render: renderLine inline code` | `` `code` `` -> dim 包裹 |
| `render: renderLine link` | `[text](url)` -> blue text |
| `render: renderLine link with bold` | `[**bold**](url)` -> blue bold text (链接优先) |
| `render: renderLine list` | `- item` -> 缩进保持 |
| `render: renderLine blockquote` | `> quote` -> dim |
| `render: renderLine mixed` | 一行内含 bold + code + 链接 |
| `render: code block auto-detect` | `` ``` `` 开头进入/退出代码块，无需 reset |

## F. G7 对照表：Zig 0.16 stdlib API 验证

| # | 方案中的调用 | 源码/依据 | 匹配? |
|---|------------|----------|-------|
| 1 | `std.mem.startsWith(u8, line, "#")` | `std/mem.zig` | ✅ |
| 2 | `std.mem.indexOf(u8, line, "**")` | `std/mem.zig` | ✅ |
| 3 | `std.unicode.utf8ByteSequenceLength(c)` | `std/unicode.zig` | ✅ |
| 4 | `std.fmt.bufPrint(&buf, "{s}{s}{s}", .{...})` | `std/fmt.zig` | ✅ |
| 5 | `Io.Writer.print("{s}", .{text})` | `std/Io.zig` | ✅ |
| 6 | `kernel32.GetStdHandle` / `SetConsoleMode` | `ansi.zig:99-108` | ✅ callconv(.winapi) |
| 7 | `std.process.Environ` / `get("NO_COLOR")` | `std/process.zig` ZIG-016-ENV | ✅ swapRemove |
| 8 | `allocator.alloc(u8, n)` / `allocator.free` | `std/mem/Allocator.zig` | ✅ |

## G. 预估行数

| 文件 | 行数 |
|------|------|
| `src/render/cli.zig` | ~290 (实现) + ~190 (测试) = ~480 |
| **合计** | ~480 |
