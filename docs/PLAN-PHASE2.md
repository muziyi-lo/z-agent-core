# Phase 2: Core API Enrichment

## Review Feedback (2026-07-13)

Third-party review identified 8 issues + 5 elegant suggestions (round 1) and 4 bugs + 5 suggestions (round 2). Adopted:

| Issue | Change |
|-------|--------|
| TokenUsage parsing details | Specified `parseFromSliceLeaky(Value, ...)` pattern (same as provider.zig SSE parsing) |
| compact abort support | Post-`wait()` abort check; curl timeout bounds max wait duration |
| /fork atomicity | Temp file + rename pattern |
| /fork auto-switch | Auto-load forked session (quality-of-life) |
| Bug #1: 2D contradiction | Rewrote Step 2D to Solution A (App-layer polling, zero global state) |
| Bug #2: result_capture UB | Chose explicit `on_turn_end` at each return point |
| Bug #3: child.wait() blocking | Zig 0.16 has no tryWait(); compact checks abort after wait, not during |
| Bug #4: temp file residual | Clean stale .tmp.jsonl before writing |

Not adopted:

| Issue | Reason |
|-------|--------|
| ApiEndpoint HTTP interface | Compact reuses existing curl subprocess pattern; no new abstraction needed |
| abort target lifecycle | Solution A eliminates global pointer entirely |
| LifecycleCb error details | Deferred to Phase 3; `TurnFinish` sufficient for CLI |
| Test depends on real LLM | False alarm: `ChatFn` mock injection already covers test isolation |
| `after` hook use-after-free | False alarm: Zig `defer` executes at end of block; after hook runs before deinit |
| CancellationToken / Atomic / Event bus | Over-engineering for Phase 2 scope |

## Overview

Eight steps adding hooks, abort, lifecycle events, token tracking, ApiEndpoint, and optional compact + fork. No file moves -- pure API additions to existing modules.

## Implementation Status (2026-07-13)

| Step | Status | Key changes | Files |
|------|--------|-------------|-------|
| 2A (ToolHooks) | ✅ Done | ToolHooks struct + before/after in runTurn | agent.zig:40-44,66,84,175-205 |
| 2B (abort) | ✅ Done | _aborted field + abort() + finishTurn | agent.zig:68,70-72,103-111,133-135,178-179 |
| 2C (LifecycleCb) | ✅ Done | LifecycleCb struct + on_turn_start/end via finishTurn | agent.zig:47-51,67,85,119-121 |
| 2D (Ctrl+C bridge) | ✅ Done | Solution A: App polling signal → agent.abort() | App.zig:232-235,355-358 |
| 2G (ApiEndpoint) | ✅ Done | ApiEndpoint + abort_target on ToolContext | types.zig:22-26,42-43; agent.zig:189-199 |
| 2H (TokenUsage) | ✅ Done | TokenUsage struct + SSE parsing + session serialization | types.zig:16-20,13,97; provider.zig:271-279,374,382; agent.zig:160; session.zig:445-456,122-133 |
| 2I (/fork) | ✅ Done | /fork command + session.writeTo() + auto-switch | App.zig:330-333,487-533; session.zig:234-255 |
| 2E (tests) | ✅ Done | 7 new tests: hooks(3) + abort(2) + lifecycle(2) | agent.zig:580-850 |
| 2F (compact.zig) | ⏳ Skipped | Optional; deferred to future | — |

### Implementation deviations from plan

| Deviation | Plan | Actual | Reason |
|-----------|------|--------|--------|
| _aborted reset location | `self._aborted = false` at runTurn entry | Reset in finishTurn(.interrupted) only | Entry reset clears flag before while-loop check |
| on_turn_start ordering | After _aborted reset, before LLM | Before arena init, before _aborted check | Simpler code; fires even on aborted turns |
| after hook location | Separate if block before deinit | Inside existing if\|*ok\| block | Zig 0.16: single \|*ptr\| capture per error union |

