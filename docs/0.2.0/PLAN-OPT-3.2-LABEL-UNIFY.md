# Plan OPT-3.2: 标签渲染统一化

## 状态: ✅ 已完成 (2026-07-15)

## 前置依赖

| 阻塞者 | 状态 | 被阻塞 |
|--------|------|--------|
| — | — | 无。纯渲染层改动，不依赖任何方案 |

## 不做

| 项 | 理由 |
|----|------|
| 修改 pub API 签名 | `writeLabeled`/`writeLabelBegin` 签名不变，内部重构 |
| 给 `.err/.warning/.success` 加底色块 | 错误/警告/成功信息不需要底色视觉权重 |
| multi-line text 缩进前缀 | 当前所有调用 text 均为单行，无多行场景 |
| LabelWriter 链式包装器 | 引入新类型增加复杂度，与 CLI 单文件直接风格冲突 |
| comptime 预构建样式字符串 | 8 个标签运行时开销可忽略，编译期优化无显著收益 |

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

空行由调用层控制：App.zig 中 token 显示后写入 `\n`，不在 `writeLabel` 内部追加双换行。
`writeLabelBegin` 保持独立结构（流式输出需要 begin/end 配对），不纳入本次统⼀。

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

`labelPlain` 保持独立实现（返回纯文本标签），不从 `labelColor` 派生，确保无颜色模式不被 ANSI 结构体污染。

### 调用简化

```
当前:
try writer.print("{s}{s} 用量 {s}{s}{s}{s}\n", .{ C.bg_bright_cyan, C.white, C.reset, C.dim, text, C.reset });

实施后:
try writeLabel(writer, C.bg_bright_black, C.white, "用量", text);
```

### 测试

新增 `writeLabel` 单元测试：
- 有颜色模式：验证底色块风格输出
- 有颜色模式：验证括号风格输出（err/warning/success）
- 无颜色模式：验证纯文本输出
- `labelColor` 八种类型不 panic

## 文件变更

| 文件 | 操作 | 说明 |
|------|------|------|
| `src/frontends/cli/render.zig` | 修改 | 新增 `writeLabel` + `labelColor`；`writeLabeled` 内部改用新函数；删除手工格式字符串；新增测试 |
| `src/frontends/cli/App.zig` | 修改 | token 用量显示后追加 `\n` 空行 |

## 验证

```powershell
zig build
zig build test
```

## 第三方评测决策

| 建议 | 决策 | 理由 |
|------|------|------|
| 漏洞1: 明确空行实现 | ✅ 采纳 | 空行由 App.zig 调用层控制，不在 render 内部处理 |
| 漏洞2: 输出格式变化兼容 | ❌ 不采纳 | CLI 交互工具无下游解析器，label 格式变化属于视觉优化 |
| 漏洞3: labelPlain 重用方式 | ✅ 采纳 | `labelPlain` 保持独立，不从 `labelColor` 派生 |
| 漏洞4: writeLabelBegin 差异 | ✅ 采纳 | `writeLabel` 仅替换 `writeLabeled`，begin/end 配对保持独立 |
| 漏洞5: 多行 text 处理 | ❌ 不采纳 | 当前所有调用均为单行，预加约束增加复杂度 |
| 实践1: comptime 预构建 | ❌ 不采纳 | 运行时开销可忽略，无显著收益 |
| 实践2: LabelWriter 包装器 | 📅 延后 | 未来 TUI/Web 前端阶段可考虑 |
| 实践3: 消息组级空行 | ✅ 采纳 | 空行逻辑放在调用层而非 render 内部 |
| 实践4: 快照测试 | ✅ 采纳 | 新增 `writeLabel` + `labelColor` 单元测试 |
