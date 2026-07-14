# z-agent-core

An experiment exploring DeepSeek's coding capabilities through a pure agent loop implementation in Zig. Supports tool hooks, abort, lifecycle callbacks, token usage tracking, and session forking. No TUI, no compaction.

## Motivation: AI knowledge lag and Zig 0.16.0

The premise of this experiment: **can someone who doesn't know Zig build a working coding agent using an AI whose training data predates Zig 0.16.0?**

DeepSeek's Zig knowledge is frozen at 0.13.x-0.14.x. Zig 0.16.0 renamed, removed, or restructured ~30% of the stdlib surface. This means the AI confidently recommends APIs that no longer exist. When it hallucinates `std.fs.cwd()`, `GeneralPurposeAllocator`, or `std.time.sleep()`, you can't ask it why the code doesn't compile -- it doesn't know.

The 15-item trap table in `AGENTS.md` catalogs the most frequent hallucinations and their 0.16.0 equivalents. Every entry was discovered by reading the Zig compiler/stdlib source, not by guessing or trial-and-error.

## Quick start

```bash
zig build run                         # interactive REPL
zig build run -- --prompt "hello"     # single-shot mode
zig build test                        # 148 unit tests
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

### Config template

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
context_window = 131072
max_tokens = 384000
params_json = "\"thinking\":{\"type\":\"enabled\"}"
input = ["text"]

[[models]]
id = "deepseek-v4-flash"
name = "DeepSeek V4 Flash"
provider = "deepseek"
context_window = 131072
max_tokens = 384000
params_json = ""
input = ["text"]
```

`params_json` is a raw JSON fragment (no outer braces) blind-concatenated into the API request body. Use `""` for no params, `"\"thinking\":{\"type\":\"enabled\"}"` for DeepSeek thinking mode. Switch models: `zig build run -- --model deepseek/deepseek-v4-pro`. Corrupted config? Delete `.zagent/config.toml` and restart to regenerate.

## Architecture

```
src/main.zig                  -- 4-line shim: delegates to src/frontends/cli/
src/frontends/cli/
  main.zig                    -- CLI entry, arg parsing (--prompt, --model)
  App.zig                     -- orchestrator: config → provider → tools → session → agent
                              --   REPL: /exit, /new, /load, /name, /list, /fork, /help
  render.zig                  -- ANSI output, Markdown, streaming LineBuffer, tool display
src/config.zig                -- TOML loading, model resolution, .env, template generation
src/toml.zig                  -- lightweight TOML parser
src/types.zig                 -- types: Message, Tool, ToolResult, TokenUsage, ApiEndpoint
src/core/
  agent.zig                   -- agent loop: ToolHooks, abort(), LifecycleCb, finishTurn
  session.zig                 -- JSONL persistence (.zagent/sessions/)
src/io/
  provider.zig                -- OpenAI-compat SSE streaming + retry, TokenUsage extraction
src/tool/
  registry.zig                -- buildRegistry(): 6 built-in tools
  read.zig                    -- read files / list directories
  write.zig                   -- create/overwrite files
  bash.zig                    -- execute shell commands (pwsh/sh)
  grep.zig                    -- regex content search
  glob.zig                    -- filename pattern matching
  skill.zig                   -- load .zagent/skills/*/SKILL.md
src/util/
  path.zig                    -- path resolution with traversal guard
  signal.zig                  -- Ctrl+C handler (Windows SetConsoleCtrlHandler)
  text.zig                    -- string trimming
```

Core = all of `src/` except `src/frontends/`. The CLI frontend implements two callback contracts injected at runtime:
- **PhaseWriterCb** — provider signals phase (thinking/content) + raw text; frontend renders via LineBuffer
- **ToolDisplayCb** — agent passes tool_name + args; frontend derives display label from args JSON

Tools return only `session_content` (LLM context data) + optional `err_msg`. No display strings cross the core/frontend boundary.

## Available tools

| Tool | Description |
|------|-------------|
| `read` | Read file (offset/limit) or list directory |
| `write` | Create/overwrite file (auto-create parent dirs) |
| `bash` | Execute shell command (pwsh on Windows, sh on Unix) |
| `grep` | Regex search in files |
| `glob` | Filename pattern matching |
| `skill` | Load `.zagent/skills/*/SKILL.md` |

Add a tool: `tool/xxx.zig` + 1 line in `registry.zig` `buildRegistry()`.

## Key design decisions

- **Frontend-backend separation**: Core modules (`core/`, `io/`, `tool/`) never import render code. Two callback contracts (`PhaseWriterCb`, `ToolDisplayCb`) inject display logic at runtime. `core/ → util/` BIDIR eliminated.
- **TOML config**: Self-contained parser, no external dependencies. Model params are TOML-driven JSON fragments (`params_json`), provider blind-concatenates — no hardcoded vendor logic.
- **SSE streaming**: Provider parses `data:` lines via curl subprocess. LineBuffer renders chunks immediately for typewriter feel; Markdown-to-ANSI on complete lines.
- **Static tool registry**: Compile-time array, one line per tool. LLM sees tools as OpenAI-compatible JSON schema auto-generated from registry.
- **Linear JSONL sessions**: One file per conversation. `/fork` copies messages to new file (atomic temp+rename) and auto-switches.
- **Single binary**: Windows icon via `addWin32ResourceFile`, zero runtime dependencies.

## Documentation

| File | Content |
|------|---------|
| `docs/CORE-FRONTEND.md` | Core definition, frontend integration, Phase 0/1/2 plan, architecture comparison with Pi Agent |
| `docs/PLAN-PHASE2.md` | Phase 2 spec + implementation status: hooks, abort, lifecycle, TokenUsage, /fork |
| `docs/PLAN-TOOLRESULT-SPLIT.md` | ToolResult data-display separation plan |
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