## Dependency Order

```
2A (ToolHooks) ────┐
2B (abort)         ├── 2E (tests)
2C (LifecycleCb) ──┘      │
2D (Ctrl+C → abort) ──────┘ (depends on 2B)
2G (ApiEndpoint) ── 2F (compact) depends on 2G
2H (TokenUsage)
2I (/fork) -- independent, zero core changes
```

Steps 2A/2B/2C are independent of each other and can be done in any order. 2D needs 2B done first. 2F needs 2G done first. 2H and 2I are independent.

---

## Step 2A: ToolHooks

### Current state

`agent.zig` calls tool execution inline with no interception:

```zig
// agent.zig (runTurn, tool_calls branch)
var exec_result = self.tool_registry.execute(ctx, tc.name, tc.arguments);
if (exec_result) |*ok| {
    defer ok.deinit(self.allocator);
    if (tool_display) |cb| { ... }
    try self.session_ref.append(.{ ... });
} else |exec_err| { ... }
```

### Changes

**`agent.zig`** -- add struct + field + init:

```zig
pub const ToolHooks = struct {
    context: ?*anyopaque = null,
    before: ?*const fn (ctx: ?*anyopaque, name: []const u8, args: []const u8) ?[]const u8 = null,
    after: ?*const fn (ctx: ?*anyopaque, result: *types.ToolResult) void = null,
};
```

Add to `AgentLoop` struct:
```zig
tool_hooks: ?ToolHooks = null,
```

Add to `init` opts:
```zig
tool_hooks: ?ToolHooks = null,
```

**`agent.zig`** -- wrap execution in runTurn tool loop:

```zig
for (tcs) |tc| {
    // ... existing interrupt check ...

    // Before hook
    if (self.tool_hooks) |h| {
        if (h.before) |beforeFn| {
            if (beforeFn(h.context, tc.name, tc.arguments)) |block_msg| {
                try self.session_ref.append(.{
                    .role = .tool,
                    .content = block_msg,
                    .tool_call_id = tc.id,
                });
                new_msgs += 1;
                continue;
            }
        }
    }

    const ctx = types.ToolContext{ ... };
    var exec_result = self.tool_registry.execute(ctx, tc.name, tc.arguments);

    // After hook
    if (self.tool_hooks) |h| {
        if (h.after) |afterFn| {
            if (exec_result) |*ok| afterFn(h.context, ok)
            else |_| {}; // no after callback on error
        }
    }

    // ... existing append + display ...
}
```

### Edge cases

- `before` returning non-null blocks execution; message appended as tool result; LLM sees it and can self-correct
- `after` runs even for null `before` -- hooks are independent
- `after` is NOT called when execute returns error (no `*ToolResult` to inspect)
- `after` runs before `defer ok.deinit()`: Zig defers fire at block end (LIFO), so the hook callback executes while the ToolResult is still valid on the stack. No use-after-free concern.
- Hook context lives in frontend (e.g., permission gating state)
- `before` return slice consumed immediately by `session.append` (deep copy)

### Tests

1. `before` returns non-null → tool skipped, block message in session, turn continues
2. `before` returns null → tool executes normally
3. `after` fires with result → can inspect `session_content`
4. `after` never fires when execute returns error
5. No hooks set → behavior identical to current (no regression)

---

## Step 2B: abort()

### Current state

`runTurn` checks `signal.isInterrupted()` at two points:
```zig
if (signal.isInterrupted()) {
    return RoundResult{ .new_message_count = new_msgs, .finish = .interrupted };
}
```

### Changes

**`agent.zig`** -- add field + method:
```zig
pub const AgentLoop = struct {
    _aborted: bool = false,

    pub fn abort(self: *AgentLoop) void {
        self._aborted = true;
    }
};
```

Replace all `signal.isInterrupted()` checks in `runTurn` with `self._aborted`:

```zig
if (self._aborted) {
    return finishTurn(self, new_msgs, .interrupted);
}
```

Signal module import stays for transitional reasons (the REPL loop uses it for input-line interrupt detection). The `agent.zig` import of `signal` can be removed after Step 2D confirms the App-layer bridge works.

### Edge cases

- `abort()` called mid-streaming: no effect until next `_aborted` check (between tool rounds)
- `abort()` called during tool execution: checked before next tool in the same turn
- `abort()` called when `runTurn` not active: flag set, cleared on next `runTurn` entry? No -- `AgentLoop` persists across turns; responsibility of caller to reset or re-init
- **Flag persistence**: add `_aborted = false` at start of `runTurn` to reset on each call

### Reset on runTurn entry

```zig
pub fn runTurn(self: *AgentLoop, tool_display: ?ToolDisplayCb) !RoundResult {
    self._aborted = false; // clear from previous turn
    // ...
}
```

### Tests

1. `abort()` before `runTurn` → returns `.interrupted` with 0 new messages
2. `abort()` mid-turn between tool rounds → returns `.interrupted`, partial results preserved
3. `abort()` then next `runTurn` call → reset, runs normally

---

## Step 2C: LifecycleCb

### Current state

No turn lifecycle notifications. Frontend has no way to know when a turn starts/ends programmatically.

### Changes

**`agent.zig`** -- add struct near `ToolDisplayCb`:
```zig
pub const LifecycleCb = struct {
    context: ?*anyopaque = null,
    on_turn_start: ?*const fn (ctx: ?*anyopaque) void = null,
    on_turn_end: ?*const fn (ctx: ?*anyopaque, finish: TurnFinish) void = null,
};
```

Add to `AgentLoop` struct:
```zig
lifecycle: ?LifecycleCb = null,
```

Add to `init` opts:
```zig
lifecycle: ?LifecycleCb = null,
```

### Call sites in runTurn

**`on_turn_start`** -- after `_aborted` reset, before first LLM call:
```zig
pub fn runTurn(self: *AgentLoop, tool_display: ?ToolDisplayCb) !RoundResult {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    self._aborted = false;
    if (self.lifecycle) |lc| {
        if (lc.on_turn_start) |cb| cb(lc.context);
    }

    const tools = try self.tool_registry.toTools(arena_alloc);
    // ...
```

**`on_turn_end`** -- called explicitly at every return point. There are 5 return sites in `runTurn`:

```zig
// 1. tool round limit
return RoundResult{ .new_message_count = new_msgs, .finish = .max_rounds };
// 2. interrupted (between tool rounds or mid-streaming)
return RoundResult{ .new_message_count = new_msgs, .finish = .interrupted };
// 3. api_error
return RoundResult{ .new_message_count = new_msgs, .finish = .api_error };
// 4. stop (final assistant message)
return RoundResult{ .new_message_count = new_msgs, .finish = .stop };
// 5. render_error (tool display failure)
return RoundResult{ .new_message_count = new_msgs, .finish = .render_error };
```

Wrap each site with a helper function that fires the callback before returning:

```zig
fn finishTurn(self: *AgentLoop, new_msgs: usize, finish: TurnFinish) RoundResult {
    if (self.lifecycle) |lc| {
        if (lc.on_turn_end) |cb| cb(lc.context, finish);
    }
    return .{ .new_message_count = new_msgs, .finish = finish };
}

// Usage replaces all `return RoundResult{...}`:
return finishTurn(self, new_msgs, .stop);
```

This avoids the `var x: TurnFinish = undefined` + `defer` UB trap. No uninitialized memory, no UB on early error paths.

### Edge cases

- `on_turn_start` fires before first LLM request -- spinner can start
- `on_turn_end` fires for ALL finish reasons including errors, interrupts
- Null callbacks == no-op (common case: headless)
- `on_turn_end` fires even if `on_turn_start` was null

### Tests

