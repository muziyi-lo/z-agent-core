# Remaining Work

## Done (2026-07-14)

| # | Item | Plan doc | Effort |
|---|------|----------|--------|
| 1 | grep/glob label: show both pattern + path | PLAN-DISPLAY-GAPS.md | Low |
| 2 | Round limit warning: user + LLM notification | PLAN-DISPLAY-GAPS.md | Low |
| 3 | Bash output display: `user_output` field | PLAN-DISPLAY-GAPS.md | Medium |

## Deferred (explicitly skipped)

| # | Item | Reason |
|---|------|--------|
| 4 | compact.zig (Phase 2F) | Optional; summary-based context compression as a tool. Requires `ctx.api_endpoint` (already available). |
| 5 | DisplayHint (v2 tool metadata) | Tool returns structured facts (match count, line count) for frontend display. Trade-off: couples `types.zig` to tool types. Deferred until metadata value outweighs coupling cost. |
| 6 | Tool event streaming (start/update/end) | Hook `before`/`after` already cover start/end. `update` (progress) requires tools to push events mid-execution — significant protocol change. |

## Future (not started, not researched)

| # | Item | Notes |
|---|------|-------|
| 7 | TUI frontend | Terminal UI framework (vaxis or similar). Same callback contracts, different render. |
| 8 | Web frontend | Single HTML served by zig binary, SSE to browser. Same core loop. |
| 9 | MCP tool discovery | `mcp_connect` tool — LLM discovers remote tools at runtime via MCP protocol. |

## Architecture wishlist

| # | Item | Notes |
|---|------|-------|
| 10 | Agent file size reduction | agent.zig 851 lines; extract test helpers, split runTurn |
| 11 | Provider file size reduction | provider.zig 790 lines; split SSE parsing, JSON building, retry logic |
| 12 | Tool test coverage for error paths | OOM on allocation failure in error paths (existing tools leak on double-allocation failure) |
