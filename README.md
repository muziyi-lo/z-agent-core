# z-agent-core

Minimal Zig AI agent CLI.

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

## License

MIT
