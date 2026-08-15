# Claude Code Token Accounting

This document explains how Claude Code reports token usage through the `claude -p`
headless CLI and how Cymphony should account for it.

## Short Version

- Claude Code `--output-format json` includes a top-level `usage` field with
  `input_tokens` and `output_tokens`.
- This usage is reported once per `claude -p` invocation, at session completion.
- Cymphony tracks cumulative totals by accumulating per-turn usage values.

## Primary Source Semantics

When running `claude -p` with `--output-format json`, the final JSON line
contains:

```json
{
  "result": "...",
  "session_id": "...",
  "usage": {
    "input_tokens": 1234,
    "output_tokens": 567
  }
}
```

- `input_tokens`: total input tokens consumed during the session
- `output_tokens`: total output tokens generated during the session

These values are absolute totals for the single `claude -p` invocation.

## Event Types

### `claude/event/token_count`

Cymphony emits internal `claude/event/token_count` events when it parses usage
from Claude Code JSON output. These events carry:

```json
{
  "total_token_usage": {
    "input_tokens": 1234,
    "output_tokens": 567,
    "total_tokens": 1801
  }
}
```

These are absolute cumulative snapshots per Cymphony turn.

### `turn/completed`

When a Claude Code turn completes, Cymphony records the usage from the JSON
output as the final turn state. The usage payload is the same schema as the
per-session usage above.

## Recommended Accounting Strategy For Cymphony

Track usage per active issue session.

For each session, keep:

- `absolute_total`: latest accepted absolute total snapshot
- `accumulated_total`: the total you expose in UI/API

### Preferred source order

When a token-related event arrives, `Tokens.extract_token_delta` uses this precedence:

1. `update[:usage]` / `update["usage"]` when that value is itself an integer token map
   (`:turn_completed` from `Agent.Runner`)
2. `payload["usage"]` on the nested stream payload
3. Codex `turn.completed` / `turn/completed` `usage`
4. Antigravity `result` / `step_update` `usage`
5. Claude `turn/completed` usage from JSON output / `method == "turn/completed"`
6. `claude/event/token_count` with `total_token_usage`

### Algorithm

#### If an absolute total is present

- Treat it as a turn-level snapshot.
- Replace the stored absolute total with the new value.
- Set exposed totals from that absolute snapshot.

#### If no usage is present

- Ignore the event for accounting.
- Keep the last accepted absolute high-water mark unchanged.

## What Cymphony Should And Should Not Do

### Do

- Prefer per-turn usage from Claude Code JSON output for live reporting.
- Treat `usage.input_tokens` and `usage.output_tokens` as authoritative for turn totals.
- Key accounting by `session_id` (resumed sessions maintain continuity).
- Expect one session to span multiple turns when Cymphony passes `--resume <session_id>`.

### Do not

- Do not assume usage is available for every turn (Claude Code may omit it in error cases).
- Do not double-count usage across turns that share the same session.

## Practical Interpretation For Cymphony Logs

When reading Claude Code output:

- `usage` in final JSON line
  - best source for dashboard and API totals
- `turn/completed` event
  - best used as end-of-turn state, carrying the final usage snapshot

## Recommended Cymphony Documentation Contract

If Cymphony documents token reporting externally, the contract should be:

- Live token totals come from the active agent's per-session usage reporting
  (Claude JSON, Codex `turn.completed`, Antigravity `result` / `step_update`).
- `:turn_completed` `update[:usage]` from `Agent.Runner` counts.
- Mid-turn stream usage (Antigravity `step_update`, Codex stream `turn.completed`)
  increments the running entry; totals still de-dupe via last-reported snapshots.
- Reporting is session-based, and multiple turns can occur on one session via
  `--resume` (Claude), `codex exec resume`, or `--conversation` (Antigravity).

## Codex

When `agent.kind` is `codex`, usage arrives on the terminal `turn.completed` JSONL event
(and on `:stream_event` payloads with `type` `turn.completed` / `turn/completed`):

```json
{"type":"turn.completed","usage":{"input_tokens":14461,"cached_input_tokens":9984,"output_tokens":5,"reasoning_output_tokens":0}}
```

`Tokens.extract_token_delta` now counts this shape, including mid-stream
`:stream_event` `turn.completed` usage and the `:turn_completed` update's own
`update[:usage]` map from `Agent.Runner`. Cymphony reads `input_tokens` and
`output_tokens` and computes `total_tokens` as their sum when missing
(`cached_input_tokens` is informational; `thinking_tokens` / `reasoning_output_tokens`
are **not** added to output). A `turn.completed` with no `item.completed` agent
message is still success (`result` may be null). Resumed sessions
(`codex exec resume <session_id>`) report per-invocation totals the same way.

## Antigravity

When `agent.kind` is `antigravity`, usage arrives on `result` envelopes and
optionally on mid-turn `step_update` events:

```json
{"event":"result","result":{"status":"SUCCESS","conversation_id":"…","response":"…","usage":{"input_tokens":100,"output_tokens":20,"thinking_tokens":8,"total_tokens":128}}}
{"event":"step_update","step_update":{"state":"ACTIVE","usage":{"input_tokens":40,"output_tokens":5}}}
```

`Tokens.extract_token_delta` accepts, in order:

1. `update[:usage]` / `update["usage"]` when the value itself is an integer token map
   (this is how `:turn_completed` from `Agent.Runner` counts)
2. `payload["usage"]` / `payload[:usage]` when `payload` is `update[:payload]`
3. `payload["type"]` in `["turn.completed", "turn/completed"]` → `payload["usage"]`
4. `payload["event"] == "result"` → `result["usage"]` or `payload["usage"]`
5. `payload["event"] == "step_update"` → `step_update["usage"]`
6. Existing Claude paths (`params.msg…total_token_usage`, `tokenUsage.total`,
   `method == "turn/completed"`)

Normalized usage keeps only `input_tokens`, `output_tokens`, and `total_tokens`.
Missing `total_tokens` is `input + output`. `thinking_tokens` and cache fields
are dropped. Mid-turn Antigravity `step_update` usage increments the running
entry the same way as a terminal result.
