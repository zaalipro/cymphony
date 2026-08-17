# Cymphony Service Specification

Status: Draft v1 (language-agnostic)

Purpose: Define a service that orchestrates coding agents to get project work done.

## 1. Problem Statement

Cymphony is a long-running automation service that continuously reads work from an issue tracker
(Linear in this specification version), creates an isolated workspace for each issue, and runs a
coding agent session for that issue inside the workspace.

The service solves four operational problems:

- It turns issue execution into a repeatable daemon workflow instead of manual scripts.
- It isolates agent execution in per-issue workspaces so agent commands run only inside per-issue
  workspace directories.
- It keeps the workflow policy in-repo (`WORKFLOW.md`) so teams version the agent prompt and runtime
  settings with their code.
- It provides enough observability to operate and debug multiple concurrent agent runs.

Implementations are expected to document their trust and safety posture explicitly. This
specification does not require a single approval, sandbox, or operator-confirmation policy; some
implementations may target trusted environments with a high-trust configuration, while others may
require stricter approvals or sandboxing.

Important boundary:

- Cymphony is a scheduler/runner and tracker reader.
- Ticket writes (state transitions, comments, PR links) are typically performed by the coding agent
  using tools available in the workflow/runtime environment.
- A successful run may end at a workflow-defined handoff state (for example `Human Review`), not
  necessarily `Done`.

## 2. Goals and Non-Goals

### 2.1 Goals

- Poll the issue tracker on a fixed cadence and dispatch work with bounded concurrency.
- Maintain a single authoritative orchestrator state for dispatch, retries, and reconciliation.
- Create deterministic per-issue workspaces and preserve them across runs.
- Stop active runs when issue state changes make them ineligible.
- Recover from transient failures with exponential backoff.
- Load runtime behavior from a repository-owned `WORKFLOW.md` contract.
- Expose operator-visible observability (at minimum structured logs).
- Support restart recovery without requiring a persistent database.

### 2.2 Non-Goals

- Rich web UI or multi-tenant control plane.
- Prescribing a specific dashboard or terminal UI implementation.
- General-purpose workflow engine or distributed job scheduler.
- Built-in business logic for how to edit tickets, PRs, or comments. (That logic lives in the
  workflow prompt and agent tooling.)
- Mandating strong sandbox controls beyond what the coding agent and host OS provide.
- Mandating a single default approval, sandbox, or operator-confirmation posture for all
  implementations.

## 3. System Overview

### 3.1 Main Components

1. `Workflow Loader`
   - Reads `WORKFLOW.md`.
   - Parses YAML front matter and prompt body.
   - Returns `{config, prompt_template}`.

2. `Config Layer`
   - Exposes typed getters for workflow config values.
   - Applies defaults and environment variable indirection.
   - Performs validation used by the orchestrator before dispatch.

3. `Issue Tracker Client`
   - Fetches candidate issues in active states.
   - Fetches current states for specific issue IDs (reconciliation).
   - Fetches terminal-state issues during startup cleanup.
   - Normalizes tracker payloads into a stable issue model.

4. `Orchestrator`
   - Owns the poll tick.
   - Owns the in-memory runtime state.
   - Decides which issues to dispatch, retry, stop, or release.
   - Tracks session metrics and retry queue state.

5. `Workspace Manager`
   - Maps issue identifiers to workspace paths.
   - Ensures per-issue workspace directories exist.
   - Runs workspace lifecycle hooks.
   - Cleans workspaces for terminal issues.

6. `Agent Runner`
   - Creates workspace.
   - Builds prompt from issue + workflow template.
   - Launches the coding agent app-server client.
   - Streams agent updates back to the orchestrator.

7. `Status Surface` (optional)
   - Presents human-readable runtime status (for example terminal output, dashboard, or other
     operator-facing view).

8. `Logging`
   - Emits structured runtime logs to one or more configured sinks.

### 3.2 Abstraction Levels

Cymphony is easiest to port when kept in these layers:

1. `Policy Layer` (repo-defined)
   - `WORKFLOW.md` prompt body.
   - Team-specific rules for ticket handling, validation, and handoff.

2. `Configuration Layer` (typed getters)
   - Parses front matter into typed runtime settings.
   - Handles defaults, environment tokens, and path normalization.

3. `Coordination Layer` (orchestrator)
   - Polling loop, issue eligibility, concurrency, retries, reconciliation.

4. `Execution Layer` (workspace + agent subprocess)
   - Filesystem lifecycle, workspace preparation, coding-agent protocol.

5. `Integration Layer` (Linear adapter)
   - API calls and normalization for tracker data.

6. `Observability Layer` (logs + optional status surface)
   - Operator visibility into orchestrator and agent behavior.

### 3.3 External Dependencies

- Issue tracker API (Linear for `tracker.kind: linear` in this specification version).
- Local filesystem for workspaces and logs.
- Optional workspace population tooling (for example Git CLI, if used).
- Coding-agent executable that supports JSON-RPC-like app-server mode over stdio.
- Host environment authentication for the issue tracker and coding agent.

## 4. Core Domain Model

### 4.1 Entities

#### 4.1.1 Issue

Normalized issue record used by orchestration, prompt rendering, and observability output.

Fields:

- `id` (string)
  - Stable tracker-internal ID.
- `identifier` (string)
  - Human-readable ticket key (example: `ABC-123`).
- `title` (string)
- `description` (string or null)
- `priority` (integer or null)
  - Lower numbers are higher priority in dispatch sorting.
- `state` (string)
  - Current tracker state name.
- `branch_name` (string or null)
  - Tracker-provided branch metadata if available.
- `url` (string or null)
- `labels` (list of strings)
  - Normalized to lowercase.
- `blocked_by` (list of blocker refs)
  - Each blocker ref contains:
    - `id` (string or null)
    - `identifier` (string or null)
    - `state` (string or null)
- `created_at` (timestamp or null)
- `updated_at` (timestamp or null)

#### 4.1.2 Workflow Definition

Parsed `WORKFLOW.md` payload:

- `config` (map)
  - YAML front matter root object.
- `prompt_template` (string)
  - Markdown body after front matter, trimmed.

#### 4.1.3 Service Config (Typed View)

Typed runtime values derived from `WorkflowDefinition.config` plus environment resolution.

Examples:

- poll interval
- workspace root
- active and terminal issue states
- concurrency limits
- coding-agent executable/args/timeouts
- workspace hooks

#### 4.1.4 Workspace

Filesystem workspace assigned to one issue identifier.

Fields (logical):

- `path` (workspace path; current runtime typically uses absolute paths, but relative roots are
  possible if configured without path separators)
- `workspace_key` (sanitized issue identifier)
- `created_now` (boolean, used to gate `after_create` hook)

#### 4.1.5 Run Attempt

One execution attempt for one issue.

Fields (logical):

- `issue_id`
- `issue_identifier`
- `attempt` (integer or null, `null` for first run, `>=1` for retries/continuation)
- `workspace_path`
- `started_at`
- `status`
- `error` (optional)

#### 4.1.6 Live Session (Agent Session Metadata)

State tracked while a coding-agent subprocess is running.

Fields:

- `session_id` (string, `<thread_id>-<turn_id>`)
- `thread_id` (string)
- `turn_id` (string)
- `claude_app_server_pid` (string or null)
- `last_claude_event` (string/enum or null)
- `last_claude_timestamp` (timestamp or null)
- `last_claude_message` (summarized payload)
- `claude_input_tokens` (integer)
- `claude_output_tokens` (integer)
- `claude_total_tokens` (integer)
- `last_reported_input_tokens` (integer)
- `last_reported_output_tokens` (integer)
- `last_reported_total_tokens` (integer)
- `turn_count` (integer)
  - Number of coding-agent turns started within the current worker lifetime.

#### 4.1.7 Retry Entry

Scheduled retry state for an issue.

Fields:

- `issue_id`
- `identifier` (best-effort human ID for status surfaces/logs)
- `attempt` (integer, 1-based for retry queue)
- `due_at_ms` (monotonic clock timestamp)
- `timer_handle` (runtime-specific timer reference)
- `error` (string or null)

Retry/backoff stays its own list (`retry_attempts`), rendered **below** In Progress. Retrying
issues are not waiting-board members and must not appear on `section.queue-board`.

#### 4.1.8 Orchestrator Runtime State

Single authoritative in-memory state owned by the orchestrator.

Fields:

- `poll_interval_ms` (current effective poll interval)
- `max_concurrent_agents` (current effective global concurrency limit)
- `running` (map `issue_id -> running entry`)
- `claimed` (set of issue IDs reserved/running/retrying)
- `retry_attempts` (map `issue_id -> RetryEntry`)
- `waiting` (ordered list of dispatch-ready `Issue` values; **name this list `waiting`
  everywhere** except UI copy `Up next` / `Queue` / header `Q queued`)
- `queue_order` (list of issue keys — identifier if present else `id`; persisted sticky
  operator order)
- `queue_pins` (map `issue_key -> %{agent_kind?, model?, effort?}`; persisted local pins
  for the next waiting dispatch; no provider)
- `queue_priority_seen` (map `issue_key -> integer | null`; last seen Linear priority,
  used only to detect a Linear **raise**)
- `completed` (set of issue IDs; bookkeeping only, not dispatch gating)
- `claude_totals` (aggregate tokens + runtime seconds)
- `claude_rate_limits` (latest rate-limit snapshot from agent events)

`queue_order`, `queue_pins`, and `queue_priority_seen` persist on the matching
`projects[]` object in `~/.cymphony/config.json` (file mode `0600` via existing
`save/1`). They are **not** WORKFLOW.md front matter and must not be added to
`Config.Schema`. `Orchestrator.init` loads them via `CymphonyConfig.load` /
`find_project`. `CymphonyConfig.update_project_queue/2` merges any of those three
keys onto the named project (`nil` name = legacy flat/all) and `save/1`. Pin maps
omit empty keys. Example:

```json
{
  "queue_order": ["LLM-51", "LLM-12"],
  "queue_pins": {
    "LLM-51": {"agent_kind": "codex", "model": "gpt-5.2-codex", "effort": "high"}
  },
  "queue_priority_seen": {"LLM-51": 2, "LLM-12": 3}
}
```

### 4.2 Stable Identifiers and Normalization Rules

- `Issue ID`
  - Use for tracker lookups and internal map keys.
- `Issue Identifier`
  - Use for human-readable logs and workspace naming.
- `Workspace Key`
  - Derive from `issue.identifier` by replacing any character not in `[A-Za-z0-9._-]` with `_`.
  - Use the sanitized value for the workspace directory name.
- `Normalized Issue State`
  - Compare states after `lowercase`.
- `Session ID`
  - Compose from coding-agent `thread_id` and `turn_id` as `<thread_id>-<turn_id>`.

## 5. Workflow Specification (Repository Contract)

### 5.1 File Discovery and Path Resolution

Workflow file path precedence:

1. Explicit application/runtime setting (set by CLI startup path).
2. Default: `WORKFLOW.md` in the current process working directory.

Loader behavior:

- If the file cannot be read, return `missing_workflow_file` error.
- The workflow file is expected to be repository-owned and version-controlled.

### 5.2 File Format

`WORKFLOW.md` is a Markdown file with optional YAML front matter.

Design note:

- `WORKFLOW.md` should be self-contained enough to describe and run different workflows (prompt,
  runtime settings, hooks, and tracker selection/config) without requiring out-of-band
  service-specific configuration.

Parsing rules:

- If file starts with `---`, parse lines until the next `---` as YAML front matter.
- Remaining lines become the prompt body.
- If front matter is absent, treat the entire file as prompt body and use an empty config map.
- YAML front matter must decode to a map/object; non-map YAML is an error.
- Prompt body is trimmed before use.

Returned workflow object:

- `config`: front matter root object (not nested under a `config` key).
- `prompt_template`: trimmed Markdown body.

### 5.3 Front Matter Schema

Top-level keys:

- `tracker`
- `polling`
- `workspace`
- `hooks`
- `agent`
- `claude`
- `codex`
- `antigravity`

Unknown keys should be ignored for forward compatibility.

Note:

- The workflow front matter is extensible. Optional extensions may define additional top-level keys
  (for example `server`) without changing the core schema above.
- Extensions should document their field schema, defaults, validation rules, and whether changes
  apply dynamically or require restart.
- Common extension: `server.port` (integer) enables the optional HTTP server described in Section
  13.7.

#### 5.3.1 `tracker` (object)

Fields:

- `kind` (string)
  - Required for dispatch.
  - Current supported value: `linear`
- `endpoint` (string)
  - Default for `tracker.kind == "linear"`: `https://api.linear.app/graphql`
- `api_key` (string)
  - May be a literal token or `$VAR_NAME`.
  - Durable operator store for Linear credentials is `~/.cymphony/config.json`:
    top-level `linear_api_key`, also stamped onto every `projects[].linear_api_key`
    (a shared key on the project map; **not** a Symphony `tracker.provider` nest).
  - Generated per-project `WORKFLOW.md` files write that value as `tracker.api_key`.
  - Resolution when building runtime config: non-empty `config.json` `linear_api_key`,
    else the first project's non-empty `linear_api_key`, else process env
    `LINEAR_API_KEY`. The env var is a fallback only (`Schema.finalize_settings/1`);
    dashboard Connect and `POST /api/v1/linear` persist the durable file key.
  - If `$VAR_NAME` resolves to an empty string, treat the key as missing.
- `project_slug` (string)
  - Required for dispatch when `tracker.kind == "linear"`.
- `active_states` (list of strings)
  - Default: `Todo`, `In Progress`
- `terminal_states` (list of strings)
  - Default: `Closed`, `Cancelled`, `Canceled`, `Duplicate`, `Done`

#### 5.3.2 `polling` (object)

Fields:

- `interval_ms` (integer or string integer)
  - Default: `30000`
  - Changes should be re-applied at runtime and affect future tick scheduling without restart.

#### 5.3.3 `workspace` (object)

Fields:

- `root` (path string or `$VAR`)
  - Default: `<system-temp>/cymphony_workspaces`
  - `~` and strings containing path separators are expanded.
  - Bare strings without path separators are preserved as-is (relative roots are allowed but
    discouraged).

#### 5.3.4 `hooks` (object)

Fields:

- `after_create` (multiline shell script string, optional)
  - Runs only when a workspace directory is newly created.
  - Failure aborts workspace creation.
- `before_run` (multiline shell script string, optional)
  - Runs before each agent attempt after workspace preparation and before launching the coding
    agent.
  - Failure aborts the current attempt.
- `after_run` (multiline shell script string, optional)
  - Runs after each agent attempt (success, failure, timeout, or cancellation) once the workspace
    exists.
  - Failure is logged but ignored.
