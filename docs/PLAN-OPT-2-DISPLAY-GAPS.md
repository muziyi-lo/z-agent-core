# Plan OPT-2: Frontend display gaps

## 状态: 部分完成

| # | 状态 |
|---|------|
| 1-4 | ✅ 已实施 |
| 5 | ⏳ 待实施 |

## 前置依赖

| 阻塞者 | 状态 | 被阻塞 |
|--------|------|--------|
| — | — | 无。所有改动独立，不阻塞其他方案 |

## 不做

| 项 | 理由 |
|----|------|
| 工具输出结构化 | OPT-3 已覆盖 |

---

## 1. grep/glob label incomplete

### Current
```
 工具  grep          ← shows only path, no pattern
 工具  glob          ← shows only pattern, no path
```

### Fix (render.zig: labelFromValue)

Combine primary fields into a short label using threadlocal static buffer. Stack-allocated buffers would be UB after function return.

```zig
// Above labelFromValue:
threadlocal var DISPLAY_BUF: [256]u8 = undefined;

fn labelFromValue(tool_name: []const u8, value: std.json.Value) []const u8 {
    // ... existing tool_name checks ...
    if (std.mem.eql(u8, tool_name, "grep")) {
        const pattern = if (value.object.get("pattern")) |v| if (v == .string) v.string else "" else "";
        const path = if (value.object.get("path")) |v| if (v == .string) v.string else "" else "";
        if (pattern.len > 0 and path.len > 0) {
            return std.fmt.bufPrint(&DISPLAY_BUF, "grep \"{s}\" {s}", .{ shorten(pattern, 40), shorten(path, 40) }) catch return tool_name;
        }
        return tool_name;
    }
    if (std.mem.eql(u8, tool_name, "glob")) {
        const pattern = if (value.object.get("pattern")) |v| if (v == .string) v.string else "" else "";
        const path = if (value.object.get("path")) |v| if (v == .string) v.string else "" else "";
        if (pattern.len > 0) {
            if (path.len > 0) {
                return std.fmt.bufPrint(&DISPLAY_BUF, "glob {s} [{s}]", .{ shorten(pattern, 40), shorten(path, 40) }) catch return tool_name;
            }
            return std.fmt.bufPrint(&DISPLAY_BUF, "glob {s}", .{shorten(pattern, 80)}) catch return tool_name;
        }
        return tool_name;
    }
    // ... rest of tool_name checks unchanged ...
}
```

Helper: `fn shorten(s: []const u8, max: usize) []const u8 { return s[0..@min(s.len, max)]; }`.

## 2. Round limit warning

### Current
Agent returns `.max_rounds` silently — user sees stop with no explanation.

### Fix (agent.zig: before round check)
```zig
if (tool_rounds >= self.max_tool_rounds) {
    return finishTurn(self, new_msgs, .max_rounds);
}
```

No code change needed in agent — it correctly returns `.max_rounds`. Fix is in frontend:

### Fix (App.zig: processLine + singleTurn)
```zig
switch (result.finish) {
    .max_rounds => {
        try render.writeLabeled(&stdout.interface, .warning, "max tool rounds reached");
    },
    ...
}
```

Also append warning to session so the LLM knows why it stopped:

### Fix (agent.zig: before returning .max_rounds)
```zig
// Before finishTurn:
try self.session_ref.append(.{
    .role = .system,
    .content = "[max tool rounds reached — further tool calls prevented]",
});
```

## 3. Bash output display

### Current
Bash returns `session_content` (stdout/stderr) → LLM only. User sees nothing.

### Fix: zero-copy borrowed view

Extend `ToolResult` with `user_output` — a borrowed view slice into `session_content`. No separate allocation.

```zig
// types.zig
pub const ToolResult = struct {
    session_content: []const u8,
    err_msg: ?[]const u8 = null,
    user_output: ?[]const u8 = null,  // borrowed slice into session_content; NOT freed by deinit

    pub fn deinit(self: *ToolResult, allocator: std.mem.Allocator) void {
        allocator.free(self.session_content);
        if (self.err_msg) |e| allocator.free(e);
        // user_output is NOT freed — it's a view into session_content
    }
};
```

Bash sets `user_output` to first 4096 bytes of output (zero-copy):

```zig
// bash.zig: after building session_content
.user_output = if (total > 0) session_content[0..@min(session_content.len, 4096)] else null,
```

### Callback contract

Add `user_output` to `ToolDisplayCb.render`. The callback is called inside `runTurn` while `ToolResult` is alive — `App.zig` cannot print `user_output` after `runTurn` returns because the result has been deinited. The callback MUST include the data.

Only one callback implementation exists (`render.zig:ToolDisplay.renderCb`). Three files change:

| File | Change |
|------|--------|
| `src/core/agent.zig` | `ToolDisplayCb.render`: add `user_output: ?[]const u8` param; call site passes `ok.user_output` |
| `src/frontends/cli/render.zig` | `ToolDisplay.renderCb` + `render`: add param; print after label if non-null |
| `src/tool/bash.zig` | Set `.user_output` to `session_content[0..@min(len, 4096)]` (zero-copy view) |

No other tool files change — `user_output` defaults to null.

## 4. Tool error display

### Current
`ToolDisplay.render` 接收 `had_error: bool` 但忽略（`_ = had_error`）。工具执行失败时无任何视觉提示。

### Fix (render.zig: render)
当 `had_error` 为 true 时：标签文字变红 + 追加 ` (err)` 后缀。

```zig
// render.zig: ToolDisplay.render
if (had_error and colorize) {
    self.writer.print("{s}{s}", .{ C.red, label }) catch |err| return err;
} else {
    self.writer.print("{s}", .{label}) catch |err| return err;
}
if (had_error) {
    self.writer.print(" (err)", .{}) catch |err| return err;
}
```

JSON 解析失败路径同理。

## 5. Thinking content Markdown rendering conflicts

### Current
`writeLabeled(.think)` 用 `{dim}` 包裹整行思考内容，但 `PhaseWriter` 对思考内容仍然走 `renderLine` 进行 Markdown→ANSI 渲染。当思考中出现 ` ``` ` 时：

```
思考内容: {dim}{dim}```{reset}  ← renderLine 注入 {dim}code{reset}
                                     ↑ 内部 reset 打破外层 dim
```

后续思考文字丢失 dim 效果。标题、粗体等 Markdown 语法的嵌套 ANSI 码同样与思考的外层 dim 冲突。

### Fix (render.zig)
思考内容放弃 Markdown 渲染，直接输出纯文本 + dim 颜色。理由：

- 思考是模型的内部独白，不是格式化输出
- ` ``` ` 是思维过程中的伪代码片段，不应作为真实代码块渲染
- 纯文本输出避免 ANSI 嵌套冲突，更简洁

### 改动
- `PhaseWriter`：思考阶段输出的文本跳过 `renderLine`，直接 `writeRaw`（dim 包裹的纯文本）
- 或 `renderLine` 新增参数 `is_thinking: bool`，思考内容时返回纯文本

## Scope

| Fix | Files | Risk |
|-----|-------|------|
| grep/glob label | render.zig | Low |
| round warning | App.zig | Low |
| bash output | src/types.zig + src/core/agent.zig + src/frontends/cli/render.zig + src/tool/bash.zig | Medium — adds field + callback param |
| tool error display | render.zig | Low |
| thinking no markdown | render.zig | Low |
