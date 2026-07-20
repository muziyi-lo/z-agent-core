# z-agent-core

An experiment exploring DeepSeek's coding capabilities through a pure agent loop implementation in Zig. Supports tool hooks, abort, lifecycle callbacks, token usage tracking, session forking, context compaction, and doom loop detection. No TUI.

## Motivation: AI knowledge lag and Zig 0.16.0

The premise of this experiment: **can someone who doesn't know Zig build a working coding agent using an AI whose training data predates Zig 0.16.0?**

DeepSeek's Zig knowledge is frozen at 0.13.x-0.14.x. Zig 0.16.0 renamed, removed, or restructured ~30% of the stdlib surface. This means the AI confidently recommends APIs that no longer exist. When it hallucinates `std.fs.cwd()`, `GeneralPurposeAllocator`, or `std.time.sleep()`, you can't ask it why the code doesn't compile -- it doesn't know.

The 33-item trap table in `AGENTS.md` catalogs the most frequent hallucinations and their 0.16.0 equivalents. Every entry was discovered by reading the Zig compiler/stdlib source, not by guessing or trial-and-error.

## Quick start

```bash
zig build run                         # interactive REPL
zig build run -- --prompt "hello"     # single-shot mode
zig build check                       # compile + architecture scan
```

Tests (GPA leak traces cause `zig build test` to deadlock — use this instead):

```powershell
zig test src/test.zig --cache-dir .zig-cache 2>&1 | Select-String "^\d+/\d+|All \d+ tests|FAIL"
```

## Requirements

- Zig 0.16.0
- curl (in PATH, for HTTP API calls)
- An OpenAI-compatible API key (DeepSeek, OpenAI, or local LLM via Ollama)
- **Windows only**: PowerShell 7+ (`pwsh.exe`) in PATH. The bash tool uses `pwsh` for command execution (PowerShell 5.1 lacks `&&`/`||` and UTF-8 support).

## Configuration

A default `.zagent/config.toml` is auto-generated on first run. Set your API key:

```powershell
$env:DEEPSEEK_API_KEY = "sk-..."
```

Or create `.zagent/.env`:

```
DEEPSEEK_API_KEY=sk-...
```

### Config template (auto-generated)

```toml
default_model = "deepseek/deepseek-v4-flash"
max_tokens = 384000
max_tool_rounds = 10

[[providers]]
name = "deepseek"
api = "openai_compat"
base_url = "https://api.deepseek.com"
api_key_env = "DEEPSEEK_API_KEY"
models = ["deepseek-v4-pro", "deepseek-v4-flash"]

[[models]]
id = "deepseek-v4-pro"
name = "DeepSeek V4 Pro"
provider = "deepseek"
context_window = 1000000
max_tokens = 384000
input = ["text"]

[models.compat]
# thinking_format — auto-detected from base_url; uncomment to force

[[models]]
id = "deepseek-v4-flash"
name = "DeepSeek V4 Flash"
provider = "deepseek"
context_window = 1000000
max_tokens = 384000
params_json = ""
input = ["text"]
```

Key points:
- **`provider` field**: binds a model to a specific provider. Leave empty (`""`) to share the model definition across all providers. Duplicate `(provider, id)` pairs: **last entry wins** (override).
- **`[models.compat]` sub-table**: optional per-model protocol quirk overrides — `thinking_format` (7 formats: `thinking_object`, `reasoning_effort`, `enable_thinking_bool`, etc.), `max_tokens_field`, `supports_stream_options`, `require_reasoning_on_tool_calls`. Everything is auto-detected from `base_url`; the sub-table only needs values you want to override.
- **API key**: via `api_key_env` environment variable or `.zagent/.env`.
- Corrupted config? Delete `.zagent/config.toml` and restart to regenerate.

### Adding a second provider (same model, different endpoint)

```toml
[[providers]]
name = "deepseek-proxy"
api = "openai_compat"
base_url = "https://my-proxy.example.com"
api_key_env = "DEEPSEEK_PROXY_KEY"
models = ["deepseek-v4-pro"]  # reuse the same model definition
```