- `before_remove` (multiline shell script string, optional)
  - Runs before workspace deletion if the directory exists.
  - Failure is logged but ignored; cleanup still proceeds.
- `timeout_ms` (integer, optional)
  - Default: `60000`
  - Applies to all workspace hooks.
  - Non-positive values should be treated as invalid and fall back to the default.
  - Changes should be re-applied at runtime for future hook executions.

#### 5.3.5 `agent` (object)

Agent-neutral settings shared by every coding-agent backend.

Fields:

- `kind` (string, `"claude"` | `"codex"` | `"antigravity"`)
  - Default: `"claude"`
  - Selects the coding-agent CLI adapter used for dispatched sessions.
  - Unknown values are a validation error.
- `model` (string or null)
  - Default: null (the agent CLI's own default model).
  - Passed through to the agent CLI verbatim (`--model` for Claude Code and
    Antigravity, `-m` for Codex).
  - Not validated against a model list; invalid values surface as run failures.
- `effort` (string or null)
  - Default: null (the agent CLI's own default effort).
  - Passed through verbatim (`--effort` for Claude Code and Antigravity,
    `-c model_reasoning_effort=…` for Codex).
- `max_concurrent_agents` (integer or string integer)
  - Default: `10`
  - Changes should be re-applied at runtime and affect subsequent dispatch decisions.
- `max_retry_backoff_ms` (integer or string integer)
  - Default: `300000` (5 minutes)
  - Changes should be re-applied at runtime and affect future retry scheduling.
- `max_concurrent_agents_by_state` (map `state_name -> positive integer`)
  - Default: empty map.
  - State keys are normalized (`lowercase`) for lookup.
  - Invalid entries (non-positive or non-numeric) are ignored.
- `turn_timeout_ms` (integer)
  - Default: `3600000` (1 hour)
  - Maximum wall-clock time for one agent turn, regardless of agent kind.
- `stall_timeout_ms` (integer)
  - Default: `300000` (5 minutes)
  - If `<= 0`, stall detection is disabled.

#### 5.3.6 `claude` (object)

Claude Code CLI-specific settings. Only consulted when `agent.kind` is `"claude"`.

For Claude Code-owned config values such as `permission_mode` and `allowed_tools`, supported
values are defined by the targeted Claude Code CLI version; treat them as pass-through.

- `command` (string shell command)
  - Default: `claude`
  - Launched per turn as `claude --bare -p <prompt> …` with `--resume <session_id>` on
    continuation turns.
- `permission_mode` (Claude Code permission mode value)
  - Default: `acceptEdits`.
- `allowed_tools` (comma-separated string)
  - Default: `Bash,Read,Edit`.
- `output_format` (string, `text` | `json` | `stream-json`)
  - Default: `stream-json`.
- `fallback_model` (string or null)
  - Default: null. Passed as `--fallback-model`.
- `max_turns` (integer or null)
  - Default: null. Claude CLI's internal turn cap (`--max-turns`), distinct from the
    orchestrator-level `agent.max_turns` continuation loop.
- `max_budget_usd` (decimal or null)
  - Default: null. Passed as `--max-budget-usd`.
- `bare_mode` (boolean)
  - Default: true. Passed as `--bare`.
- `provider` / `providers` (string / list of strings)
  - Auth aliases resolved via shell functions or the config `providers` map; see Section 6.
  - Provider env capture keeps `ANTHROPIC_*`, `CLAUDE_CODE_*`, and `API_TIMEOUT` variables.

#### 5.3.7 `codex` (object)

Codex CLI-specific settings. Only consulted when `agent.kind` is `"codex"`.

- `command` (string shell command)
  - Default: `codex`
  - Launched per turn as `codex exec --json --skip-git-repo-check …`; continuation turns use
    `codex exec resume <session_id> …`.
- `sandbox` (string, `read-only` | `workspace-write` | `danger-full-access`)
  - Default: `workspace-write`.
  - Always passed as `-c sandbox_mode="<value>"` (the `-s` shorthand is not accepted by
    `codex exec resume`).
- `network_access` (boolean)
  - Default: true.
  - When true with the `workspace-write` sandbox, passes
    `-c sandbox_workspace_write.network_access=true`.
- `provider` / `providers` (string / list of strings)
  - Auth aliases, as for Claude, but env capture keeps `OPENAI_*`, `CODEX_*`, and
    `API_TIMEOUT` variables.

Completion conditions for a Codex turn: a `turn.completed` JSONL event is success; a
`turn.failed` event, missing terminal event, nonzero process exit, or turn timeout is failure.
Session identifiers come from the `thread.started` event's `thread_id`. If `thread.started` is
missing, a later event's `thread_id` is accepted. A `turn.completed` event with no
`item.completed` agent message is still success (`result` may be null). Non-JSON and blank
lines (including mixed stderr noise on the merged stream) are ignored.

#### 5.3.8 `antigravity` (object)

Antigravity CLI-specific settings (Google Antigravity / `agy`, successor to Gemini CLI).
Only consulted when `agent.kind` is `"antigravity"`.

The binary is `run_spec.command || settings.command || "agy"` (empty string falls through,
same rule as Codex). `ANTIGRAVITY_CLI_BIN` / `AGY_CLI_BIN` are not read; operators override
via `antigravity.command`.

Headless invocation: `agy -p <prompt>` (`-p` aliases `--print` / `--prompt`). stdout is the
result; stderr is diagnostics. The runner merges stderr into stdout (`:stderr_to_stdout`) so
both land in the same line stream.

Fields:

- `command` (string shell command)
  - Default: `agy`
  - Required. Override the Antigravity CLI binary.
- `output_format` (string, `text` | `json` | `stream-json`)
  - Default: `stream-json`.
  - Passed as `--output-format`.
- `extra_args` (string or null)
  - Default: null.
  - Trusted operator input. A non-empty string is appended unescaped as a trailing
    fragment. A list of binaries is escaped item-by-item and appended.
- `skip_permissions` (boolean)
  - Default: `true`.
  - When true, passes `--dangerously-skip-permissions` (same spirit as Claude
    `acceptEdits`).
- `sandbox` (boolean)
  - Default: `false`.
  - When true, passes `--sandbox`.
- `print_timeout` (string or null)
  - Default: null.
  - When a non-empty string, passed as `--print-timeout <value>`. Do not auto-wire
    `agent.turn_timeout_ms` to `--print-timeout`.
- `provider` / `providers` (string / list of strings)
  - Auth aliases, as for Claude/Codex. Env capture keeps `ANTIGRAVITY_*`, `GOOGLE_*`,
    `GEMINI_*`, and `API_TIMEOUT` variables. Fallback keys: `GOOGLE_API_KEY`,
    `GEMINI_API_KEY`.

Argv (space-joined; prompt, session id, model, and effort are shell-escaped):

```text
<cmd> -p <escaped prompt> --output-format <output_format>
  [--model <escaped model>]          when model is a non-empty binary
  [--effort <escaped effort>]        when effort is a non-empty binary
  [--conversation <escaped id>]      when session_id is a non-empty binary
  [--dangerously-skip-permissions]   when skip_permissions is true
  [--sandbox]                        when sandbox is true
  [--print-timeout <print_timeout>]  when print_timeout is a non-empty binary
  <extra_args fragment>
```

Resume uses `--conversation <conversation_id>` only. Never emit `-c` / `--continue`
(those resume the last session in cwd and would cross-pollute issues). Do not emit
`--resume`. Do not invent MCP flags (`--mcp-config` is not in the official headless
table); operators may pass extras via `extra_args`.

Output parse contract:

- `stream-json` (NDJSON): decode each line; emit `%{event: :stream_event, payload, raw, timestamp}`
  for every decoded map. Fold:
  - `event=="init"` → `session_id = conversation_id` (top-level or `init.conversation_id`)
  - `event=="step_update"` → append `step_update.text_delta` (binaries only) onto
    `last_message`; keep the latest `step_update.usage` map
  - `event=="result"` → take `result` (or the event itself); `session_id` from
    `conversation_id`; `result_text` from `response`; `usage` from `usage`; `status`
    from `status`
  - After fold: if a completed map has `status` present and `status != "SUCCESS"` →
    `{:error, {:turn_failed, error}}`; if a completed map is present →
    `{:ok, %{session_id, result, usage, raw}}`; else
    `{:error, {:no_result_in_stream, joined}}`.
- `json`: last trimmed line that starts with `{` and ends with `}` (same find-last-json
  as Claude). Decode. `status` present and not `SUCCESS` → `{:error, {:turn_failed, error}}`;
  else `{:ok, %{session_id: conversation_id, result: response, usage, raw}}`. Errors:
  `{:no_json_output, joined}`, `{:json_decode_failed, err, line}`. The json path emits
  no `:stream_event`.
- `text` (anything else): `{:ok, %{session_id: nil, result: joined, usage: nil, raw: joined}}`.

`json` envelope fields: `conversation_id`, `status`
(`SUCCESS|ERROR|CANCELED|INTERRUPTED|INVALID|WAITING|RUNNING`), `response`, `error?`,
`duration_seconds`, `num_turns`, `usage:{input_tokens,output_tokens,thinking_tokens,cache_read_tokens,total_tokens}`.

Normalized usage keeps only `input_tokens`, `output_tokens`, and `total_tokens`
(integer-or-zero). Missing `total_tokens` is `input + output`. `thinking_tokens` and
cache fields are dropped from the normalized map. Non-JSON lines are ignored and do
not fail the turn. An unknown `--model` slug exits nonzero with `status ERROR`.
Invalid `--effort` (not `low|medium|high`) fails the run.

### 5.4 Prompt Template Contract

The Markdown body of `WORKFLOW.md` is the per-issue prompt template.

Rendering requirements:

- Use a strict template engine (Liquid-compatible semantics are sufficient).
- Unknown variables must fail rendering.
- Unknown filters must fail rendering.

Template input variables:

- `issue` (object)
  - Includes all normalized issue fields, including labels and blockers.
- `attempt` (integer or null)
  - `null`/absent on first attempt.
  - Integer on retry or continuation run.

Fallback prompt behavior:

- If the workflow prompt body is empty, the runtime may use a minimal default prompt
  (`You are working on an issue from Linear.`).
- Workflow file read/parse failures are configuration/validation errors and should not silently fall
  back to a prompt.

### 5.5 Workflow Validation and Error Surface

Error classes:

- `missing_workflow_file`
- `workflow_parse_error`
- `workflow_front_matter_not_a_map`
- `template_parse_error` (during prompt rendering)
- `template_render_error` (unknown variable/filter, invalid interpolation)

Dispatch gating behavior:

- Workflow file read/YAML errors block new dispatches until fixed.
- Template errors fail only the affected run attempt.

## 6. Configuration Specification

### 6.1 Source Precedence and Resolution Semantics

Configuration precedence:

1. Workflow file path selection (runtime setting -> cwd default).
2. YAML front matter values.
3. Environment indirection via `$VAR_NAME` inside selected YAML values.
4. Built-in defaults.

Value coercion semantics:

- Path/command fields support:
  - `~` home expansion
  - `$VAR` expansion for env-backed path values
  - Apply expansion only to values intended to be local filesystem paths; do not rewrite URIs or
    arbitrary shell command strings.

### 6.2 Dynamic Reload Semantics

Dynamic reload is required:

- The software should watch `WORKFLOW.md` for changes.
- On change, it should re-read and re-apply workflow config and prompt template without restart.
- The software should attempt to adjust live behavior to the new config (for example polling
  cadence, concurrency limits, active/terminal states, claude settings, workspace paths/hooks, and
  prompt content for future runs).
- Reloaded config applies to future dispatch, retry scheduling, reconciliation decisions, hook
  execution, and agent launches.
- Implementations are not required to restart in-flight agent sessions automatically when config
  changes.
- Extensions that manage their own listeners/resources (for example an HTTP server port change) may
  require restart unless the implementation explicitly supports live rebind.
- Implementations should also re-validate/reload defensively during runtime operations (for example
  before dispatch) in case filesystem watch events are missed.
- Invalid reloads should not crash the service; keep operating with the last known good effective
  configuration and emit an operator-visible error.

### 6.3 Dispatch Preflight Validation

This validation is a scheduler preflight run before attempting to dispatch new work. It validates
the workflow/config needed to poll and launch workers, not a full audit of all possible workflow
behavior.

Startup validation:

- Validate configuration before starting the scheduling loop.
- If startup validation fails, fail startup and emit an operator-visible error.

Per-tick dispatch validation:

- Re-validate before each dispatch cycle.
- If validation fails, skip dispatch for that tick, keep reconciliation active, and emit an
  operator-visible error.

Validation checks:

- Workflow file can be loaded and parsed.
- `tracker.kind` is present and supported.
- `tracker.api_key` is present after `$` resolution.
- `tracker.project_slug` is present when required by the selected tracker kind.
- `claude.command` is present and non-empty.

### 6.4 Config Fields Summary (Cheat Sheet)

This section is intentionally redundant so a coding agent can implement the config layer quickly.

- `tracker.kind`: string, required, currently `linear`
- `tracker.endpoint`: string, default `https://api.linear.app/graphql` when `tracker.kind=linear`
- `tracker.api_key`: string or `$VAR`; durable source is `~/.cymphony/config.json`
  `linear_api_key` (generated into this field). `LINEAR_API_KEY` is env fallback
  only when the file has no non-empty key (`tracker.kind=linear`)
- `tracker.project_slug`: string, required when `tracker.kind=linear`
- `tracker.active_states`: list of strings, default `["Todo", "In Progress"]`
- `tracker.terminal_states`: list of strings, default `["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]`
- `polling.interval_ms`: integer, default `30000`
- `workspace.root`: path, default `<system-temp>/cymphony_workspaces`
- `worker.ssh_hosts` (extension): list of SSH host strings, optional; when omitted, work runs
  locally
- `worker.max_concurrent_agents_per_host` (extension): positive integer, optional; shared per-host
  cap applied across configured SSH hosts
- `hooks.after_create`: shell script or null
- `hooks.before_run`: shell script or null
- `hooks.after_run`: shell script or null
- `hooks.before_remove`: shell script or null
- `hooks.timeout_ms`: integer, default `60000`
- `agent.kind`: string, `claude` | `codex` | `antigravity`, default `claude`
- `agent.max_concurrent_agents`: integer, default `10`
- `agent.max_turns`: integer, default `20`
- `agent.max_retry_backoff_ms`: integer, default `300000` (5m)
- `agent.max_concurrent_agents_by_state`: map of positive integers, default `{}`
- `claude.command`: shell command string, default `claude`
- `claude.approval_policy`: Claude Code approval policy value, default implementation-defined
- `claude.permission_mode`: Claude Code permission mode value, default implementation-defined
- `claude.allowed_tools`: list of strings, default implementation-defined
- `claude.turn_timeout_ms`: integer, default `3600000`
- `claude.read_timeout_ms`: integer, default `5000`
- `claude.stall_timeout_ms`: integer, default `300000`
- `antigravity.command`: shell command string, default `agy`
- `antigravity.output_format`: `text` | `json` | `stream-json`, default `stream-json`
- `antigravity.extra_args`: string or null
- `antigravity.skip_permissions`: boolean, default `true`
- `antigravity.sandbox`: boolean, default `false`
- `antigravity.print_timeout`: string or null
- `antigravity.provider` / `antigravity.providers`: string / list of strings
- `server.port` (extension): integer, optional; enables the optional HTTP server, `0` may be used
  for ephemeral local bind, and CLI `--port` overrides it

## 7. Orchestration State Machine

The orchestrator is the only component that mutates scheduling state. All worker outcomes are
reported back to it and converted into explicit state transitions.

### 7.1 Issue Orchestration States

This is not the same as tracker states (`Todo`, `In Progress`, etc.). This is the service's internal
claim state.

1. `Unclaimed`
   - Issue is not running and has no retry scheduled.

2. `Claimed`
   - Orchestrator has reserved the issue to prevent duplicate dispatch.
   - In practice, claimed issues are either `Running` or `RetryQueued`.

3. `Running`
   - Worker task exists and the issue is tracked in `running` map.

4. `RetryQueued`
   - Worker is not running, but a retry timer exists in `retry_attempts`.

5. `Released`
   - Claim removed because issue is terminal, non-active, missing, or retry path completed without
     re-dispatch.

Important nuance:

- A successful worker exit does not mean the issue is done forever.
- The worker may continue through multiple back-to-back coding-agent turns before it exits.
- After each normal turn completion, the worker re-checks the tracker issue state.
- If the issue is still in an active state, the worker should start another turn on the same live
  coding-agent thread in the same workspace, up to `agent.max_turns`.
- The first turn should use the full rendered task prompt.
- Continuation turns should send only continuation guidance to the existing thread, not resend the
  original task prompt that is already present in thread history.
- Once the worker exits normally, the orchestrator still schedules a short continuation retry
  (about 1 second) so it can re-check whether the issue remains active and needs another worker
  session.

### 7.2 Run Attempt Lifecycle

A run attempt transitions through these phases:

1. `PreparingWorkspace`
2. `BuildingPrompt`
3. `LaunchingAgentProcess`
4. `InitializingSession`
5. `StreamingTurn`
6. `Finishing`
7. `Succeeded`
8. `Failed`
9. `TimedOut`
10. `Stalled`
11. `CanceledByReconciliation`

Distinct terminal reasons are important because retry logic and logs differ.

### 7.3 Transition Triggers

- `Poll Tick`
  - Reconcile active runs.
  - Validate config.
  - Fetch candidate issues.
  - Dispatch until slots are exhausted.

- `Worker Exit (normal)`
  - Remove running entry.
  - Update aggregate runtime totals.
  - Schedule continuation retry (attempt `1`) after the worker exhausts or finishes its in-process
    turn loop.

- `Worker Exit (abnormal)`
  - Remove running entry.
  - Update aggregate runtime totals.
  - Schedule exponential-backoff retry.

- `Claude Update Event`
  - Update live session fields, token counters, and rate limits.

- `Retry Timer Fired`
  - Re-fetch active candidates and attempt re-dispatch, or release claim if no longer eligible.

- `Reconciliation State Refresh`
  - Stop runs whose issue states are terminal or no longer active.

- `Stall Timeout`
  - Kill worker and schedule retry.

### 7.4 Idempotency and Recovery Rules

- The orchestrator serializes state mutations through one authority to avoid duplicate dispatch.
- `claimed` and `running` checks are required before launching any worker.
- Reconciliation runs before dispatch on every tick.
- Restart recovery is tracker-driven and filesystem-driven (no durable orchestrator DB required).
- Startup terminal cleanup removes stale workspaces for issues already in terminal states.

## 8. Polling, Scheduling, and Reconciliation

### 8.1 Poll Loop

At startup, the service validates config, performs startup cleanup, schedules an immediate tick, and
then repeats every `polling.interval_ms`.

The effective poll interval should be updated when workflow config changes are re-applied.

Tick sequence:

1. Reconcile running issues.
2. Run dispatch preflight validation.
3. Fetch candidate issues from the tracker using active states (always fetch,
   including when paused and when `available_slots == 0`). Fetch or config
   errors keep last `waiting`.
4. After a successful fetch, filter waiting-eligible issues and run
   `Queue.reconcile` (sticky operator order). Assign `State.waiting`. Do not
   claim waiting ids. Do not re-sort via `Dispatch.sort_for_dispatch` once a
   saved or reconciled order exists. Canceled / no-longer-eligible cards drop
   off; newly Todo issues appear. Dashboard Refresh uses this same path.
5. When **not** paused, dispatch from the **leftmost** waiting card while
   global slots remain (Section 8.2). Skip a head only when per-state or
   per-host slots are full. Paused ticks refresh `waiting` and must not spawn.
6. Notify observability/status consumers of state changes.

If per-tick validation fails, dispatch is skipped for that tick, but reconciliation still happens
first.

### 8.2 Candidate Selection Rules

Waiting-board membership and dispatch order are **sticky operator order**, not a per-tick
re-sort. `Dispatch.sort_for_dispatch/1` is **INITIAL ORDER only** (no saved `queue_order`
yet). Subsequent ticks use `Queue.reconcile`. Do not write Cymphony ranks or queue order
back to Linear (no Linear GraphQL writes).

Cymphony rank is the left-to-right then wrap (row-major) index on the board: `0` = next
slot after a running session finishes, larger = later. This rank is **not** Linear
priority. Linear priority numbers are `1` = Urgent, `2` = High, `3` = Medium, `4` = Low,
`0` / `nil` = none.

#### Waiting membership

An issue is waiting-eligible (dispatch-ready, not currently running) only if all are true:

- It has `id`, `identifier`, `title`, and `state` (`candidate_issue?`).
- Its state is in `active_states` and not in `terminal_states`.
- It is not already in `running`.
- It is not already in `claimed`.
- It is not in `retry_attempts` (retry/backoff stays its own list **below** In Progress;
  Section 8.4).
- Blocker rule for `Todo` state passes:
  - If the issue state is `Todo`, do not include it when any blocker is non-terminal.

Do not put Backlog, canceled, or blocked issues on the board. Hide the board when
`waiting` is empty (no empty columns). Do not claim waiting ids.

Global / per-state / per-host slot checks are **not** membership filters; they apply when
walking `waiting` to dispatch (below).

#### INITIAL ORDER (no saved order yet)

No saved order means `queue_order` is missing or never written (`nil`). Treat `[]` after a
prior persist as **empty-saved** (every eligible arrival is NEW).

First reconcile with no saved order:

1. `order = Dispatch.sort_for_dispatch(eligible)`
   - Linear `priority` ascending (`1..4` preferred; `0` / `nil` / unknown sort last)
   - then oldest `created_at`
   - then `identifier` lexicographic tie-breaker
2. Seed `queue_priority_seen` from current priorities.
3. Persist that `queue_order`.

`choose_issues` must not re-sort via `Dispatch.sort_for_dispatch` once a saved or
reconciled order exists.

#### Sticky reconcile (`Queue.reconcile`)

`issue_key` = `identifier` if present else `id`.
`linear_rank(p)` = `p` when `p` in `1..4`, else `5` (none). Both sides of a raise
comparison use `linear_rank`, so `0`/`nil` → `2` is a raise.

On subsequent ticks:

1. Drop keys that left the eligible set. Keep saved relative order for remaining keys.
2. **LINEAR RAISE** — for each remaining key whose
   `linear_rank(current) < linear_rank(priority_seen[key])`, re-insert **that one card
   only** (do not reshuffle cards whose Linear priority did not change):
   - Urgent (`1`) at index `0` (far left)
   - High (`2`) before the first remaining card with `linear_rank > 2`
   - Medium (`3`) before the first remaining card with `linear_rank > 3`
   - Low (`4`) before the first remaining card with `linear_rank > 4`
3. **LINEAR LOWER** (rank increases or stays equal) never moves the card. A High → Low
   change after a drag does not move the card.
4. **NEW** keys (not in saved `queue_order`) append at the right, unless Linear
   `priority == 1` (Urgent), which inserts at index `0`.
5. After reconcile, persist `queue_order` + `queue_priority_seen` if either changed.

**DRAG:** the operator permutes the waiting list. Persist the full identifier/id order
per project. Drag wins until **that** issue's Linear priority changes (a raise re-inserts
that card only). Persist across daemon restart.

#### Dispatch consumes leftmost waiting

`maybe_dispatch` always fetches (including when paused and when `available_slots == 0`). After
a successful fetch, filter eligible, `Queue.reconcile`, assign `State.waiting`. When not
paused, walk leftmost:

- If global slots are `0`, stop dispatching (keep remaining `waiting`).
- If the head fails **only** `state_slots_available?` or `worker_slots_available?`, skip
  that card (leave it on `waiting`) and try the next.
- If `should_dispatch`, spawn (claim only then) and drop the card from `waiting`.

Paused ticks still fetch and rebuild `waiting`, but must not spawn. Fetch/config errors keep last
`waiting`. Next free slot starts the leftmost waiting card.

#### Per-issue run spec resolution

At dispatch time, the orchestrator resolves the session's agent kind, model, reasoning effort,
and (optionally) provider for the issue. Field-level precedence, highest first:

1. **Queue pin** — persisted `queue_pins[issue_key]` `agent_kind` / `model` / `effort`
   (no provider). Overlay in orchestrator `dispatch_run_spec/3`; do **not** change
   `RunSpecResolver`. Pins apply when the issue is dispatched **from the waiting list**.
   Empty / `"keep"` omits the field. Deleting all three fields removes that pin entry.
   Unknown `agent_kind` is ignored (same as labels). Card Edit persists the pin and must
   **not** kill anything (the issue is not running).
2. **Linear labels** — `agent:<kind>`, `model:<name>`, `effort:<level>`, `provider:<alias>`.
   Labels arrive downcased from the tracker adapter. Duplicate prefixes pick the sorted-first
   value with a warning; empty values are ignored.
3. **Description directive** — the first line in the issue description of the form
   `cymphony: key=value key=value …` with keys in `agent|model|effort|provider`. Values match
   `[A-Za-z0-9._/-]+`; `agent`/`effort` values are lowercased. Unknown keys are ignored.
4. **Project config** — `agent.kind`, `agent.model`, `agent.effort`; provider comes from the
   active kind's rotation (Section 8.3).

Precedence is **pin > labels > directive > config**.

Rules:

- `agent` must be a known kind; unknown kinds log a warning and fall through to the next
  source (never fail dispatch). `model`/`effort`/`provider` are pass-through.
- The resolved spec is **pinned for the whole run attempt**: multi-turn resume never
  re-resolves, so an agent-kind switch mid-session is impossible.
- Retries re-resolve from the freshly polled issue (plus any still-persisted queue pin),
  so label edits take effect on the next attempt.
- An explicit issue-level `provider` bypasses rotation for that issue. When a label switches
  the agent kind away from the project default, the provider falls back to that kind's
  configured `provider` (rotation lists are per-kind). Queue pins never set provider.
- The dispatch log line records `agent=… model=… effort=… source=pin|labels|directive|config`.
- Known kinds include `claude`, `codex`, and `antigravity`. Labels such as
  `agent:antigravity` and a description directive `cymphony: agent=antigravity`
  are valid once `agent.kind` accepts that union.
- Dashboard/API `set_issue_run_spec` may pin `:provider`, `:model`, `:effort`,
  and `:agent_kind` (all optional; empty / `"keep"` skips). A restart kills the
  running session and redispatches with those overrides for the next attempt. It
  does **not** write `queue_pins`. When an issue is dispatched from `waiting`, a
  queue pin wins over Keyword overrides from `set_issue_run_spec`.

### 8.3 Concurrency Control

Global limit:

- `available_slots = max(max_concurrent_agents - running_count, 0)`

Per-state limit:

- `max_concurrent_agents_by_state[state]` if present (state key normalized)
- otherwise fallback to global limit

The runtime counts issues by their current tracked state in the `running` map.

Optional SSH host limit:

- When `worker.max_concurrent_agents_per_host` is set, each configured SSH host may run at most
  that many concurrent agents at once.
- Hosts at that cap are skipped for new dispatch until capacity frees up.

### 8.4 Retry and Backoff

Retry/backoff remains a **separate** list below In Progress. Do not put `retry_attempts`
entries on the waiting board (`section.queue-board`). Board membership excludes
`retry_attempts` (Section 8.2).

Retry entry creation:

- Cancel any existing retry timer for the same issue.
- Store `attempt`, `identifier`, `error`, `due_at_ms`, and new timer handle.

Backoff formula:

- Normal continuation retries after a clean worker exit use a short fixed delay of `1000` ms.
- Failure-driven retries use `delay = min(10000 * 2^(attempt - 1), agent.max_retry_backoff_ms)`.
- Power is capped by the configured max retry backoff (default `300000` / 5m).

Retry handling behavior:

1. Fetch active candidate issues (not all issues).
2. Find the specific issue by `issue_id`.
3. If not found, release claim.
4. If found and still candidate-eligible:
   - Dispatch if slots are available.
   - Otherwise requeue with error `no available orchestrator slots`.
5. If found but no longer active, release claim.

Note:

- Terminal-state workspace cleanup is handled by startup cleanup and active-run reconciliation
  (including terminal transitions for currently running issues).
- Retry handling mainly operates on active candidates and releases claims when the issue is absent,
  rather than performing terminal cleanup itself.

### 8.5 Active Run Reconciliation

Reconciliation runs every tick and has two parts.

Part A: Stall detection

- For each running issue, compute `elapsed_ms` since:
  - `last_claude_timestamp` if any event has been seen, else
  - `started_at`
- If `elapsed_ms > claude.stall_timeout_ms`, terminate the worker and queue a retry.
- If `stall_timeout_ms <= 0`, skip stall detection entirely.

Part B: Tracker state refresh

- Fetch current issue states for all running issue IDs.
- For each running issue:
  - If tracker state is terminal: terminate worker and clean workspace.
  - If tracker state is still active: update the in-memory issue snapshot.
  - If tracker state is neither active nor terminal: terminate worker without workspace cleanup.
- If state refresh fails, keep workers running and try again on the next tick.

### 8.6 Startup Terminal Workspace Cleanup

When the service starts:

1. Query tracker for issues in terminal states.
2. For each returned issue identifier, remove the corresponding workspace directory.
3. If the terminal-issues fetch fails, log a warning and continue startup.

This prevents stale terminal workspaces from accumulating after restarts.

## 9. Workspace Management and Safety

### 9.1 Workspace Layout

Workspace root:

- `workspace.root` (normalized path; the current config layer expands path-like values and preserves
  bare relative names)

Per-issue workspace path:

- `<workspace.root>/<sanitized_issue_identifier>`

Workspace persistence:

- Workspaces are reused across runs for the same issue.
- Successful runs do not auto-delete workspaces.

### 9.2 Workspace Creation and Reuse

Input: `issue.identifier`

Algorithm summary:

1. Sanitize identifier to `workspace_key`.
2. Compute workspace path under workspace root.
3. Ensure the workspace path exists as a directory.
4. Mark `created_now=true` only if the directory was created during this call; otherwise
   `created_now=false`.
5. If `created_now=true`, run `after_create` hook if configured.

Notes:

- This section does not assume any specific repository/VCS workflow.
- Workspace preparation beyond directory creation (for example dependency bootstrap, checkout/sync,
  code generation) is implementation-defined and is typically handled via hooks.

### 9.3 Optional Workspace Population (Implementation-Defined)

The spec does not require any built-in VCS or repository bootstrap behavior.

Implementations may populate or synchronize the workspace using implementation-defined logic and/or
hooks (for example `after_create` and/or `before_run`).

Failure handling:

- Workspace population/synchronization failures return an error for the current attempt.
- If failure happens while creating a brand-new workspace, implementations may remove the partially
  prepared directory.
- Reused workspaces should not be destructively reset on population failure unless that policy is
  explicitly chosen and documented.

### 9.4 Workspace Hooks

Supported hooks:

- `hooks.after_create`
- `hooks.before_run`
- `hooks.after_run`
- `hooks.before_remove`

Execution contract:

- Execute in a local shell context appropriate to the host OS, with the workspace directory as
  `cwd`.
- On POSIX systems, `sh -lc <script>` (or a stricter equivalent such as `bash -lc <script>`) is a
  conforming default.
- Hook timeout uses `hooks.timeout_ms`; default: `60000 ms`.
- Log hook start, failures, and timeouts.

Failure semantics:

- `after_create` failure or timeout is fatal to workspace creation.
- `before_run` failure or timeout is fatal to the current run attempt.
- `after_run` failure or timeout is logged and ignored.
- `before_remove` failure or timeout is logged and ignored.

### 9.5 Safety Invariants

This is the most important portability constraint.

Invariant 1: Run the coding agent only in the per-issue workspace path.

- Before launching the coding-agent subprocess, validate:
  - `cwd == workspace_path`

Invariant 2: Workspace path must stay inside workspace root.

- Normalize both paths to absolute.
- Require `workspace_path` to have `workspace_root` as a prefix directory.
- Reject any path outside the workspace root.

Invariant 3: Workspace key is sanitized.

- Only `[A-Za-z0-9._-]` allowed in workspace directory names.
- Replace all other characters with `_`.

## 10. Agent Runner Protocol (Coding Agent Integration)

This section defines the language-neutral contract for integrating a coding agent app-server.

Compatibility profile:

- The normative contract is message ordering, required behaviors, and the logical fields that must
  be extracted (for example session IDs, completion state, approval handling, and usage/rate-limit
  telemetry).
- Exact JSON field names may vary slightly across compatible app-server versions.
- Implementations should tolerate equivalent payload shapes when they carry the same logical
  meaning, especially for nested IDs, approval requests, user-input-required signals, and
  token/rate-limit metadata.

### 10.1 Launch Contract

Subprocess launch parameters:

- Command: `claude.command`
- Invocation: `bash -lc <claude.command>`
- Working directory: workspace path
- Stdout/stderr: separate streams
- Framing: line-delimited protocol messages on stdout (JSON-RPC-like JSON per line)

Notes:

- The default command is `claude`.
- Approval policy, cwd, and prompt are expressed in the protocol messages in Section 10.2.

Recommended additional process settings:

- Max line size: 10 MB (for safe buffering)

### 10.2 Session Startup Handshake

The client must send these protocol messages in order:

Illustrative startup transcript (equivalent payload shapes are acceptable if they preserve the same
semantics):

```json
{"id":1,"method":"initialize","params":{"clientInfo":{"name":"cymphony","version":"1.0"},"capabilities":{}}}
{"method":"initialized","params":{}}
{"id":2,"method":"thread/start","params":{"approvalPolicy":"<implementation-defined>","sandbox":"<implementation-defined>","cwd":"/abs/workspace"}}
{"id":3,"method":"turn/start","params":{"threadId":"<thread-id>","input":[{"type":"text","text":"<rendered prompt-or-continuation-guidance>"}],"cwd":"/abs/workspace","title":"ABC-123: Example","approvalPolicy":"<implementation-defined>","sandboxPolicy":{"type":"<implementation-defined>"}}}
```

1. `initialize` request
   - Params include:
     - `clientInfo` object (for example `{name, version}`)
     - `capabilities` object (may be empty)
   - If the targeted Claude Code app-server requires capability negotiation for dynamic tools, include the
     necessary capability flag(s) here.
   - Wait for response (`read_timeout_ms`)
2. `initialized` notification
3. `thread/start` request
   - Params include:
     - `approvalPolicy` = implementation-defined session approval policy value
     - `sandbox` = implementation-defined session sandbox value
     - `cwd` = absolute workspace path
     - If optional client-side tools are implemented, include their advertised tool specs using the
       protocol mechanism supported by the targeted Claude Code app-server version.
4. `turn/start` request
   - Params include:
     - `threadId`
     - `input` = single text item containing rendered prompt for the first turn, or continuation
       guidance for later turns on the same thread
     - `cwd`
     - `title` = `<issue.identifier>: <issue.title>`
     - `approvalPolicy` = implementation-defined turn approval policy value
     - `sandboxPolicy` = implementation-defined object-form sandbox policy payload when required by
       the targeted Claude Code app-server version

Session identifiers:

- Read `thread_id` from `thread/start` result `result.thread.id`
- Read `turn_id` from each `turn/start` result `result.turn.id`
- Emit `session_id = "<thread_id>-<turn_id>"`
- Reuse the same `thread_id` for all continuation turns inside one worker run

### 10.3 Streaming Turn Processing

The client reads line-delimited messages until the turn terminates.

Completion conditions:

- `turn/completed` -> success
- `turn/failed` -> failure
- `turn/cancelled` -> failure
- turn timeout (`turn_timeout_ms`) -> failure
- subprocess exit -> failure

Continuation processing:

- If the worker decides to continue after a successful turn, it should issue another `turn/start`
  on the same live `threadId`.
- The app-server subprocess should remain alive across those continuation turns and be stopped only
  when the worker run is ending.

Line handling requirements:

- Read protocol messages from stdout only.
- Buffer partial stdout lines until newline arrives.
- Attempt JSON parse on complete stdout lines.
- Stderr is not part of the protocol stream:
  - ignore it or log it as diagnostics
  - do not attempt protocol JSON parsing on stderr

### 10.4 Emitted Runtime Events (Upstream to Orchestrator)

The app-server client emits structured events to the orchestrator callback. Each event should
include:

- `event` (enum/string)
- `timestamp` (UTC timestamp)
- `claude_app_server_pid` (if available)
- optional `usage` map (token counts)
- payload fields as needed

Important emitted events may include:

- `session_started`
- `startup_failed`
- `turn_completed`
- `turn_failed`
- `turn_cancelled`
- `turn_ended_with_error`
- `turn_input_required`
- `approval_auto_approved`
- `unsupported_tool_call`
- `notification`
- `other_message`
- `malformed`

### 10.5 Approval, Tool Calls, and User Input Policy

Approval, sandbox, and user-input behavior is implementation-defined.

Policy requirements:

- Each implementation should document its chosen approval, sandbox, and operator-confirmation
  posture.
- Approval requests and user-input-required events must not leave a run stalled indefinitely. An
  implementation should either satisfy them, surface them to an operator, auto-resolve them, or
  fail the run according to its documented policy.

Example high-trust behavior:

- Auto-approve command execution approvals for the session.
- Auto-approve file-change approvals for the session.
- Treat user-input-required turns as hard failure.

Unsupported dynamic tool calls:

- Supported dynamic tool calls that are explicitly implemented and advertised by the runtime should
  be handled according to their extension contract.
- If the agent requests a dynamic tool call (`item/tool/call`) that is not supported, return a tool
  failure response and continue the session.
- This prevents the session from stalling on unsupported tool execution paths.

Optional client-side tool extension:

- An implementation may expose a limited set of client-side tools to the app-server session.
- Current optional standardized tool: `linear_graphql`.
- If implemented, supported tools should be advertised to the app-server session during startup
  using the protocol mechanism supported by the targeted Claude Code app-server version.
- Unsupported tool names should still return a failure result and continue the session.

`linear_graphql` extension contract:

- Purpose: execute a raw GraphQL query or mutation against Linear using Cymphony's configured
  tracker auth for the current session.
- Availability: only meaningful when `tracker.kind == "linear"` and valid Linear auth is configured.
- Preferred input shape:

  ```json
  {
    "query": "single GraphQL query or mutation document",
    "variables": {
      "optional": "graphql variables object"
    }
  }
  ```

- `query` must be a non-empty string.
- `query` must contain exactly one GraphQL operation.
- `variables` is optional and, when present, must be a JSON object.
- Implementations may additionally accept a raw GraphQL query string as shorthand input.
- Execute one GraphQL operation per tool call.
- If the provided document contains multiple operations, reject the tool call as invalid input.
- `operationName` selection is intentionally out of scope for this extension.
- Reuse the configured Linear endpoint and auth from the active Cymphony workflow/runtime config; do
  not require the coding agent to read raw tokens from disk.
- Tool result semantics:
  - transport success + no top-level GraphQL `errors` -> `success=true`
  - top-level GraphQL `errors` present -> `success=false`, but preserve the GraphQL response body
    for debugging
  - invalid input, missing auth, or transport failure -> `success=false` with an error payload
- Return the GraphQL response or error payload as structured tool output that the model can inspect
  in-session.

Illustrative responses (equivalent payload shapes are acceptable if they preserve the same outcome):

```json
{"id":"<approval-id>","result":{"approved":true}}
{"id":"<tool-call-id>","result":{"success":false,"error":"unsupported_tool_call"}}
```

Hard failure on user input requirement:

- If the agent requests user input, fail the run attempt immediately.
- The client detects this via:
  - explicit method (`item/tool/requestUserInput`), or
  - turn methods/flags indicating input is required.

### 10.6 Timeouts and Error Mapping

Timeouts:

- `claude.read_timeout_ms`: request/response timeout during startup and sync requests
- `claude.turn_timeout_ms`: total turn stream timeout
- `claude.stall_timeout_ms`: enforced by orchestrator based on event inactivity

Error mapping (recommended normalized categories):

- `claude_not_found`
- `invalid_workspace_cwd`
- `response_timeout`
- `turn_timeout`
- `port_exit`
- `response_error`
- `turn_failed`
- `turn_cancelled`
- `turn_input_required`

### 10.7 Agent Runner Contract

The `Agent Runner` wraps workspace + prompt + app-server client.

Behavior:

1. Create/reuse workspace for issue.
2. Build prompt from workflow template.
3. Start app-server session.
4. Forward app-server events to orchestrator.
5. On any error, fail the worker attempt (the orchestrator will retry).

Note:

- Workspaces are intentionally preserved after successful runs.

### 10.8 Harness stdout streaming

The agent runner emits live CLI stdout incrementally so a dashboard can tail a
session without flooding LiveView or ingesting raw lines into orchestrator
`log_events`.

Pipeline:

1. `Agent.Runner.collect_output` emits `%{event: :harness_stdout, raw, timestamp}`
   after each completed stdout line (`{:eol, chunk}`) and for a leftover buffer
   on exit 0. `raw` is truncated to 2048 bytes. `{:noeol, _}` chunks stay
   buffered and are not emitted. `parse_output` still runs only after a
   successful (exit 0) process; a nonzero exit is `{:agent_exit, status, remaining}`
   with no parse. Adapter `:stream_event` emissions stay post-exit (or still go
   through `on_message` if an adapter later streams parse).
2. `AgentRunner` does **not** forward `:harness_stdout` to the orchestrator. It
   calls `HarnessStream.append(issue_id, raw)` and may send
   `%{event: :harness_heartbeat, timestamp}` to the orchestrator at most once
   per 2000 ms per issue (stall detection only).
3. `HarnessStream` (GenServer + ETS) keeps a per-issue ring of at most 400
   newest lines (each truncated to 2048 bytes), with a monotonic `seq` starting
   at 1. `dropped` counts lines discarded by the ring. Broadcasts are coalesced:
   at most one broadcast per issue per 80 ms; each broadcast carries at most 40
   newly-appended lines since the last flush. The first append after a quiet
   period flushes immediately.
4. `ObservabilityPubSub.broadcast_harness/2` publishes a **map** (never a bare
   atom) on topic `observability:issue:<issue_id>:harness`:

   ```elixir
   %{event: :harness_stream, issue_id: String.t(), last_seq: non_neg_integer(),
     lines: [%{seq: pos_integer(), at: DateTime.t(), text: String.t()}],
     dropped: non_neg_integer()}
   ```

   Existing `subscribe` / `broadcast_update` / `subscribe_issue` /
   `broadcast_issue_update` still send the bare atom `:observability_updated`.
5. LiveView subscribes on session-row expand, snapshots the ring, and appends
   only lines with `seq` greater than the stored `last_seq` (cap 400). Collapse
   unsubscribes and drops the tail assign. A Follow/Paused toggle controls
   autoscroll. Expanding a row must not spawn a full presenter payload reload
   for harness ticks.
6. The orchestrator treats `:harness_heartbeat` as a timestamp-only stall poke:
   it updates `running_entry.last_agent_timestamp` and does **not**
   `append_log_event`, `notify_dashboard`, or `broadcast_issue_update`.
   `:harness_stdout` / `:harness_heartbeat` must never appear in the 50-event
   `log_events` ring. On every path that removes a running entry (success, kill,
   fail, abandon) the orchestrator calls `HarnessStream.drop(issue_id)`.

Public `HarnessStream` API: `start_link/1`, `append/2`, `snapshot/1`, `drop/1`.
`snapshot/1` returns `%{issue_id, last_seq, lines, dropped}` with `last_seq` 0
and `lines` `[]` when the issue is unknown.

## 11. Issue Tracker Integration Contract (Linear-Compatible)

### 11.1 Required Operations

An implementation must support these tracker adapter operations:

1. `fetch_candidate_issues()`
   - Return issues in configured active states for a configured project.

2. `fetch_issues_by_states(state_names)`
   - Used for startup terminal cleanup.

3. `fetch_issue_states_by_ids(issue_ids)`
   - Used for active-run reconciliation.

### 11.2 Query Semantics (Linear)

Linear-specific requirements for `tracker.kind == "linear"`:

- `tracker.kind == "linear"`
- GraphQL endpoint (default `https://api.linear.app/graphql`)
- Auth token sent in `Authorization` header
- `tracker.project_slug` maps to Linear project `slugId`
- Candidate issue query filters project using `project: { slugId: { eq: $projectSlug } }`
- Issue-state refresh query uses GraphQL issue IDs with variable type `[ID!]`
- Pagination required for candidate issues
- Page size default: `50`
- Network timeout: `30000 ms`

Important:

- Linear GraphQL schema details can drift. Keep query construction isolated and test the exact query
  fields/types required by this specification.

A non-Linear implementation may change transport details, but the normalized outputs must match the
domain model in Section 4.

### 11.3 Normalization Rules

Candidate issue normalization should produce fields listed in Section 4.1.1.

Additional normalization details:

- `labels` -> lowercase strings
- `blocked_by` -> derived from inverse relations where relation type is `blocks`
- `priority` -> integer only (non-integers become null)
- `created_at` and `updated_at` -> parse ISO-8601 timestamps

### 11.4 Error Handling Contract

Recommended error categories:

- `unsupported_tracker_kind`
- `missing_tracker_api_key`
- `missing_tracker_project_slug`
- `linear_api_request` (transport failures)
- `linear_api_status` (non-200 HTTP)
- `linear_graphql_errors`
- `linear_unknown_payload`
- `linear_missing_end_cursor` (pagination integrity error)

Orchestrator behavior on tracker errors:

- Candidate fetch failure: log and skip dispatch for this tick.
- Running-state refresh failure: log and keep active workers running.
- Startup terminal cleanup failure: log warning and continue startup.

### 11.5 Tracker Writes (Important Boundary)

Cymphony does not require first-class tracker write APIs in the orchestrator.

- Ticket mutations (state transitions, comments, PR metadata) are typically handled by the coding
  agent using tools defined by the workflow prompt.
- The service remains a scheduler/runner and tracker reader.
- Workflow-specific success often means "reached the next handoff state" (for example
  `Human Review`) rather than tracker terminal state `Done`.
- If the optional `linear_graphql` client-side tool extension is implemented, it is still part of
  the agent toolchain rather than orchestrator business logic.

## 12. Prompt Construction and Context Assembly

### 12.1 Inputs

Inputs to prompt rendering:

- `workflow.prompt_template`
- normalized `issue` object
- optional `attempt` integer (retry/continuation metadata)

### 12.2 Rendering Rules

- Render with strict variable checking.
- Render with strict filter checking.
- Convert issue object keys to strings for template compatibility.
- Preserve nested arrays/maps (labels, blockers) so templates can iterate.

### 12.3 Retry/Continuation Semantics

`attempt` should be passed to the template because the workflow prompt may provide different
instructions for:

- first run (`attempt` null or absent)
- continuation run after a successful prior session
- retry after error/timeout/stall

### 12.4 Failure Semantics

If prompt rendering fails:

- Fail the run attempt immediately.
- Let the orchestrator treat it like any other worker failure and decide retry behavior.

## 13. Logging, Status, and Observability

### 13.1 Logging Conventions

Required context fields for issue-related logs:

- `issue_id`
- `issue_identifier`

Required context for coding-agent session lifecycle logs:

- `session_id`

Message formatting requirements:

- Use stable `key=value` phrasing.
- Include action outcome (`completed`, `failed`, `retrying`, etc.).
- Include concise failure reason when present.
- Avoid logging large raw payloads unless necessary.

### 13.2 Logging Outputs and Sinks

The spec does not prescribe where logs must go (stderr, file, remote sink, etc.).

Requirements:

- Operators must be able to see startup/validation/dispatch failures without attaching a debugger.
- Implementations may write to one or more sinks.
- If a configured log sink fails, the service should continue running when possible and emit an
  operator-visible warning through any remaining sink.

### 13.3 Runtime Snapshot / Monitoring Interface (Optional but Recommended)

If the implementation exposes a synchronous runtime snapshot (for dashboards or monitoring), it
should return:

- `running` (list of running session rows)
- each running row should include `turn_count`
- `waiting` (ordered compact rows for the sticky waiting board; name this key `waiting`,
  not `queued`)
  - `handle_call(:snapshot)` rows: `issue_id`, `identifier`, `issue`, `priority`, `state`,
    `created_at`, `agent_kind`, `model`, `effort` where `agent_kind` / `model` / `effort`
    are persisted `queue_pins` only (`null` if unpinned)
  - Presenter project rows add `waiting` (list) + `waiting_count`. Each payload row:
    `issue_identifier`, `issue_title`, `issue_url`, `issue_id`, `priority`, `state`,
    `created_at` (ISO8601), `agent_kind`, `model`, `effort`
  - Top-level `payload.counts.waiting` is the sum of project waiting lengths
    (`payload_counts(running, retrying, waiting)`). Default LiveView payload and snapshot
    fixtures include `waiting: []` and `counts.waiting`
  - `GET /api/v1/projects` stays running/retrying only. Do not add `waiting` to
    `StatusDashboard`
- `retrying` (list of retry queue rows)
- `claude_totals`
  - `input_tokens`
  - `output_tokens`
  - `total_tokens`
  - `seconds_running` (aggregate runtime seconds as of snapshot time, including active sessions)
- `rate_limits` (latest coding-agent rate limit payload, if available)

Recommended snapshot error modes:

- `timeout`
- `unavailable`

### 13.4 Optional Human-Readable Status Surface

A human-readable status surface (terminal output, dashboard, etc.) is optional and
implementation-defined.

If present, it should draw from orchestrator state/metrics only and must not be required for
correctness.

### 13.5 Session Metrics and Token Accounting

Token accounting rules:

- Agent events may include token counts in multiple payload shapes.
- `Tokens.extract_token_delta` takes the first integer token map found, in this
  order:
  1. `update[:usage]` / `update["usage"]` when that value itself is an integer
     token map (this is how `:turn_completed` from `Agent.Runner` counts)
  2. `payload["usage"]` / `payload[:usage]` when `payload` is `update[:payload]`
  3. `payload["type"]` in `["turn.completed", "turn/completed"]` → `payload["usage"]`
     (Codex JSONL)
  4. `payload["event"] == "result"` → `result["usage"]` or `payload["usage"]`
     (Antigravity result envelope)
  5. `payload["event"] == "step_update"` → `step_update["usage"]` (Antigravity
     mid-turn)
  6. Existing Claude paths (`params.msg…total_token_usage`, `tokenUsage.total`,
     `method == "turn/completed"`)
- Prefer absolute thread totals when available, such as:
  - `thread/tokenUsage/updated` payloads
  - `total_token_usage` within token-count wrapper events
- Ignore delta-style payloads such as `last_token_usage` for dashboard/API totals.
- Extract input/output/total token counts leniently from common field names within the selected
  payload.
- If `total_tokens` is missing, `total = input + output`. `thinking_tokens` is
  not added to output.
- For absolute totals, track deltas relative to last reported totals to avoid double-counting.
- Do not treat generic `usage` maps as cumulative totals unless the event type defines them that
  way.
- Accumulate aggregate totals in orchestrator state.
- Mid-turn Antigravity `step_update` usage and Codex stream-event
  `turn.completed` usage increment the running entry the same way.

Runtime accounting:

- Runtime should be reported as a live aggregate at snapshot/render time.
- Implementations may maintain a cumulative counter for ended sessions and add active-session
  elapsed time derived from `running` entries (for example `started_at`) when producing a
  snapshot/status view.
- Add run duration seconds to the cumulative ended-session runtime when a session ends (normal exit
  or cancellation/termination).
- Continuous background ticking of runtime totals is not required.

Rate-limit tracking:

- Track the latest rate-limit payload seen in any agent update.
- Any human-readable presentation of rate-limit data is implementation-defined.

### 13.6 Humanized Agent Event Summaries (Optional)

Humanized summaries of raw agent protocol events are optional.

If implemented:

- Treat them as observability-only output.
- Do not make orchestrator logic depend on humanized strings.

### 13.7 Optional HTTP Server Extension

This section defines an optional HTTP interface for observability and operational control.

If implemented:

- The HTTP server is an extension and is not required for conformance.
- The implementation may serve server-rendered HTML or a client-side application for the dashboard.
- The dashboard/API must be observability/control surfaces only and must not become required for
  orchestrator correctness.

Enablement (extension):

- Start the HTTP server when a CLI `--port` argument is provided.
- Start the HTTP server when `server.port` is present in `WORKFLOW.md` front matter.
- `server.port` is extension configuration and is intentionally not part of the core front-matter
  schema in Section 5.3.
- Precedence: CLI `--port` overrides `server.port` when both are present.
- `server.port` must be an integer. Positive values bind that port. `0` may be used to request an
  ephemeral port for local development and tests.
- Implementations should bind loopback by default (`127.0.0.1` or host equivalent) unless explicitly
  configured otherwise.
- Changes to HTTP listener settings (for example `server.port`) do not need to hot-rebind;
  restart-required behavior is conformant.

#### 13.7.1 Human-Readable Dashboard (`/`)

- Host a human-readable dashboard at `/`.
- The returned document should depict the current state of the system (for example the
  per-project waiting board, active sessions, retry delays, token consumption, runtime
  totals, recent events, and health/error indicators).
- It is up to the implementation whether this is server-generated HTML or a client-side app that
  consumes the JSON API below.
- Settings drawer (`aside.settings-drawer`) includes, after Experience and before Automation,
  visible in both simple and advanced modes:
  - **Linear** (`section.settings-group.settings-group--linear`): connect status
    (`Connected` / `Disconnected`), last-4 mask of the stored key when connected, and form
    `#linear-connect-form` (`phx-submit="connect_linear"`) with password input
    `#linear-api-key` (`name=api_key`, `autocomplete=off`). Submit validates the key against
    Linear, persists `linear_api_key` to `~/.cymphony/config.json` (top-level and every
    project; file mode `0600`), and rewrites each registered project's generated
    `WORKFLOW.md` `tracker.api_key`. Never put the raw key in LiveView assigns, flashes,
    logs, or API responses — flash the last-4 mask only (for example `Linear connected · ••••xxxx`).
  - **Projects** (`section.settings-group.settings-group--projects`): when disconnected,
    help text "Connect Linear to add a project". When connected, form `#add-project-form`
    (`phx-submit="add_project"`) with a searchable Combobox on `#add-project-slug`
    (`name=linear_project_slug`; **not** a native `<select>`). Options come from the
    operator's accessible Linear projects (label `name (slug_id)`, value `slug_id`) and
    type-to-filter. Also: name input `#add-project-name`, optional GitHub URL
    `#add-project-github`, and advanced-only agent / `.model-switcher` Combobox / native
    effort `<select>` / provider fields. `preview_add_project` drafts those advanced
    fields. Submit appends the project to `config.json`, writes a temp `WORKFLOW.md`,
    and starts the project supervisor immediately — no daemon restart. Duplicate
    name/slug is an operator-visible error.
  - Drawer fields only (`#linear-api-key`, add-project slug/name/github/agent/model/effort/provider,
    `#drawer-global-concurrency`, `#drawer-refresh-interval`) use class `settings-field`
    (filled control chrome). Do not restyle header/session `.inline-form` pills as naked
    labels.
  - Automation / Orchestrator (after global concurrency) includes
    `#drawer-refresh-interval` (`type=number`, `name=value`, `min=1`, default `3`,
    `phx-submit="set_refresh_interval"`). Persist the value as top-level
    `~/.cymphony/config.json` `dashboard_refresh_seconds` (positive integer, minimum 1;
    default `3` when missing/unreadable). This is the dashboard payload refresh cadence
    only — it is **not** `polling.interval_ms`, must not rewrite `WORKFLOW.md` for Linear
    refresh, and must not change orchestrator poll timing. Open dashboards keep their
    current interval until remount or a successful `set_refresh_interval`.
- Per-project header agent `<select>` uses a stable id `agent-<project>` (never embed the
  current kind or effort). Changing to a known kind persists immediately (kind only;
  model/effort wait for header **Set**). Header **Set** and `POST /api/v1/agent` persist
  kind+model+effort, rewrite the project's generated `WORKFLOW.md`, and overlay
  `config.json` so `snapshot.agent_kind` survives the next refresh. Dashboard payload
  reloads are generation-tokened so an in-flight stale snapshot cannot revert the select
  after persist.
- Header and expanded-session **model** controls are a labeled `.model-switcher` Combobox
  (type-to-filter suggestions; not `<datalist>`). Header wrapping form remains
  `form.project-agent-form` (`phx-change="preview_project_agent"`,
  `phx-submit="set_project_agent"`) so **Set** still sends kind+model+effort. Inner pills:
  `.agent-switcher` (`#agent-<project>` native select), `.model-switcher` (Combobox),
  `.effort-switcher` (native `#effort-<project>` select), and **Set**. Effort stays a
  native `<select>`. Session restart is `form.restart-form` (`phx-change="preview_issue_run_spec"`,
  `phx-submit="set_issue_run_spec"`) with labeled Harness / Provider / Model Combobox /
  Effort pills — not one cramped pill. Harness stdout `section#harness-tail-<id>` is
  unchanged.
- Provider pills/fields (`form[phx-submit=set_project_providers]`, `#add-project-provider`,
  restart `name=provider`) are visible only when the selected agent kind is `claude`.
  Hide them for `codex`, `antigravity`, empty/default, and unknown kinds. Header uses
  `agent_settings.kind` (draft or `project.agent_kind`); restart uses
  `session_spec.suggestion_kind` (draft known kind else `entry.agent_kind`); add-project
  uses assign `:add_project_kind` (default `""` hides provider). Switching agent must
  hide/show on the next render via `preview_project_agent` / `preview_issue_run_spec` /
  `preview_add_project`. Do not delete persisted providers when the field is hidden.
  Session provider chips and the read-only Provider stat stay visible for every kind.
- Per-project header counts: `N/M running · Q queued · R retrying`. Advanced metrics add
  `.metric-pill--queue.section--queue` = `counts.waiting`. The simple Waiting pill stays
  `counts.retrying`.
- Theme / settings glyphs are CSS geometry only on `.theme-toggle-button` and
  `[data-drawer-toggle]` (no ☀ / ☾ / ⌂ / ⚙ text).
- Display preferences include `{Board, board}`. Hide the board with
  `html[data-hidden-sections~=board] .section--board { display: none }`.
- Waiting board (`section.queue-board.section--board`) sits inside
  `article.project-section` **above** In Progress (`.session-row-list`) and **below** the
  empty-state. Empty-state is shown iff `running == []` and `retrying == []` **and**
  `waiting == []`. Hide the board when `waiting == []` (no empty columns). Retry remains
  its own list **below** In Progress (Section 8.4).
- Board HEEx: `section.queue-board.section--board` > `header.queue-board-header` (simple
  `Up next` / advanced `Queue` + `span.queue-board-count.numeric`) >
  `div#queue-board-<project.name>.queue-board-list` (`phx-hook=QueueBoard`, `data-project`,
  `data-order`) > `article#queue-card-<project>-<identifier>.queue-card` (`data-issue`,
  `data-issue-id`, `data-rank`, `tabindex=0`). Card face only: `.queue-card-id` (mono
  caption; `a.session-row-link.queue-card-link` if url) + `.queue-card-title` (body-sm,
  2-line clamp) + `button.queue-card-edit-toggle` (text `Edit` or CSS kebab, no emoji).
  No Linear priority / state / agent chips. Edit is not an alert:
  `div.queue-card-edit` when `{project, id}` is in assign `:queue_edit_ids`;
  `form.queue-edit-form` (`phx-change=preview_queue_run_spec`,
  `phx-submit=set_queue_run_spec`); hidden `project` + `issue`;
  comboboxes for `agent_kind` / `model` / `effort` preselect the card pin when
  set, otherwise the project header agent/model/effort (no `keep` blank);
  submit `Pin`; no provider. Pin persists with the queue and does **not** kill
  anything. Empty / `"keep"` in the pin payload still skip a field (API compat).
- LiveView mount assigns `:queue_edit_ids` (`MapSet.new()`) and
  `:queue_run_spec_drafts` (`%{}`). Events:
  - `reorder_queue` — params `project` + full identifier `order` list; optimistic
    client reorder, then `Control.set_queue_order`, reload
  - `toggle_queue_edit` — `project` + `issue`; toggle `{project, identifier}` in
    `:queue_edit_ids`
  - `preview_queue_run_spec` — draft `:queue_run_spec_drafts[{project, id}]` like
    `preview_issue_run_spec`; kind change to another harness clears model/effort;
    changing back to the inherited kind restores its model/effort; no persist
  - `set_queue_run_spec` — hidden `project` + `issue`; empty / keep skip;
    `Control.set_queue_pin`; do not kill
- `QueueBoard` hook mounts on `div#queue-board-<project.name>.queue-board-list` in
  `layouts.ex` beside `HarnessTail` / `Combobox` (`mounted` / `updated` / `destroyed`;
  `pushEvent reorder_queue`). `Combobox.setChrome` also toggles the closest
  `.queue-card`.
- Refresh behavior: server-side re-render is change-only, and the second-by-second clock
  runs in the browser. The poll/pubsub cadence itself is unchanged (see the
  `dashboard_refresh_seconds` bullet above and Section 8.1).
  - Time-derived text is server-rendered once per payload load, wrapped in a span carrying a
    clock anchor. An anchor is always a remaining/elapsed **amount**, never an absolute wall
    time, so client clock skew cannot accumulate: `data-clock="countdown"` +
    `data-remaining-ms` (poll countdown), `data-clock="due"` + `data-remaining-ms` (retry
    due-in), `data-clock="elapsed"` + `data-base-seconds` (session runtime, stall duration).
    The global runtime tile is `elapsed` and adds `data-rate` = number of running sessions,
    because that total advances one second per running session per wall second. There is no
    turns suffix on any clock; `data-rate` is the only multiplier the format takes.
  - One `LiveClock` hook (registered in `layouts.ex` beside `HarnessTail` / `Combobox` /
    `QueueBoard`) mounts on a single wrapper `div#live-clock` around the dashboard and runs
    one 1s interval that rewrites only those spans' `textContent`; it clears the interval on
    `destroyed`. It re-anchors per element per tick by comparing the live data attributes
    against a snapshot cached on the node, so every payload load re-anchors the clocks. It
    must also repaint on `updated`: every LiveView patch morphs this container and writes the
    spans' text back to what the server rendered at the last payload load, so without the
    `updated` repaint the clocks rewind on each patch (a streaming harness pane patches many
    times a second) and stay wrong until the next interval. Its
    formatting must stay byte-identical to the server formatters. A span with a missing or
    unparseable anchor is skipped, leaving the server-rendered text (`n/a`, `unknown`, `now`)
    as the no-JS and bad-data fallback. Poll `checking?` ("Checking…") stays server-rendered:
    it is data, not time.
  - The 1s runtime tick still schedules the periodic payload refresh but must **not** assign
    `:now`. `:now` is a clock *anchor*, not a clock: it is assigned at mount and re-anchored
    by a payload load — the async `{:payload_loaded, seq, payload}` reply and the synchronous
    reload used by event handlers both go through the same split — but **only when a section
    a clock reads actually moved** (`:token_totals`, `:running`, `:projects`). `:now` is read
    inside the per-project comprehension (session runtime, retry due-in), and a HEEx
    comprehension is a single change-tracked slot: re-anchoring on a load that moved nothing
    would re-evaluate and re-serialize every project header, queue card, session row and
    restart form, which is the re-render the section split exists to skip. Server-rendered
    values are therefore correct as of the last load that moved a clock-bearing section, and
    the hook takes over between loads. A clock hung off a section outside that set renders a
    stale amount, so the set must stay in step with the `:now` reads in the template. The
    poll countdown reads no wall clock at all — `next_poll_in_ms` is already a remaining
    amount — so it must not be formatted against `:now`.
  - A loaded payload is fanned into one assign per section (`:counts`, `:token_totals`,
    `:rate_limits`, `:polling`, `:projects`, `:running`, `:retrying`, `:completions`,
    `:payload_error`). There is no monolithic `:payload` assign, because nested `@payload.x`
    reads mark the whole template dirty on every load. A section whose value did not change
    is not reassigned, so LiveView change tracking skips it. `generated_at` gets no assign
    (it moves on every load and is rendered nowhere). The comparison also ignores a running
    entry's `tokens_per_second`, which the presenter re-derives from the wall clock on every
    load (tokens over seconds-since-start) and which would otherwise make `:running` and
    `:projects` differ on every refresh while an agent runs; any other movement still assigns
    the whole fresh section, drifted rate included. The accepted trade-off is that the
    rendered per-session `t/s` chip holds the value from the last load that moved a real
    field: while an agent sits in a long tool call the chip does not decay, and it catches up
    the moment anything else about the session moves. A retry's `due_at` must be computed so
    it does not drift for the same reason: `now + due_in_ms` truncated **after** the offset is
    applied, not a truncated clock plus whole seconds. That names the same absolute second
    across loads as long as the snapshot round-trip does not straddle a second boundary — it
    is a large reduction in flip rate, not a guarantee; `due_in_ms` is measured against the
    orchestrator's monotonic clock and `now` is sampled later in the presenter. A section
    missing from the payload falls back to the default payload (error snapshots, older
    snapshot shapes). Both the async and the synchronous load path go through the same split;
    `payload_seq` guarding is unchanged.
  - Acceptance: an idle dashboard ships no per-second diff, and a poll whose only movement is
    `generated_at` reassigns no section and does not re-anchor `:now` — only `:token_samples`
    (throughput window) moves.

#### 13.7.2 JSON REST API (`/api/v1/*`)

Provide a JSON REST API under `/api/v1/*` for current runtime state and operational debugging.

Minimum endpoints:

- `GET /api/v1/state`
  - Returns a summary view of the current system state (running sessions, waiting board,
    retry queue/delays, aggregate token/runtime totals, latest rate limits, and any
    additional tracked summary fields).
  - `counts.waiting` is the sum of per-project `waiting` lengths (`waiting_count`).
    Each project object includes `waiting` (list) + `waiting_count`. Default payload /
    fixtures include `waiting: []` and `counts.waiting`.
  - Suggested response shape:

    ```json
    {
      "generated_at": "2026-02-24T20:15:30Z",
      "counts": {
        "running": 2,
        "retrying": 1,
        "waiting": 1
      },
      "running": [
        {
          "issue_id": "abc123",
          "issue_identifier": "MT-649",
          "state": "In Progress",
          "session_id": "thread-1-turn-1",
          "turn_count": 7,
          "last_event": "turn_completed",
          "last_message": "",
          "started_at": "2026-02-24T20:10:12Z",
          "last_event_at": "2026-02-24T20:14:59Z",
          "tokens": {
            "input_tokens": 1200,
            "output_tokens": 800,
            "total_tokens": 2000
          }
        }
      ],
      "retrying": [
        {
          "issue_id": "def456",
          "issue_identifier": "MT-650",
          "attempt": 3,
          "due_at": "2026-02-24T20:16:00Z",
          "error": "no available orchestrator slots"
        }
      ],
      "waiting": [
        {
          "issue_identifier": "MT-651",
          "issue_title": "Add queue board",
          "issue_url": "https://linear.app/team/issue/MT-651",
          "issue_id": "ghi789",
          "priority": 2,
          "state": "Todo",
          "created_at": "2026-02-24T19:00:00Z",
          "agent_kind": "codex",
          "model": "gpt-5.2-codex",
          "effort": "high"
        }
      ],
      "claude_totals": {
        "input_tokens": 5000,
        "output_tokens": 2400,
        "total_tokens": 7400,
        "seconds_running": 1834.2
      },
      "rate_limits": null
    }
    ```

- `GET /api/v1/linear`
  - Must be declared **before** the `GET /api/v1/<issue_identifier>` catch-all.
  - Returns Linear connect status. `200` JSON keys: `connected` (boolean), `masked_key`
    (last-4 mask or `null`), `source` (`"config"` | `"env"` | `null`). Never returns the
    raw key.
- `POST /api/v1/linear`
  - Must be declared **before** the issue catch-all. Unsupported methods on this path
    return `405`.
  - Body `{"api_key":"..."}`. Validates against Linear (`viewer { id }`), then persists
    `linear_api_key` to `~/.cymphony/config.json` (top-level and every project) and
    rewrites each registered project's `WORKFLOW.md` `tracker.api_key`.
  - `202` with the same `connected` / `masked_key` / `source` JSON as GET.
  - `422` `{"error":{"code":"empty_api_key"|"invalid_api_key"|"linear_unauthorized"|"linear_error","message":"..."}}`.
  - Never echo `api_key` in the response, logs, or error message.
- `GET /api/v1/linear/projects`
  - Must be declared **before** the issue catch-all.
  - Lists Linear projects accessible with the stored key:
    `200` `{"projects":[{"id":"...","name":"...","slug_id":"..."}]}`.
  - `422` `{"error":{"code":"linear_not_connected","message":"..."}}` if no key is
    resolved (file or env).
- `POST /api/v1/projects`
  - Must be declared **before** the issue catch-all. `GET /api/v1/projects` (running
    counts) is unchanged.
  - Body `{"name":"...","linear_project_slug":"..."}` plus optional `github_repo_url`,
    `workspace_root`, `agent`, `model`, `effort`, `provider`.
  - Appends to `~/.cymphony/config.json`, writes a temp `WORKFLOW.md`, and starts the
    project supervisor (no daemon restart). Inherits the shared `linear_api_key`.
  - `202` `{"name":"...","linear_project_slug":"...","started":true}` (never include the
    raw key).
  - `422` codes: `not_connected`, `invalid_project`, `duplicate_project_name`,
    `duplicate_project_slug`, `project_start_failed`.

- `POST /api/v1/queue`
  - Must be declared (and `match :*` `405`) **before** `/api/v1/:issue_identifier`.
  - Query `?project=` is **required**. `Control.set_queue_order({:project, name}, order)`
    applies the orchestrator call first, then persists. `:all` is
    `{:error, :invalid_scope}`.
  - Body `{"order":["LLM-51","LLM-12"]}` — full identifier/id order for that project.
    `parse_queue_order/1` rejects non-lists / blank keys.
  - `202` `{"order":[...],"project":"Name"}`.
  - `422` `{"error":{"code":"invalid_queue_order","message":"..."}}`.
  - Other methods `405`. No Linear writes.
- `POST /api/v1/queue-pin`
  - Must be declared (and `match :*` `405`) **before** `/api/v1/:issue_identifier`.
  - Query `?project=` is **required**. `Control.set_queue_pin({:project, name}, issue_key,
    pin_map)` applies the orchestrator call first, then persists. `:all` is
    `{:error, :invalid_scope}`.
  - Body `{"issue":"LLM-51","kind":"codex","model":"...","effort":"..."}` — each of
    `kind` / `model` / `effort` optional; empty / `keep` skipped; at least one real
    field required. `parse_queue_pin/1` rejects blank keys / unknown agent kinds.
  - `202` `{"issue","agent_kind","model","effort","project"}`.
  - `422` `{"error":{"code":"invalid_queue_pin","message":"..."}}`.
  - Other methods `405`. Does not kill a session (the issue is not running). No
    Linear writes. No provider on queue pins.

- `GET /api/v1/<issue_identifier>/harness`
  - Must be declared **before** the `GET /api/v1/<issue_identifier>` catch-all.
  - Optional query `?project=<name>`.
  - `200`: `HarnessStream.snapshot(issue_id)` plus `issue_identifier`.
  - `404`: the issue is not running and there is no leftover snapshot.
- `GET /api/v1/<issue_identifier>`
  - Returns issue-specific runtime/debug details for the identified issue, including any information
    the implementation tracks that is useful for debugging.
  - Suggested response shape:

    ```json
    {
      "issue_identifier": "MT-649",
      "issue_id": "abc123",
      "status": "running",
      "workspace": {
        "path": "/tmp/cymphony_workspaces/MT-649"
      },
      "attempts": {
        "restart_count": 1,
        "current_retry_attempt": 2
      },
      "running": {
        "session_id": "thread-1-turn-1",
        "turn_count": 7,
        "state": "In Progress",
        "started_at": "2026-02-24T20:10:12Z",
        "last_event": "notification",
        "last_message": "Working on tests",
        "last_event_at": "2026-02-24T20:14:59Z",
        "tokens": {
          "input_tokens": 1200,
          "output_tokens": 800,
          "total_tokens": 2000
        }
      },
      "retry": null,
      "logs": {
        "claude_session_logs": [
          {
            "label": "latest",
            "path": "/var/log/cymphony/claude/MT-649/latest.log",
            "url": null
          }
        ]
      },
      "recent_events": [
        {
          "at": "2026-02-24T20:14:59Z",
          "event": "notification",
          "message": "Working on tests"
        }
      ],
      "last_error": null,
      "tracked": {}
    }
    ```

  - If the issue is unknown to the current in-memory state, return `404` with an error response (for
    example `{\"error\":{\"code\":\"issue_not_found\",\"message\":\"...\"}}`).

- `POST /api/v1/refresh`
  - Queues an immediate tracker poll + reconciliation cycle (best-effort trigger; implementations
    may coalesce repeated requests).
  - This is **not** `POST /api/v1/refresh-interval` (dashboard payload cadence).
  - Suggested request body: empty body or `{}`.
  - Suggested response (`202 Accepted`) shape:

    ```json
    {
      "queued": true,
      "coalesced": false,
      "requested_at": "2026-02-24T20:15:30Z",
      "operations": ["poll", "reconcile"]
    }
    ```

- `POST /api/v1/refresh-interval`
  - Must be declared **before** the `GET /api/v1/<issue_identifier>` catch-all (and
    `match :*` on this path). Unsupported methods return `405`.
  - This is **not** `POST /api/v1/refresh` (Linear poll + reconcile). It does not
    write `polling.interval_ms`, rewrite `WORKFLOW.md` for tracker refresh, or change
    orchestrator poll timing. It does not take `?project=`.
  - Body `{"value": N}` where `N` is a positive integer ≥ 1.
  - Persists only the top-level `~/.cymphony/config.json` key
    `dashboard_refresh_seconds` (beside `projects`, never inside a project map).
  - `202` `{"dashboard_refresh_seconds": N}`.
  - `422` `{"error":{"code":"invalid_refresh_interval","message":"..."}}`.

Optional operational-control endpoints (extension; all return `202 Accepted` and accept an
optional `?project=<name>` scope):

- `POST /api/v1/pause` / `POST /api/v1/resume` — stop/start dispatching new issues; running
  sessions complete normally.
- `POST /api/v1/concurrency` — body `{"value": <int>}`; updates `max_concurrent_agents` at
  runtime and persists to the operator config store.
- `POST /api/v1/providers` — body `{"value": "a1,a2"}`; updates the active agent kind's
  provider rotation; applies to subsequent dispatches only.
- `POST /api/v1/agent` — body with any of `kind` (`"claude"`/`"codex"`/`"antigravity"`),
  `model`, `effort` (empty string clears model/effort to the agent default); updates
  runtime agent settings and persists to `~/.cymphony/config.json`; **rewrites the
  project's generated `WORKFLOW.md` and overlays `config.json` agent/model/effort so
  `snapshot.agent_kind` survives the next dashboard/API refresh**. Dashboard header
  **Set** and change-to-save (kind-only persist on the project agent `<select>`) follow
  the same rewrite + overlay path. Applies to subsequent dispatches. Error when
  none of those keys are present or `kind` is not a known kind:
  `"body must include at least one of kind/model/effort; kind must be one of: claude, codex, antigravity"`.
- `POST /api/v1/refresh-interval` is documented with the minimum endpoints above
  (not `?project=`-scoped; not `POST /refresh`).
- Dashboard `set_issue_run_spec` (LiveView / orchestrator) accepts optional
  `:provider`, `:model`, `:effort`, and `:agent_kind` overrides and kills +
  redispatches the session. Empty / `"keep"` skips a field.
- Linear connect / add-project writes (`POST /api/v1/linear`,
  `POST /api/v1/projects`) are documented with the Linear routes above (`202` on
  success, `422` on validation). They do not take `?project=`.

Dashboard display preferences (density, hidden sections including `{Board, board}`,
visible columns, list lengths) are client-side only (browser localStorage); they are not
server state and have no API surface.

API design notes:

- The JSON shapes above are the recommended baseline for interoperability and debugging ergonomics.
- Implementations may add fields, but should avoid breaking existing fields within a version.
- Endpoints should be read-only except for operational triggers like `/refresh`,
  `/refresh-interval`, `/linear`, `POST /projects`, `POST /queue`, `POST /queue-pin`,
  and the operational-control endpoints above.
- Unsupported methods on defined routes should return `405 Method Not Allowed`.
- API errors should use a JSON envelope such as `{"error":{"code":"...","message":"..."}}`.
- If the dashboard is a client-side app, it should consume this API rather than duplicating state
  logic.

## 14. Failure Model and Recovery Strategy

### 14.1 Failure Classes

1. `Workflow/Config Failures`
   - Missing `WORKFLOW.md`
   - Invalid YAML front matter
   - Unsupported tracker kind or missing tracker credentials/project slug
   - Missing coding-agent executable

2. `Workspace Failures`
   - Workspace directory creation failure
   - Workspace population/synchronization failure (implementation-defined; may come from hooks)
   - Invalid workspace path configuration
   - Hook timeout/failure

3. `Agent Session Failures`
   - Startup handshake failure
   - Turn failed/cancelled
   - Turn timeout
   - User input requested (hard fail)
   - Subprocess exit
   - Stalled session (no activity)

4. `Tracker Failures`
   - API transport errors
   - Non-200 status
   - GraphQL errors
   - malformed payloads

5. `Observability Failures`
   - Snapshot timeout
   - Dashboard render errors
   - Log sink configuration failure

### 14.2 Recovery Behavior

- Dispatch validation failures:
  - Skip new dispatches.
  - Keep service alive.
  - Continue reconciliation where possible.

- Worker failures:
  - Convert to retries with exponential backoff.

- Tracker candidate-fetch failures:
  - Skip this tick.
  - Try again on next tick.

- Reconciliation state-refresh failures:
  - Keep current workers.
  - Retry on next tick.

- Dashboard/log failures:
  - Do not crash the orchestrator.

### 14.3 Partial State Recovery (Restart)

Current design is intentionally in-memory for scheduler state.

After restart:

- No retry timers are restored from prior process memory.
- No running sessions are assumed recoverable.
- Service recovers by:
  - startup terminal workspace cleanup
  - fresh polling of active issues
  - re-dispatching eligible work

### 14.4 Operator Intervention Points

Operators can control behavior by:

- Editing `WORKFLOW.md` (prompt and most runtime settings).
- `WORKFLOW.md` changes should be detected and re-applied automatically without restart.
- Changing issue states in the tracker:
  - terminal state -> running session is stopped and workspace cleaned when reconciled
  - non-active state -> running session is stopped without cleanup
- Restarting the service for process recovery or deployment (not as the normal path for applying
  workflow config changes).

## 15. Security and Operational Safety

### 15.1 Trust Boundary Assumption

Each implementation defines its own trust boundary.

Operational safety requirements:

- Implementations should state clearly whether they are intended for trusted environments, more
  restrictive environments, or both.
- Implementations should state clearly whether they rely on auto-approved actions, operator
  approvals, stricter sandboxing, or some combination of those controls.
- Workspace isolation and path validation are important baseline controls, but they are not a
  substitute for whatever approval and sandbox policy an implementation chooses.

### 15.2 Filesystem Safety Requirements

Mandatory:

- Workspace path must remain under configured workspace root.
- Coding-agent cwd must be the per-issue workspace path for the current run.
- Workspace directory names must use sanitized identifiers.

Recommended additional hardening for ports:

- Run under a dedicated OS user.
- Restrict workspace root permissions.
- Mount workspace root on a dedicated volume if possible.

### 15.3 Secret Handling

- Support `$VAR` indirection in workflow config.
- Do not log API tokens or secret env values.
- Validate presence of secrets without printing them.

### 15.4 Hook Script Safety

Workspace hooks are arbitrary shell scripts from `WORKFLOW.md`.

Implications:

- Hooks are fully trusted configuration.
- Hooks run inside the workspace directory.
- Hook output should be truncated in logs.
- Hook timeouts are required to avoid hanging the orchestrator.

### 15.5 Harness Hardening Guidance

Running Claude Code agents against repositories, issue trackers, and other inputs that may contain
sensitive data or externally-controlled content can be dangerous. A permissive deployment can lead
to data leaks, destructive mutations, or full machine compromise if the agent is induced to execute
harmful commands or use overly-powerful integrations.

Implementations should explicitly evaluate their own risk profile and harden the execution harness
where appropriate. This specification intentionally does not mandate a single hardening posture, but
ports should not assume that tracker data, repository contents, prompt inputs, or tool arguments are
fully trustworthy just because they originate inside a normal workflow.

Possible hardening measures include:

- Tightening Claude Code approval and sandbox settings described elsewhere in this specification instead
  of running with a maximally permissive configuration.
- Adding external isolation layers such as OS/container/VM sandboxing, network restrictions, or
  separate credentials beyond the built-in Claude Code policy controls.
- Filtering which Linear issues, projects, teams, labels, or other tracker sources are eligible for
  dispatch so untrusted or out-of-scope tasks do not automatically reach the agent.
- Narrowing the optional `linear_graphql` tool so it can only read or mutate data inside the
  intended project scope, rather than exposing general workspace-wide tracker access.
- Reducing the set of client-side tools, credentials, filesystem paths, and network destinations
  available to the agent to the minimum needed for the workflow.

The correct controls are deployment-specific, but implementations should document them clearly and
treat harness hardening as part of the core safety model rather than an optional afterthought.

## 16. Reference Algorithms (Language-Agnostic)

### 16.1 Service Startup

```text
function start_service():
  configure_logging()
  start_observability_outputs()
  start_workflow_watch(on_change=reload_and_reapply_workflow)

  state = {
    poll_interval_ms: get_config_poll_interval_ms(),
    max_concurrent_agents: get_config_max_concurrent_agents(),
    running: {},
    claimed: set(),
    retry_attempts: {},
    waiting: [],
    queue_order: load_project_queue_order(),
    queue_pins: load_project_queue_pins(),
    queue_priority_seen: load_project_queue_priority_seen(),
    completed: set(),
    claude_totals: {input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
    claude_rate_limits: null
  }

  validation = validate_dispatch_config()
  if validation is not ok:
    log_validation_error(validation)
    fail_startup(validation)

  startup_terminal_workspace_cleanup()
  schedule_tick(delay_ms=0)

  event_loop(state)
```

### 16.2 Poll-and-Dispatch Tick

```text
on_tick(state):
  state = reconcile_running_issues(state)

  validation = validate_dispatch_config()
  if validation is not ok:
    log_validation_error(validation)
    notify_observers()
    schedule_tick(state.poll_interval_ms)
    return state  # keep last waiting

  issues = tracker.fetch_candidate_issues()
  if issues failed:
    log_tracker_error()
    notify_observers()
    schedule_tick(state.poll_interval_ms)
    return state  # keep last waiting

  # always fetch, including when paused and available_slots == 0
  eligible = filter_waiting_eligible(issues)
    # candidate_issue? and not todo_blocked and not claimed
    # and not running and not retry_attempts
  state = Queue.reconcile(state, eligible)
    # sets state.waiting; may persist queue_order + queue_priority_seen
    # do not claim waiting ids
    # do not re-sort via sort_for_dispatch once a saved/reconciled order exists

  if paused:
    notify_observers()
    schedule_tick(state.poll_interval_ms)
    return state  # waiting refreshed; do not spawn

  for issue in state.waiting:  # leftmost first
    if no_global_slots(state):
      break  # keep remaining waiting
    if not state_slots_available(issue) or not worker_slots_available(issue):
      continue  # leave on waiting; try next
    if should_dispatch(issue, state):
      state = dispatch_issue(issue, state, attempt=null)  # claim only then
      state.waiting.remove(issue)

  notify_observers()
  schedule_tick(state.poll_interval_ms)
  return state
```

### 16.3 Reconcile Active Runs

```text
function reconcile_running_issues(state):
  state = reconcile_stalled_runs(state)

  running_ids = keys(state.running)
  if running_ids is empty:
    return state

  refreshed = tracker.fetch_issue_states_by_ids(running_ids)
  if refreshed failed:
    log_debug("keep workers running")
    return state

  for issue in refreshed:
    if issue.state in terminal_states:
      state = terminate_running_issue(state, issue.id, cleanup_workspace=true)
    else if issue.state in active_states:
      state.running[issue.id].issue = issue
    else:
      state = terminate_running_issue(state, issue.id, cleanup_workspace=false)

  return state
```

### 16.4 Dispatch One Issue

```text
function dispatch_issue(issue, state, attempt):
  worker = spawn_worker(
    fn -> run_agent_attempt(issue, attempt, parent_orchestrator_pid) end
  )

  if worker spawn failed:
    return schedule_retry(state, issue.id, next_attempt(attempt), {
      identifier: issue.identifier,
      error: "failed to spawn agent"
    })

  state.running[issue.id] = {
    worker_handle,
    monitor_handle,
    identifier: issue.identifier,
    issue,
    session_id: null,
    claude_app_server_pid: null,
    last_claude_message: null,
    last_claude_event: null,
    last_claude_timestamp: null,
    claude_input_tokens: 0,
    claude_output_tokens: 0,
    claude_total_tokens: 0,
    last_reported_input_tokens: 0,
    last_reported_output_tokens: 0,
    last_reported_total_tokens: 0,
    retry_attempt: normalize_attempt(attempt),
    started_at: now_utc()
  }

  state.claimed.add(issue.id)
  state.retry_attempts.remove(issue.id)
  return state
```

### 16.5 Worker Attempt (Workspace + Prompt + Agent)

```text
function run_agent_attempt(issue, attempt, orchestrator_channel):
  workspace = workspace_manager.create_for_issue(issue.identifier)
  if workspace failed:
    fail_worker("workspace error")

  if run_hook("before_run", workspace.path) failed:
    fail_worker("before_run hook error")

  session = app_server.start_session(workspace=workspace.path)
  if session failed:
    run_hook_best_effort("after_run", workspace.path)
    fail_worker("agent session startup error")

  max_turns = config.agent.max_turns
  turn_number = 1

  while true:
    prompt = build_turn_prompt(workflow_template, issue, attempt, turn_number, max_turns)
    if prompt failed:
      app_server.stop_session(session)
      run_hook_best_effort("after_run", workspace.path)
      fail_worker("prompt error")

    turn_result = app_server.run_turn(
      session=session,
      prompt=prompt,
      issue=issue,
      on_message=(msg) -> send(orchestrator_channel, {claude_update, issue.id, msg})
    )

    if turn_result failed:
      app_server.stop_session(session)
      run_hook_best_effort("after_run", workspace.path)
      fail_worker("agent turn error")

    refreshed_issue = tracker.fetch_issue_states_by_ids([issue.id])
    if refreshed_issue failed:
      app_server.stop_session(session)
      run_hook_best_effort("after_run", workspace.path)
      fail_worker("issue state refresh error")

    issue = refreshed_issue[0] or issue

    if issue.state is not active:
      break

    if turn_number >= max_turns:
      break

    turn_number = turn_number + 1

  app_server.stop_session(session)
  run_hook_best_effort("after_run", workspace.path)

  exit_normal()
```

### 16.6 Worker Exit and Retry Handling

```text
on_worker_exit(issue_id, reason, state):
  running_entry = state.running.remove(issue_id)
  state = add_runtime_seconds_to_totals(state, running_entry)

  if reason == normal:
    state.completed.add(issue_id)  # bookkeeping only
    state = schedule_retry(state, issue_id, 1, {
      identifier: running_entry.identifier,
      delay_type: continuation
    })
  else:
    state = schedule_retry(state, issue_id, next_attempt_from(running_entry), {
      identifier: running_entry.identifier,
      error: format("worker exited: %reason")
    })

  notify_observers()
  return state
```

```text
on_retry_timer(issue_id, state):
  retry_entry = state.retry_attempts.pop(issue_id)
  if missing:
    return state

  candidates = tracker.fetch_candidate_issues()
  if fetch failed:
    return schedule_retry(state, issue_id, retry_entry.attempt + 1, {
      identifier: retry_entry.identifier,
      error: "retry poll failed"
    })

  issue = find_by_id(candidates, issue_id)
  if issue is null:
    state.claimed.remove(issue_id)
    return state

  if available_slots(state) == 0:
    return schedule_retry(state, issue_id, retry_entry.attempt + 1, {
      identifier: issue.identifier,
      error: "no available orchestrator slots"
    })

  return dispatch_issue(issue, state, attempt=retry_entry.attempt)
```

## 17. Test and Validation Matrix

A conforming implementation should include tests that cover the behaviors defined in this
specification.

Validation profiles:

- `Core Conformance`: deterministic tests required for all conforming implementations.
- `Extension Conformance`: required only for optional features that an implementation chooses to
  ship.
- `Real Integration Profile`: environment-dependent smoke/integration checks recommended before
  production use.

Unless otherwise noted, Sections 17.1 through 17.7 are `Core Conformance`. Bullets that begin with
`If ... is implemented` are `Extension Conformance`.

### 17.1 Workflow and Config Parsing

- Workflow file path precedence:
  - explicit runtime path is used when provided
  - cwd default is `WORKFLOW.md` when no explicit runtime path is provided
- Workflow file changes are detected and trigger re-read/re-apply without restart
- Invalid workflow reload keeps last known good effective configuration and emits an
  operator-visible error
- Missing `WORKFLOW.md` returns typed error
- Invalid YAML front matter returns typed error
- Front matter non-map returns typed error
- Config defaults apply when optional values are missing
- `tracker.kind` validation enforces currently supported kind (`linear`)
- `tracker.api_key` works (including `$VAR` indirection)
- `$VAR` resolution works for tracker API key and path values
- `~` path expansion works
- `claude.command` is preserved as a shell command string
- Per-state concurrency override map normalizes state names and ignores invalid values
- Prompt template renders `issue` and `attempt`
- Prompt rendering fails on unknown variables (strict mode)

### 17.2 Workspace Manager and Safety

- Deterministic workspace path per issue identifier
- Missing workspace directory is created
- Existing workspace directory is reused
- Existing non-directory path at workspace location is handled safely (replace or fail per
  implementation policy)
- Optional workspace population/synchronization errors are surfaced
- Temporary artifacts (`tmp`, `.elixir_ls`) are removed during prep
- `after_create` hook runs only on new workspace creation
- `before_run` hook runs before each attempt and failure/timeouts abort the current attempt
- `after_run` hook runs after each attempt and failure/timeouts are logged and ignored
- `before_remove` hook runs on cleanup and failures/timeouts are ignored
- Workspace path sanitization and root containment invariants are enforced before agent launch
- Agent launch uses the per-issue workspace path as cwd and rejects out-of-root paths

### 17.3 Issue Tracker Client

- Candidate issue fetch uses active states and project slug
- Linear query uses the specified project filter field (`slugId`)
- Empty `fetch_issues_by_states([])` returns empty without API call
- Pagination preserves order across multiple pages
- Blockers are normalized from inverse relations of type `blocks`
- Labels are normalized to lowercase
- Issue state refresh by ID returns minimal normalized issues
- Issue state refresh query uses GraphQL ID typing (`[ID!]`) as specified in Section 11.2
- Error mapping for request errors, non-200, GraphQL errors, malformed payloads

### 17.4 Orchestrator Dispatch, Reconciliation, and Retry

- Dispatch consumes `waiting` order after `Queue.reconcile` (leftmost first).
  `Dispatch.sort_for_dispatch` is INITIAL ORDER only (no saved `queue_order`).
  Drag persists full identifier order; Linear raise re-inserts that one card;
  Linear lower never moves; new issues append unless Urgent (`priority == 1`)
  which inserts at index `0`. Skip a waiting head only when per-state or
  per-host slots are full; global slot exhaustion stops the walk and keeps
  remaining `waiting`. Do not claim waiting ids. No Linear writes.
- Queue pins overlay `dispatch_run_spec/3` as pin > labels > directive > config
  when dispatching from `waiting`.
- `Todo` issue with non-terminal blockers is not eligible
- `Todo` issue with terminal blockers is eligible
- Active-state issue refresh updates running entry state
- Non-active state stops running agent without workspace cleanup
- Terminal state stops running agent and cleans workspace
- Reconciliation with no running issues is a no-op
- Normal worker exit schedules a short continuation retry (attempt 1)
- Abnormal worker exit increments retries with 10s-based exponential backoff
- Retry backoff cap uses configured `agent.max_retry_backoff_ms`
- Retry queue entries include attempt, due time, identifier, and error
- Stall detection kills stalled sessions and schedules retry
- Slot exhaustion requeues retries with explicit error reason
- If a snapshot API is implemented, it returns running rows, waiting rows
  (`waiting` / `waiting_count` / `counts.waiting`), retry rows, token totals, and rate
  limits
- If a snapshot API is implemented, timeout/unavailable cases are surfaced

### 17.5 Coding-Agent App-Server Client

- Launch command uses workspace cwd and invokes `bash -lc <claude.command>`
- Startup handshake sends `initialize`, `initialized`, `thread/start`, `turn/start`
- `initialize` includes client identity/capabilities payload required by the targeted Claude Code
  app-server protocol
- Policy-related startup payloads use the implementation's documented approval/sandbox settings
- `thread/start` and `turn/start` parse nested IDs and emit `session_started`
- Request/response read timeout is enforced
- Turn timeout is enforced
- Partial JSON lines are buffered until newline
- Stdout and stderr are handled separately; protocol JSON is parsed from stdout only
- Non-JSON stderr lines are logged but do not crash parsing
- Command/file-change approvals are handled according to the implementation's documented policy
- Unsupported dynamic tool calls are rejected without stalling the session
- User input requests are handled according to the implementation's documented policy and do not
  stall indefinitely
- Usage and rate-limit payloads are extracted from nested payload shapes
- Compatible payload variants for approvals, user-input-required signals, and usage/rate-limit
  telemetry are accepted when they preserve the same logical meaning
- If optional client-side tools are implemented, the startup handshake advertises the supported tool
  specs required for discovery by the targeted app-server version
- If the optional `linear_graphql` client-side tool extension is implemented:
  - the tool is advertised to the session
  - valid `query` / `variables` inputs execute against configured Linear auth
  - top-level GraphQL `errors` produce `success=false` while preserving the GraphQL body
  - invalid arguments, missing auth, and transport failures return structured failure payloads
  - unsupported tool names still fail without stalling the session

### 17.6 Observability

- Validation failures are operator-visible
- Structured logging includes issue/session context fields
- Logging sink failures do not crash orchestration
- Token/rate-limit aggregation remains correct across repeated agent updates
- If a human-readable status surface is implemented, it is driven from orchestrator state and does
  not affect correctness
- If humanized event summaries are implemented, they cover key wrapper/agent event classes without
  changing orchestrator behavior
- If the LiveView dashboard is implemented (Section 13.7.1 refresh behavior):
  - a runtime tick that is not yet due to refresh moves no assign and renders identical HTML;
    the tick that *is* due still schedules the payload load (and so moves `:payload_seq` and
    `:last_payload_refresh`)
  - re-delivering a byte-identical payload, and a payload whose only movement is
    `generated_at`, reassigns no section and does not re-anchor `:now` (only
    `:token_samples` moves)
  - a payload whose only movement is a wall-clock-derived field the server re-derives on
    every load (a running entry's `tokens_per_second`) reassigns no section either
  - a payload that moves one section leaves the other section assigns alone
  - a payload that only moves the poll countdown leaves `:now` and the per-project section
    alone; a payload that moves a clock-bearing section re-anchors `:now`
  - time-derived spans carry their `data-clock` anchor as a remaining/elapsed amount, and
    drop the anchor attribute entirely when the amount is unknown so the server-rendered
    text survives
  - the client clock formatter and the server formatters produce identical strings

### 17.7 CLI and Host Lifecycle

- CLI accepts an optional positional workflow path argument (`path-to-WORKFLOW.md`)
- CLI uses `./WORKFLOW.md` when no workflow path argument is provided
- CLI errors on nonexistent explicit workflow path or missing default `./WORKFLOW.md`
- CLI surfaces startup failure cleanly
- CLI exits with success when application starts and shuts down normally
- CLI exits nonzero when startup fails or the host process exits abnormally

### 17.8 Real Integration Profile (Recommended)

These checks are recommended for production readiness and may be skipped in CI when credentials,
network access, or external service permissions are unavailable.

- A real tracker smoke test can be run with valid credentials supplied by `LINEAR_API_KEY` or a
  documented local bootstrap mechanism (for example `~/.linear_api_key`).
- Real integration tests should use isolated test identifiers/workspaces and clean up tracker
  artifacts when practical.
- A skipped real-integration test should be reported as skipped, not silently treated as passed.
- If a real-integration profile is explicitly enabled in CI or release validation, failures should
  fail that job.

## 18. Implementation Checklist (Definition of Done)

Use the same validation profiles as Section 17:

- Section 18.1 = `Core Conformance`
- Section 18.2 = `Extension Conformance`
- Section 18.3 = `Real Integration Profile`

### 18.1 Required for Conformance

- Workflow path selection supports explicit runtime path and cwd default
- `WORKFLOW.md` loader with YAML front matter + prompt body split
- Typed config layer with defaults and `$` resolution
- Dynamic `WORKFLOW.md` watch/reload/re-apply for config and prompt
- Polling orchestrator with single-authority mutable state
- Issue tracker client with candidate fetch + state refresh + terminal fetch
- Workspace manager with sanitized per-issue workspaces
- Workspace lifecycle hooks (`after_create`, `before_run`, `after_run`, `before_remove`)
- Hook timeout config (`hooks.timeout_ms`, default `60000`)
- Coding-agent app-server subprocess client with JSON line protocol
- Claude Code launch command config (`claude.command`, default `claude`)
- Strict prompt rendering with `issue` and `attempt` variables
- Exponential retry queue with continuation retries after normal exit
- Configurable retry backoff cap (`agent.max_retry_backoff_ms`, default 5m)
- Reconciliation that stops runs on terminal/non-active tracker states
- Workspace cleanup for terminal issues (startup sweep + active transition)
- Structured logs with `issue_id`, `issue_identifier`, and `session_id`
- Operator-visible observability (structured logs; optional snapshot/status surface)

### 18.2 Recommended Extensions (Not Required for Conformance)

- Optional HTTP server honors CLI `--port` over `server.port`, uses a safe default bind host, and
  exposes the baseline endpoints/error semantics in Section 13.7 if shipped.
- Optional `linear_graphql` client-side tool extension exposes raw Linear GraphQL access through the
  app-server session using configured Cymphony auth.
- TODO: Persist retry queue and session metadata across process restarts.
- TODO: Make observability settings configurable in workflow front matter without prescribing UI
  implementation details.
- TODO: Add first-class tracker write APIs (comments/state transitions) in the orchestrator instead
  of only via agent tools.
- TODO: Add pluggable issue tracker adapters beyond Linear.

### 18.3 Operational Validation Before Production (Recommended)

- Run the `Real Integration Profile` from Section 17.8 with valid credentials and network access.
- Verify hook execution and workflow path resolution on the target host OS/shell environment.
- If the optional HTTP server is shipped, verify the configured port behavior and loopback/default
  bind expectations on the target environment.

## Appendix A. SSH Worker Extension (Optional)

This appendix describes a common extension profile in which Cymphony keeps one central
orchestrator but executes worker runs on one or more remote hosts over SSH.

### A.1 Execution Model

- The orchestrator remains the single source of truth for polling, claims, retries, and
  reconciliation.
- `worker.ssh_hosts` provides the candidate SSH destinations for remote execution.
- Each worker run is assigned to one host at a time, and that host becomes part of the run's
  effective execution identity along with the issue workspace.
- `workspace.root` is interpreted on the remote host, not on the orchestrator host.
- The coding-agent app-server is launched over SSH stdio instead of as a local subprocess, so the
  orchestrator still owns the session lifecycle even though commands execute remotely.
- Continuation turns inside one worker lifetime should stay on the same host and workspace.
- A remote host should satisfy the same basic contract as a local worker environment: reachable
  shell, writable workspace root, coding-agent executable, and any required auth or repository
  prerequisites.

### A.2 Scheduling Notes

- SSH hosts may be treated as a pool for dispatch.
- Implementations may prefer the previously used host on retries when that host is still
  available.
- `worker.max_concurrent_agents_per_host` is an optional shared per-host cap across configured SSH
  hosts.
- When all SSH hosts are at capacity, dispatch should wait rather than silently falling back to a
  different execution mode.
- Implementations may fail over to another host when the original host is unavailable before work
  has meaningfully started.
- Once a run has already produced side effects, a transparent rerun on another host should be
  treated as a new attempt, not as invisible failover.

### A.3 Problems to Consider

- Remote environment drift:
  - Each host needs the expected shell environment, coding-agent executable, auth, and repository
    prerequisites.
- Workspace locality:
  - Workspaces are usually host-local, so moving an issue to a different host is typically a cold
    restart unless shared storage exists.
- Path and command safety:
  - Remote path resolution, shell quoting, and workspace-boundary checks matter more once execution
    crosses a machine boundary.
- Startup and failover semantics:
  - Implementations should distinguish host-connectivity/startup failures from in-workspace agent
    failures so the same ticket is not accidentally re-executed on multiple hosts.
- Host health and saturation:
  - A dead or overloaded host should reduce available capacity, not cause duplicate execution or an
    accidental fallback to local work.
- Cleanup and observability:
  - Operators need to know which host owns a run, where its workspace lives, and whether cleanup
    happened on the right machine.
