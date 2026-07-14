# Phase 1a: 逐 token 流式 + 换行覆盖渲染 — 实施计划

> 在 LineBuffer 基础上，改为"raw bytes 即时显示 → `\n` 到达后覆盖为 ANSI 格式化行"的混合渲染。

## A. 目标

| 维度 | 现状 | 目标 |
|------|------|------|
| 显示时机 | 等 `\n` 才输出格式化行，无即时反馈 | raw bytes 即时显示，`\n` 后覆盖为格式化行 |
| 块级格式 | 逐行延迟但渲染完整 | ` ``` ` 行首出现即 toggle `code_block_active`，从此刻起后续 raw 输出直接用 dim 格式 |
| 内联格式 | `renderLine` 正常处理 | 同现状（覆盖时写入） |

## B. 渲染流程

```
Provider SSE chunk bytes
  │
  ├─→ 1. 写入 raw bytes 到 stdout（即时显示，无 \n）
  │      └─ 不写 flush（由覆盖写时 flush）
  │
  └─→ 2. 累积到 LineBuffer (同现状)
         │
         └─→ \n 到达
              ├─→ 3. renderLine(完整行) → styled
              ├─→ 4. \r\033[K → 清当前行 → 写入 styled → \n → flush
              └─→ 5. drainBuf
```

## C. 逐步骤实施

### C1. LineBuffer 改为双输出模式

在 `render/cli.zig` 中修改 `LineBuffer.feed`：

```zig
pub fn feed(self: *LineBuffer, bytes: []const u8, writer: *std.Io.Writer) !void {
    // 1. 即时回显 raw bytes（不含 \n）
    var i: usize = 0;
    while (i < bytes.len) {
        const nl = std.mem.indexOfScalarPos(u8, bytes, i, '\n') orelse bytes.len;
        if (nl > i) {
            writer.print("{s}", .{bytes[i..nl]}) catch {};
        }
        if (nl < bytes.len) {
            // \n 在下次循环处理，不写入
            i = nl + 1;
        } else {
            i = bytes.len;
        }
    }

    // 2. 累积到内部 buf（同现状）
    try self.buf.appendSlice(self.allocator, bytes);

    // 3. 提取完整行 → 覆盖写
    while (true) {
        const nl_pos = std.mem.indexOfScalar(u8, self.buf.items, '\n') orelse break;
        const line_end = nl_pos + 1;
        // ... UTF-8 boundary check (同现状) ...
        const line_raw = ...; // 不含 \n 的完整行
        const line = self.buf.items[0..line_raw];

        const styled = renderLine(self.render_ctx, self.allocator, line) catch {
            drainBuf(&self.buf, line_end);
            continue;
        };
        defer self.allocator.free(styled);

        // 4. 覆盖写: \r\033[K + styled + \n
        writer.print("\r\x1b[K{s}\n", .{styled}) catch {};
        writer.flush() catch {};

        drainBuf(&self.buf, line_end);
    }
}
```

**关键改动**：
- 步骤 1：逐 byte 扫描 raw bytes，跳过 `\n`，其余即时 `writer.print`
- 步骤 4：`\r\033[K` = carriage return + clear to end of line，覆盖同行的 raw 文本，然后写入 ANSI 格式化内容 + `\n`

### C2. flush 同样覆盖写

```zig
pub fn flush(self: *LineBuffer, writer: *std.Io.Writer) !void {
    if (self.buf.items.len == 0) return;
    // ... (同现状) ...
    writer.print("\r\x1b[K{s}\n", .{styled}) catch {};
    writer.flush() catch {};
}
```

### C3. 限制与已知边界

| 场景 | 行为 | 说明 |
|------|------|------|
| 单行（不折行） | `\r\033[K` 精确覆盖 | 主路径 |
| 多行 raw 输出（终端折行） | 只清最后一行，残留字符留在上方 | 终端宽度依赖 + CJK 双宽 → 精确行数计算复杂。Phase 3 前不处理 |
| 无 `\n` 的 chunk 尾 | raw bytes 已即时显示，缓冲区等待后续 | 不丢内容 |
| ` ``` ` 代码块边界 | `renderLine` tx 时 toggle `code_block_active`，后续行立即用 dim | 从 ` ``` ` 后的第一个字开始正确渲染 |
| EPIPE/BrokenPipe | `catch {}`，stdout_dead 由 agent turn 间检查 | 同现状 |

## D. 改动文件

| 文件 | 改动 |
|------|------|
| `src/render/cli.zig` | `LineBuffer.feed` 改为双输出（raw 即时 + 覆盖写）；`flush` 同步修改；累计 ~30 行改 |
| `src/App.zig` | 无改动（WriterCtx 接口不变） |

## E. 验证

```powershell
zig build                    # 编译通过
zig build test               # 或直接跑 test.exe — 141 tests pass
zig build run -- --prompt "hello"  # 端到端：raw bytes 即时显示 + 换行后 ANSI 覆盖
```

### 新增测试

| # | 测试 | 验证 |
|---|------|------|
| 1 | `LineBuffer: feed echoes raw bytes immediately` | mock writer 收到 raw bytes |
| 2 | `LineBuffer: feed overwrites with styled on newline` | `\r\033[K` + styled 出现在 writer 输出中 |
| 3 | `LineBuffer: feed handles multi-chunk line` | raw chunk1 + raw chunk2 → 一次覆盖写 |
| 4 | `LineBuffer: feed CRLF normalizes` | `\r\n` 识别为一行 |