Set `provider = ""` in the `[[models]]` block to share it across providers.

## Architecture

```
src/main.zig                  -- 4-line shim: delegates to src/frontends/cli/
src/frontends/cli/
  main.zig                    -- CLI entry, arg parsing (--prompt, --model, --thinking)
  App.zig                     -- orchestrator: config → provider → tools → session → agent
                              --   REPL: /exit, /new, /load, /name, /list, /fork, /thinking, /help
  render.zig                  -- ANSI output, Markdown→ANSI, streaming LineBuffer, tool display
src/config.zig                -- TOML loading, model/provider resolution, compat override, .env
src/toml.zig                  -- lightweight TOML parser (self-contained, no deps)
src/session_ops.zig           -- session lifecycle: new, load, fork, rollback
src/types.zig                 -- types: Message, Tool, ToolResult, TokenUsage, ToolMeta,
                              --   Model, ProviderEntry, ModelCompat, detectCompat()
src/core/
  agent.zig                   -- agent loop: ToolHooks, abort(), LifecycleCb, SystemPromptCb,
                              --   StormBreaker (doom loop detection), context window monitoring
  session.zig                 -- JSONL persistence (.zagent/sessions/), updateFirstSystem
src/io/
  provider.zig                -- OpenAI-compat SSE streaming + retry (5× backoff),
                              --   error classification, thinking format dispatch (7 variants)
src/tool/
  registry.zig                -- buildRegistry(): 8 built-in tools
  read.zig                    -- read files / list directories
  write.zig                   -- create/overwrite files
  bash.zig                    -- execute shell commands (pwsh/sh)
  grep.zig                    -- content search (substring match)
  glob.zig                    -- filename pattern matching
  edit.zig                    -- exact string replacement with diff preview
  compact.zig                 -- context compaction via LLM summarization
  skill.zig                   -- load .zagent/skills/*/SKILL.md
src/util/
  path.zig                    -- path resolution with traversal guard, Windows drive letter normalize
  signal.zig                  -- Ctrl+C handler (Windows SetConsoleCtrlHandler)
  text.zig                    -- string trimming
```

Core = all of `src/` except `src/frontends/`. The CLI frontend implements three callback contracts injected at runtime:
- **PhaseWriterCb** — provider signals phase (thinking/content) + raw text; frontend renders via LineBuffer
- **ToolDisplayCb** — agent passes tool_name + args + meta; frontend derives display label
- **SystemPromptCb** — agent calls at turn start; frontend rebuilds system prompt with env/skills/AGENTS.md

Tools return only `session_content` (LLM context data) + optional `err_msg`. No display strings cross the core/frontend boundary.

## Available tools

| Tool | Description |
|------|-------------|
| `read` | Read file (offset/limit) or list directory. Binary detection, 50KB max. |
| `write` | Create/overwrite file (auto-create parent dirs). 512KB max. |
| `bash` | Execute shell command (pwsh on Windows, sh on Unix). Timeout, ANSI filtering. |
| `grep` | Substring search in files with glob filter. 500 max matches. |
| `glob` | Filename pattern matching with `**` recursive support. |
| `edit` | Exact string replacement with diff preview. Supports `replaceAll`. |
| `compact` | Compress conversation via LLM summarization (keep system + recent N). |
| `skill` | Load `.zagent/skills/*/SKILL.md`. Traversal-guarded. |

Add a tool: `tool/xxx.zig` + 1 line in `registry.zig` `buildRegistry()`.

## Key design decisions

