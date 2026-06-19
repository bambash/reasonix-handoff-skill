# reasonix-handoff

> Claude Code skill for brokering work to a local [DeepSeek](https://deepseek.ai) model via the [`reasonix`](https://reasonix.ai) CLI, with deterministic session reuse for **~28x cheaper** cached inference.

## What is this?

`reasonix-handoff` is an AI skill that lets a calling agent (Claude, OpenCode, etc.) hand off code-generation, code-review, or OpenSpec tasks to a locally running DeepSeek model. It wraps the `reasonix` CLI with a session broker (`rxbroker`) that ensures every reconnect to the same logical unit of work hits the same growing transcript — triggering DeepSeek's KV prefix cache for dramatically lower token costs.

## Why?

- **Cost**: A resumed turn on the same session costs ~0.0003 yen vs. ~0.0084 yen cold (verified on `deepseek-v4-flash`). That's ~28x savings.
- **Determinism**: Sessions are keyed by `sha256(repo\0type\0model\0thread)`, so the same request always reconnects to the same transcript.
- **Concurrency**: Up to 4 concurrent sessions, with soft advisory capping and queueing guidance.
- **Self-contained**: All state lives in `.reasonix-broker/` per-repo — no external database, no daemon.

## Requirements

- `reasonix` CLI (provides `run`, `serve`, `acp`, `doctor`)
- `jq` (JSON processor)
- `flock` (file locking, standard on Linux)
- `sha256sum` (or `shasum -a 256`)
- Bash 4+

## Installation

```bash
# Clone the skill into your skills directory
git clone git@github.com:bambash/reasonix-handoff-skill.git \
  ~/.claude/skills/reasonix-handoff

# Or for OpenCode
git clone git@github.com:bambash/reasonix-handoff-skill.git \
  ~/.config/opencode/skills/reasonix-handoff
```

The skill is activated by loading `SKILL.md` in your agent configuration — no additional setup required. The broker script lives at `scripts/rxbroker` within the cloned directory.

## Configuration

Default configuration lives in `config.defaults.toml`:

```toml
[models]
codegen  = "deepseek-flash"   # fast/cheap model for writing code
review   = "deepseek-pro"     # stronger model for read-only review
openspec = "deepseek-pro"     # stronger model for proposal/spec/tasks

[limits]
concurrency_cap = 4

[run]
max_steps = 0                 # 0 = use reasonix own config
```

To override per-repository, create `.reasonix-broker/config.toml` with the same `[section]` structure. Only flat `key = value` lines under a `[section]` are parsed (minimal TOML parser in awk).

### Available Models

| Config key       | reasonix model      | Cost profile | Use case                    |
|------------------|---------------------|-------------|-----------------------------|
| `deepseek-flash` | `deepseek-v4-flash` | Cheap       | Code generation (`codegen`) |
| `deepseek-pro`   | `deepseek-v4-pro`   | Stronger    | Review, OpenSpec work       |

## Session Model

Every session is identified by a deterministic key computed from four components:

```
key = sha256(repo_id \0 type \0 model \0 thread)[0:16]
```

| Component  | Description                                             |
|------------|---------------------------------------------------------|
| `repo_id`  | Absolute path to the git toplevel (or working directory) |
| `type`     | One of `codegen`, `review`, `openspec`                  |
| `model`    | Resolved model name (from `--model` flag or config)     |
| `thread`   | Stable id naming the logical unit of work               |

### Thread Discipline

- **Same thread id** → reconnects to the same session (cache hit).
- **New thread id** → creates a new session (cold start).
- **Never** pile unrelated tasks onto a single thread — break them into separate threads.
- Threads can run concurrently (up to the cap).

### Request Types

| Type       | Model (default)    | Description                                  |
|------------|--------------------|----------------------------------------------|
| `codegen`  | `deepseek-flash`   | Writing, editing, or generating code         |
| `review`   | `deepseek-pro`     | Read-only code review and analysis           |
| `openspec` | `deepseek-pro`     | OpenSpec proposal, spec, and task generation |

## Commands

Always invoke through `scripts/rxbroker` — **never call `reasonix` directly**.

### `rxbroker key`

Print the deterministic key for a given session without creating it.

```
rxbroker --type codegen --thread "add-auth-middleware" key
```

Outputs JSON:
```json
{
  "key": "a1b2c3d4e5f6a7b8",
  "path": "/path/to/repo/.reasonix-broker/sessions/codegen/a1b2c3d4e5f6a7b8.jsonl",
  "type": "codegen",
  "thread": "add-auth-middleware",
  "model": "deepseek-flash",
  "repo": "/path/to/repo"
}
```

### `rxbroker ensure`

Idempotent session factory. Creates the JSONL file and index entry if they don't exist.

```
rxbroker --type codegen --thread "add-auth-middleware" ensure
```

Output:
```json
{ "status": "created", "key": "a1b2c3d4...", "turns": 0 }
```
or
```json
{ "status": "reused",  "key": "a1b2c3d4...", "turns": 1 }
```

### `rxbroker run`

The main command. Calls `ensure`, acquires a per-key `flock` (serializing concurrent runs on the same session to protect the append-only JSONL and prefix invariant), then invokes `reasonix run -resume <path>`.

```
rxbroker --type codegen --thread "add-auth-middleware" run \
  "Write a FastAPI auth middleware with JWT validation"
```

Or pipe the prompt via stdin:

```
echo "Write a FastAPI auth middleware with JWT validation" | \
  rxbroker --type codegen --thread "add-auth-middleware" run -
```

Output is a JSON envelope:
```json
{
  "key": "a1b2c3d4...",
  "path": "/path/to/.reasonix-broker/sessions/codegen/a1b2c3d4.jsonl",
  "type": "codegen",
  "thread": "add-auth-middleware",
  "model": "deepseek-flash",
  "status": "ok",
  "turns": 2,
  "exit": { "code": 0 },
  "metrics": {
    "prompt_tokens": 1200,
    "completion_tokens": 800,
    "cache_hit_tokens": 1100,
    "cache_miss_tokens": 100,
    "steps": 3,
    "cost": 0.0003,
    "currency": "¥",
    "compactions": 0
  },
  "concurrency": {
    "count": 2,
    "cap": 4,
    "over": false
  },
  "output": "Generated code output text..."
}
```

Use `--raw` to stream plain text output instead of JSON:
```
rxbroker --raw --type codegen --thread "add-auth-middleware" run "Write code..."
```

### `rxbroker list`

List all known sessions, optionally filtered.

```
rxbroker list
rxbroker --type codegen list
rxbroker --thread "add-auth-middleware" list
```

### `rxbroker promote`

Promote a session to a long-running server (`reasonix serve`) for live observation, streaming, or sharing across processes.

```
rxbroker --type codegen --thread "add-auth-middleware" promote --addr "localhost:9090"
```

Starts the server in the background, persists the `serve` entry in the index.

### `rxbroker stop`

Kill the `serve` process for a session.

```
rxbroker --type codegen --thread "add-auth-middleware" stop
```

## Directory Layout

```
<repo root>/
└── .reasonix-broker/
    ├── config.toml          # Optional per-repo overrides
    ├── index.json           # Session registry (atomic with flock)
    ├── sessions/
    │   ├── codegen/
    │   │   └── <key>.jsonl   # Growing session transcripts
    │   ├── review/
    │   │   └── <key>.jsonl
    │   └── openspec/
    │       └── <key>.jsonl
    └── locks/
        └── <key>.lock        # Per-session flock files
```

Each `.jsonl` session file is append-only. reasonix appends JSONL records and writes a parallel `.meta` sidecar file.

## Concurrency Model

- **Cap**: 4 concurrent sessions (soft advisory, configurable via `limits.concurrency_cap`).
- **Serialization**: Concurrent `run` calls on the *same session key* are serialized via `flock` to protect the append-only JSONL and preserve the prefix-cache invariant.
- **Different sessions**: Run fully in parallel (different keys → different locks).
- **Queueing guidance**: After each `run`, check `.concurrency.over` in the output. If `true`, either reuse an existing session or wait before starting a new one.

## The Prefix Cache

DeepSeek's KV prefix cache is keyed on byte-identical leading prefixes of the input. To maintain cache hits:

1. **Resume the same growing transcript** — always reconnect to the same session for the same logical unit of work.
2. **Don't change the system prompt or tool schemas mid-session** — this would break the prefix.
3. **Don't mix models** — different models produce different cache keys.

The broker enforces all three invariants automatically through its deterministic session keying and per-key locking.

## Files

| File | Purpose |
|------|---------|
| `SKILL.md` | Skill definition with YAML frontmatter and agent instructions |
| `config.defaults.toml` | Default configuration (models, limits, run options) |
| `scripts/rxbroker` | Main broker executable (233 lines of bash) |
| `scripts/lib/common.sh` | Shared library (keys, paths, TOML parsing, index ops) |
| `reference/prompt-template.md` | Brokering policy for calling agents |
| `reference/reasonix-cli.md` | Underlying reasonix CLI reference |

## License

MIT
