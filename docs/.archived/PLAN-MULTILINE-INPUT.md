# Multi-Line Input Support — 实施计划

## A. 现状

| 平台 | 输入方式 | 换行行为 |
|------|---------|---------|
| Windows | `ReadConsoleW`（行缓冲模式） | Enter 即提交，无 Shift+Enter 检测 |
| POSIX | `Io.File.Reader.takeByte()`（cooked 模式） | `\n` 即提交，无修饰键检测 |

**结果**：用户无法在 REPL 中输入多行内容（长 prompt、多行代码块等）。每次 Enter 即触发 agent turn。

## B. 目标

- **Windows**: `ReadConsoleInputW` 事件循环，检测 `KEY_EVENT_RECORD.dwControlKeyState` 中 `SHIFT_PRESSED` 位
- **POSIX**: `\` 续行（POSIX 终端不报告 Shift 状态，无法检测 Shift+Enter）
- 两条路径统一到同一个平台无关的编辑命令状态机

### 交互模型

| 操作 | Windows | POSIX |
|------|---------|-------|
| Enter | 提交当前所有行 | 提交当前所有行 |
| Shift+Enter | 插入换行，继续输入 | —（不支持） |
| `\` + Enter | —（不需要） | 插入换行，继续输入，**尾部 `\` 被自动移除** |
| Ctrl+C | 丢弃当前所有行 | 丢弃当前所有行 |
| Backspace | 删除前一个字符（支持跨行边界） | 同 |
| Left/Right | 字符级光标移动 | 同 |

### 显示

```
 用户  first line          ← 首行提示符
     > second line          ← 续行提示符（Shift+Enter 或 \ 触发）
     > third line [Enter]
 思考 ...
```

## C. 架构设计：EditCmd 状态机

> 第三方审查建议：将按键解析转化为统一的 `EditCmd` 流，解析层与编辑逻辑解耦。

```zig
const EditCmd = enum {
    insert: struct { byte: u8 },
    backspace,
    move_left,
    move_right,
    newline,     // Shift+Enter 或 \续行 → 插入换行
    submit,      // 普通 Enter → 提交
    cancel,      // Ctrl+C → 丢弃
};
```

- **平台解析层**（C1/C2）：各自读取原始输入（`ReadConsoleInputW` / `tcsetattr` + `read`），转换为 `EditCmd`
- **编辑状态机**（C3）：接收 `EditCmd` 流，操作 `InputBuffer`，与平台完全解耦

**优点**：单元测试仅需构造 `EditCmd` 列表，无需 mock 终端。

### InputBuffer 数据结构

```zig
const InputBuffer = struct {
    lines: std.ArrayListAligned(u8, null),  // 累积的全部输入（含换行符分隔）
    cursor: usize,                           // 当前光标位置（字节偏移）
    allocator: std.mem.Allocator,
};
```

- `lines` 存储用户已输入的全部内容，行间以 `\n` 分隔
- `cursor` 为字节偏移量（非列号），跨行时自动计算
- CJK 宽字符: `InputBuffer` 内存储 UTF-8 字节，光标按字节偏移，渲染时由终端处理列宽

## D. 实现步骤

### D1. Windows: ReadConsoleInputW 事件循环

**源码基线**: `src/App.zig:338-353` (`winReadLine`)

**改动**: 替换 `ReadConsoleW` 行缓冲读取为 `ReadConsoleInputW` 事件循环。

**Zig 0.16 API 状态**: `ReadConsoleInputW`、`GetConsoleMode`、`SetConsoleMode`、`INPUT_RECORD`、`KEY_EVENT_RECORD` 及 console 模式常量（`ENABLE_LINE_INPUT` 等）**均不存在于 Zig 0.16 stdlib**。需自行声明 extern kernel32 函数和常量。

需新增的 extern 声明：

```zig
const ENABLE_PROCESSED_INPUT = 0x0001;
const ENABLE_LINE_INPUT      = 0x0002;
const ENABLE_ECHO_INPUT      = 0x0004;
const ENABLE_WINDOW_INPUT    = 0x0008;
const SHIFT_PRESSED          = 0x0010;

const INPUT_RECORD = extern struct {
    EventType: u16,
    _pad: u16,
    Event: extern union {
        KeyEvent: KEY_EVENT_RECORD,
        // ... other event types unused
    },
};

const KEY_EVENT_RECORD = extern struct {
    bKeyDown: i32,
    wRepeatCount: u16,
    wVirtualKeyCode: u16,
    wVirtualScanCode: u16,
    uChar: u16,
    dwControlKeyState: u32,
};

