# Plan OPT-1: ToolResult display-data separation

## 状态: ✅ 已完成

## 前置依赖

| 阻塞者 | 状态 | 被阻塞 |
|--------|------|--------|
| — | — | OPT-3 (ToolMeta) 在 OPT-1 基础上前进 |

OPT-1 建立了 core/frontend 分离方向，OPT-3 在此基础上加结构化 meta。

## 不做

| 项 | 理由 |
|----|------|
| DisplayHint (v2) | `ToolMeta` union 耦合 types.zig 到每个工具类型，OPT-3 已开始处理 |
| ToolResult 回退到含 action/summary | 已完成的分离方向不回退 |

---

## Problem

`ToolResult` currently carries three fields where two (`action`, `summary`) are display strings constructed by the tool. This puts display decisions in the tool layer — the opposite of the core/frontend split.

```
Before: tool decides display
─────────────────────────────
Read tool:    action = "Read src/main.zig",      summary = null
Grep tool:    action = "Grep 'fn ' src/main.zig", summary = "-> 5 matches"
Bash tool:    action = "$ ls",                    summary = null
```

The frontend should decide what to show, using structured data from the tool. The tool should only provide content for the LLM (session_content) and err_msg status.

## Design

### ToolResult (core/backend)

```zig
pub const ToolResult = struct {
    /// Content for the LLM context. Must be allocated with the caller's allocator
    /// (ctx.allocator in tools). Never return static strings — the caller frees this
    /// via deinit with the same allocator.
    session_content: []const u8,
    /// Non-null if tool execution failed. Same allocation contract as session_content.
    err_msg: ?[]const u8 = null,

    pub fn deinit(self: *ToolResult, allocator: std.mem.Allocator) void {
        allocator.free(self.session_content);
        if (self.err_msg) |e| allocator.free(e);
    }
};
```

### ToolDisplayCb (contract change)

Pass only `had_error` instead of the full ToolResult — eliminates any risk of the frontend accessing `session_content`:

```zig
pub const ToolDisplayCb = struct {
    context: ?*anyopaque,
    /// tool_name: e.g. "read", "bash"
    /// tool_args: raw JSON arguments from the LLM tool call
    /// had_error: true if the tool returned an err_msg
    /// Frontend MUST NOT access session_content. Use only tool_name + tool_args + had_error.
    render: *const fn (
        ctx: ?*anyopaque,
        tool_name: []const u8,
        tool_args: []const u8,
        had_error: bool,
    ) anyerror!void,
};
```

### Frontend display logic (render.zig)

The frontend constructs display from tool name + arguments JSON:

```zig
fn toolDisplayLabel(tool_name: []const u8, args_json: []const u8, had_error: bool) []const u8 {
    const label = switch (toolName(tool_name)) {
        .read, .write, .bash, .grep, .glob, .skill => tool_name_and_path(tool_name, args_json),
    };
```

For each tool, extract the primary identifier from args JSON (path for read/write, pattern+path for grep/glob, command prefix for bash, name for skill).

If JSON parse fails → show `{tool_name} <args>` with first 50 chars of raw args JSON, control chars stripped, truncated with "...". If had_error → append ` (err_msg)` to the label.

### Frontend contract

The frontend receives `had_error: bool` instead of the full `ToolResult`. This prevents accidental access to `session_content` (LLM data) and eliminates any dangling-pointer risk from async/delayed rendering.

## File changes

| File | Change |
|------|--------|
| `src/types.zig` | Remove `action`, `summary` from ToolResult; keep `session_content`, add `err_msg: ?[]const u8` |
| `src/core/agent.zig` | ToolDisplayCb.render: pass `tool_name`, `tool_args`, `had_error`; call site passes `tc.name`, `tc.arguments`, `exec_result` err status |
| `src/core/agent.zig` | runTurn: pass tc.name + tc.arguments to callback |
| `src/core/agent.zig` | ToolHooks.after: update to new ToolResult fields (err_msg instead of inspecting content) |
| `src/frontends/cli/render.zig` | ToolDisplay.renderCb + render: add tool_name/tool_args params; build display from args |
| `src/tool/read.zig` | Remove action/summary allocations; set err_msg on failure |
| `src/tool/write.zig` | Same |
| `src/tool/bash.zig` | Same; drop shortCmd helper |
| `src/tool/grep.zig` | Same |
| `src/tool/glob.zig` | Same |
| `src/tool/skill.zig` | Same |
| `src/tool/registry.zig` | Same for unknown-tool path |

## Frontend display mapping

| Tool | args JSON key | Display format |
|------|--------------|----------------|
| read | `path` | `Read {path}` |
| write | `path` | `Write {path}` |
| bash | `command` | `$ {first 60 chars}` |
| grep | `pattern`, `path` | `Grep "{pattern}" {path}` |
| glob | `pattern`, `path?` | `Glob {pattern} [{path|"."}]` |
| skill | `name` | `Skill {name}` |

Error indicator: append ` (err_msg)` if result.err_msg != null.

## Impact on agent.zig runTurn

The agent already has `tc.name` and `tc.arguments` at the callback call site. Just pass them through.

## Test impact

- All tool tests: update to new ToolResult fields (remove action/summary, add err_msg)
- render tests: update ToolDisplay tests to pass tool_name + args
- agent tests: update mock display callback signature
- No new tests needed — existing coverage is preserved

## Verification

```powershell
zig build
zig build test
node ../../.opencode/skills/zig-dev/scripts/check-arch.mjs .
```

All 148 tests must pass. No architecture regression.

## Future: DisplayHint (v2)

The current plan loses result metadata that was previously in `summary` (match counts, line counts, byte counts). The frontend derives display from tool args JSON alone, which cannot convey result statistics.

A v2 enhancement would add `tool_meta: ?ToolMeta` to `ToolResult` — a union of per-tool-kind data facts:

| Tool | Meta fields |
|------|------------|
| read | path, line_count |
| grep | pattern, path, match_count |
| bash | command, byte_count, exit_code |
| glob | pattern, file_count |
| write | path, byte_count |

Tools populate the meta struct with their own data. The frontend formats display from meta (e.g., `"-> {n} matches"`). This preserves clean separation: tools provide data facts, frontend provides display form. It also avoids having the frontend re-parse args JSON (reducing implicit coupling).

Trade-off: `ToolMeta` union couples `types.zig` to every tool type. A new tool must add a variant to the union AND a render case. Current design (no meta, no coupling) keeps the registry fully open — a new tool is one file + one registry line, zero types.zig changes. Deferred until the value of result metadata outweighs the coupling cost.

All 148 tests must pass. No architecture regression.
