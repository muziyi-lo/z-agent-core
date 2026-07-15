# Plan OPT-3.2: 标签渲染统一化

## 状态: 计划中

## 前置依赖

| 阻塞者 | 状态 | 被阻塞 |
|--------|------|--------|
| — | — | 无。纯渲染层改动，不依赖任何方案 |

## 不做

| 项 | 理由 |
|----|------|
| 修改 pub API 签名 | `writeLabeled`/`writeLabelBegin` 签名不变，内部重构 |
| 给 `.err/.warning/.success` 加底色块 | 错误/警告/成功信息不需要底色视觉权重 |

## 问题

1. 新增标签（如 `.usage`）每次都在 `writeLabeled`/`writeLabelBegin`/`labelPlain` 三处手写格式字符串，容易遗漏分隔空格
2. `.usage` 标签 `bg_bright_cyan` + `white` 对比度不足
3. 用量标签与下一个用户标签之间无空行
4. `.err`/`.warning`/`.success` 只有彩色文字，容易被忽略

## 设计

### 统一标签函数

```zig
fn writeLabel(writer: *Io.Writer, bg: []const u8, fg: []const u8, label: []const u8, text: []const u8) !void {
    if (!colorize) {
        try writer.print("{s}{s}\n", .{ label, text });
        return;
    }
    if (bg.len > 0) {
        // 底色块风格： 用量 text
        try writer.print("{s}{s} {s} {s}{s}{s}\n", .{ bg, fg, label, C.reset, fg, text, C.reset });
    } else {
        // 无底色括号风格：[ ERROR ] text
        try writer.print("{s}[ {s} ]{s} {s}\n", .{ fg, label, C.reset, text });
    }
}
```

### 标签颜色表

```zig
fn labelColor(mtype: MessageType) struct { bg: []const u8, fg: []const u8, label: []const u8 } {
    return switch (mtype) {
        .user    => .{ .bg = C.bg_blue,           .fg = C.white, .label = "用户" },
        .think   => .{ .bg = C.bg_gray,           .fg = C.white, .label = "思考" },
        .tool    => .{ .bg = C.bg_bright_magenta,  .fg = C.white, .label = "工具" },
        .output  => .{ .bg = C.bg_green,           .fg = C.white, .label = "输出" },
        .err     => .{ .bg = "",                    .fg = C.red,   .label = "ERROR" },
        .warning => .{ .bg = "",                    .fg = C.yellow,.label = "WARN" },
        .success => .{ .bg = "",                    .fg = C.green, .label = "OK" },
        .usage   => .{ .bg = C.bg_bright_black,     .fg = C.white, .label = "用量" },
    };
}
```

### 调用简化

```
当前:
try writer.print("{s}{s} 用量 {s}{s}{s}{s}\n", .{ C.bg_bright_cyan, C.white, C.reset, C.dim, text, C.reset });

实施后:
try writeLabel(writer, C.bg_bright_black, C.white, "用量", text);
```

### 标签输出对比

```
当前:  用量 输入 2186 | 输出 843 | 累计 4502/131072
                                ↑ 无空行
 用户  你好

实施后:  用量 输入 2186 | 输出 843 | 累计 4502/131072
                                ↑ 附加空行
 用户  你好
```

## 文件变更

| 文件 | 操作 | 说明 |
|------|------|------|
| `src/frontends/cli/render.zig` | 修改 | 新增 `writeLabel` + `labelColor`；`writeLabeled`/`writeLabelBegin` 内部改用新函数；删除手工格式字符串 |

不碰任何其他文件。`labelPlain` 保留供无颜色模式，内部也改用 `labelColor`。

## 验证

```powershell
zig build
zig build test
```