extern "kernel32" fn ReadConsoleInputW(
    hConsoleInput: ?*anyopaque,
    lpBuffer: [*]INPUT_RECORD,
    nLength: u32,
    lpNumberOfEventsRead: *u32,
) callconv(.winapi) i32;
extern "kernel32" fn GetConsoleMode(
    hConsoleHandle: ?*anyopaque,
    lpMode: *u32,
) callconv(.winapi) i32;
extern "kernel32" fn SetConsoleMode(
    hConsoleHandle: ?*anyopaque,
    dwMode: u32,
) callconv(.winapi) i32;
```

**控制台模式切换**（修正：覆盖→位操作）：

```
伪代码:
  winReadLine:
    GetConsoleMode → save_mode
    new_mode = save_mode & ~(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT)
    new_mode |= ENABLE_WINDOW_INPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING
    SetConsoleMode(new_mode)
    defer SetConsoleMode(save_mode)

    surrogate_lead: ?u16 = null  // ← 代理项暂存
    while true:
      ReadConsoleInputW → 事件数组
      for each INPUT_RECORD:
        if EventType == KEY_EVENT && KeyEvent.bKeyDown:
          convert KEY_EVENT_RECORD → EditCmd:
            if wVirtualKeyCode == VK_RETURN && dwControlKeyState & SHIFT_PRESSED:
              emit EditCmd.newline
            elif wVirtualKeyCode == VK_RETURN:
              emit EditCmd.submit
            elif wVirtualKeyCode == VK_BACK:
              emit EditCmd.backspace
            elif wVirtualKeyCode == VK_LEFT:
              emit EditCmd.move_left
            elif wVirtualKeyCode == VK_RIGHT:
              emit EditCmd.move_right
            elif uChar == 0x03:  // Ctrl+C
              emit EditCmd.cancel
            elif uChar != 0:
              if surrogate_lead != null:                    // ← 代理项合并
                if uChar >= 0xDC00 && uChar <= 0xDFFF:     // 低代理项
                  const cp = 0x10000 + (((surrogate_lead orelse 0) - 0xD800) << 10) + (uChar - 0xDC00)
                  emit EditCmd.insert(utf32_to_utf8(cp))
                else:  // 孤立的低代理项或错配，丢弃整个代理对
                  // skip — invalid
                surrogate_lead = null
              elif uChar >= 0xD800 && uChar <= 0xDBFF:     // 高代理项
                surrogate_lead = uChar
              else:
                emit EditCmd.insert(utf16_to_utf8(uChar))
```

**注意**:
- `uChar` 为 `u16`（UTF-16LE code unit）；BMP 字符单次事件，补充平面字符（emoji 等）需两次事件 → 代理项暂存 + 合并（漏洞 3 修复）
- WIN-001: 回显字符时 `WriteConsoleW` 累积 ≥256 字节后一次性写入，不可逐字符
- VT 处理：`SetConsoleMode` 中显式 `|= ENABLE_VIRTUAL_TERMINAL_PROCESSING`（0x4，Zig 0.16 stdlib 中已存在）。若 SetConsoleMode 失败（旧版/非控制台），降级为不使用 ANSI 清屏（漏洞 5 修复）
- 现有代码已使用 `GetStdHandle(STD_INPUT_HANDLE)` 获取控制台句柄

**改动**: `winReadLine` 重写 + extern 声明，约 100 行。

### D2. POSIX: raw 模式 + `\` 续行

**源码基线**: `src/App.zig:494-521` (`readLine`)

**改动**: 函数入口设置 raw 模式，逐字符解析，`\` + Enter 触发续行。

**Zig 0.16 API 签名**（与 C 不同，非指针传参）:

```zig
// tcgetattr 返回值（非指针）
const raw = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
// lflag 为 packed struct bool 位域，非整数掩码
raw.lflag.ICANON = false;
raw.lflag.ECHO = false;
// tcsetattr 接受值（非指针），TCSA.NOW 是枚举标签
try std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, raw);
// 读取: std.posix.read(fd, buf) ReadError!usize
```

```
伪代码:
  readLine:
    save = try std.posix.tcgetattr(STDIN_FILENO)
    raw = save
    raw.lflag.ICANON = false
    raw.lflag.ECHO = false
    try std.posix.tcsetattr(STDIN_FILENO, .NOW, raw)
    defer std.posix.tcsetattr(STDIN_FILENO, .NOW, save) catch {}

    while true:
      const n = try std.posix.read(STDIN_FILENO, &byte_buf);  // 返回 0 = EOF
      if n == 0: emit EditCmd.cancel          // ← Ctrl+D / EOF
      byte = byte_buf[0]:
        convert byte → EditCmd:
          if byte == '\n' && lastCharBeforeCursor(buf, cursor) == '\\':
            pop '\\' from buffer       // ← 自动吃掉续行符
            emit EditCmd.newline
          elif byte == '\n':
            emit EditCmd.submit
          elif byte == 0x03:           // Ctrl+C
            emit EditCmd.cancel
          elif byte == 0x1b:           // ESC → parse ANSI sequence
            if seq == '[A' → emit EditCmd.history_prev  (future)
            if seq == '[B' → emit EditCmd.history_next  (future)
            if seq == '[C' → emit EditCmd.move_right
            if seq == '[D' → emit EditCmd.move_left
            // ignore unknown sequences
          elif byte == 0x7F or byte == 0x08:  // backspace
            emit EditCmd.backspace
          else if byte >= 0x20:                // printable
            emit EditCmd.insert(byte)