1. Both callbacks fire in normal stop turn
2. `on_turn_end` fires on `api_error` and `interrupted`
3. Null lifecycle → no calls (existing tests pass unchanged)

---

## Step 2D: Wire Ctrl+C → agent.abort()

### Problem

Windows `SetConsoleCtrlHandler` callback signature is:
```c
BOOL CALLBACK HandlerRoutine(DWORD dwCtrlType);
```
No `?*anyopaque` context parameter. Cannot pass `agent.abort()` directly.

### Solution: App-layer polling (Solution A)

Signal handler continues to set the existing global `signal.interrupted` flag via `signal.setInterrupted()`. The frontend (App.zig) polls `signal.isInterrupted()` after each `runTurn` call and forwards to `agent.abort()`.

**`util/signal.zig`** -- no changes. Maintains existing `setInterrupted()` + `isInterrupted()` + global flag.

**`core/agent.zig`** -- no new globals, no `setAbortTarget`. Remove `signal.isInterrupted()` from `runTurn` (replaced by `self._aborted` check -- see Step 2B).

```zig
// runTurn checks only _aborted (not signal.isInterrupted):
if (self._aborted) {
    return finishTurn(self, new_msgs, .interrupted);
}
```

**`frontends/cli/App.zig`** -- in `singleTurn` and `processLine`, after `runTurn` returns:

```zig
const result = self.agent.runTurn(tool_cb) catch |err| { ... };
if (signal.isInterrupted()) {
    self.agent.abort(); // prepare for next turn
    signal.reset();
}
```

### Changes summary

| File | Change |
|------|--------|
| `agent.zig` | Drop `signal.isInterrupted()` checks; use only `self._aborted` |
| `util/signal.zig` | **No changes** -- existing API suffices |
| `frontends/cli/App.zig` | Poll `signal.isInterrupted()` after `runTurn`, call `agent.abort()` |

Zero new globals, zero new imports between signal and agent. No BIDIR.

### Edge cases

- Ctrl+C fires during `runTurn` (between rounds): `_aborted` set by `agent.abort()` from previous turn; caught at next `_aborted` check
- Ctrl+C fires during tool execution (blocking HTTP): `_aborted` not yet set; signal flag is set; next App poll triggers `agent.abort()`; next `runTurn` call resets `_aborted` and returns `.interrupted` immediately
- Ctrl+C fires between turns: `signal.isInterrupted()` true; `agent.abort()` called; next `runTurn` sees `_aborted`

### Tests

No unit test (requires signal mocking). Manual REPL test: press Ctrl+C mid-turn → `.interrupted` result, REPL continues.

---

## Step 2E: Update tests for hooks + abort + lifecycle

### Test additions

**Hooks tests** (add to `agent.zig` test section):

1. `test "agent: hooks before blocks execution"`:
   - Set up agent with tool_hooks.before that returns "blocked"
   - Run turn with a tool_call response
   - Assert tool message contains "blocked", tool did NOT execute
   - Assert turn continues (finish = stop)

2. `test "agent: hooks before allows execution"`:
   - Set up agent with tool_hooks.before that returns null
   - Run turn with a tool_call response
   - Assert tool executed normally

3. `test "agent: hooks after fires"`:
   - Set up agent with tool_hooks.after that sets a flag
   - Run turn with a tool_call response
   - Assert after callback was called

4. `test "agent: hooks after does not fire on error"`:
   - Set up agent with tool_hooks.after + tool that fails
   - Run turn, assert after not called

**Abort tests**:

5. `test "agent: abort before runTurn returns interrupted"`:
   - `agent.abort()`, then `runTurn(null)`, expect `.interrupted`

6. `test "agent: abort resets on next runTurn"`:
   - `agent.abort()`, `runTurn(null)`, then `runTurn(null)` again, expect `.stop` on second call

**Lifecycle tests**:

7. `test "agent: lifecycle on_turn_start fires"`:
   - Set lifecycle flag, run turn, assert callback called

