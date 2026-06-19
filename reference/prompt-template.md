# Brokering prompt template

Drop-in guidance for a calling agent that hands work to DeepSeek-Reasonix through
`rxbroker`. The goal is **cache-stable, deterministic session reuse**: re-sending the same
growing transcript is what makes DeepSeek's prefix cache hit.

```
RXB=~/.claude/skills/reasonix-handoff/scripts/rxbroker
```

## Policy

You broker DeepSeek work through `rxbroker`. You never call `reasonix` directly.

For every request, decide three things:

1. **type** — what kind of work this is:
   - `codegen` — write/modify code (writer tools, fast model)
   - `review` — read/critique code (read-only posture, stronger model)
   - `openspec` — OpenSpec proposal/spec/tasks work
   Each type is its own session lineage; never mix two types on one thread.

2. **thread** — a *stable* id naming the unit of work:
   - `openspec` → the OpenSpec change id
   - `codegen` / `review` → the feature/branch name, PR number, or a durable task slug
   Use the **same thread id** every time you continue or refine that same artifact — that is
   what reconnects you to the cached transcript. Use a **new thread id** only for an
   unrelated unit of work.

3. **reuse vs. new** — continuing the same artifact ⇒ reuse the thread id (cache hit).
   Switching to something unrelated ⇒ new thread id. Do **not** pile unrelated tasks onto one
   thread; that mutates the prefix and destroys the cache benefit.

## Multi-threading

- Independent workstreams ⇒ separate threads (and/or types), run in parallel.
- Keep **≤ 4 concurrent** sessions. After each `run`, check `.concurrency.over`; if true,
  reuse an existing thread or queue the work rather than opening more.
- Concurrent `run`s on the *same* thread are serialized by a per-key lock (safe but not
  parallel). To parallelize, use different threads.

## Running work

```bash
# Inline task:
$RXB run --type codegen --thread <id> "<task>"
# Large/structured prompt via stdin:
cat prompt.md | $RXB run --type review --thread <id> -
# Override the model for one request (changes the session key → new lineage):
$RXB run --type codegen --thread <id> --model deepseek-pro "<task>"
```

Parse the JSON envelope:
- `.output` — the model's result (use this).
- `.status` — `created` (new session) or `reused` (reconnected).
- `.metrics.cache_hit_tokens` / `.metrics.cache_miss_tokens` — confirm the cache is working;
  a healthy resumed session shows hit ≫ miss.
- `.turns` — how many turns this session has accumulated.
- `.concurrency` — `{active, cap, over}` advisory.

Thread these back into follow-ups: keep using the same `--type`/`--thread` to stay on the
cached session. You don't need to track `key`/`path` yourself — the broker derives them
deterministically from `(repo, type, model, thread)`.

## When to promote to `serve`

Stay on `run` by default. Promote a thread to a live HTTP+SSE server only when a workstream
needs to be **observed live, streamed, or shared across processes/a human**:

```bash
$RXB promote --type codegen --thread <id> --addr 127.0.0.1:8790   # -> http://127.0.0.1:8790/
$RXB stop    --type codegen --thread <id>
```

`serve` resumes the same session file, so the cache contract is preserved.

## Inspecting state

```bash
$RXB list                      # all sessions in this repo
$RXB list --type openspec      # filter
$RXB key --type codegen --thread <id>   # show computed key/path without running
```
