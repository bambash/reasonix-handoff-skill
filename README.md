# reasonix-handoff

> Agent skill for brokering work to a local [DeepSeek](https://deepseek.ai) model via the [`reasonix`](https://reasonix.ai) CLI, with deterministic session reuse for **~28x cheaper** cached inference.

## What is this?

`reasonix-handoff` is an AI skill that lets a calling agent (Claude, OpenCode, etc.) hand off code-generation, code-review, or OpenSpec tasks to a locally running DeepSeek model. It wraps the `reasonix` CLI with a session broker (`rxbroker`) that ensures every reconnect to the same logical unit of work hits the same growing transcript — triggering DeepSeek's KV prefix cache for dramatically lower token costs.

## Why?

- **Cost**: A resumed turn on the same session costs ~0.0003 yen vs. ~0.0084 yen cold (verified on `deepseek-v4-flash`). That's ~28x savings.
- **Determinism**: Sessions are keyed by `sha256(repo\0type\0model\0thread)`, so the same request always reconnects to the same transcript.
- **Concurrency**: Up to 4 concurrent sessions, with soft advisory capping and queueing guidance.
- **Harness-friendly**: `capabilities` and `run-task` provide a JSON protocol for sub-agent orchestration.
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

### Sub-agent Roles

Other harnesses can map higher-level sub-agent roles onto the same broker request types:

| Role | Type | Writes | Use |
|------|------|-------:|-----|
| `planner` | `openspec` | no | Plan work or draft OpenSpec artifacts |
| `implementer` | `codegen` | yes | Modify code for a scoped artifact |
| `reviewer` | `review` | no | Critique code, diffs, specs, or plans |
| `tester` | `review` | no | Run or design verification without editing by default |
| `fixer` | `codegen` | yes | Apply focused fixes after review or test failure |

## Commands

Always invoke through `scripts/rxbroker` — **never call `reasonix` directly**.

### `rxbroker key`

Print the deterministic key for a given session without creating it.

```
rxbroker key --type codegen --thread "add-auth-middleware"
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
rxbroker ensure --type codegen --thread "add-auth-middleware"
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
rxbroker run --type codegen --thread "add-auth-middleware" \
  "Write a FastAPI auth middleware with JWT validation"
```

Or pipe the prompt via stdin:

```
echo "Write a FastAPI auth middleware with JWT validation" | \
  rxbroker run --type codegen --thread "add-auth-middleware" -
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
rxbroker run --raw --type codegen --thread "add-auth-middleware" "Write code..."
```

Use `--agent` to echo sub-agent identity in the JSON envelope:

```
rxbroker run --type codegen --thread "add-auth-middleware" \
  --agent implementer-1 "Write code..."
```

### `rxbroker capabilities`

Print machine-readable protocol metadata for another harness.

```
rxbroker capabilities --repo /path/to/repo
```

The response includes `protocol: "reasonix-handoff/v1"`, supported commands, request types,
role mappings, configured models, task-envelope fields, result-contract fields, concurrency
limits, and whether `reasonix` is available.

### `rxbroker run-task`

Run a portable JSON task envelope. This is the preferred interface for sub-agent driven
development from another harness.

```
rxbroker run-task task.json
```

Minimum task:

```json
{
  "type": "codegen",
  "thread": "add-rate-limiter",
  "agent": "implementer-1",
  "objective": "Implement rate limiting middleware."
}
```

The task may also include `repo`, `model`, `max_steps`, `scope`, `constraints`,
`expected_output`, and `result_schema`. The full envelope is forwarded to Reasonix.

### `rxbroker list`

List all known sessions, optionally filtered.

```
rxbroker list
rxbroker list --type codegen
rxbroker list --thread "add-auth-middleware"
```

### `rxbroker promote`

Promote a session to a long-running server (`reasonix serve`) for live observation, streaming, or sharing across processes.

```
rxbroker promote --type codegen --thread "add-auth-middleware" --addr "localhost:9090"
```

Starts the server in the background, persists the `serve` entry in the index.

### `rxbroker stop`

Kill the `serve` process for a session.

```
rxbroker stop --type codegen --thread "add-auth-middleware"
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
