# Reasonix CLI & cache invariant (what the broker relies on)

Verified against `reasonix v1.5.0`. Config at `~/.config/reasonix/`
(`config.toml` + `credentials` + `sessions/`).

## Relevant subcommands & flags

```
reasonix run   -model NAME -resume FILE -max-steps N -metrics PATH -dir DIR <task>
reasonix serve -model NAME -resume FILE -addr HOST:PORT   # HTTP+SSE, default 127.0.0.1:8787
reasonix acp   -model NAME                                # ACP over stdio (NO -resume)
reasonix doctor -json
```

- `-resume FILE` — resume a **specific** session file. Takes precedence over `-continue`.
  **The file must already exist** (reasonix `open`s it; it does not create it).
- `-metrics PATH` — write a JSON token/cache/cost summary of the run.
- `-dir DIR` — project root; config, sandbox, and file tools resolve from here.
- `-max-steps N` — tool-call round cap (`0` = config default).
- `-model NAME` — provider name (default `default_model`).

## Verified `-resume` behavior (the broker's foundation)

- Point `-resume` at an **arbitrary path you own** *after pre-creating it empty* (`: > path`).
  Reasonix appends `{role, content}` JSONL lines to that exact file and writes a `<path>.meta`
  sidecar next to it. It creates **nothing** under `~/.config/reasonix/sessions/`.
- So the broker owns `.reasonix-broker/sessions/<type>/<key>.jsonl`, creates it empty in
  `ensure`, and always `-resume`s it — giving a pure, deterministic path from the key.

## `-metrics` JSON shape

```json
{ "prompt_tokens": N, "completion_tokens": N,
  "cache_hit_tokens": N, "cache_miss_tokens": N,
  "steps": N, "cost": F, "currency": "¥", "compactions": N }
```

The broker surfaces this as `.metrics` in the `run` envelope. `cache_hit_tokens ≫
cache_miss_tokens` on a resumed turn means the prefix cache is working.

## The prefix-cache invariant (why the broker is shaped this way)

DeepSeek's KV prefix cache is keyed on the **byte-identical leading prefix** of a request
(system prompt + tool schemas + prepend-only message history). To keep hits:

- **Resume the same growing transcript** — the only way to reuse the *conversation* prefix.
  (Measured: cold turn 0 cached / 8409 new ≈ ¥0.0084; resumed turn 8320 cached / 99 new ≈
  ¥0.0003.)
- **Do not change the system prompt or tool schemas mid-session.** A different tool posture
  (codegen vs. review) is a different `--type`, hence a different session.
- **Do not mix models in one session** (SPEC §3.5: planner/executor stay separate). Model is
  part of the session key, so the broker can never co-mingle models in one transcript.

## Models (from config)

| Provider name | Model | Notes |
|---|---|---|
| `deepseek-flash` | `deepseek-v4-flash` | default; cheap; broker default for `codegen` |
| `deepseek-pro`   | `deepseek-v4-pro`   | stronger; broker default for `review` / `openspec` |

Auth is via reasonix's own `credentials` file (no `DEEPSEEK_API_KEY` env needed here).

## Operational note

`permissions.mode = "ask"` makes autonomous tool use prompt for approval; a non-interactive
`run` doing real file edits may block. Text-only turns don't. Configure permissions (or an
allowlist) for the tools a codegen task needs before brokering it.