8. `test "agent: lifecycle on_turn_end fires"`:
   - Set lifecycle flag, run turn, assert callback called with correct finish

**Regression**:

9. All existing 8 agent tests pass without modification (null hooks/lifecycle = equivalent behavior)

### Mock helpers

Add a `TestCallbacks` struct to reduce boilerplate:
```zig
const TestCallbacks = struct {
    before_called: bool = false,
    before_return: ?[]const u8 = null,
    after_called: bool = false,
    start_called: bool = false,
    end_called: bool = false,
    end_finish: TurnFinish = .stop,
};
```

With static callback functions that cast context to `*TestCallbacks`.

---

## Step 2G: ApiEndpoint

### Current state

`ToolContext` has no API access. Internal tools (compact) cannot call the LLM.

### Changes

**`types.zig`** -- add struct:
```zig
pub const ApiEndpoint = struct {
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
};
```

Add to `ToolContext`:
```zig
api_endpoint: ?ApiEndpoint = null,
abort_target: ?*bool = null,  // compact checks this for cancellation (set from _aborted)
```

**`agent.zig`** -- populate in runTurn before creating ToolContext:

```zig
const api_endpoint: ?types.ApiEndpoint = if (self.provider_ref.config.base_url.len > 0)
    .{
        .base_url = self.provider_ref.config.base_url,
        .api_key = self.provider_ref.config.api_key,
        .model = self.provider_ref.config.model,
    }
else
    null;

const ctx = types.ToolContext{
    .allocator = self.allocator,
    .io = self.io,
    .project_root = self.project_root,
    .api_endpoint = api_endpoint,
    .abort_target = &self._aborted,
};
```

### Edge cases

- Provider with empty api_key → api_endpoint is null (compact tool returns error)
- Slices borrowed from provider config; config outlives turn
- Not populated from environment -- provider already resolved the key

### Tests

1. `api_endpoint` populated when provider has config
2. `api_endpoint` null when provider config is empty

---

## Step 2F: compact.zig (Optional)

Prerequisite: 2G (ApiEndpoint).

### Tool spec

```
name:        "compact"
description: "Summarize earlier messages to reduce context window usage.
              Keeps the system message, the last N user/assistant pairs, and replaces
              older messages with an LLM-generated summary."
params:
  max_messages:  integer (optional, default 10) -- keep at least this many recent messages
  force:         boolean (optional, default false) -- compact even if under threshold
  
execute:
  1. Read session messages
  2. If len <= max_messages + 2 and not force → return "no compaction needed"
  3. Split: recent = last N messages, old = messages[1..len-N] (skip system msg)
  4. Call LLM summarise API via ctx.api_endpoint:
     POST {base_url}/chat/completions
     { model, messages: [{role:"system",content:"Summarize..."},{role:"user",content:old_json}],
       max_tokens: 1024, stream: false }
  5. Parse summary from response
  6. Replace session messages: [system_msg] + [summary_as_system_msg] + recent
  7. Return ToolResult with session_content containing the summary
```

### Behavior notes

- Respects direction "summary-based, not truncation" per Pi pitfall #5
- Uses synchronous (non-streaming) API call via curl subprocess (same pattern as `provider.zig` lines 169-206)
- Summary message role: `.system` (instructional context, not part of conversation proper)
- Token counting (2H) not required for v1 -- use message count heuristic

### HTTP implementation (curl subprocess)

Reuse the existing `provider.zig` curl pattern: launch `curl.exe` with `-sN --fail-with-body`, write JSON body to stdin pipe, read stdout. Key differences from provider:

- `stream: false` in request body (non-streaming response)
- Timeouts from `provider.zig` `Config.connect_timeout_secs` / `max_timeout_secs`
- Parse response JSON with `parseFromSliceLeaky(Value, ...)` -- same as provider SSE parsing

### Abort support

