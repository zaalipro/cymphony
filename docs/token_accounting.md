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

When a token-related event arrives, use this precedence:

1. `turn/completed` usage from Claude Code JSON output
2. `claude/event/token_count` with `total_token_usage`

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

- Live token totals come from Claude Code per-session usage reporting.
- Usage is reported at turn completion, not streamed incrementally.
- Reporting is session-based, and multiple turns can occur on one session via `--resume`.

## Codex

When `agent.kind` is `codex`, usage arrives once per `codex exec` invocation on the terminal
`turn.completed` JSONL event:

```json
{"type":"turn.completed","usage":{"input_tokens":14461,"cached_input_tokens":9984,"output_tokens":5,"reasoning_output_tokens":0}}
```

Cymphony reads `input_tokens` and `output_tokens` and computes `total_tokens` as their sum
(`cached_input_tokens` is informational; `reasoning_output_tokens` is already included in
`output_tokens`). Resumed sessions (`codex exec resume <session_id>`) report per-invocation
totals the same way, and the same delta-accounting path used for Claude applies.
