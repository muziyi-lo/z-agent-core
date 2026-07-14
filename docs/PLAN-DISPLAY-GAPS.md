# Fix: Frontend display gaps

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
| `core/agent.zig` | `ToolDisplayCb.render`: add `user_output: ?[]const u8` param; call site passes `ok.user_output` |
| `frontends/cli/render.zig` | `ToolDisplay.renderCb` + `render`: add param; print after label if non-null |
| `tool/bash.zig` | Set `.user_output` to `session_content[0..@min(len, 4096)]` (zero-copy view) |

No other tool files change — `user_output` defaults to null.

## Scope

| Fix | Files | Risk |
|-----|-------|------|
| grep/glob label | render.zig | Low |
| round warning | App.zig | Low |
| bash output | types.zig + agent.zig + render.zig + bash.zig | Medium — adds field + callback param |
