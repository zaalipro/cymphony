# Logging Best Practices

This guide defines logging conventions for Cymphony so Claude Code can diagnose failures quickly.

## Goals

- Make logs searchable by issue and session.
- Capture enough execution context to identify root cause without reruns.
- Keep messages stable so dashboards/alerts are reliable.

## Where Logs Land

`CymphonyElixir.LogFile.configure/0` runs first in both application entrypoints and installs two
disk handlers, then removes the default console handler. Every path derives from
`CymphonyConfig.config_dir/0` (`~/.cymphony` by default).

| Path | Handler | Contents |
|------|---------|----------|
| `~/.cymphony/log/cymphony.log.N` | `:logger_disk_log_h` (`type: :wrap`, 10 MB × 5) | Everything `debug` and up. `cymphony logs` reads this (rotations included). |
| `~/.cymphony/daemon.log` | `:logger_std_h` (`type: :file`, 2 MB × 2) | `warning` and up only — the file to `tail` when a background daemon misbehaves. |
| `~/.cymphony/daemon.out` | none (the `nohup` redirect) | Raw daemon stdout/stderr: status TUI repaint frames, plus any crash that happens before Logger is configured. Not a log; the CLI reads its tail when a background start produces no pidfile. |

Both handlers buffer, and the CLI halts the VM without unwinding it, so every exit path calls
`Logger.flush()` before `System.halt/1`. Skipping that leaves both files empty exactly when a
startup failure needs explaining.

`CymphonyElixir.CLI.halt/1` is that one exit path — including `BurritoCLI.run_cli/1`'s
unhandled-error handler, which is the only place a crash in the shipped binary is recorded
and which runs after the console handler has already been removed. There is exactly one
`System.halt/1` *call site* in `lib/`, inside `CLI.halt/1`; anything else that needs to exit
calls `CLI.halt/1`.

Both paths are overridable through the `:cymphony_elixir` app env (`:log_file`,
`:daemon_log_file`), and `config/config.exs` points them at `tmp/test-logs` under
`config_env() == :test`. `Application.start/2` installs the handlers unconditionally, so without
that override `mix test` appends the whole suite's warning noise — including raw agent stdout — to
the `~/.cymphony/daemon.log` an operator tails, and rotates their real one away. A test that
unsets either key to exercise the config-dir defaults must put it back afterwards.

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
  - A nonzero exit is not a harness event: it returns `{:agent_exit, status, tail}`, where `tail` is the newest 20 printed lines, **newest first**, capped at 2048 bytes from the back, with ANSI/control bytes stripped. That string is the failure reason the retry queue and the Linear abandonment comment show, and every one of those surfaces truncates from the front, so the CLI's own error line has to be at the start.
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
