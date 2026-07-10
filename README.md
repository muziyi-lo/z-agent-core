# z-agent-core

An experiment exploring DeepSeek's coding capabilities through a pure agent loop implementation in Zig. Stripped from [z-agent](https://github.com/muziyi-lo/z-agent) -- which grew too complex to maintain -- this project preserves the essential core: prompt, parse, execute, render. No TUI, no permissions, no hooks, no memory system.

## Motivation: AI knowledge lag and Zig 0.16.0

The premise of this experiment: **can someone who doesn't know Zig build a working coding agent using an AI whose training data predates Zig 0.16.0?**

DeepSeek's Zig knowledge is frozen at 0.13.x-0.14.x. Zig 0.16.0 renamed, removed, or restructured ~30% of the stdlib surface. This means the AI confidently recommends APIs that no longer exist. When it hallucinates `std.fs.cwd()`, `GeneralPurposeAllocator`, or `std.time.sleep()`, you can't ask it why the code doesn't compile -- it doesn't know.

The 15-item trap table in `AGENTS.md` catalogs the most frequent hallucinations and their 0.16.0 equivalents. Every entry was discovered by reading the Zig compiler/stdlib source, not by guessing or trial-and-error. The meta-system (source-code-as-ground-truth + compiler-feedback loop + accumulated trap table) serves as a real-time knowledge layer that compensates for the AI's outdated training data.

This is not a critique of DeepSeek's coding ability -- the code it writes is correct for the Zig version it was trained on. The problem is **knowledge temporal fracture**: the gap between what the AI knows and what the compiler accepts.

## Quick start

```bash
zig build run
# or single-shot:
zig build run -- --prompt "list files in src/"
```

## Requirements

- Zig 0.16.0
- curl (in PATH, for HTTP API calls)
- An OpenAI-compatible API (DeepSeek, OpenAI, local LLM)

## Configuration

Place `.zagent/config.toml` at the project root (or any parent directory):

```toml
default_model = "deepseek/deepseek-v4-pro"
max_tokens = 4096

[[providers]]
name = "deepseek"
api = "openai_compat"
base_url = "https://api.deepseek.com"
api_key_env = "DEEPSEEK_API_KEY"
models = ["deepseek-v4-pro"]
```

Set the API key via environment variable: `$env:DEEPSEEK_API_KEY = "sk-..."`

The agent walks up from CWD to find `.zagent/config.toml`. If not found, CWD is used as the project root.

### Optional: `.zagent/.env`

```
DEEPSEEK_API_KEY=sk-...
```

## Architecture

```
main.zig          -- entry point, CLI args (--prompt, --model)
src/App.zig       -- orchestrator: init config -> provider -> tools -> session -> agent loop
src/config.zig    -- TOML config loading, model resolution, .env parsing
src/toml.zig      -- lightweight TOML parser
src/types.zig     -- shared types (Message, Tool, ProviderEntry, etc.)
src/core/
  agent.zig       -- agent loop: maintain messages, call provider, execute tools
  session.zig     -- JSONL session persistence (.zagent/sessions/)
src/io/
  provider.zig    -- OpenAI-compatible HTTP client with SSE streaming + retry
src/tool/
  registry.zig    -- tool registration and dispatch
  read.zig        -- read files / list directories
  write.zig       -- create/overwrite files
  bash.zig        -- execute shell commands
  grep.zig        -- regex content search
  glob.zig        -- filename pattern matching
  skill.zig       -- load .zagent/skills/*/SKILL.md
src/render/
  cli.zig         -- terminal output: tool calls, assistant messages, errors
src/util/
  path.zig        -- path resolution with traversal guard
  signal.zig      -- Ctrl+C handler (Windows SetConsoleCtrlHandler)
  text.zig        -- string trimming
```

## Documentation

Design docs for v0.0.1-alpha live in `docs/0.0.1-alpha/`:

| File | Content |
|------|---------|
| `PLAN-V1-CLI-CORE.md` | Master plan: module layering, dependency rules, implementation constraints |
| `plan-step1-config.md` | Config system design: TOML parsing, model resolution, `.env` loading |
| `plan-step2-provider.md` | Provider client: curl subprocess, SSE streaming, retry strategy |
| `plan-step3-tools.md` | Tool system: registry pattern, param schemas, execution contract |
| `plan-step4-session.md` | Session management: JSONL format, append/flush, line protocol |
| `plan-step5-agent.md` | Agent loop: message state machine, tool round limits |
| `plan-step6-render.md` | CLI renderer: phase labels, tool call/output formatting |
| `plan-step7-app-integration.md` | App orchestrator: init pipeline, component wiring |
| `plan-step8-fix-audit.md` | Implementation fixes and post-build audit |

## Build

```bash
zig build               # compile
zig build run           # run interactive REPL
zig build run -- --prompt "..."    # single-shot mode
zig build -Dversion="1.2.3"  # override version string
zig build test          # run unit tests
```

## Key design decisions

- **Arena allocator** -- most allocations share `process.arena`, freed on exit. Only session/tool results use their own GPA.
- **TOML config** -- self-contained parser in `toml.zig`, no external dependencies.
- **SSE streaming** -- provider parses `data:` lines with ZIG-SSE-001 guard against non-SSE error responses.
- **Static tool registry** -- compile-time array of `ToolEntry`, no runtime registration needed.
- **Single binary** -- Windows icon embedded via `addWin32ResourceFile`.

## Vibe Coding insights

### The meta-system determines the quality ceiling

The quality of AI-generated code does not depend on what the AI *can* do, but on what you *prevent* it from doing. The formula:

```
memory system x error correction x workflow constraints x review gates x agent isolation = output quality ceiling
```

None of these factors require domain expertise. A non-programmer can produce a working project if the constraint system is solid enough.

### Constraints grow from usage, not from planning

Skills, agent types, and workflow rules in this project were not designed upfront. They grew organically: `AGENTS.md` accumulated rules until it was too large, then was extracted into the `zig-dev` skill, which later spawned `zig-reviewer` and `zig-debugger` sub-agents. External skills serve as references; the ones that stick are the ones that grow from real usage.

### The error loop is the real learning engine

The project's 65+ learnings in `.opencode/learnings/LEARNINGS.md` follow a repeated cycle: AI hallucinates a non-existent API -> compiler rejects it -> read Zig source to find the real API -> record in the trap table -> never hit the same trap again. This feedback loop, not the AI's initial output, is what produces correct code.

### Decision layer owns persistence, not execution layer

When the agent loop writes session data to disk and the app layer also needs to roll back errors, the persistence gate must live in the decision layer (App), not the execution layer (agent). An agent that appends messages and then fails leaves orphan data that corrupts the session file. Execution modules should only touch memory; the orchestrator decides when and what to flush.

### Verify bottom-up, not top-down

Building the full agent loop before verifying the HTTP layer worked was the single biggest waste in z-agent's history. Zig 0.16.0's `std.http.Client` is broken on Windows (AFD.CONNECT IOCTL timeout), and discovering this after implementing serialization, dialog parsing, and CLI interaction meant all upper-layer work was thrown away. Verify the foundation before building on it.

## License

MIT
