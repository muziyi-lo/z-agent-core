# z-agent-core: Core Definition & Frontend Integration

## Refactoring Plan: Clean API + Split CLI Frontend from Core

### Overview

Two-phase refactoring:

| Phase | What | Scope | Status |
|-------|------|-------|--------|
| Phase 0 | Clean callback API (remove `writer` param, add `!void` return) | `agent.zig`, `render/cli.zig`, `App.zig` | ✅ Done |
| Phase 1 | Move CLI files to `src/frontends/cli/` | File moves + import path fixes | ✅ Done |
| Phase 2 | Enrich core API: hooks, abort, lifecycle events | `agent.zig`, new section below | ✅ Done |

### Phase 0: API cleanup

#### 0A. ToolDisplayCb: remove `writer` parameter, add `!void` return

**Why**: The `writer` leaks CLI implementation detail into core. A TUI/GUI/Web frontend doesn't write to an `Io.Writer` — it updates a widget or pushes to a queue. The writer belongs in the frontend's `?*anyopaque` context. `!void` makes render errors explicit instead of relying on the `stdout_dead` side channel.

```diff
// Current: 7-param signature with begin_tool, err_msg, meta
pub const ToolDisplayCb = struct {
    context: ?*anyopaque,
    begin_tool: ?*const fn (ctx: ?*anyopaque, tool_name: []const u8) void = null,
    render: *const fn (
        ctx: ?*anyopaque,
        tool_name: []const u8,
        tool_args: []const u8,
        had_error: bool,
        err_msg: ?[]const u8,
        user_output: ?[]const u8,
        meta: types.ToolMeta,
    ) anyerror!void,
};
```

### Phase 0: API cleanup