Zig 0.16 `std.process.Child` has only blocking `wait()` -- no `tryWait()` or timeout-based poll. Compact cannot interrupt curl mid-request. Instead:

1. curl subprocess is launched with `--max-time` from provider config (bounded wait)
2. `child.wait()` blocks until curl completes or times out
3. After `wait()` returns, check `ctx.abort_target`:
   - If aborted: discard response, return error ToolResult (`is_error: true`)
   - If not aborted: parse response normally
4. Agent loop's next `_aborted` check catches the abort after compact returns

```zig
const term = try child.wait(self.io);
if (ctx.abort_target) |target| {
    if (target.*) {
        return ToolResult{
            .session_content = "compact aborted by user",
            .is_error = true,
        };
    }
}
```

The maximum abort latency is bounded by curl's `--max-time` (default 300s from provider config). For CLI usage this is acceptable -- Ctrl+C during an HTTP call will always have some delay.

### prompt_hint

```
hint = "When the conversation context approaches the model's limit,
        call compact to summarize earlier messages. This keeps the
        most recent exchanges while preserving key information from
        earlier turns."
```

### Registration

One line in `buildRegistry()`:
```zig
.{ .name = "compact", .description = ..., .params = ..., .execute = compact.execute },
```

---

## Step 2H: TokenUsage

### Current state

SSE `[DONE]` frame contains usage but provider drops it.

### Changes

**`types.zig`** -- add struct:
```zig
pub const TokenUsage = struct {
    input: u32,
    output: u32,
    total: u32,
};
```

Add to `Message`:
```zig
usage: ?TokenUsage = null,
```

**`io/provider.zig`** -- add to `ProviderResponse`:
```zig
usage: ?TokenUsage = null,
```

Extract from SSE [DONE] frame. Instead of parsing the final data line only, accumulate usage from the last non-DONE `data:` line:

```zig
var last_data_payload: ?[]const u8 = null;
// ... inside SSE loop, after each successful parse ...
last_data_payload = payload; // keep the last successfully parsed payload
```

After the SSE loop, parse usage from `last_data_payload` using the same pattern as the SSE `choices` parsing (`provider.zig` currently uses `std.json.parseFromSliceLeaky(std.json.Value, ...)`):

```zig
if (last_data_payload) |payload| {
    const parsed = std.json.parseFromSliceLeaky(
        std.json.Value, alloc, payload,
        .{ .ignore_unknown_fields = true },
    ) catch null; // drop silently on parse failure
    if (parsed) |root| {
        if (root.object.get("usage")) |usage_obj| {
            return ProviderResponse{
                .content = ...,
                .tool_calls = ...,
                .finish_reason = ...,
                .usage = .{
                    .input = @intCast(usage_obj.object.get("prompt_tokens").?.integer),
                    .output = @intCast(usage_obj.object.get("completion_tokens").?.integer),
                    .total = @intCast(usage_obj.object.get("total_tokens").?.integer),
                },
            };
        }
    }
}
```

Note: `parseFromSliceLeaky` with arena allocator matches the existing provider.zig pattern (line 253).

**`agent.zig`** -- copy usage into message:
```zig
try self.session_ref.append(.{
    .role = .assistant,
    .content = resp.content orelse "",
    .tool_calls = resp.tool_calls,
    .usage = resp.usage,
});
```

### Edge cases

- Some providers don't return usage → `usage` stays null → no change in behavior
- Usage in non-final chunks? Only parse from last data frame before DONE
- `session.zig` JSONL serialization: `TokenUsage` needs to serialize/deserialize. Add `jsonStringify`/`jsonParse` or use a flat object approach

### Tests

1. ProviderResponse with usage → Message stores it
2. ProviderResponse without usage → Message.usage is null
3. Session serialize/deserialize roundtrip preserves usage

---

## Step 2I: /fork (Optional)

### Current state

No session branching. `/new` creates fresh session. `/load` loads existing. `/list` shows flat file list.