- **Frontend-backend separation**: Core modules (`core/`, `io/`, `tool/`) never import render code. Three callback contracts (`PhaseWriterCb`, `ToolDisplayCb`, `SystemPromptCb`) inject display/logic at runtime.
- **Compat auto-detection**: `detectCompat()` infers thinking format, max_tokens field, and stream_options from `base_url` hostname/path. `[models.compat]` in TOML selectively overrides auto-detected values. Supports 7 thinking JSON formats (DeepSeek, OpenAI, Qwen, Aliyun, Anthropic, Gemini, none).
- **TOML config**: Self-contained parser, no external dependencies. Model definitions can be shared across providers (`provider = ""`) or scoped to a single provider. Duplicate entries use last-write-wins override semantics.
- **SSE streaming + retry**: Provider parses `data:` lines via curl subprocess with 5× exponential backoff (500ms→8s), error classification (rate limit/503 retryable, 4xx fatal), `stream_options` 400 auto-fallback. LineBuffer renders chunks immediately for typewriter feel; Markdown-to-ANSI on complete lines.
- **Dual-phase streaming**: `thinking_started`/`text_started` independent flags replace single `in_content_phase`, preventing flicker with interleaved reasoning and supporting models like Qwen that stream reasoning before content.
- **Static tool registry**: Compile-time array, one line per tool (8 tools). LLM sees tools as OpenAI-compatible JSON schema auto-generated from registry.
- **Linear JSONL sessions**: One file per conversation. `/fork` copies messages to new file (atomic temp+rename) and auto-switches.
- **Context compaction**: Token monitoring at 85% window threshold; `compact` tool uses LLM to summarize old messages and replace them in-place.
- **StormBreaker**: FIFO queue (5 entries) tracks tool call `{name, args_hash}`; 3 consecutive identical calls injects system warning.
- **Single binary**: Windows icon via `addWin32ResourceFile`, zero runtime dependencies beyond curl.

## Documentation

| File | Content |
|------|---------|
| `docs/CORE-FRONTEND.md` | Core definition, frontend integration, Phase 0/1/2 plan, architecture comparison |
| `docs/PLAN-PHASE2.md` | Phase 2 spec + implementation (done): hooks, abort, lifecycle, /fork, compact |
| `docs/PLAN-PHASE-3-COMPAT.md` | Phase 3: compat protocol layer (done): ModelCompat, detectCompat, 7 thinking formats |
| `docs/PLAN-PHASE-4-CACHE.md` | Phase 4: cache-first loop + reasoning separation (done): reasoning_content, prompt freeze |
| `docs/PLAN-PHASE-5-WEBFETCH.md` | Phase 5: webfetch tool — HTTP GET with HTML→Markdown conversion (planned) |
| `docs/PLAN-PHASE-6-TUI.md` | Phase 6: TUI frontend architecture + framework evaluation (design stage) |
| `docs/设计原则整理.md` | 15 design principles accumulated from development |
| `docs/REMAINING.md` | Remaining work tracker: done/planned/deferred/future/wishlist |
| `docs/0.2.0/` | v0.2.0 plan docs: OPT-1 through OPT-6 + FIX-1 (9 files, all done) |
| `docs/0.0.1-alpha/` | v0.0.1-alpha step-by-step design docs (8 files) |

## Vibe Coding insights

### The meta-system determines the quality ceiling

The quality of AI-generated code does not depend on what the AI *can* do, but on what you *prevent* it from doing.

```
memory system x error correction x workflow constraints x review gates x agent isolation = output quality ceiling
```

### Constraints grow from usage, not from planning

Skills, agent types, and workflow rules in this project were not designed upfront. They grew organically: `AGENTS.md` accumulated rules until it was too large, then was extracted into the `zig-dev` skill, which later spawned `zig-reviewer` and `zig-debugger` sub-agents.

### The error loop is the real learning engine

The project's learnings follow a repeated cycle: AI hallucinates a non-existent API → compiler rejects it → read Zig source to find the real API → record in the trap table → never hit the same trap again. This feedback loop, not the AI's initial output, is what produces correct code.

### Decision layer owns persistence, not execution layer

When the agent loop writes session data to disk and the app layer also needs to roll back errors, the persistence gate must live in the decision layer (App), not the execution layer (agent). Execution modules should only touch memory; the orchestrator decides when and what to flush.

### Verify bottom-up, not top-down

Building the full agent loop before verifying the HTTP layer worked was the single biggest waste in z-agent's history. Zig 0.16.0's `std.http.Client` is broken on Windows (AFD.CONNECT IOCTL timeout), and discovering this after implementing serialization and CLI interaction meant all upper-layer work was thrown away. Verify the foundation before building on it.

## License

MIT