```

**POSIX 无 Shift+Enter 检测**：POSIX 终端不报告修饰键状态到 TTY。使用 `\` 续行：行末 `\` + Enter → 删除 `\`，插入换行，继续输入。

**`lastCharBeforeCursor` 定义**（漏洞 4 修复）：光标前一个字节即为当前行末字符（Enter 时 `\n` 尚未插入）：

```
lastCharBeforeCursor(buf, cursor):
  if cursor == 0: return 0
  return buf.lines.items[cursor - 1]   // cursor 此时即行末位置
```

**原始模式恢复风险**：`defer tcsetattr` 在 panic 时仍执行（栈展开），但 segfault/abort 不触发。风险低，标注即可。

**改动**: `readLine` 重写，约 85 行。

### D3. 编辑状态机 + 渲染

**改动**: 新增模块级函数 `processEditCmd(buf: *InputBuffer, cmd: EditCmd) !BufferAction`，处理所有编辑操作。

```
processEditCmd:
  switch cmd:
    .insert => |b| buf.lines.insert(buf.cursor, b); cursor += 1
    .backspace => if cursor > 0: buf.lines.remove(cursor - 1); cursor -= 1
    .move_left =>
      if cursor > 0: cursor = prevCodepointStart(buf.lines, cursor)    // ← UTF-8 安全跳转
    .move_right =>
      if cursor < buf.lines.len: cursor = nextCodepointStart(buf.lines, cursor)
    .newline => buf.lines.insert(cursor, '\n'); cursor += 1
    .submit => return .submit
    .cancel => return .cancel
  return .continue

enum BufferAction { continue, submit, cancel }
```

**UTF-8 安全光标移动**（漏洞 2 修复）：

```
prevCodepointStart(buf, idx):
  if idx == 0: return 0
  var i = idx - 1
  while i > 0 and buf[i] & 0xC0 == 0x80: i -= 1   // 跳过多字节字符的续字节
  return i

nextCodepointStart(buf, idx):
  const len = std.unicode.utf8ByteSequenceLength(buf[idx]) catch return idx + 1
  return idx + len