### Design

per CORE-FRONTEND.md Session design section.

### Implementation

**`frontends/cli/App.zig`** -- in `processLine`:

```zig
if (std.mem.startsWith(u8, line, "/fork ")) {
    const fork_name = std.mem.trim(u8, line["/fork ".len..], " \t");
    try self.forkSession(fork_name);
    return;
}
```

**forkSession method**:

```
1. Validate fork_name: non-empty, no path traversal characters (/ or \)
2. Construct target path: {session_dir}/{fork_name}.jsonl
3. If file exists → error "session already exists"
4. Write to temp file ({session_dir}/{fork_name}.tmp.jsonl):
   - Delete any stale .tmp.jsonl from a previous crash (ignore FileNotFound)
   - Open temp file, write current messages as JSONL
   - Flush and close
   - Rename temp → target (atomic on same filesystem)
   - If any step fails → delete temp file, return error
5. Auto-load the new session:
   - Save current session (flush)
   - Create new session by loading the forked file
   - Re-init agent with new session
6. Display success message: "forked to {fork_name} (switched)"
```

### Edge cases

- Fork name with `/` or `\` → reject (path traversal guard)
- Fork name matches existing session → error
- Fork empty session → valid (copies system message only)
- Temp file left behind on crash → next `/fork` with same name cleans it up
- Auto-switch: fork then immediately work in new session (no manual `/load` needed)

### Tests

No unit tests (filesystem operation). Manual REPL test.

---

## Phase 2 Implementation Order

```
Pass 1 (core, no frontend):  2A, 2B, 2C  (parallel)
Pass 2 (wiring):              2D (depends on 2B), 2H (independent)
Pass 3 (types enrichment):    2G (needed by 2F)
Pass 4 (tools):               2F (depends on 2G)
Pass 5 (frontend):            2I (independent)
Pass 6 (tests):               2E (depends on 2A/2B/2C)
```

Each pass verified with `zig build` + `zig test` before proceeding.

## Verification

```powershell
zig build               # compile
node .opencode/skills/zig-dev/scripts/depgraph.mjs .
node .opencode/skills/zig-dev/scripts/check-arch.mjs .
Get-ChildItem -Recurse .zig-cache\o -Name "test.exe" | Select-Object -Last 1 | % { & ".zig-cache\o\$_" }
```

## Architecture impact (per pass)

| Pass | God Objects | BIDIR | Notes |
|------|-------------|-------|-------|
| 1 (2A/2B/2C) | agent.zig grows ~80 lines | no change | Still within 500-line GO threshold |
| 2 (2D/2H) | no change | **no change** | 2D uses Solution A (App polling); no new imports between signal and agent |
| 3 (2G) | types.zig +1 field | no change | |
| 4 (2F) | +1 tool file, +1 registry line | tool/ imports types/ (existing) | |
| 5 (2I) | App.zig +30 lines | no change | |
| 6 (2E) | agent.zig +100 lines test | no change | Tests don't affect arch scan |

## Design note: why Solution A over global pointer

Step 2D originally considered a global `agent.abort()` target in `agent.zig` to route Windows `SetConsoleCtrlHandler` (which has no context parameter) to the agent. This would require `signal.zig` to import `agent.zig`, creating a BIDIR (`util/ ← core/`).

Solution A avoids this entirely:
- `signal.zig` stays unchanged (existing `setInterrupted()` global flag)
- `agent.zig` drops `signal.isInterrupted()` checks, uses only `self._aborted`
- `App.zig` bridges them: after each `runTurn` call, polls `signal.isInterrupted()`, calls `agent.abort()`, resets signal

Trade-off: abort is one turn delayed (signal fires during turn N; abort detected at turn N+1 or after tool returns). For CLI this is acceptable -- the interrupt is visible within the same turn via `_aborted` checks between tool rounds, and at worst one blocking tool call completes before the abort takes effect.