// agent.zig — runTurn drops the writer parameter (unused after callback change)
-pub fn runTurn(self: *AgentLoop, writer: *std.Io.Writer, tool_display: ?ToolDisplayCb) !RoundResult {
+pub fn runTurn(self: *AgentLoop, tool_display: ?ToolDisplayCb) !RoundResult {

// agent.zig — call site (inside runTurn loop)
-if (tool_display) |cb| {
-    cb.render(cb.context, writer, ok.*);
-}
+if (tool_display) |cb| {
+    cb.render(cb.context, ok.*) catch {
+        return RoundResult{ .new_message_count = new_msgs, .finish = .render_error };
+    };
+}

// agent.zig — TurnFinish enum
 pub const TurnFinish = enum {
     stop,
     max_rounds,
     interrupted,
     api_error,
+    render_error,
 };
```

```diff
// render/cli.zig (future: frontends/cli/render.zig)
-// ToolDisplay stores the writer in its context, not received via parameter
 pub const ToolDisplay = struct {
     ctx: *RenderContext,
+    writer: *std.Io.Writer,    // CLI-specific: now in context, not callback param

-    pub fn renderCb(context: ?*anyopaque, writer: *std.Io.Writer, result: types.ToolResult) void {
+    pub fn renderCb(context: ?*anyopaque, tool_name: []const u8, tool_args: []const u8, had_error: bool, user_output: ?[]const u8) anyerror!void {
         const self: *ToolDisplay = @ptrCast(@alignCast(context orelse return error.NullContext));
-        self.render(writer, result);
+        try self.render(tool_name, tool_args, had_error, user_output);
     }

-    pub fn render(self: *ToolDisplay, writer: *std.Io.Writer, result: types.ToolResult) void {
+    pub fn render(self: *ToolDisplay, tool_name: []const u8, tool_args: []const u8, had_error: bool, user_output: ?[]const u8) anyerror!void {
-        writer.print(...) catch |err| { ... }
+        self.writer.print(...) catch |err| {
+            return err;
+        };
     }
 };
```

```diff
// App.zig — initAgent() wiring
-self.tool_display = render.ToolDisplay{ .ctx = undefined };
+self.tool_display = render.ToolDisplay{ .ctx = undefined, .writer = undefined };
 self.line_buffer = render.LineBuffer.init(self.allocator, &self.render_ctx);
 self.tool_display.ctx = &self.render_ctx;
+self.tool_display.writer = &stdout.interface;   // CLI stores writer in context
```

#### 0B. PhaseWriterCb: keep `void` — NOT changed

PhaseWriterCb callbacks remain `void`. Rationale:
- On all platforms, Zig's Threaded IO (the default for `process.io`) installs a do-nothing SIGPIPE handler, so BrokenPipe returns `error.BrokenPipe` — never kills the process.
- On Windows, SIGPIPE does not exist; `WriteFile` returns `ERROR_BROKEN_PIPE` mapped to `error.BrokenPipe`.
- The content is collected into `content_buf` **before** `write_raw` is called — display failure does not cause data loss.
- Making them `!void` would require error propagation through the streaming parse loop, adding complexity for no practical recovery path.

#### 0C. Remove `stdout_dead_ptr` from AgentLoop (follows from 0A)

Since `render_error` now propagates through the callback return value, the `stdout_dead_ptr` bool in `AgentLoop` and `RenderContext.stdout_dead` can be removed. Confirm there are no other consumers before deleting.

#### 0D. Migrate model params to registry pattern

Replace hardcoded `reasoning: bool` field on `types.Model` with `params_json: ?[]const u8`. Delete the `if (self.config.reasoning)` branch in `provider.zig` (`provider.zig:431-433`). Provider blindly concatenates `params_json` into the JSON body.

| File | Change |
|------|--------|
| `types.zig` | `reasoning: bool` → `params_json: ?[]const u8 = null` |
| `toml.zig` | Parse `params_json` from TOML model entry |
| `config.zig` | `resolveModel()` copies `params_json` into Provider.Config |
| `provider.zig` | Delete `reasoning` if-block; add blind concatenation of `params_json` |
| `.zagent/config.toml` (template) | `models = [{ id = "deepseek-v4-pro", params_json = '"thinking":{"type":"enabled"}' }]` |

### Phase 1: File split

#### Dependency verification

```
Core files that import render/cli.zig:  NONE
Frontend files that import render/cli.zig:
  src/App.zig:9       const render = @import("render/cli.zig");
  src/test.zig:17     _ = @import("render/cli.zig");
```

`core/agent.zig` and `io/provider.zig` have zero references to `render/cli.zig`. The callback injection already decoupled them.

#### Steps

| Step | Action | File changes |
|------|--------|--------------|
| 1 | Create `src/frontends/cli/` directory | `mkdir` |
| 2 | Move `src/render/cli.zig` → `src/frontends/cli/render.zig` | `git mv` |
| 3 | Move `src/App.zig` → `src/frontends/cli/App.zig` | `git mv` |
| 4 | Move entry logic from `src/main.zig` → `src/frontends/cli/main.zig` | copy |
| 5 | Replace `src/main.zig` with shim delegating to `src/frontends/cli/main.zig` | rewrite to 4-line dispatch |
| 6 | Fix imports in `src/frontends/cli/render.zig` | `@import("../types.zig")` → `@import("../../types.zig")` |
| 7 | Fix imports in `src/frontends/cli/App.zig` | All `src/` imports: add `../../` prefix; `render/cli.zig` → `render.zig` |
| 8 | Update `src/test.zig` | `@import("render/cli.zig")` → `@import("frontends/cli/render.zig")` |
| 9 | `build.zig`: `root_source_file` stays `b.path("src/main.zig")` (now points to shim) | No change |
| 10 | Run `zig build` to verify | Zero logic changes, only import paths |
| 11 | Run `zig build test` to verify | All tests should pass |

**Implementation note (Zig 0.16)**: Step 5 was not in the original plan. Zig 0.16 rejects `@import` paths that escape the module root directory (set by `root_source_file`). Placing `root_source_file` at `src/main.zig` lifts the module root to `src/`, allowing `src/frontends/` files to import from `../../` (which resolves within `src/`). Without the shim, `root_source_file` would need to live inside `src/frontends/cli/`, blocking all `<frontend> -> <core>` imports.

#### Before/After

```
BEFORE                                AFTER
─────────────────────────────         ──────────────────────────────
src/                                  src/
  main.zig       ← CLI entry           main.zig          ← shim: frontend dispatch (--cli/--tui/--web)
  App.zig        ← CLI orchestrator    core/
  render/cli.zig ← ANSI, Markdown        agent.zig
  core/                                  session.zig
    agent.zig                           io/
    session.zig                           provider.zig
  io/                                   tool/
    provider.zig                          registry.zig, read.zig, ...
  tool/                                 types.zig
    registry.zig, read.zig, ...         config.zig
  types.zig                             toml.zig
  config.zig                            util/
  toml.zig                                path.zig, signal.zig, text.zig
  util/                                 frontends/
    path.zig, signal.zig, text.zig        cli/
  test.zig                                main.zig        ← moved (CLI entry)
                                          App.zig         ← moved
                                          render.zig      ← moved (was render/cli.zig)
```

Core = all of `src/` except `src/frontends/`. No dedicated `core/` wrapper directory needed; non-frontend consumers directly import `src/core/`, `src/io/`, `src/tool/`.

#### Import changes detail (actual implementation)

Frontends live inside `src/` (`src/frontends/`) due to Zig 0.16 module root constraint (see below).

**`src/frontends/cli/render.zig`** (was `src/render/cli.zig`):
```diff
-const types = @import("../types.zig");
+const types = @import("../../types.zig");
```

**`src/frontends/cli/App.zig`** (was `src/App.zig`):
```diff
-const types = @import("types.zig");
-const config_mod = @import("config.zig");
-const provider_mod = @import("io/provider.zig");
-const registry_mod = @import("tool/registry.zig");
-const session_mod = @import("core/session.zig");
-const agent_mod = @import("core/agent.zig");
-const render = @import("render/cli.zig");
-const signal = @import("util/signal.zig");
+const types = @import("../../types.zig");
+const config_mod = @import("../../config.zig");
+const provider_mod = @import("../../io/provider.zig");
+const registry_mod = @import("../../tool/registry.zig");
+const session_mod = @import("../../core/session.zig");
+const agent_mod = @import("../../core/agent.zig");
+const render = @import("render.zig");
+const signal = @import("../../util/signal.zig");
```

**`src/frontends/cli/main.zig`** (was `src/main.zig`):
Same directory, no import change needed.

**`src/test.zig`**:
```diff
-    _ = @import("render/cli.zig");
+    _ = @import("frontends/cli/render.zig");
```

**`build.zig`** root module entry — unchanged path (now points to shim):
```
.root_source_file = b.path("src/main.zig"),
```

#### Zig 0.16 module root constraint

Zig 0.16's `@import` paths must resolve within the directory subtree of the module's `root_source_file`. Had `root_source_file` been set to `src/frontends/cli/main.zig`, the module root would be `src/frontends/cli/`, and `../../types.zig` would resolve to `src/types.zig` -- outside the module root. Compiler rejects this.

The `src/main.zig` shim lifts the module root to `src/`, covering both `src/core/` and `src/frontends/` in a single package tree. This is the minimal mechanism to support layered imports in Zig 0.16 without splitting into separate compilation units.

#### Multi-frontend dispatch (future)

When TUI/Web frontends are added, `src/main.zig` becomes the dispatch point:

```zig
const cli = @import("frontends/cli/main.zig");

pub fn main(process: std.process.Init) !void {
    // TODO: parse --cli / --tui / --web from process.args
    return cli.main(process);
}
```

No `build.zig` changes needed. Single binary, multiple frontends selectable at runtime via CLI flag.

### Phase 2: Core API enrichment (done)

After Phase 1 is complete, add three lightweight mechanisms. No file moves — pure API additions.

| Step | Action | Module |
|------|--------|--------|
| 2A | Add `ToolHooks` struct + inject into `AgentLoop` | `agent.zig` |
| 2B | Add `abort()` method, replace `signal.isInterrupted()` with `_aborted` | `agent.zig` |
| 2C | Add optional `LifecycleCb` (on_turn_start, on_turn_end) | `agent.zig` |
| 2D | Wire Ctrl+C handler to call `agent.abort()` | `frontends/cli/App.zig` |
| 2E | Update test mocks for hooks + abort | `agent.zig` tests |
| 2F | (Optional) Create `tool/compact.zig` — context compression as a tool | `tool/compact.zig` + 1 line in `buildRegistry()` |
| | Design note: must be summary-based (replace old messages with an LLM-generated summary), NOT truncation-based. See [Pi pitfall #5](https://how-pi-agent-works.vercel.app/reference/pitfalls). Requires `ctx.api_endpoint` to call summarise API. | |
| 2G | Add `ApiEndpoint` to `ToolContext` — data-only struct (base_url, api_key, model) | `types.zig`, `core/agent.zig` (populates from Provider) |
| | Populated in `runTurn` before creating ToolContext: copy `provider_ref.config.base_url`, `.api_key`, `.model` into `ApiEndpoint`. Passed via `ctx.api_endpoint` only — tools don't get the Provider object itself. | |
| 2H | Capture token usage from SSE DONE frame, add `usage` to `types.Message` | `provider.zig`, `types.zig`, `core/session.zig` |
| 2I | (Optional) Add `/fork <name>` REPL command — copy current session to new file | `frontends/cli/App.zig` (zero core changes) |

Design details for each step are in the [Architecture: Comparison with Pi Agent](#architecture-comparison-with-pi-agent) section below.

### Session design: linear JSONL with fork, not internal tree

Pi uses one JSONL file as a session tree — every entry carries `parentId`, branching creates new nodes in the same file. z-agent-core deliberately avoids this:

| | Pi (tree in one file) | z-agent-core (one file per conversation) |
|---|---|---|
| Storage | Single JSONL with `parentId` per entry | Each conversation is its own `.jsonl` file |
| Branching | `switchLeaf(id)` — point leaf to existing node | `/fork <name>` — copies messages up to fork point into new file |
| Context rebuild | Traverse `parentId` chain from leaf | Read the file linearly |
| List sessions | Needs tree UI to navigate | `/list` shows flat file list |
| Core complexity | `byId` map, `pathToLeaf()`, `switchLeaf()` | `load()` / `flush()` / `list()` — that's it |

Fork semantics (`/fork`) vs Pi's branch semantics (`parentId`):

```
User: /fork "learn-api"             session-A.jsonl: msg1..msg10  (stays as-is)
                                    session-learn-api.jsonl: msg1..msg10  (independent copy)
User: ask API questions             session-learn-api: msg1..msg10, msg11..msg15
User: /load main-session            session-A: msg1..msg10  (never saw branch messages)
User: "查了 API，结论是 X"           session-A: msg1..msg10, msg11
```

Key property: fork inherits the full context (all messages up to the fork point), but the two files evolve independently after that. The knowledge you gained in the fork lives in your head, not in the session file — you bring it back by telling the LLM. This is simpler than auto-syncing between branches, and it matches how humans actually work: "let me look something up, then I'll tell you what I found."

---

## What is the core?

The core is **4 concepts, 2 contracts, zero rendering**.

| Concept | Responsibility | Module |
|---------|---------------|--------|
| **Prompt** | Build request body, call LLM API, parse streaming response | `io/provider.zig` |
| **Parse** | SSE line parsing, tool call merge, finish reason detection | (in provider) |
| **Execute** | Tool registry dispatch, argument parsing, result collection | `tool/` |
| **Agent loop** | Orchestrate: send -> parse -> detect tools -> execute -> loop until stop | `core/agent.zig` |

Everything else is infrastructure (types, session, signal, path) or **frontend** (`frontends/cli/`).

## Architecture: Comparison with Pi Agent

[Pi Agent](https://github.com/cellinlab/how-pi-agent-works) is a TypeScript coding agent with similar design goals. Its architecture validates our approach while suggesting three lightweight mechanisms we should adopt.

### Pi's three layers mapped to z-agent-core

```
Pi                                      z-agent-core
──────────────────────────────          ──────────────────────────────
pi-coding-agent                         frontends/cli/
  Session, Resources, Compaction,         App.zig, render.zig
  Extensions, TUI/RPC/print              (compaction + extensions excluded)

pi-agent-core                           src/core/
  Agent, runAgentLoop, Event,             agent.zig, session.zig
  Hooks, steer/followUp/abort

pi-ai                                   src/io/
  streamSimple, multi-provider,           provider.zig
  unified Message/Tool/Event             (single provider: OpenAI-compat)
```

### Pi's 5 essential concepts

| Concept | Pi | z-agent-core |
|---------|-----|-------------|
| Message | Save user, assistant, tool results | `types.Message` |
| Model | Generate next step from context | `io/provider.zig` |
| Tool | Connect model to external world | `tool/*.zig` |
| Loop | Iterate: output -> result -> request | `core/agent.zig` |
| Event | Expose process to UI and logs | PhaseWriterCb + ToolDisplayCb |

z-agent-core covers all five. The gap is that **Events are callbacks, not first-class structured types**. Pi's `AgentEvent` covers lifecycle start/end, message updates, and tool execution as typed events — our callbacks are ad-hoc.

### What to adopt (Phase 2)

Three lightweight mechanisms from Pi that add capability without adding complexity:

#### 1. Hooks: `beforeToolCall` / `afterToolCall`

**Pi's approach**: Agent exposes hook callbacks. Product layer registers interceptors for logging, permission gating, or result modification. Hooks are a mechanism — "permission system" is a policy built on top of hooks.

**z-agent-core today**: agent loop calls `registry.execute()` directly with no interception point (`agent.zig:153`).

**Proposed**:

```zig
pub const ToolHooks = struct {
    // Return non-null to block tool execution with an error message.
    before: ?*const fn (ctx: ?*anyopaque, name: []const u8, args: []const u8) ?[]const u8 = null,
    // Called after tool execution, before result is appended to session.
    after: ?*const fn (ctx: ?*anyopaque, result: *ToolResult) void = null,
};
```

In agent loop:
```zig
// Before execution
if (self.tool_hooks) |h| {
    if (h.before) |beforeFn| {
        if (beforeFn(h.context, tc.name, tc.arguments)) |block_msg| {
            // Tool blocked — append error to session, continue loop
            try self.session_ref.append(.{ .role = .tool, .content = block_msg, .tool_call_id = tc.id });
            continue;
        }
    }
}
var exec_result = self.tool_registry.execute(ctx, tc.name, tc.arguments);
// After execution
if (self.tool_hooks) |h| {
    if (h.after) |afterFn| afterFn(h.context, &exec_result);
}
```

This does NOT violate the negative boundary: hooks are a mechanism, not a "permission system" policy. A CLI frontend could use hooks for logging; a TUI frontend could use them for user confirmation dialogs.

**Hook return value lifecycle**: `before` returns `?[]const u8` — `null` means allow, non-null means block with this message. The returned slice is consumed immediately by `session.append(...)` which deep-copies it. The hook may return a static string, a stack-allocated buffer, or an arena slice — it only needs to live until the hook call returns. See [Memory lifecycle contract](#memory-lifecycle-contract).

#### 2. Explicit `abort()` method

**Pi's approach**: Agent exposes `abort()` alongside `prompt()` and `steer()`.

**z-agent-core today**: Interrupt is a global flag (`signal.setInterrupted()`) checked between tool rounds (`agent.zig:102`, `agent.zig:145`). This couples the agent loop to a global signal module.

**Proposed**:

```zig
pub const AgentLoop = struct {
    _aborted: bool = false,
    // ...
    pub fn abort(self: *AgentLoop) void {
        self._aborted = true;
    }
};
```

`runTurn` checks `self._aborted` instead of `signal.isInterrupted()`. `signal.init(io)` sets up the Ctrl+C handler to call `agent.abort()`. The abort mechanism lives in core; the signal wiring lives in the frontend.

#### 3. Lifecycle event callbacks

**Pi's approach**: `AgentEvent` covers turn lifecycle end-to-end.

**z-agent-core today**: PhaseWriterCb covers streaming display; ToolDisplayCb covers tool results. Missing: turn start/end notifications, tool-call-before-execution.

**Proposed** — extend `AgentLoop.init` opts with optional lifecycle callbacks:

```zig
pub const LifecycleCb = struct {
    context: ?*anyopaque,
    on_turn_start: ?*const fn (ctx: ?*anyopaque) void = null,
    on_turn_end: ?*const fn (ctx: ?*anyopaque, finish: TurnFinish) void = null,
};
```

Frontends can use `on_turn_start` to show a spinner, `on_turn_end` to hide it. All callbacks are optional — pass `null` for headless.

#### 4. Token usage tracking

**Pi's approach**: Every `AssistantMessage` carries `usage: { input, output, totalTokens }`.

**z-agent-core today**: The SSE stream's final `[DONE]` frame contains a `usage` object. `provider.zig` parses it but drops the data — it's never stored on `Message`.

**Proposed**:

```zig
// types.zig
pub const TokenUsage = struct {
    input: u32,
    output: u32,
    total: u32,
};

pub const Message = struct {
    role: Role,
    content: []const u8,
    tool_calls: ?[]const ToolCall = null,
    tool_call_id: ?[]const u8 = null,
    timestamp: i64 = 0,
    model: ?[]const u8 = null,
    usage: ?TokenUsage = null,   // captured from SSE [DONE]; null for user/tool messages
};
```

`provider.zig` extracts `usage` from the last SSE chunk and attaches it to the returned `ProviderResponse`. `agent.zig` copies it into the assistant `Message` it appends.

Why this matters:
- **Compaction tool needs it** — `compact.zig` must know how many tokens are in the current session to decide when to summarize
- **Context window management** — the LLM can't track its own usage; the agent must track it
- **Cost visibility** — frontends can show token consumption per turn
- **Zero overhead for existing code** — `usage` is `null` by default, all existing tool code ignores it

### What NOT to adopt

| Pi feature | Why not |
|------------|---------|
| Multi-provider abstraction (pi-ai) | DeepSeek-first; OpenAI-compat covers Ollama/OpenAI |
| Session tree with branching (id/parentId/leafId) | Linear JSONL per conversation. Fork creates a new file (copy messages up to fork point), not a tree node. Simpler, and fork is a frontend command — zero core changes. |
| Context compaction | Already in negative boundary; 128K window sufficient |
| Full extension system | Already in negative boundary; was the original z-agent killer |
| ResourceLoader as core | AGENTS.md loading is frontend; skill tool already exists in core |

## Core output model

The core does NOT output text to a terminal. It produces **structured results** that the frontend decides how to present:

```
AgentLoop.runTurn(tool_display) -> RoundResult {
    new_message_count: usize,    // how many messages were appended
    finish: TurnFinish,          // stop | max_rounds | interrupted | api_error | render_error
}
```

Tool results are produced as `ToolResult` — pure data, no display strings:
```
ToolResult {
    session_content:   "...file contents..."   // LLM context data
    err_msg:           null,                    // non-null = tool failed
    user_output:       null,                    // optional human-facing output (borrowed view)
}
```

The frontend derives display labels from the tool name + args JSON — tools do not construct `action` or `summary` strings.
The `is_error` concept is replaced by `err_msg: ?[]const u8` — non-null indicates failure.

### Messages are source of truth; events are projection

This is a fundamental design rule inherited from Pi Agent's [message and stream model](https://how-pi-agent-works.vercel.app/concepts/message-and-stream).

There are two data flows in parallel during a turn:

| Flow | What | Storage | Consumer |
|------|------|---------|----------|
| **Messages** | Structured chat history (`types.Message` with role, content, tool_calls, tool_call_id) | `core/session.zig` (JSONL) | LLM context, session persistence, future compaction/branching |
| **Usage** | Token counts per assistant message (`usage: ?TokenUsage`) | Appended to Message from SSE [DONE] frame | Compaction decisions, cost visibility, context window management |
| **Events** | Real-time display signals (PhaseWriterCb, ToolDisplayCb, LifecycleCb) | Nothing — fire and forget | Terminal, TUI, GUI, Web SSE |

The two are **never** the same thing:

- Messages are **append-only** and must be structural enough to rebuild context for any future model request
- Events are **transient** — if the terminal crashes mid-turn, events are lost but messages are safe in session
- Tool results go into **both** flows: `session_content` goes into the message store
- During streaming, PhaseWriterCb projects raw chunks to the display **while** content accumulates in memory for the final message

This dual-flow design means:
- Session replay is possible (reconstruct turns from JSONL)
- Display failures don't corrupt session data
- Different frontends can project the same messages differently (ANSI vs TUI widgets vs SSE)

## Core pattern: Everything is a ToolEntry

There is exactly one way to add capability to z-agent-core: register a `ToolEntry`. No plugin system, no extension API, no hook-based capability injection. If it can't map to the minimum `ToolEntry { name, description, params, execute }` shape, it doesn't belong.

This is not a limitation. It's a filter that prevents complexity from creeping back in.

### The one decision rule

| Can it map to ToolEntry? | Action |
|--------------------------|--------|
| ✅ Yes | `tool/xxx.zig` + 1 line in `buildRegistry()` |
| ✅ Yes, but needs Session | Same, use `ctx.session` |
| ✅ Yes, but tools come from a remote server | `tool/mcp_connect.zig` — LLM calls it, it extends registry at runtime |
| ❌ No | Ask: are you creating a new abstraction layer? |

### Three kinds of tools, one registry

```
tool/
  registry.zig        ← buildRegistry() + runtime extend()
  read.zig            ← external: file system only
  write.zig
  bash.zig
  grep.zig
  glob.zig
  skill.zig
  compact.zig         ← internal (planned): uses ctx.session to read/rewrite messages
  branch.zig          ← internal (planned): uses ctx.session to fork sessions
  remember.zig        ← internal (planned): maintains its own persistent storage
  recall.zig          ← internal (planned): queries that storage
  mcp_connect.zig     ← external (planned): LLM calls it; it connects MCP server, extends registry
  fetch.zig           ← external (planned): makes HTTP requests
```

All three kinds share the same `ToolEntry` struct, the same `Registry.execute()`, and the same LLM schema generation. The difference is only in what `execute()` does internally.

### ToolEntry anatomy

The current implementation uses `types.Tool` with 4 fields (`name`, `description`, `params`, `execute`). The future vision adds `prompt_hint` and `validate` — shown here as aspirational `ToolEntry`:

```zig
// Current: types.Tool (4 fields)          // Future: ToolEntry (6 fields)
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    params: []const u8,
    execute: *const fn (...) anyerror!ToolResult,
};
```

```zig
// Aspirational ToolEntry extends Tool with:
pub const ToolEntry = struct {
    name: []const u8,
    description: []const u8,
    params: []const u8,
    prompt_hint: ?[]const u8 = null, // injected into system prompt, NOT sent to tools API
    validate: *const fn (allocator: std.mem.Allocator, args_json: []const u8) !void,
    execute: *const fn (ctx: ToolContext, args_json: []const u8) !ToolResult,  // errors are ToolResults, not exceptions
};

pub const ToolResult = struct {
    action: []const u8,           // what the tool did ("Read src/main.zig")
    summary: ?[]const u8,         // optional result digest ("1-35/35 lines")
    session_content: []const u8,  // what goes into the LLM context
    is_error: bool = false,       // true => model can self-correct
};
```

**`prompt_hint`** — behavioral guidance for the LLM, injected into system prompt once at startup. Separate from `description`/`params` which go to the tools API schema. Example:

```zig
// read.zig
pub const tool_hint = "Before reading a file, consider using grep or glob to narrow down the right file.";

// grep.zig
pub const tool_hint = "Use grep to find relevant code before reading entire files.";

// bash.zig
pub const tool_hint = "Run commands with `--help` first to verify flags. Prefer non-destructive operations.";
```

`buildSystemPrompt()` iterates registered tools and appends all non-null hints to the system message. The LLM learns usage strategy without changing the tools API contract.

**`validate`** — runs before `execute` in the Registry dispatch path. Catches malformed arguments before any side effects:

```zig
pub fn execute(self: *Registry, ctx: ToolContext, name: []const u8, args_json: []const u8) !ToolResult {
    // Search runtime extensions first, then built-in
    for (self.extensions.items) |h| {
        if (std.mem.eql(u8, h.name, name)) {
            h.validate(ctx.allocator, args_json) catch |err| {
                const msg = try std.fmt.allocPrint(ctx.allocator, "Invalid arguments for {s}: {s}", .{ name, @errorName(err) });
                return ToolResult{ .session_content = msg, .err_msg = msg };
            };
            return h.execute(ctx, args_json);  // execute errors caught by agent loop, not here
        }
    }
    for (self.handlers) |h| {
        if (std.mem.eql(u8, h.name, name)) {
            h.validate(ctx.allocator, args_json) catch |err| {
                const msg = try std.fmt.allocPrint(ctx.allocator, "Invalid arguments for {s}: {s}", .{ name, @errorName(err) });
                return ToolResult{ .session_content = msg, .err_msg = msg };
            };
            return h.execute(ctx, args_json);  // execute errors caught by agent loop, not here
        }
    }
    // unknown tool → also an error ToolResult, not an exception
}
```

**`is_error` on ToolResult** — tools never throw exceptions. Even file-not-found, permission-denied, or validation-failure return a `ToolResult` with `is_error: true`. The agent loop appends it to session as a tool message. The LLM sees the error and can adjust its plan (e.g., try a different path, ask for clarification).

#### Design rules for tool authors

| Rule | Why |
|------|-----|
| `description` must be clear enough for the LLM to know WHEN to call | Vague descriptions → model guesses wrong → wasted rounds |
| `validate` checks args shape before `execute` runs | Wrong args caught before side effects (no half-written files) |
| `execute` never throws — errors are `is_error: true` ToolResults | Model sees the error and self-corrects; agent loop doesn't need try/catch |
| Long output must be truncated inside the tool or via after-hook | A 500KB file read fills the context window, starving subsequent turns |
| `prompt_hint` explains strategy, not mechanics | "Use grep first" not "params: pattern, path" — the latter is already in `params` |

#### External tools

No access to agent state. Operate on the file system or external processes.

```zig
pub fn execute(ctx: ToolContext, args_json: []const u8) !ToolResult {
    // ctx.allocator, ctx.io, ctx.project_root
    // ctx.session is null — don't touch agent state
}
```

#### Internal tools

Need access to session state. Marked by convention, not by type.

```zig
// ToolContext: the single context passed to every tool.
// External tools use allocator/io/project_root. Internal tools also use session.
// mcp_connect uses registry to append discovered tools at runtime.
// compact uses api_endpoint to call the LLM summarise API.
pub const ToolContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    session: ?*Session = null,        // internal tools (compact, branch, remember, recall)
    registry: ?*Registry = null,      // mcp_connect appends discovered tools
    api_endpoint: ?types.ApiEndpoint = null,  // compact calls LLM for summarisation
};

// types.zig
pub const ApiEndpoint = struct {
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
};

// compact.zig
pub fn execute(ctx: ToolContext, args_json: []const u8) !ToolResult {
    const sess = ctx.session orelse return error.NoSession;
    const endpoint = ctx.api_endpoint orelse return error.NoApiEndpoint;
    const old_msgs = sess.messages();
    // Call LLM summarise API via endpoint.base_url + endpoint.api_key
    // Replace old messages with summary, keep recent N messages
    // Return ToolResult — agent loop appends it like any other tool result
}
}
```

No new concepts. No "plugin manager". No "internal tool registry". Just fields on a struct that already exists.

#### Remote tools via MCP (runtime extension)

MCP is a tool, not a startup service. The LLM decides when to connect.

```zig
// tool/mcp_connect.zig — registered in buildRegistry() like any other tool
pub fn execute(ctx: ToolContext, args_json: []const u8) !ToolResult {
    const reg = ctx.registry orelse return error.NoRegistry;
    const args = try parseArgs(args_json);  // { "server": "http://localhost:3456" }
    const entries = try discoverTools(ctx.allocator, args.server);  // MCP tools/list
    try reg.extend(ctx.allocator, entries);  // append to runtime list
    return ToolResult{
        .session_content = try formatDiscoveredTools(ctx.allocator, entries),
    };
}
```

`discoverTools()` handles MCP protocol handshake and `tools/list`. Returns `[]ToolEntry` — same struct as every other tool. After `reg.extend()`, the agent loop calls `toTools()` again in the next round and the LLM sees the new tools.

The registry change is minimal — a static array becomes a static array + optional ArrayList:

```zig
pub const Registry = struct {
    handlers: []const ToolEntry,                            // compile-time built-in
    extensions: std.ArrayListAligned(ToolEntry, null),      // runtime-added (MCP)

    pub fn extend(self: *Registry, allocator: std.mem.Allocator, entries: []const ToolEntry) !void {
        for (entries) |entry| {
            if (self.hasTool(entry.name)) return error.DuplicateToolName;
            try self.extensions.append(allocator, entry);
        }
    }

    fn hasTool(self: *Registry, name: []const u8) bool {
        for (self.handlers) |h| { if (std.mem.eql(u8, h.name, name)) return true; }
        for (self.extensions.items) |e| { if (std.mem.eql(u8, e.name, name)) return true; }
        return false;
    }
};
```

Full MCP flow in a single turn:
```
Turn N, Round 1:
  LLM: toolCall mcp_connect({server: "http://mcp/search"})
  Agent: executes mcp_connect → discoverTools → reg.extend → 4 new tools
  Agent: appends mcp_connect result to session

Turn N, Round 2:
  Agent: toTools() now returns 6 built-in + 4 MCP = 10 tools
  LLM: toolCall web_search({query: "Zig 0.16 release notes"})
  Agent: dispatches web_search → same path as read, same registry, same loop
```

Agent loop never knows MCP exists. It only sees the tool list grew.

### Tool registry properties

- **Add a tool (any kind)**: one file + one line in `buildRegistry()` — no changes to agent, provider, or App
- **LLM schema auto-generated**: `toTools()` converts all entries (built-in + runtime extensions) to OpenAI tools array
- **Dispatch is a simple loop**: `registry.execute(name, args)` searches extensions first, then built-in
- **Runtime extension**: `registry.extend()` appends entries — one ArrayList field, one method
- **Does NOT need**: a plugin system, a hook system, a capability negotiation protocol, a separate registry per tool kind, a startup discovery phase, or an MCP runtime

#### Design note: single Tool type for both LLM schema and local dispatch

Pi splits tool representation into two types: `ToolDefinition` (name + description + params, sent to LLM) and `RegisteredTool` (adds `execute`, kept local). z-agent-core uses a single `types.Tool` for both:

```zig
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    params: []const u8,
    execute: *const fn (ctx: ToolContext, args: []const u8) anyerror!ToolResult,
};
```

The `execute` field is a Zig function pointer — it cannot be serialized as JSON. When `buildJsonBody()` constructs the tools array for the LLM, it only reads `name`, `description`, and `params`. The `execute` field exists in the struct but never leaves the process.

This is a deliberate simplification over Pi's two-type approach:
- Fewer types, fewer allocations
- No risk of mismatched Tool ↔ ToolDefinition pairs
- The function pointer's non-serializability is the safety guarantee — the compiler prevents sending it to the API, no runtime check needed

### Model/provider registry (configuration-time)

Each model in TOML carries a pre-serialized JSON fragment. Provider blindly concatenates it into the request body:

```toml
# .zagent/config.toml
[[providers]]
name = "deepseek"
base_url = "https://api.deepseek.com"
api_key_env = "DEEPSEEK_API_KEY"
models = [
    { id = "deepseek-v4-pro", params_json = '"thinking":{"type":"enabled"}', context_window = 131072 },
    { id = "deepseek-chat",   params_json = '', context_window = 65536 },
]

[[providers]]
name = "openai"
base_url = "https://api.openai.com"
api_key_env = "OPENAI_API_KEY"
models = [
    { id = "o3-mini", params_json = '"reasoning_effort":"high"', context_window = 200000 },
    { id = "gpt-4o",  params_json = '', context_window = 128000 },
]
```

```zig
// types.zig
pub const Model = struct {
    id: []const u8,
    name: []const u8,
    provider: []const u8 = "",
    context_window: u32,
    max_tokens: u32,
    params_json: ?[]const u8 = null,  // key-value JSON fragment WITHOUT outer braces: '"thinking":{"type":"enabled"}'
                                       // NOT: '{"thinking": {"type": "enabled"}}' (outer braces break JSON)
    // reasoning: bool  ← removed: DeepSeek thinking is now params_json
};

// provider.zig — buildJsonBody()
if (self.config.model_params) |params| {
    try buf.appendSlice(allocator, ",");
    try buf.appendSlice(allocator, params);   // paste without interpretation
}
```

Key properties:
- **Add a model**: one TOML block — no recompile
- **Add a vendor-specific param**: add to `params_json` in TOML — no zig changes
- **Provider stays dumb**: it doesn't know what `thinking` or `reasoning_effort` mean
- **Validation is optional**: the API server validates the JSON; z-agent-core doesn't need to

### Same pattern, different registration timing

| | External tools | Internal tools | MCP tools | Model registry |
|------|---|---|---|---|
| Example | read, write, bash, fetch | compact, branch, remember | mcp_connect (then LLM calls web_search etc.) | deepseek-v4-pro, gpt-4o |
| Registration | Compile-time | Compile-time (opt-in flag) | Runtime — LLM calls mcp_connect | Config-time (TOML parse) |
| Needs Session | No | Yes (`ctx.session`) | No (needs `ctx.registry`) | N/A |
| Core change | 1 file + 1 line | 1 file + 1 line | 1 file + 1 line + ArrayList on Registry | TOML only |
| Discoverable by LLM | Always | When opted in | LLM decides when to connect | N/A |

## The two contract points

### 1. ToolDisplayCb -- how tool execution is shown

Injected into `AgentLoop.runTurn()`. Called once per tool execution. Returns `!void` — if the frontend fails to display (e.g. BrokenPipe, OOM), the agent aborts the turn with `TurnFinish.render_error`.

```
ToolDisplayCb {
    context: ?*anyopaque,
    begin_tool: ?*const fn (ctx: ?*anyopaque, tool_name: []const u8) void = null,
    render: *const fn (ctx: ?*anyopaque, tool_name: []const u8, tool_args: []const u8, had_error: bool, err_msg: ?[]const u8, user_output: ?[]const u8, meta: types.ToolMeta) anyerror!void,
}
```

Pass `null` for headless operation.

### 2. PhaseWriterCb -- how streaming phases are shown

Injected into `Provider.init()`. Called during SSE streaming to signal phase transitions and stream text chunks. Returns `void` — display failure during streaming is non-fatal (data is already collected in memory before the callback fires).

```
PhaseWriterCb {
    context:       ?*anyopaque,
    begin_phase:   fn(ctx, PhaseType),       // .thinking | .content | .none
    write_raw:     fn(ctx, bytes: []u8),     // raw chunk (may be partial UTF-8)
    write_rendered: fn(ctx, line: []u8),     // complete, renderable line
    end_phase:     fn(ctx),                  // flush + cleanup
}
```

Pass `null` for headless operation.

### Memory lifecycle contract

> **All `[]u8` slices passed to callbacks are borrowed from the core's internal arena. They are valid only within the callback's call stack (synchronous borrow). Frontends that need to hold data beyond the callback return (e.g. GUI event queues) MUST duplicate the data using their own allocator before enqueueing.**

This applies to:
- `ToolResult.action`, `.summary`, `.session_content`
- `PhaseWriterCb.write_raw(bytes)`, `write_rendered(line)`

### Time contract

> **All callbacks MUST return quickly (< 1ms typical).** The agent loop is synchronous — a slow callback blocks the LLM stream, tool execution pipeline, and all subsequent turns. Frontends that need user interaction (e.g. permission confirmation dialogs) MUST: (1) enqueue the event asynchronously and return immediately, (2) wait for user response outside the callback, (3) use the `ToolHooks.before` return value (Phase 2) to gate tool execution synchronously.

This applies to:
- `ToolDisplayCb.render` — if BrokenPipe is detected, return `error.BrokenPipe` immediately; do not retry
- `PhaseWriterCb` callbacks — buffers are flushed inside the callback; do not block on I/O
- `ToolHooks.before` (Phase 2) — return `?[]const u8` immediately (null = allow, non-null = block with message); do not pop up a dialog inside the callback

### Example: permission dialog without blocking

```zig
// WRONG — blocks the agent loop until user clicks
fn badHook(ctx: ?*anyopaque, name: []const u8, args: []const u8) ?[]const u8 {
    return showModalAndWait("Allow executing {s}?", .{name});  // blocks!
}

// CORRECT — hook returns immediately, UI resolves asynchronously
fn goodHook(ctx: ?*anyopaque, name: []const u8, args: []const u8) ?[]const u8 {
    const gui: *GuiState = @ptrCast(@alignCast(ctx orelse return "no ctx"));
    gui.pending_approval = .{ .name = name, .args = args };  // enqueue
    return "Waiting for user approval...";  // block this call, model will retry
}
// GUI main loop resolves pending_approval on user click, stores result for next turn
```

`ToolResult.deinit()` is called by the agent loop immediately after the callback returns. If a GUI frontend pushes a `ToolResult` to a queue, it must copy all three fields before returning from the callback:

```zig
fn guiToolCb(ctx: ?*anyopaque, result: ToolResult) !void {
    const gui: *GuiState = @ptrCast(@alignCast(ctx orelse return error.NullContext));
    // Must copy — result fields are invalid after this callback returns
    const copy = gui.dupToolResult(result);  // uses gui's allocator
    gui.event_queue.push(.{ .tool_done = copy });
}
```

## Frontend integration patterns

z-agent-core supports three frontend modes. Unlike Pi (which needs Node.js + React + Vite for its web UI), all three modes work from the same Zig binary with zero external runtime dependencies.

| Mode | Runtime | Frontend code | Status |
|------|---------|---------------|--------|
| **CLI** | Zig binary → stdout | `frontends/cli/` (pure Zig) | ✅ Implemented |
| **TUI** | Zig binary → terminal grid | `frontends/tui/` (Zig + vaxis or similar) | 🔮 Future |
| **Web** | Zig binary → HTTP → browser | `frontends/web/server.zig` (Zig) + `index.html` (vanilla JS) | 🔮 Future |

### Pattern A: CLI (`frontends/cli/`)

The CLI frontend implements both contracts. Since it writes to stdout, it stores the writer in its `?*anyopaque` context rather than receiving it via callback parameter.

```zig
// frontends/cli/App.zig
const render = @import("render.zig");
const provider_mod = @import("../../io/provider.zig");
const agent_mod = @import("../../core/agent.zig");

// PhaseWriterCb: connect callbacks to render module
const phase_writer_cb = provider_mod.PhaseWriterCb{
    .context = &writer_ctx,
    .begin_phase = pwBeginPhase,
    .write_raw = pwWriteRaw,
    .write_rendered = pwWriteRendered,
    .end_phase = pwEndPhase,
};

// ToolDisplayCb: writer stored in ToolDisplay context, not in callback signature
const tool_cb = agent_mod.ToolDisplayCb{
    .context = &self.tool_display,      // ToolDisplay holds *Io.Writer inside
    .render = render.ToolDisplay.renderCb,
};
const result = self.agent.runTurn(tool_cb);
```

CLI-specific rendering:
- `write_raw` feeds bytes into `LineBuffer` that flushes on newline
- `write_rendered` runs Markdown-to-ANSI, writes to stdout
- `ToolDisplay.renderCb` writes `[TOOL] read src/foo.zig` styled lines to stored writer
- `begin_phase`/`end_phase` manage streaming labels ("Thinking..." / "Output:")
- `renderCb` returns `error.BrokenPipe` on stdout disconnect → agent aborts turn with `render_error`
- REPL loop handles `/exit`, `/new`, `/load`, `/name`, `/list`, `/fork`, `/help`

### Pattern B: TUI (terminal UI framework)

```zig
// Hypothetical: frontends/tui/AppTui.zig
const provider_mod = @import("../../io/provider.zig");
const agent_mod = @import("../../core/agent.zig");

const tui_phase_cb = provider_mod.PhaseWriterCb{
    .context = &tui_state,
    .begin_phase = tuiBeginPhase,
    .write_raw = tuiWriteRaw,
    .write_rendered = tuiWriteRendered,
    .end_phase = tuiEndPhase,
};

const tui_tool_cb = agent_mod.ToolDisplayCb{
    .context = &tui_state,
    .render = tuiToolDisplay,       // no writer param — TUI draws to its own grid
};

fn tuiToolDisplay(ctx: ?*anyopaque, tool_name: []const u8, tool_args: []const u8, had_error: bool, err_msg: ?[]const u8, user_output: ?[]const u8, meta: types.ToolMeta) !void {
    _ = tool_name;
    _ = tool_args;
    _ = had_error;
    _ = err_msg;
    _ = user_output;
    _ = meta;
    const tui: *TuiState = @ptrCast(@alignCast(ctx orelse return error.NullContext));
    tui.redraw();
}
```

Key difference from CLI: TUI never touches stdout directly. It accumulates state and redraws the terminal grid. The callback returns `error.OutOfMemory` if buffers are exhausted — this propagates to the agent as `render_error`, which is correct behavior.

### Pattern C: GUI (native desktop)

```zig
// Hypothetical: frontends/gui/AppGui.zig
// Core runs in a worker thread, sends events via SPSC queue

const GuiEvent = union(enum) {
    phase_begin: PhaseType,
    text_chunk: []const u8,       // dupe'd copy
    tool_done: GuiToolResult,     // dupe'd copy
    turn_done: RoundResult,
};

fn guiToolCb(ctx: ?*anyopaque, result: ToolResult) !void {
    const gui: *GuiState = @ptrCast(@alignCast(ctx orelse return error.NullContext));
    // Must copy — result is arena-backed, invalid after return
    const copy = GuiToolResult{ .content = try gui.allocator.dupe(u8, result.session_content), };
    gui.event_queue.push(.{ .tool_done = copy }) catch return error.QueueFull;
}

// GUI thread consumes events:
fn guiEventLoop(tx: *Queue(GuiEvent)) void {
    while (tx.pop()) |event| {
        switch (event) {
            .phase_begin => |p| status_bar.set(if (p == .thinking) "Thinking..." else ""),
            .text_chunk => |c| { defer gui.allocator.free(c); text_view.append(c); },
            .tool_done => |r| { defer gui.freeResult(r); tool_panel.add(r); },
            .turn_done => |r| {
                if (r.finish != .stop) show_error(r.finish);
                input_field.enable();
            },
        }
    }
}
```

### Pattern D: Web (HTTP/SSE server)

Pi Agent's [Express API](https://how-pi-agent-works.vercel.app/project/build-05-api) is the reference design: three minimal endpoints wrapping the same core loop. z-agent-core can follow the same pattern with a Zig HTTP server.

**API surface**:

| Method | Path | z-agent-core mapping |
|--------|------|---------------------|
| `GET` | `/api/session` | `session.messages()` + `tool_registry.toTools()` → JSON |
| `POST` | `/api/prompt` | Orchestrates: append user msg → compact tool (LLM decides) → build context → `agent.runTurn()` → append results → respond |
| `POST` | `/api/reset` | `session.deinit()` + `session.init()` (equivalent to CLI `/new`) |

**POST /api/prompt flow** (mapped from Pi's Express to z-agent-core):

```zig
// frontends/web/server.zig
fn handlePrompt(sess: *Session, agent: *AgentLoop, body: PromptBody) !Response {
    // 1. Validate input
    if (body.text.len == 0) return errorResponse(400, "text is required");

    // 2. Append user message to session
    try sess.append(.{ .role = .user, .content = body.text });

    // 3. Run agent turn — compact is handled by LLM as a tool call, not here
    //    (Pi calls compactIfNeeded() at this point; z-agent defers to LLM)
    const result = try agent.runTurn(tool_cb);

    // 4. Session already contains new messages (appended inside runTurn)
    // 5. Flush to disk
    try sess.flush();

    // 6. Return full session state
    return jsonResponse(SessionResponse{
        .messages = sess.messages(),
        .tools = tool_registry.toTools(arena),
        .finish = result.finish,
    });
}
```

**SSE streaming** (events projected to browser):

```zig
fn webPhaseCb(ctx: ?*anyopaque, phase: PhaseType) void {
    const conn: *HttpConnection = @ptrCast(@alignCast(ctx orelse return));
    const event = switch (phase) {
        .thinking => "thinking_start",
        .content => "content_start",
        .none => return,
    };
    conn.sendSse(event, "");
}

fn webToolCb(ctx: ?*anyopaque, result: ToolResult) !void {
    const conn: *HttpConnection = @ptrCast(@alignCast(ctx orelse return error.NullContext));
    const json = serializeToolResult(conn.arena, result);
    conn.sendSse("tool_result", json);
}
```

Key difference from Pi: Pi calls `compactIfNeeded()` in the API layer before the loop. z-agent-core defers this to the LLM — if context is tight, the LLM can call the `compact` tool itself. The orchestrator stays dumb.

#### Web frontend without Node.js

Pi's frontend needs React + Vite + npm because it renders a rich SPA with session tree, event timeline, and tool panels. z-agent-core's web frontend takes a different approach: **a single HTML file served by the Zig binary, zero build step**.

```
browser (index.html)           Zig binary (frontends/web/server.zig)
────────────────────────       ───────────────────────────────────────
GET /                     →    serve embedded index.html
fetch('/api/session')     →    session.messages() → JSON
fetch('/api/prompt')      →    runTurn() → JSON
EventSource('/api/stream') →   PhaseWriterCb → SSE (text chunks)
                              ToolDisplayCb → SSE (tool results)
```

The HTML file is embedded at compile time via `@embedFile`:

```zig
// frontends/web/server.zig
const index_html = @embedFile("index.html");

fn handleRoot(conn: *HttpConnection) !void {
    conn.sendHtml(index_html);
}
```

The browser side is vanilla JavaScript — no framework, no build tool, no npm:

```html
<!-- frontends/web/index.html -->
<input id="prompt" />
<button onclick="send()">Send</button>
<div id="chat"></div>

<script>
async function send() {
  const text = document.getElementById("prompt").value;
  const res = await fetch("/api/prompt", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ text }),
  });
  const data = await res.json();
  data.messages.forEach(m => {
    document.getElementById("chat").innerHTML += `<div class="${m.role}">${m.content}</div>`;
  });
}
</script>
```

For streaming, use `EventSource`:

```js
const es = new EventSource("/api/stream");
es.addEventListener("content_chunk", e => { appendToChat(e.data); });
es.addEventListener("tool_result", e => { showToolCard(JSON.parse(e.data)); });
es.addEventListener("turn_end", e => { enableInput(); });
```

This is the same data flow as the CLI — just projected to HTML instead of ANSI. The core callbacks remain identical.

## Minimal frontend checklist

| What | Required? | Notes |
|------|-----------|-------|
| `PhaseWriterCb` callbacks | Yes (pass null to skip) | 4 functions returning `void` |
| `ToolDisplayCb` callback | Yes (pass null to skip) | 1 function returning `!void` |
| User input collection | Yes | stdin, TUI handler, HTTP POST, etc. |
| Session persistence | Optional | `session.flush()` after each turn |
| Config loading | Yes | `Config.load()` provides `types.ProviderEntry` and `types.Model` |
| Provider creation | Yes | `Provider.init()` with phase callbacks |
| Tool registry | Yes | `buildRegistry()` returns static `Registry` |
| Agent creation | Yes | `AgentLoop.init()` with tool display callback |
| Error handling | Yes | Handle `TurnFinish.api_error`, `.interrupted`, `.render_error` |
| Ctrl+C handling | Optional | `signal.init(io)` + check `signal.isInterrupted()` |
| Memory copies for async | Yes (if async) | Copy all callback slices before returning if using event queues |

## What should NOT go into core (negative boundary list)

| Feature | Why it stays out |
|---------|-----------------|
| Markdown rendering | Frontend concern: CLI parses to ANSI, TUI parses to styled spans, Web sends raw Markdown |
| ANSI color codes | CLI-specific; GUI/TUI use their own styling systems |
| REPL loop | CLI interaction pattern; GUI has event loop, Web has HTTP handlers |
| Multi-line input | Input handling belongs to frontend |
| Session listing/management commands (/list, /name, /load) | Frontend concern |
| Permission system | Was the original reason z-agent became unmaintainable. Hooks (mechanism) are in core; permission gating (policy) lives in frontend via hooks. |
| Memory/compaction system | Was the original reason z-agent became unmaintainable. Compaction is designed as a Tool (compact.zig, planned), not as a built-in agent mechanism. The agent loop doesn't know what compaction is — it just dispatches tool calls. |
| Sub-agent delegation | Was the original reason z-agent became unmaintainable |
| TUI framework dependency | Would couple all frontends to one rendering library |
| Io.Writer in callback signatures | Writer is CLI-specific; frontend stores its own output target in context |
