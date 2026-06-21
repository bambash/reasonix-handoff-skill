---
name: reasonix-handoff
description: Use when delegating code-generation, code-review, or OpenSpec work to DeepSeek via the local `reasonix` CLI and you want cache-stable, deterministic session reuse — starts or reconnects to a per-(repo,type,model,thread) session so DeepSeek's prefix cache hits, and multi-threads independent workstreams. Triggers include "hand this off to deepseek/reasonix", "run this through reasonix", brokering codegen/review/openspec to reasonix, or reconnecting to an existing reasonix session.
---

# Reasonix DeepSeek Agent Handoff

Broker work to DeepSeek-Reasonix through a thin script (`rxbroker`) that owns a
**deterministic, idempotent** session per `(repo, request-type, model, thread)`. Reusing the
same growing transcript is what earns DeepSeek's KV **prefix-cache** hits (verified ~28×
cheaper on resume). Independent workstreams run as separate sessions (multi-threading).

## The one rule

**Always go through `rxbroker run` or `rxbroker run-task`. Never call `reasonix` directly.**
Direct calls fork uncontrolled sessions and break the cache contract.

```
RXB=~/.claude/skills/reasonix-handoff/scripts/rxbroker
```

## Choosing a session (this is the whole skill)

1. **`--type`** ∈ `codegen` | `review` | `openspec`. Each is a separate session lineage
   (different tool posture/model — never interleave them).
2. **`--thread <id>`** — a *stable* logical id. **Same id = reconnect (cache hit). New id =
   new session.** Pick a real handle:
   - `openspec` → the change id (e.g. `add-user-auth`)
   - `codegen` / `review` → the feature/branch name, PR number, or a stable task slug
3. **Reuse vs. new:** continuing or refining the *same artifact* → reuse the id. An
   *unrelated* unit of work → new id. Putting two unrelated tasks on one thread poisons the
   prefix and tanks the cache.
4. **Multi-thread:** open parallel threads for independent work, **≤ 4 concurrent** (the `run`
   output's `.concurrency.over` flags when you exceed it — reuse or queue past that).
5. **`--model`** only to override the per-type default (it changes the session key).

## Commands

| Command | Purpose |
|---|---|
| `$RXB run --type T --thread ID [--max-steps N] [--raw] (<task> \| -)` | Ensure + cache-stable resume + run. The workhorse. |
| `$RXB run-task TASK.json [--raw]` | Harness-facing JSON task envelope runner. |
| `$RXB ensure --type T --thread ID` | Idempotently create/resolve a session without running. |
| `$RXB key --type T --thread ID` | Print the computed key/path (determinism check). |
| `$RXB list [--type T] [--thread ID]` | JSON of known sessions (turns, last_used, serve). |
| `$RXB capabilities [--repo DIR]` | Machine-readable protocol, roles, limits, and command discovery. |
| `$RXB promote --type T --thread ID [--addr H:P]` | Bind a live `reasonix serve` (HTTP+SSE) to the session. Opt-in. |
| `$RXB stop --type T --thread ID` | Stop that session's serve process. |

`run` emits one JSON object: `{key, path, type, thread, model, status, turns, exit,
metrics:{cache_hit_tokens, cache_miss_tokens, cost, ...}, concurrency, output}`. Read
`.output` for the result and `.metrics` to confirm the cache is working. Use `--raw` for
plain streamed text instead of the envelope.

For sub-agent driven harnesses, call `capabilities` first, then submit JSON envelopes with
`run-task`. The protocol name is `reasonix-handoff/v1`; conventional roles are `planner`,
`implementer`, `reviewer`, `tester`, and `fixer`, mapped onto the same three request types.
Use `--agent NAME` or the task envelope's `agent` field to echo sub-agent identity in broker
responses.

## Examples

```bash
# Hand a codegen task to deepseek-flash, reconnecting on the same feature thread:
$RXB run --type codegen --thread add-rate-limiter "Implement the TODOs in limiter.go"

# Pipe a larger prompt from stdin:
git diff | $RXB run --type review --thread pr-482 -

# OpenSpec change, keyed by change id so every step accumulates cache:
$RXB run --type openspec --thread add-user-auth "Draft tasks.md for this change"

# Harness discovery and portable JSON task execution:
$RXB capabilities --repo /path/to/repo
$RXB run-task task.json

# Promote a hot session to a live server, then tear down:
$RXB promote --type codegen --thread add-rate-limiter --addr 127.0.0.1:8790
$RXB stop    --type codegen --thread add-rate-limiter
```

## How it works / deeper detail

- `reference/prompt-template.md` — the brokering policy to follow when driving `rxbroker`
  (thread-id discipline, reuse-vs-new, multi-threading, when to promote to `serve`).
- `reference/subagent-protocol.md` — the machine-facing protocol for other harnesses that
  orchestrate planner/implementer/reviewer/tester/fixer sub-agents through `rxbroker`.
- `reference/reasonix-cli.md` — underlying `reasonix` flags, the prefix-cache invariant, and
  the verified `-resume`/`-metrics` behavior the broker depends on.

State lives per-repo in `.reasonix-broker/` (gitignore it): `sessions/<type>/<key>.jsonl`
transcripts, `index.json` metadata, `locks/` for per-key serialization. Model mapping and the
concurrency cap come from `config.defaults.toml`, overridable via `.reasonix-broker/config.toml`.

## Gotchas

- `reasonix` config `permissions.mode = "ask"` can make autonomous tool use block; for real
  codegen via the broker, ensure permissions allow the tools the task needs.
- The per-key lock serializes runs on the *same* session — fire concurrent work on *different*
  threads to actually parallelize.
