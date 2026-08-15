# Logging Best Practices

This guide defines logging conventions for Cymphony so Claude Code can diagnose failures quickly.

## Goals

- Make logs searchable by issue and session.
- Capture enough execution context to identify root cause without reruns.
- Keep messages stable so dashboards/alerts are reliable.

## Required Context Fields

When logging issue-related work, include both identifiers:

- `issue_id`: Linear internal UUID (stable foreign key).
- `issue_identifier`: human ticket key (for example `MT-620`).

When logging coding-agent execution lifecycle events, include:

- `session_id`: agent session identifier (Claude `--resume`, Codex `thread_id`, Antigravity `--conversation`).

## Message Design

- Use explicit `key=value` pairs in message text for high-signal fields.
- Prefer deterministic wording for recurring lifecycle events.
- Include the action outcome (`completed`, `failed`, `retrying`) and the reason/error when available.
- Avoid logging large payloads unless required for debugging.

## Scope Guidance

- `AgentRunner`: log start/completion/failure with issue context, plus `session_id` when known.
- `Orchestrator`: log dispatch, retry, terminal/non-active transitions, and worker exits with issue context. Include `session_id` whenever running-entry data has it.
- `Claude.AppServer` / `Agent.Runner`: log session start/completion/error with issue context and `session_id`.

## Harness stream events

These events carry live CLI stdout. They must **not** land in the orchestrator `log_events` ring (50 newest-first summarized events).

- `:harness_stdout`
  - Emitted by `Agent.Runner.collect_output` on every completed stdout line (`{:eol, chunk}`) and on a leftover buffer after exit 0.
  - `raw` is truncated to 2048 bytes. `{:noeol, _}` chunks are not emitted.
  - Logged at debug when a line is captured (`log_stream_line/1`); do not treat the payload as an orchestrator log event.
  - `AgentRunner` forwards the line to `HarnessStream.append/2` only. It does **not** send `:harness_stdout` itself to the orchestrator.
- `:harness_heartbeat`
  - Sent to the orchestrator at most once per 2000 ms per issue so stall detection sees activity.
  - Updates `running_entry.last_agent_timestamp` only. Do not `append_log_event`, `notify_dashboard`, or `broadcast_issue_update`.
  - If either event leaks into humanize, render it as `"harness"`.

Live tails are published on topic `observability:issue:<issue_id>:harness` as `%{event: :harness_stream, …}` maps (see SPEC §10.8).

## Checklist For New Logs

- Is this event tied to a Linear issue? Include `issue_id` and `issue_identifier`.
- Is this event tied to a coding-agent session? Include `session_id`.
- Is the failure reason present and concise?
- Is the message format consistent with existing lifecycle logs?
- If this is CLI stdout, is it `:harness_stdout` (debug, 2048 cap) rather than an orchestrator `log_events` entry?