```

**渲染刷新**（漏洞 1 修复）：放弃局部 `\r` + `\x1b[K`，改用**完全重绘**：

```
renderFull(writer, buf, cursor):
  // 1. 跳到输入区域下方，从首行开始重绘
  writer.print("\r\n")
  // 2. 遍历 buffer.lines 按 \n 分行，逐行输出提示符+内容
  for each line in split(buf.lines, '\n'):
    if first_line: writer.print(" 用户  {s}", .{line})
    else:          writer.print("     > {s}", .{line})
    writer.print("\r\n")
  // 3. 清除下方残留旧行（光标已在全部新内容之下）
  writer.print("\x1b[0J")
  // 4. 向上跳回 cursor 所在行
  const row = countLinesBeforeCursor(buf, cursor)
  writer.print("\x1b[{d}A", .{row})         // 向上跳 row 行
  // 5. 用 \r + 打印前缀到光标位置确定列，清除行尾残留
  writer.print("\r")
  const prefix = extractLineBeforeCursor(buf, cursor)  // 当前行中光标之前的内容 ([行首, cursor) 切片)
  const prompt = if first_line_of_cursor " 用户  " else "     > "
  writer.print("{s}{s}", .{ prompt, prefix })           // 终端的列宽计算是正确的
  writer.print("\x1b[K")                                // ← 清除当前行光标后的残留字符（删减时旧字符留屏）
```

**为何不用 `G` 绝对列跳**（漏洞 1 修复）：`cursor` 是 UTF-8 字节偏移，但 `G` 需要终端显示列。中文 1 字符=3 字节=2 显示列，字节偏移与列宽不等。方案：用 `\r`（列 0）+ 打印 `提示符 + 前缀内容`，让终端自己算列宽——这是终端唯一的正确列宽权威。

**为何 `\x1b[0J` 不会清除历史**（漏洞 2 不采纳的确认）：`\x1b[0J` 在步骤 3 执行时，光标已在全部新输入内容**之下**（步骤 2 末尾的 `\r\n` 已逐行下移）。它只清除下方可能残留的旧行，不触及上方历史。

**为何用完全重绘**：删除 `\n` 合并行时，旧的第一、二行物理显示不会自动消失。局部刷新 `\x1b[K` 只清除当前行，无法清除上一轮残留的后续行。完全重绘虽然"朴素"，但在 4096 字节限制下性能无影响，且绝对可靠。

**改动**: `processEditCmd` + `prevCodepointStart`/`nextCodepointStart` + `renderFull`，约 75 行（含渲染逻辑 +20 行）。

### D4. 续行提示符

**源码基线**: `src/render/cli.zig:writePrompt`

新增 `pub fn writeContinuePrompt(writer: *std.Io.Writer) !void` — 输出 `     > `（6 空格 + `>` + 空格，对齐首行提示符缩进）。

**改动**: `render/cli.zig` 新增 5 行。

## E. 边界条件

| 边界 | 处理 |
|------|------|
| 空行提交 | Enter 无 Shift/`\` 提交空行 → 同现有行为（ignore） |
| Ctrl+C 在多行中 | 丢弃已输入的全部行，输出 `^C`, 不提交 |
| 首行 Backspace 到 `>` 前 | 忽略（不可删除提示符） |
| 跨行 Backspace | 若 cursor 在 `\n` 后第 0 位，删除 `\n` 合并两行 |
| 4096 字节限制 | 跨行累积不超过 4096 字节，超限返回 `error.LineTooLong` |
| 编码 | UTF-8 输入。CJK 多字节字符删除时一次删除整个码点 (`utf8ByteSequenceLength`) |
| 终端断连 | 同现有 EPIPE 检测 |
| UTF-8 光标安全 | `move_left`/`move_right` 使用 `utf8ByteSequenceLength` 跳完整码点（漏洞 2） |
| Windows 代理项 | 高/低代理分两次事件 → 暂存合并为 `u32` 码点转 UTF-8（漏洞 3） |
| POSIX EOF (Ctrl+D) | `read` 返回 0 → `EditCmd.cancel`，不进入死循环（漏洞 4） |
| VT 不支持降级 | `ENABLE_VIRTUAL_TERMINAL_PROCESSING` 设置失败 → 跳过 ANSI 清屏，仅用 `\r\n`（漏洞 5） |
| 多行重绘残留 | 完全重绘模式，`\x1b[0J` 清除旧行残留（漏洞 1） |
| 回滚 | 多行输入失败不影响 session |
| raw 模式恢复 | `defer tcsetattr` 覆盖 panic 路径；segfault/abort 不恢复（概率极低） |

## F. 不在此范围

- **历史记录**（↑↓ 箭头回显历史命令）: EditCmd 已预留 `history_prev`/`history_next`，实现后续独立计划
- **语法高亮**: TUI 层功能
- **Tab 补全**: 需文件系统/命令表查询

## G. 文件改动

| 文件 | D1 | D2 | D3 | D4 | 合计 |
|------|:--:|:--:|:--:|:--:|:----:|
| `src/App.zig` | +105 | +85 | +75 | | **+265** |
| `src/render/cli.zig` | | | | +5 | **+5** |
| **净增行** | 105 | 85 | 75 | 5 | **+270** |

## H. Zig 0.16 API 验证表

| 方案引用 | Zig 0.16 实际 | 匹配? |
|---------|--------------|-------|
| `ReadConsoleInputW` | **不存在** stdlib，需 extern 声明 | ⚠️ 自声明 |
| `GetConsoleMode` / `SetConsoleMode` | **不存在** stdlib，需 extern 声明 | ⚠️ 自声明 |
| `INPUT_RECORD` / `KEY_EVENT_RECORD` | **不存在** stdlib，需 extern struct 定义 | ⚠️ 自定义 |
| `ENABLE_LINE_INPUT` (0x0002) 等 | **不存在**，仅 `ENABLE_VIRTUAL_TERMINAL_PROCESSING` (0x4) 存在 | ⚠️ 自定义常量 |
| `SHIFT_PRESSED` (0x10) | **不存在** | ⚠️ 自定义常量 |
| `std.posix.tcgetattr(fd) !termios` | 返回值（非指针），`posix.zig:1163` | ✅ |
| `std.posix.tcsetattr(fd, .NOW, termios) !void` | 接受值（非指针），枚举标签非整数，`posix.zig:1178` | ✅ |
| `termios.lflag.ICANON` | packed struct bool 位域，赋值 `= false` 非位掩码，`linux.zig:8528` | ⚠️ API 差异 |
| `std.posix.read(fd, buf) !usize` | `posix.zig:400`，Windows/WASI 不可用 | ✅ |

## I. 验证

| 验证项 | 命令 | 通过标准 |
|--------|------|---------|
| 编译 | `zig build` | 零错误 |
| 全量测试 | `zig build test` | 全部通过 |
| EditCmd 单元测试 | `zig test src/App.zig` | 构造 EditCmd 序列验证 InputBuffer 输出 |
| Windows: 单行提交 | `hello` + Enter | 提交 "hello" |
| Windows: Shift+Enter | `line1` Shift+Enter `line2` Enter | 提交 "line1\nline2" |
| Windows: Ctrl+C | 输入中 Ctrl+C | `^C interrupted`, 不提交 |
| POSIX: `\` 续行 | `line1\` Enter `line2` Enter | 提交 "line1\nline2"，`\` 被移除 |
| POSIX: Ctrl+C | 输入中 Ctrl+C | 同 Windows |
| 字符限制 | >4096 字符 | 返回 `LineTooLong` |

## J. 审查采纳记录

| # | 建议 | 裁决 | 理由 |
|---|------|------|------|
| 1 | POSIX Shift+Enter 三段矛盾 | **采纳** | POSIX 统一为 `\` 续行，交互模型表分裂 Windows/POSIX 列，伪代码去除 `shift_pressed` |
| 2 | 缺失 InputBuffer / 光标数据结构 | **采纳** | 新增 `InputBuffer` struct 定义（D3 节） |
| 3 | 渲染刷新逻辑空白 | **标注** | D3 节新增渲染策略描述（`\r` + 覆盖写入 + ANSI 清行尾），详细实现留实现阶段细化 |
| 4 | Windows 模式标志覆盖 | **采纳** | 修正为 `GetConsoleMode` → 位清除 → `SetConsoleMode` 模式 |
| 5 | POSIX raw 恢复风险 | **标注** | D2/E 节标注 `defer` 在 panic 时仍执行，仅 segfault 不触发（概率极低） |
| 6 | EditCmd 解耦架构 | **采纳** | 新增 C 节架构设计，D3 节实现 `processEditCmd` |
| 7 | `\` 续行符自动吃掉 | **采纳** | D2 伪代码：`pop '\' from buffer` 后 emit newline |
| 8 | 多行重绘残留（漏洞 1） | **采纳** | D3 `renderFull` 完全重绘 + `\x1b[0J` 清除残留行 |
| 9 | UTF-8 光标劈开码点（漏洞 2） | **采纳** | D3 `prevCodepointStart`/`nextCodepointStart` 使用 `utf8ByteSequenceLength` |
| 10 | Windows 代理项未合并（漏洞 3） | **采纳** | D1 高/低代理暂存 + `utf32_to_utf8` 合并 |
| 11 | POSIX EOF 死循环（漏洞 4） | **采纳** | D2 `read` 返回 0 → `EditCmd.cancel` |
| 12 | 未显式启用 VT（漏洞 5） | **采纳** | D1 `SetConsoleMode` 新增 `ENABLE_VIRTUAL_TERMINAL_PROCESSING` |
| 13 | CJK 列偏移：字节≠显示列 | **采纳** | D3 `renderFull` 放弃 `G` 绝对列跳，改用 `\r` + 打印前缀到光标 |
| 14 | 代理项公式 `<<` 优先级 | **采纳** | D1 修正括号：`((lead - 0xD800) << 10) + (uChar - 0xDC00)` |
| 15 | `last_char_in_line` 定义缺失 | **采纳** | D2 新增 `lastCharBeforeCursor` 辅助函数 |
| 16 | `\x1b[0J` 清除范围过大 | **不采纳** | 光标已在全部新内容之下执行，仅清除下方残留，不触及上方历史 |
| 17 | POSIX VT100 不支持 `\x1b[0J` | **标注** | 现代终端均支持；Windows 侧已有 VT 降级，POSIX 侧标注即可 |
| 18 | `lastCharBeforeCursor` 返回行首非行末 | **采纳** | D2 修正：`return buf.lines.items[cursor - 1]`（1 行） |
| 19 | `renderFull` 缺失行内 `\x1b[K` | **采纳** | D3 第 5 步新增 `writer.print("\x1b[K")` |
