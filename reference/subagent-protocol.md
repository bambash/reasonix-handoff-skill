# Sub-agent protocol

`reasonix-handoff/v1` is a small, harness-agnostic protocol for using `rxbroker` as the
session authority while another harness orchestrates planner, implementer, reviewer, tester,
or fixer sub-agents.

The broker still owns the cache invariant: every task maps to one deterministic
`(repo, type, model, thread)` session. The calling harness owns scheduling, permissions, and
how sub-agent results are combined.

## Discovery

Harnesses should start by calling:

```bash
$RXB capabilities --repo /path/to/repo
```

The response is JSON with the supported protocol, commands, request types, role mappings,
configured models, concurrency cap, task-envelope fields, result-contract fields, and whether
the `reasonix` binary is available.

## Roles

These are conventional role mappings. They are intentionally expressed in terms of the three
broker request types so older callers remain compatible.

| Role | Broker type | Writes | Use |
|---|---|---:|---|
| `planner` | `openspec` | no | Plan work or draft OpenSpec artifacts. |
| `implementer` | `codegen` | yes | Modify code for one scoped artifact. |
| `reviewer` | `review` | no | Critique code, diffs, specs, or plans. |
| `tester` | `review` | no | Run or design verification without editing by default. |
| `fixer` | `codegen` | yes | Apply focused fixes after review or test failure. |

The harness should enforce write permissions outside `rxbroker` according to its own sandbox
or tool policy. The broker reports role intent, but it does not enforce file access.

## Task envelope

Use `run-task` for a portable task file:

```bash
$RXB run-task task.json
```

Minimum task:

```json
{
  "type": "codegen",
  "thread": "add-rate-limiter",
  "objective": "Implement rate limiting middleware."
}
```

Full task:

```json
{
  "type": "codegen",
  "thread": "add-rate-limiter",
  "repo": "/path/to/repo",
  "agent": "implementer-1",
  "max_steps": 20,
  "objective": "Implement rate limiting middleware.",
  "scope": {
    "files": ["internal/http/*.go", "tests/rate_limit_test.go"],
    "allowed_commands": ["go test ./..."]
  },
  "constraints": [
    "Make minimal changes.",
    "Do not modify unrelated files.",
    "Run go test ./... when finished."
  ],
  "expected_output": {
    "format": "json",
    "include": ["status", "summary", "files_changed", "tests_run", "issues", "next_steps"]
  }
}
```

Fields:

| Field | Required | Purpose |
|---|---:|---|
| `type` | yes | One of `codegen`, `review`, or `openspec`. |
| `thread` | yes | Stable logical unit of work. Same thread resumes the cached session. |
| `prompt` or `objective` | yes | The actual task instruction. |
| `repo` | no | Repository path. Defaults to caller working directory. |
| `model` | no | Model override. This changes the session key. |
| `agent` | no | Calling sub-agent id echoed in the broker JSON envelope. |
| `max_steps` | no | Per-task reasonix step cap. |
| `scope` | no | Files, directories, commands, or boundaries the harness wants observed. |
| `constraints` | no | Non-negotiable implementation or review constraints. |
| `expected_output` | no | Desired final response shape. |
| `result_schema` | no | Optional stricter schema supplied by the harness. |

`run-task` forwards the full envelope into the Reasonix prompt so the sub-agent sees the same
structured context the harness used for routing.

## Result contract

When the harness requests JSON, use this shape:

```json
{
  "status": "completed",
  "summary": "Implemented rate limiting middleware.",
  "files_changed": ["internal/http/rate_limit.go"],
  "tests_run": [
    {
      "command": "go test ./...",
      "result": "passed",
      "output_summary": "All packages passed."
    }
  ],
  "issues": [],
  "next_steps": []
}
```

Allowed `status` values are `completed`, `blocked`, and `failed`. If blocked, include the
smallest concrete question or missing input needed to continue.

## Threading rules

- Continue or fix the same artifact on the same `type` and `thread`.
- Use a separate thread for unrelated artifacts, even if the same sub-agent role handles them.
- Do not run unrelated tasks on the same thread; that poisons the prefix and hurts cache reuse.
- Same-thread concurrent runs are safe but serialized by the broker lock.
- Parallelism comes from independent threads. Keep active sessions at or under
  `.limits.concurrency_cap` from `capabilities` or `.concurrency.cap` from `run`.

## Orchestration pattern

1. The supervising harness calls `capabilities`.
2. A planner creates task envelopes with stable thread ids.
3. Implementers run independent `codegen` envelopes on separate threads.
4. Reviewers run `review` envelopes keyed by PR, change id, or task slug.
5. Fixers reuse the implementation thread for focused follow-ups.
6. The harness parses the broker JSON envelope, then parses `.output` according to the
   requested result contract.
