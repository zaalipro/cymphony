---
spec_id: 01
feature_name: orchestrator_hardening
status: complete
created: 2026-05-19
last_updated: 2026-05-19
source_prompt: |
  Now please create a spec file for this feature — covering all three of the
  retrospective's "worth fixing" items combined into one spec:
    1. Persistent completed-sessions store (was: in-memory ring buffer cleared on restart).
    2. Documented + tested blocker-aware dispatch (verify and harden existing behavior).
    3. linear_graphql tool exposed to Claude via MCP (overrides the current
       "agents can curl Linear directly" stance in claude/dynamic_tool.ex).
assumptions:
  - The completion store will be backed by SQLite via the exqlite library — embedded, single-file, no external service required, matches the project's "no persistent DB required" SPEC heritage while still surviving restarts.
  - The linear_graphql tool will be implemented as a per-session stdio MCP server passed to Claude via `--mcp-config` — that is the canonical Claude Code extension mechanism, mirrors openai/symphony SPEC §10.5's "advertised client-side tool" intent, and isolates lifecycle to a single agent run.
  - Blocker-aware dispatch is already implemented in `orchestrator.ex` (`should_dispatch_issue?/4` + `todo_issue_blocked_by_non_terminal?/2`); the work for REQ-002 is therefore regression tests + documentation, not new behavior.
  - The completion store file lives at `~/.cymphony/sessions.db` by default and is shared across projects (each row carries `project_name`).
  - MCP server failure is non-fatal — the agent run continues without the tool rather than aborting.
---

# 01 — Orchestrator Hardening

## Requirements Document

### Introduction

This feature hardens three independent orchestrator concerns in a single shipment: it persists completed-session records so audit history survives daemon restarts, it adds regression coverage and documentation for blocker-aware dispatch (already in code), and it formalizes Linear API access from agents by spawning a per-session `linear_graphql` MCP server that Claude can invoke as a first-class tool. The audience is the Cymphony operator who runs the daemon and the agent author who authors prompts; the business value is durability (no lost audit trail), correctness coverage (blocker rule cannot regress silently), and ergonomic Linear access for agents (typed GraphQL operations instead of ad-hoc curl).

### Functional Requirements

#### REQ-001 — Persistent completed-sessions store

**User Story**

> As an operator, I want completed agent sessions to survive daemon restarts, so that I can audit historical work without losing the in-memory ring buffer on every redeploy.

**Acceptance Criteria**

1. **AC-001** — WHEN a session reaches a terminal lifecycle outcome (succeeded, failed, timed-out, cancelled-by-reconciliation) THEN the orchestrator SHALL write a completion record to the persistent store before updating the in-memory `recent_completed` ring buffer.
2. **AC-002** — WHEN the daemon starts THEN it SHALL load up to the most-recent 100 completion records from the persistent store into each project's in-memory `recent_completed` buffer, scoped by `project_name`.
3. **AC-003** — WHEN `GET /api/v1/completed` is called with `?limit=N` (1 ≤ N ≤ 1000) THEN the response SHALL return up to `N` records drawn from the persistent store ordered by `ended_at` descending, optionally filtered by `?project=<name>`.
4. **AC-004** — IF the persistent store fails to open at startup THEN the orchestrator SHALL log a structured warning and continue running with an in-memory-only buffer; subsequent completion writes SHALL NOT crash the orchestrator.
5. **AC-005** — WHEN a completion write fails after the store has opened successfully THEN the orchestrator SHALL log a structured error and continue (the write is best-effort and does not block the lifecycle transition).

#### REQ-002 — Documented and tested blocker-aware dispatch

**User Story**

> As an operator, I want regression coverage of blocker-aware dispatch, so that future refactors cannot silently re-enable dispatch of Todo issues whose blockers are still non-terminal.

**Acceptance Criteria**

1. **AC-006** — WHEN a Todo issue has at least one blocker whose state is not in `terminal_states` THEN `should_dispatch_issue?/4` SHALL return `false`.
2. **AC-007** — WHEN a Todo issue's blockers are all in `terminal_states` THEN `should_dispatch_issue?/4` SHALL return `true` (assuming all other dispatch conditions hold).
3. **AC-008** — WHEN an issue in any state other than Todo has non-terminal blockers THEN the blocker rule SHALL NOT prevent dispatch (the rule applies only to Todo per openai/symphony SPEC §8.2).
4. **AC-009** — WHEN a Todo issue's `blocked_by` list is empty THEN dispatch SHALL NOT be blocked by this rule.

#### REQ-003 — `linear_graphql` MCP tool for Claude

**User Story**

> As an agent author, I want a first-class `linear_graphql` tool exposed to Claude via MCP, so that agents can run typed GraphQL operations against Linear without shelling out to curl and parsing raw JSON by hand.

**Acceptance Criteria**

1. **AC-010** — WHEN an agent run starts AND `tracker.kind == "linear"` AND `tracker.api_key` resolves to a non-empty string THEN the spawned `claude` process SHALL receive a `--mcp-config <path>` flag pointing to a per-session MCP descriptor that registers a stdio MCP server named `cymphony-linear`.
2. **AC-011** — WHEN the agent invokes the `linear_graphql` tool with `{ "query": <string>, "variables": <object|null> }` THEN the MCP server SHALL execute the operation against the configured Linear endpoint using the configured `api_key` and return the GraphQL response body.
3. **AC-012** — WHEN the GraphQL response contains a non-empty top-level `errors` array THEN the MCP tool SHALL return `{ "success": false, "errors": <errors>, "data": <data-or-null> }`.
4. **AC-013** — WHEN the GraphQL response succeeds with no top-level `errors` THEN the MCP tool SHALL return `{ "success": true, "data": <data> }`.
5. **AC-014** — IF the `query` argument is empty, non-string, or contains more than one GraphQL operation THEN the MCP tool SHALL return `{ "success": false, "error": <reason> }` without making any network call.
6. **AC-015** — WHILE `tracker.kind != "linear"` or `tracker.api_key` is missing THE SYSTEM SHALL NOT include any `--mcp-config` entry for `cymphony-linear` in the spawned `claude` command line (the tool must be absent, not present-and-failing).

### Non-Functional Requirements

#### NFR-001 — Performance

1. **AC-016** — WHEN the completion store writes a record THEN the operation SHALL complete within 50 ms at the 95th percentile under nominal load (≤ 10 writes/sec across all projects).
2. **AC-017** — WHEN the `linear_graphql` MCP tool is invoked THEN it SHALL return a response (success or error) within 30 seconds; a slower upstream Linear response is surfaced as a timeout error.

#### NFR-002 — Security

1. **AC-018** — WHILE the `linear_graphql` MCP server is logging THE SYSTEM SHALL NOT emit the `api_key` value to any log sink.
2. **AC-019** — WHEN the completion store file is created THEN its permissions SHALL be set to `0600` (owner read/write only).
3. **AC-020** — WHERE the MCP server reads the Linear API key THE SYSTEM SHALL read it from an environment variable passed to the stdio server, not from CLI arguments visible in `ps`.

#### NFR-003 — Accessibility

None — no new UI surface is added in this spec; the existing dashboard's "Recent completions" section keeps its current keyboard/screen-reader semantics and inherits any improvements made elsewhere.

#### NFR-004 — Observability

1. **AC-021** — WHEN the completion store writes a record THEN a structured log event SHALL be emitted with fields `event="completion_store.write" issue_id=... project=... status=ok|error duration_ms=...`.
2. **AC-022** — WHEN the MCP `cymphony-linear` server starts THEN a structured log event SHALL be emitted with fields `event="mcp.linear_graphql.started" workspace_path=... pid=...`.
3. **AC-023** — WHEN the MCP `linear_graphql` tool executes a call THEN a structured log event SHALL be emitted with fields `event="mcp.linear_graphql.call" operation_name=... success=true|false duration_ms=...`.

#### NFR-005 — Reliability

1. **AC-024** — IF the completion store fails to open at startup THEN the orchestrator SHALL log `event="completion_store.unavailable"` and continue with in-memory-only operation; subsequent completions SHALL NOT crash the orchestrator.
2. **AC-025** — IF the MCP `cymphony-linear` server crashes during an agent run THEN the agent run SHALL continue and the crashed MCP server SHALL NOT be auto-restarted within the same run.

#### NFR-006 — Compatibility

1. **AC-026** — WHEN the daemon starts against an installation that has no `sessions.db` file THEN the file SHALL be created at `~/.cymphony/sessions.db` with schema migrations applied automatically.
2. **AC-027** — WHEN `tracker.kind != "linear"` THEN the spawned `claude` command line SHALL NOT include any `cymphony-linear` MCP config entry — the feature is opt-in by tracker configuration.

### Out of Scope

- Long-term retention, compaction, or vacuum policy for `sessions.db` (operator runs SQLite tools manually if size grows).
- A search or filter UI for completed sessions in the Phoenix dashboard (the existing list view is preserved).
- Export of completion records to external observability systems (Prometheus, Honeycomb, OpenTelemetry).
- A generalized MCP server framework for non-Linear trackers — only `linear_graphql` is in scope.
- Deprecating the existing curl-based pattern in `prompt_template.ex` — both paths coexist for at least one release.
- Replacing the in-memory ring buffer — both coexist; the store is the source of truth on restart, the ring buffer is the live view.

### User Journeys

1. **Happy path — restart-safe audit.** Operator runs `cymphony restart`. They open the dashboard at `http://localhost:4089/` and see the last 100 sessions in "Recent completions" — same content as before the restart. They call `GET /api/v1/completed?limit=500&project=AgentFarm` and receive 500 historical records ordered most-recent first.
2. **Happy path — agent uses Linear MCP tool.** Agent author writes a prompt that says "use the `linear_graphql` tool to transition this issue to Human Review." Claude calls the tool with a typed mutation; the MCP server forwards it to Linear, returns the GraphQL response. The agent confirms success and continues.
3. **Alternate path — blocked issue stays queued.** Operator creates a Todo issue B that is blocked by A (A is `In Progress`). Cymphony polls, sees B but does not dispatch it. A reaches `Done` (terminal). On the next poll tick, B becomes eligible and dispatches.
4. **Alternate path — store unavailable, daemon still useful.** Disk is full; SQLite cannot open. The daemon logs `completion_store.unavailable`, starts anyway, completions populate the in-memory buffer only. Operator clears disk space and restarts.

---

## Plan Document

### Introduction

This plan adds two new modules — `CymphonyElixir.CompletionStore` (a single-writer GenServer that wraps an embedded SQLite database via `exqlite`) and `CymphonyElixir.Mcp.LinearGraphqlServer` (a stdio-protocol MCP server that exposes a `linear_graphql` tool to Claude) — and minimally amends three existing modules (`orchestrator.ex`, `claude/app_server.ex`, `claude/dynamic_tool.ex`). It also adds focused regression tests for the existing `should_dispatch_issue?/4` blocker logic and an explanatory docstring on `todo_issue_blocked_by_non_terminal?/2`. The completion store integrates at two orchestrator call sites (`init/1` for restore, `complete_issue/3` for write). The MCP server integrates at one site (`build_claude_command/4`, which composes the spawned `claude` argv). All new code follows existing conventions: `@spec` on every public function (enforced by `mix specs.check`), Ecto schemas where structured data flows, structured `Logger` events for observability, and `100%` coverage threshold on tracked modules.

### Understanding

The user's request restated: combine three retrospective items — persistent completed-session storage, formal coverage of the existing blocker-aware dispatch, and a real `linear_graphql` MCP tool — into one spec.

**Key objectives**

- Completion records survive daemon restart with no operator action required.
- The blocker rule has explicit unit tests that pin its current behavior so a future refactor cannot break it silently.
- An agent calling `linear_graphql` invokes a typed tool instead of shelling out to curl.

**Constraints**

- No new external services (no Postgres, no Redis). Embedded SQLite only.
- No breaking changes to `/api/v1/completed` — only additive (new `?limit=` upper bound, new persistence behind the scenes).
- MCP server must be opt-in via `tracker.kind == "linear"` so non-Linear deployments are unaffected.
- Must pass `make all` (specs.check, credo --strict, dialyzer, coverage).

**Open clarifying questions:** None. Storage backend (SQLite) and tool transport (MCP stdio) are captured as Assumptions in the metadata header.

### Solution Design

**High-level approach.** Introduce one new GenServer for persistence and one new escript-style stdio process for tool transport. Both are bolt-on additions hooked into existing call sites — neither replaces existing in-memory state. The orchestrator continues to own all mutable state; the store is a write-through cache from the orchestrator's perspective and a read-through index from the API's perspective.

**Data flow & architecture.**

```
                                      ┌─────────────────────┐
                                      │  Orchestrator (per  │
   ┌─── init/1 (restore last 100) ───>│  project GenServer) │
   │                                  └──┬──────────────────┘
   │                                     │ complete_issue/3
   │                                     ▼ write_async
┌──┴──────────────────────────┐       ┌──────────────────────┐
│ CompletionStore (GenServer) │<──────│ ~/.cymphony/         │
│ — single-writer SQLite      │       │   sessions.db (0600) │
└──┬──────────────────────────┘       └──────────────────────┘
   │ read (limit/project filter)
   ▼
┌─────────────────────────────┐
│ ObservabilityApiController  │  GET /api/v1/completed
└─────────────────────────────┘

Per agent run:
  Orchestrator dispatch
     │
     ▼
  AgentRunner ──► Claude.AppServer.build_claude_command/4
                       │
                       │ if tracker.kind == "linear" && api_key
                       ▼
                  writes per-session mcp_config.json into workspace
                       │
                       ▼
                  spawns: claude -p ... --mcp-config <path>
                       │
                       ▼
                  Claude spawns stdio: elixir mcp/linear_graphql.exs
                       │
                       ▼
                  MCP server reads LINEAR_API_KEY from env, serves
                  `linear_graphql` tool calls against Linear GraphQL
```

**Step-by-step execution plan.**

1. Add `exqlite` dependency to `mix.exs`.
2. Implement `CymphonyElixir.CompletionStore` (GenServer): start under main supervisor, open `~/.cymphony/sessions.db`, run idempotent schema migration, expose `put/1`, `recent/2`, `count/1`.
3. Wire `Orchestrator.init/1` to seed `recent_completed` from `CompletionStore.recent(project_name, 100)`.
4. Wire `Orchestrator.complete_issue/3` to call `CompletionStore.put_async/1` immediately before updating `state.recent_completed`.
5. Update `ObservabilityApiController.completed/2` to read from `CompletionStore.recent/2` when `?limit` is set, falling back to the in-memory snapshot otherwise.
6. Add regression tests for `should_dispatch_issue?/4` covering AC-006..AC-009; add a docstring to `todo_issue_blocked_by_non_terminal?/2` linking the SPEC clause.
7. Implement `CymphonyElixir.Mcp.LinearGraphqlServer` — a `Mix.Task` that runs as a stdio MCP server, reads `LINEAR_API_KEY` from the env, validates input, calls `Linear.Client.graphql/3`, returns response.
8. In `Claude.AppServer.build_claude_command/4`: when `tracker.kind == "linear"` and an api_key is configured, write a per-workspace `mcp_config.json` (descriptor for the `cymphony-linear` server) and append `--mcp-config <path>` to the argv.
9. Update `Claude.DynamicTool` module doc to record the new MCP-based path; keep the placeholder body so existing tests still pass.
10. Add the three structured log events called out in NFR-004.

**Edge cases & failure handling.**

- `sessions.db` is locked by another process (e.g., a stale daemon). Outcome: store opens with `busy_timeout=5000`, retries once, then logs `completion_store.unavailable` and the daemon continues with in-memory-only operation (AC-004, AC-024).
- `LINEAR_API_KEY` env var is set but the value is wrong. Outcome: MCP server starts; first tool call returns `{ success: false, error: "linear_api_status_401" }` (AC-012's error envelope).
- Claude is invoked but no `linear_graphql` call is ever made. Outcome: MCP server idles on stdin, exits when Claude exits — zero cost beyond process spawn.
- Multiple projects complete sessions simultaneously. Outcome: `CompletionStore` is a single-writer GenServer, so writes are serialized; reads use SQLite's default snapshot semantics.

**Scalability & performance.** SQLite easily sustains the project's order-of-magnitude (≤ 10 completions/sec across all projects). The completion table is indexed on `(project_name, ended_at DESC)` so the typical "last 100 per project" query is `O(100)`. The MCP server is one process per agent run, sharing the workspace's lifetime, so per-process memory is bounded by Linear's GraphQL response size.

**Decisions**

- **DES-001** — Use embedded SQLite via `exqlite` for the completion store. *Satisfies: REQ-001.* Reasoning: no external service, single file, ACID, fast enough; matches Cymphony's "no required DB" SPEC heritage while gaining durability.
- **DES-002** — `CompletionStore` is a single-writer GenServer with async (`cast`) writes from `Orchestrator` and synchronous (`call`) reads from the API controller. *Satisfies: REQ-001.* Reasoning: serializes writes (eliminates SQLite lock contention), keeps the orchestrator's lifecycle transition non-blocking on the write path, allows clean degradation when the DB is unavailable.
- **DES-003** — Add regression tests against the existing `should_dispatch_issue?/4` rather than refactoring the rule. *Satisfies: REQ-002.* Reasoning: the current implementation is correct (verified against SPEC §8.2); the gap is coverage, not behavior. A non-invasive test pins the behavior.
- **DES-004** — Implement `linear_graphql` as a per-session stdio MCP server (not a built-in tool, not a `~/.claude.json` global server). *Satisfies: REQ-003.* Reasoning: lifetime bound to the agent run; isolation per workspace; no shared global config to leak between sessions; matches Claude Code's documented MCP extension model.
- **DES-005** — The MCP descriptor file lives in the per-issue workspace as `mcp_config.json`. *Satisfies: REQ-003, AC-010.* Reasoning: cleanup is automatic when the workspace is cleaned; one descriptor per session avoids cross-issue mixing.
- **DES-006** — Linear API key is passed to the MCP server via the spawned environment, not via argv. *Satisfies: NFR-002, AC-020.* Reasoning: argv is visible in `ps` and process listings; env is per-process and not exposed.

### Components & Interfaces

- **CymphonyElixir.CompletionStore** — Single-writer GenServer wrapping an `exqlite` SQLite connection. Owns `sessions.db` schema and the `put/1`, `recent/2`, `count/1` API.
  - API: `start_link(opts)`, `put_async(record :: map())`, `recent(project_name :: String.t() | :all, limit :: pos_integer()) :: [map()]`, `count(project_name :: String.t() | :all) :: non_neg_integer()`.
  - Path: `lib/cymphony_elixir/completion_store.ex`.

- **CymphonyElixir.Mcp.LinearGraphqlServer** — Stdio MCP server that exposes a `linear_graphql` tool backed by `Linear.Client`. Runs as a child process under Claude, not under Cymphony's supervision tree.
  - API: `main(argv :: [String.t()]) :: no_return()` — reads JSON-RPC frames from stdin, writes responses to stdout.
  - Path: `lib/cymphony_elixir/mcp/linear_graphql_server.ex`.

- **CymphonyElixir.Mcp.ConfigWriter** — Pure module that emits the per-session `mcp_config.json` Claude expects.
  - API: `write(workspace_path :: Path.t(), tracker_config :: map()) :: {:ok, Path.t()} | {:error, term()}`.
  - Path: `lib/cymphony_elixir/mcp/config_writer.ex`.

- **CymphonyElixir.Orchestrator** (modified) — Calls `CompletionStore.recent/2` in `init/1`; calls `CompletionStore.put_async/1` in `complete_issue/3`.
  - Path: `lib/cymphony_elixir/orchestrator.ex` (lines ~43, ~879).

- **CymphonyElixir.Claude.AppServer** (modified) — `build_claude_command/4` invokes `Mcp.ConfigWriter.write/2` and appends `--mcp-config <path>` when applicable.
  - Path: `lib/cymphony_elixir/claude/app_server.ex` (line ~148).

- **CymphonyElixir.Claude.DynamicTool** (modified) — Docstring updated to point at the new MCP path. Public functions retained as no-op placeholders for backward compatibility.
  - Path: `lib/cymphony_elixir/claude/dynamic_tool.ex`.

- **CymphonyElixir.ObservabilityApiController** (modified) — `completed/2` honors `?limit` against the persistent store; in-memory snapshot used when no limit specified.
  - Path: `lib/cymphony_elixir_web/controllers/observability_api_controller.ex` (line ~49).

- **CymphonyElixir.Supervisor** (modified) — Adds `CompletionStore` as a permanent child early in the supervision tree (before `ProjectDynamicSupervisor`).
  - Path: `lib/cymphony_elixir.ex` (lines 25–38).

### Dependencies

- **exqlite** `~> 0.27` — Bare SQLite NIF driver for Elixir. Chosen over `ecto_sqlite3` because the store needs only three queries (insert, select, count) and Ecto would be overhead; matches the project's minimal-deps stance.

### Integration Points

Insert into the supervision tree (between `Registry` and `Task.Supervisor`, before any project starts):

```elixir
# lib/cymphony_elixir.ex
children = [
  {Phoenix.PubSub, name: CymphonyElixir.PubSub},
  {Registry, keys: :unique, name: CymphonyElixir.ProjectRegistry},
  CymphonyElixir.CompletionStore,
  {Task.Supervisor, name: CymphonyElixir.TaskSupervisor},
  {DynamicSupervisor, name: CymphonyElixir.ProjectDynamicSupervisor, strategy: :one_for_one},
  CymphonyElixir.HttpServer,
  CymphonyElixir.StatusDashboard
]
```

Seed the in-memory ring buffer from the store on orchestrator startup:

```elixir
# lib/cymphony_elixir/orchestrator.ex (init/1)
recent_completed =
  CompletionStore.recent(project_name, @max_recent_completed)

{:ok, %State{state | recent_completed: recent_completed}, {:continue, :schedule_first_tick}}
```

Write-through on session completion:

```elixir
# lib/cymphony_elixir/orchestrator.ex (complete_issue/3)
defp complete_issue(%State{} = state, issue_id, running_entry) do
  record = build_completed_record(issue_id, running_entry, state.project_name)
  :ok = CompletionStore.put_async(record)
  recent = [record | state.recent_completed] |> Enum.take(@max_recent_completed)
  %{state | recent_completed: recent, retry_attempts: Map.delete(state.retry_attempts, issue_id)}
end
```

Append `--mcp-config` when Linear is the active tracker:

```elixir
# lib/cymphony_elixir/claude/app_server.ex (build_claude_command/4)
args =
  args
  |> maybe_add_mcp_config(workspace, config)

defp maybe_add_mcp_config(args, workspace, %{tracker: %{kind: "linear", api_key: key}} = _config)
     when is_binary(key) and key != "" do
  case Mcp.ConfigWriter.write(workspace, %{api_key: key, endpoint: ...}) do
    {:ok, path} -> args ++ ["--mcp-config", shell_escape(path)]
    {:error, _} -> args
  end
end

defp maybe_add_mcp_config(args, _workspace, _config), do: args
```

The MCP descriptor file Cymphony writes (consumed by Claude):

```json
{
  "mcpServers": {
    "cymphony-linear": {
      "command": "elixir",
      "args": ["-S", "mix", "cymphony.mcp.linear_graphql"],
      "env": {
        "LINEAR_API_KEY": "***resolved-at-write-time***",
        "LINEAR_ENDPOINT": "https://api.linear.app/graphql"
      }
    }
  }
}
```

### Testing Strategy

- **Unit:** **TEST-001** — `CompletionStore.put_async/1` then `recent/2` round-trip; verify ordering by `ended_at` desc and per-project filtering. Verifies: AC-001, AC-002, AC-003.
- **Unit:** **TEST-002** — `CompletionStore.start_link/1` with an un-openable path; assert `{:ok, _pid}` plus a `completion_store.unavailable` log event; subsequent `put_async/1` returns `:ok` (no crash). Verifies: AC-004, AC-005, AC-024.
- **Unit:** **TEST-003** — `Orchestrator.should_dispatch_issue?/4` truth-table covering: (a) Todo + non-terminal blocker → false, (b) Todo + all-terminal blockers → true, (c) In Progress + non-terminal blocker → true, (d) Todo + empty blocker list → true. Verifies: AC-006, AC-007, AC-008, AC-009.
- **Unit:** **TEST-004** — `Mcp.ConfigWriter.write/2` produces a JSON file with the expected `mcpServers.cymphony-linear` entry and the resolved api_key in `env` (not `args`). Verifies: AC-010, AC-020, AC-027.
- **Integration:** **TEST-005** — `Mcp.LinearGraphqlServer` end-to-end: feed a JSON-RPC `tools/call` frame with a mocked GraphQL endpoint, assert the success and error envelopes match AC-011..AC-014. Verifies: AC-011, AC-012, AC-013, AC-014.
- **Integration:** **TEST-006** — `Claude.AppServer.build_claude_command/4` with `tracker.kind == "linear"` includes `--mcp-config`; with `tracker.kind == "memory"` does not. Verifies: AC-015, AC-026, AC-027.
- **Integration:** **TEST-007** — Restart-recovery: write 150 completions, shut down `CompletionStore`, start a fresh orchestrator, assert `state.recent_completed` is the most-recent 100 records ordered correctly. Verifies: AC-002.
- **End-to-end:** **TEST-008** — Gated behind `CYMPHONY_RUN_LIVE_E2E=1`. Launch a real Claude session in the Docker harness with the MCP server attached, prompt the agent to call `linear_graphql`, assert a real Linear API roundtrip succeeds. Verifies: AC-010..AC-014, AC-017.
- **Regression:** None — the existing test suite covers prior behavior; this spec is purely additive.
- **Manual QA:** Restart the daemon between two real runs, confirm `/api/v1/completed?limit=200` returns records from before the restart.

### Rollout Plan

- **Migration steps:** On first startup with the new code, `CompletionStore` creates `~/.cymphony/sessions.db` and applies an idempotent `CREATE TABLE IF NOT EXISTS sessions (...)` migration. No data migration needed (no prior persistent state).
- **Backwards compatibility:** The in-memory ring buffer remains the source of truth for the live LiveView dashboard. The store augments rather than replaces it. `/api/v1/completed` without `?limit` returns the same shape as before. Existing prompts that curl Linear continue to work unchanged.
- **Rollback:** Three steps. (1) Revert the orchestrator integration commit. (2) Remove the `--mcp-config` append in `Claude.AppServer.build_claude_command/4`. (3) Optionally delete `~/.cymphony/sessions.db`. The MCP server module and `CompletionStore` module can stay in tree — they have no effect when the integration call sites are removed.
- **Observability:** Three new structured log events (AC-021, AC-022, AC-023). No new metrics or alerts proposed in this spec.
- **Feature flags:** None — the changes are guarded by tracker kind (`linear_graphql` MCP) and graceful degradation (`CompletionStore` falls back to in-memory). An explicit flag is not warranted for the initial release.

### Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| SQLite file growth in long-running daemons | Medium | Low | Spec out-of-scope for this iteration; manual vacuum suffices for 6+ months at observed rates |
| MCP server crash kills the agent run | Low | Medium | Claude treats MCP server crashes as tool unavailability, not run failure; we also document AC-025 explicitly |
| Existing prompts that curl Linear now have a more attractive tool — split adoption | Medium | Low | Both paths kept; documentation update suggests `linear_graphql` for new prompts, no forced migration |
| Per-session MCP descriptor leaks api_key to disk | Medium | Medium | Descriptor file mode `0600`; lives in workspace (already isolated); deleted with workspace cleanup |
| Coverage threshold breaks because new modules included | Low | Low | New modules added to `mix.exs` tracked list with full test coverage targets |

### Research

- [Claude Code MCP documentation](https://docs.claude.com/en/docs/claude-code/mcp) — version 2026-Q2, accessed 2026-05-19 — Confirms `--mcp-config <path>` accepts a JSON object with `mcpServers.<name>.{command, args, env}` and the server speaks JSON-RPC over stdio.
- [openai/symphony SPEC.md §10.5](https://github.com/openai/symphony/blob/main/SPEC.md) — version main@2026-05-16, accessed 2026-05-19 — Defines the `linear_graphql` tool contract that DES-004's MCP implementation satisfies (input shape, success/error envelopes, single-operation rule).
- [exqlite Hex docs](https://hexdocs.pm/exqlite/Exqlite.html) — version 0.27.x, accessed 2026-05-19 — Confirms `Exqlite.Sqlite3.open/2` with `busy_timeout` option, parameter binding, and statement caching meet our performance budget.
- [SQLite WAL journal mode](https://www.sqlite.org/wal.html) — accessed 2026-05-19 — Confirms WAL mode is safe for our single-writer / multiple-reader pattern.

### Codebase Analysis

- **Architecture patterns observed:** GenServer-per-project (`Orchestrator`), Behaviour-based abstraction (`Tracker`), Phoenix.PubSub for fan-out, Registry for project lookup, Task.Supervisor for spawned agent tasks, Port for `claude` subprocess. New modules will fit naturally: `CompletionStore` is one more GenServer under the main supervisor.
- **Coding conventions in use:** Every public `def` carries `@spec` (enforced by `mix specs.check`), Ecto embedded schemas for config (`config/schema.ex`), `Logger` for structured logging, `@type t :: %__MODULE__{}` on every struct module.
- **Testing approaches in use:** ExUnit, 100% coverage threshold on tracked modules (declared in `mix.exs:11–40`), `:live_e2e` tag for Docker-backed real-world tests, snapshot tests for the terminal dashboard (`test/fixtures/status_dashboard_snapshots/`).
- **Similar implementations:** `Orchestrator.complete_issue/3` and `build_completed_record/3` (`lib/cymphony_elixir/orchestrator.ex:879-910`) already produce the exact record shape we want to persist. `Linear.Client` (`lib/cymphony_elixir/linear/client.ex`) already encapsulates GraphQL HTTP plumbing — the MCP server will call it directly. The pattern for `--<flag> <value>` argv composition already exists in `build_claude_command/4` (`lib/cymphony_elixir/claude/app_server.ex:148`).
- **Integration points new code must hook into:** `CymphonyElixir.Supervisor.children/0` (add `CompletionStore`); `Orchestrator.init/1` and `Orchestrator.complete_issue/3` (read + write); `Claude.AppServer.build_claude_command/4` (append `--mcp-config`); `ObservabilityApiController.completed/2` (read).
- **Existing utilities to reuse:** `Linear.Client.graphql/3` for MCP server execution; `PathSafety.canonicalize/1` for the workspace-relative descriptor path; `Cymphony.Config` for `~/.cymphony` directory resolution; `Logger.metadata/1` for structured log context fields.

---

## Task List Document

- [ ] **TASK-001** [setup] Add `exqlite` dependency at `~> 0.27` to `mix.exs` and run `mix deps.get`. Paths: `mix.exs`, `mix.lock`. Implements: `REQ-001`, `DES-001`. Verifies: `N/A`. Depends: `None`. Done when: `mix deps.get` succeeds and `Application.spec(:exqlite, :vsn)` returns a non-nil 0.27.x version.
- [ ] **TASK-002** [model] Create `CymphonyElixir.CompletionStore` GenServer skeleton: on `init/1` open `~/.cymphony/sessions.db` (mode `0600`, `busy_timeout=5000`, `journal_mode=WAL`); apply idempotent migration creating `sessions(issue_id TEXT, identifier TEXT, project_name TEXT, ended_at TEXT, started_at TEXT, runtime_seconds INTEGER, claude_input_tokens INTEGER, claude_output_tokens INTEGER, claude_total_tokens INTEGER, worker_host TEXT, workspace_path TEXT, PRIMARY KEY (issue_id, ended_at))` plus index `idx_sessions_project_ended` on `(project_name, ended_at DESC)`; on open failure transition to `:degraded` state without crashing. Paths: `lib/cymphony_elixir/completion_store.ex`. Implements: `REQ-001`, `DES-001`, `DES-002`. Verifies: `N/A`. Depends: `TASK-001`. Done when: `mix compile` succeeds; `ls -l ~/.cymphony/sessions.db` shows mode `-rw-------`; opening with an unwritable path returns `{:ok, _pid}` and logs `completion_store.unavailable`.
- [ ] **TASK-003** [service] Implement `CompletionStore.put_async/1`, `recent/2` (signature `String.t() | :all, 1..1000`, returns rows ordered by `ended_at` DESC), and `count/1`. Emit structured Logger events `event="completion_store.write" status=ok|error duration_ms=...` per AC-021. Paths: `lib/cymphony_elixir/completion_store.ex`. Implements: `REQ-001`, `DES-002`. Verifies: `N/A`. Depends: `TASK-002`. Done when: `mix specs.check` passes; REPL: `CompletionStore.put_async(r) ; CompletionStore.recent("p", 3)` returns the 3 newest in DESC order.
- [ ] **TASK-004** [service] Implement `CymphonyElixir.Mcp.ConfigWriter.write/2` that writes `<workspace>/.cymphony/mcp_config.json` (mode `0600`) containing `mcpServers.cymphony-linear.{command:"elixir", args:["-S","mix","cymphony.mcp.linear_graphql"], env:{LINEAR_API_KEY, LINEAR_ENDPOINT}}`. The api_key MUST appear only in `env`, never in `args`. Paths: `lib/cymphony_elixir/mcp/config_writer.ex`. Implements: `REQ-003`, `DES-005`, `DES-006`. Verifies: `N/A`. Depends: `TASK-001`. Done when: `mix specs.check` passes; file written matches the JSON shape from §6.6 of this spec.
- [ ] **TASK-005** [service] Implement `CymphonyElixir.Mcp.LinearGraphqlServer` as Mix.Task `cymphony.mcp.linear_graphql`: read JSON-RPC frames from stdin, advertise one tool `linear_graphql` (input schema `{query: string, variables?: object}`), validate query non-empty + single operation, call `CymphonyElixir.Linear.Client.graphql/3` using `LINEAR_API_KEY` and `LINEAR_ENDPOINT` from env, write JSON-RPC responses to stdout. Emit `event="mcp.linear_graphql.started"` on init and `event="mcp.linear_graphql.call" success= duration_ms=` per call. Paths: `lib/mix/tasks/cymphony.mcp.linear_graphql.ex`, `lib/cymphony_elixir/mcp/linear_graphql_server.ex`. Implements: `REQ-003`, `DES-004`. Verifies: `N/A`. Depends: `TASK-001`. Done when: `echo '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{}}' \| mix cymphony.mcp.linear_graphql` returns a well-formed initialize response on stdout.
- [ ] **TASK-006** [integration] Register `CymphonyElixir.CompletionStore` as a permanent supervisor child between `Registry` and `Task.Supervisor` in `CymphonyElixir.Supervisor.children/0`. Paths: `lib/cymphony_elixir.ex`. Implements: `REQ-001`, `DES-002`. Verifies: `N/A`. Depends: `TASK-003`. Done when: `iex -S mix` and `Process.whereis(CymphonyElixir.CompletionStore)` returns a pid.
- [ ] **TASK-007** [integration] In `Orchestrator.init/1` replace the `recent_completed: []` initialization with `CompletionStore.recent(project_name, @max_recent_completed)`; on `:degraded` store, fall back to `[]` without raising. Paths: `lib/cymphony_elixir/orchestrator.ex` (line ~43). Implements: `REQ-001`, `DES-002`. Verifies: `N/A`. Depends: `TASK-006`. Done when: starting an orchestrator for a project that has seeded DB rows populates `state.recent_completed` in DESC order.
- [ ] **TASK-008** [integration] In `Orchestrator.complete_issue/3` insert `:ok = CompletionStore.put_async(record)` immediately before the `recent = [record | ...]` line; wrap in `try/rescue` that logs and continues on any exception. Paths: `lib/cymphony_elixir/orchestrator.ex` (line ~879). Implements: `REQ-001`, `DES-002`. Verifies: `N/A`. Depends: `TASK-006`. Done when: completing a session writes a row to `sessions.db`; raising in `put_async` does not crash the orchestrator (manual: `:sys.replace_state` to inject a faulty store).
- [ ] **TASK-009** [integration] In `Claude.AppServer.build_claude_command/4` add private `maybe_add_mcp_config/3` that, when `config.tracker.kind == "linear"` and `config.tracker.api_key` is non-empty, calls `Mcp.ConfigWriter.write/2` and appends `["--mcp-config", shell_escape(path)]` to argv. For any other tracker kind or missing key, return argv unchanged. Paths: `lib/cymphony_elixir/claude/app_server.ex` (line ~148). Implements: `REQ-003`, `DES-004`, `DES-005`. Verifies: `N/A`. Depends: `TASK-004`. Done when: unit assertions in TASK-016 pass.
- [ ] **TASK-010** [api] In `ObservabilityApiController.completed/2` accept `?limit=N` (clamp to `1..1000`) and `?project=<name>`; when `limit` is present read from `CompletionStore.recent(project, limit)`; otherwise preserve the existing in-memory snapshot path. Paths: `lib/cymphony_elixir_web/controllers/observability_api_controller.ex`. Implements: `REQ-001`, `DES-002`. Verifies: `N/A`. Depends: `TASK-006`. Done when: `curl 'localhost:4089/api/v1/completed?limit=200&project=P'` returns persisted rows; `?limit=99999` clamps to 1000.
- [ ] **TASK-011** [test] Write `CompletionStore` round-trip test (TEST-001): put 5 records across 2 projects, assert `recent("p1", 3)` returns the 3 newest in DESC order; `recent(:all, 10)` returns all 5; `count("p1")` returns 3. Paths: `test/cymphony_elixir/completion_store_test.exs`. Implements: `REQ-001`, `DES-001`, `DES-002`. Verifies: `TEST-001` covering `AC-001`, `AC-002`, `AC-003`, `AC-016`, `AC-021`. Depends: `TASK-003`. Done when: `mix test test/cymphony_elixir/completion_store_test.exs` passes.
- [ ] **TASK-012** [test] Write degraded-start test (TEST-002): start `CompletionStore` with `~/.cymphony` pointed at an unwritable path, assert `{:ok, _pid}`, assert `put_async/1` returns `:ok` without raising, assert a `completion_store.unavailable` Logger event was emitted (capture via `ExUnit.CaptureLog`). Paths: `test/cymphony_elixir/completion_store_test.exs`. Implements: `REQ-001`, `DES-002`. Verifies: `TEST-002` covering `AC-004`, `AC-005`, `AC-024`. Depends: `TASK-003`. Done when: test passes.
- [ ] **TASK-013** [test] Write blocker truth-table test (TEST-003) for `Orchestrator.should_dispatch_issue?/4` via the existing test-export at `lib/cymphony_elixir/orchestrator.ex:346`: (a) Todo + non-terminal blocker → false; (b) Todo + all-terminal blockers → true; (c) "In Progress" + non-terminal blocker → true; (d) Todo + empty `blocked_by` → true. Paths: `test/cymphony_elixir/orchestrator_status_test.exs`. Implements: `REQ-002`, `DES-003`. Verifies: `TEST-003` covering `AC-006`, `AC-007`, `AC-008`, `AC-009`. Depends: `None`. Done when: all four cases pass.
- [ ] **TASK-014** [test] Write `Mcp.ConfigWriter` shape test (TEST-004): supply `%{api_key: "abc123", endpoint: "https://api.linear.app/graphql"}`, parse the resulting JSON; assert `mcpServers.cymphony-linear.command == "elixir"`, `args` contains `"cymphony.mcp.linear_graphql"` and does NOT contain `"abc123"`, `env.LINEAR_API_KEY == "abc123"`, and `File.stat!(path).mode &&& 0o777 == 0o600`. Paths: `test/cymphony_elixir/mcp/config_writer_test.exs`. Implements: `REQ-003`, `DES-005`, `DES-006`. Verifies: `TEST-004` covering `AC-010`, `AC-018`, `AC-020`, `AC-027`. Depends: `TASK-004`. Done when: test passes.
- [ ] **TASK-015** [test] Write `Mcp.LinearGraphqlServer` stdio test (TEST-005): with `Linear.Client.graphql/3` mocked via `Mox`, feed three `tools/call` JSON-RPC frames: (a) valid query returning success — assert `{success: true, data: ...}`; (b) GraphQL errors returned — assert `{success: false, errors: [...], data: ...}`; (c) empty query string — assert `{success: false, error: "..."}` with no network call. Also assert the structured log events `event="mcp.linear_graphql.started"` and `event="mcp.linear_graphql.call"` are emitted. Paths: `test/cymphony_elixir/mcp/linear_graphql_server_test.exs`. Implements: `REQ-003`, `DES-004`. Verifies: `TEST-005` covering `AC-011`, `AC-012`, `AC-013`, `AC-014`, `AC-017`, `AC-022`, `AC-023`. Depends: `TASK-005`. Done when: test passes.
- [ ] **TASK-016** [test] Write `Claude.AppServer.build_claude_command/4` conditionality test (TEST-006): with `tracker.kind="linear"` + api_key="abc123" → argv contains `"--mcp-config"` and the descriptor file exists at the expected path; with `tracker.kind="memory"` → argv contains no `--mcp-config` entry. Paths: `test/cymphony_elixir/app_server_test.exs`. Implements: `REQ-003`, `DES-004`, `DES-005`. Verifies: `TEST-006` covering `AC-015`, `AC-026`, `AC-027`. Depends: `TASK-009`. Done when: both cases pass.
- [ ] **TASK-017** [test] Write restart-recovery test (TEST-007): in a temp dir, instantiate `CompletionStore` with that dir as the store root, `put_async/1` 150 records for `project_name="p1"`, stop the store, start a fresh `Orchestrator` for `"p1"`, assert `state.recent_completed |> length() == 100` and entries are in DESC order by `ended_at`. Paths: `test/cymphony_elixir/orchestrator_status_test.exs`. Implements: `REQ-001`, `DES-002`. Verifies: `TEST-007` covering `AC-002`. Depends: `TASK-007`. Done when: test passes.
- [ ] **TASK-018** [test] Write live e2e test (TEST-008) gated behind `@tag :live_e2e`: under `CYMPHONY_RUN_LIVE_E2E=1`, launch a real Docker-hosted Claude session pointing at a real Linear test project; prompt the agent to use `linear_graphql` to fetch its own issue; assert the agent's response includes the issue identifier returned by Linear. Paths: `test/cymphony_elixir/live_e2e_test.exs`. Implements: `REQ-003`, `DES-004`. Verifies: `TEST-008` covering `AC-010`, `AC-011`, `AC-013`, `AC-017`. Depends: `TASK-009`, `TASK-005`. Done when: `CYMPHONY_RUN_LIVE_E2E=1 mix test --only live_e2e test/cymphony_elixir/live_e2e_test.exs` passes locally.
- [ ] **TASK-019** [docs] Add a `@doc` to `Orchestrator.todo_issue_blocked_by_non_terminal?/2` explaining the rule and citing openai/symphony SPEC §8.2 with a stable link. Keep the function private. Paths: `lib/cymphony_elixir/orchestrator.ex` (line ~660). Implements: `REQ-002`, `DES-003`. Verifies: `N/A`. Depends: `TASK-013`. Done when: `grep -A2 "todo_issue_blocked_by_non_terminal" lib/cymphony_elixir/orchestrator.ex` shows the new docstring containing the SPEC §8.2 citation.
- [ ] **TASK-020** [docs] Rewrite `@moduledoc` of `CymphonyElixir.Claude.DynamicTool` to (a) state `linear_graphql` is now exposed as an MCP tool via `lib/cymphony_elixir/mcp/linear_graphql_server.ex`, (b) explain the placeholder body is retained for backward compatibility, (c) link to the SPEC §10.5 reference. Paths: `lib/cymphony_elixir/claude/dynamic_tool.ex`. Implements: `REQ-003`, `DES-004`. Verifies: `N/A`. Depends: `TASK-009`. Done when: `mix docs` renders the updated moduledoc; existing `test/cymphony_elixir/dynamic_tool_test.exs` still passes unchanged.
- [ ] **TASK-021** [verification] Run the full quality gate. Paths: `N/A — full repo verification`. Implements: `N/A`. Verifies: `N/A`. Depends: `TASK-001` through `TASK-020`. Done when: `make all` exits 0 (setup + build + fmt-check + lint + coverage 100% on tracked modules + dialyzer).
- [ ] **TASK-022** [verification] Manual operational QA. Paths: `N/A — operational smoke test`. Implements: `N/A`. Verifies: `N/A`. Depends: `TASK-021`. Done when: (1) `cymphony start project P cr 2 port 4089` launched; (2) at least 2 sessions complete and appear in dashboard "Recent completions"; (3) `cymphony restart`; (4) dashboard still shows the same 2 sessions; (5) `curl 'localhost:4089/api/v1/completed?limit=200'` returns ≥ 2 rows; (6) tailing logs shows at least one `event="mcp.linear_graphql.started"` line for a fresh session.

---

## Short Summary

This change makes Cymphony's audit trail survive daemon restarts, pins the existing "don't dispatch blocked Todos" rule with regression tests, and gives Claude a first-class Linear tool instead of relying on the agent to curl Linear by hand. Completed sessions are written to a small embedded SQLite file at `~/.cymphony/sessions.db`; the in-memory dashboard buffer is now seeded from that file on startup. The Linear tool is exposed through a per-session MCP server that Cymphony spawns alongside Claude, so an agent can call `linear_graphql` directly with a typed GraphQL operation. The change is additive — no public APIs break, all current behavior is preserved, and any new failure path (store unavailable, MCP server crash) degrades gracefully without taking the daemon down. Long-term retention policy, a search UI for past sessions, and a generalized MCP framework for non-Linear trackers are explicitly out of scope.

---

## Traceability Matrix

| REQ-ID  | AC-IDs                                                                 | DES-IDs                          | TASK-IDs                                                                                  | TEST-IDs                                 |
| ------- | ---------------------------------------------------------------------- | -------------------------------- | ----------------------------------------------------------------------------------------- | ---------------------------------------- |
| REQ-001 | AC-001, AC-002, AC-003, AC-004, AC-005                                 | DES-001, DES-002                 | TASK-001, TASK-002, TASK-003, TASK-006, TASK-007, TASK-008, TASK-010, TASK-011, TASK-012, TASK-017 | TEST-001, TEST-002, TEST-007             |
| REQ-002 | AC-006, AC-007, AC-008, AC-009                                         | DES-003                          | TASK-013, TASK-019                                                                        | TEST-003                                 |
| REQ-003 | AC-010, AC-011, AC-012, AC-013, AC-014, AC-015                         | DES-004, DES-005, DES-006        | TASK-004, TASK-005, TASK-009, TASK-014, TASK-015, TASK-016, TASK-018, TASK-020            | TEST-004, TEST-005, TEST-006, TEST-008   |
| NFR-001 | AC-016, AC-017                                                         | DES-002, DES-004                 | TASK-003, TASK-005, TASK-011, TASK-015                                                    | TEST-001, TEST-005                       |
| NFR-002 | AC-018, AC-019, AC-020                                                 | DES-006                          | TASK-002, TASK-004, TASK-014                                                              | TEST-004                                 |
| NFR-003 | None                                                                   | None                             | None                                                                                      | None                                     |
| NFR-004 | AC-021, AC-022, AC-023                                                 | DES-001, DES-004                 | TASK-003, TASK-005, TASK-011, TASK-015                                                    | TEST-001, TEST-005                       |
| NFR-005 | AC-024, AC-025                                                         | DES-002, DES-004                 | TASK-002, TASK-008, TASK-012                                                              | TEST-002                                 |
| NFR-006 | AC-026, AC-027                                                         | DES-001, DES-004                 | TASK-002, TASK-009, TASK-016                                                              | TEST-006                                 |

---

## Draft Spec Compliance Checklist (§11.1)

- [x] Metadata header present, all seven fields filled.
- [x] Requirements Document, Plan Document, and Traceability Matrix present.
- [x] Every functional requirement has `REQ-NNN`, a User Story, and numbered `AC-NNN` acceptance criteria.
- [x] NFR section addresses all six categories (NFR-003 has an explicit `None — <reason>`).
- [x] Out-of-Scope section present with concrete bullets.
- [x] Plan Document contains all eleven subsections (§6.1 – §6.11).
- [x] Each `DES-NNN` lists which `REQ-NNN`(s) it satisfies.
- [x] Components & Interfaces lists file paths for every entry.
- [x] Dependencies entries include name, version, and reason.
- [x] Integration Points use fenced code blocks with correct language identifiers (`elixir`, `json`).
- [x] Testing Strategy maps each `TEST-NNN` to the `AC-NNN`(s) it verifies.
- [x] Rollout Plan present, including rollback steps.
- [x] Risks table populated.
- [x] Research entries include source URL, version, and research date.
- [x] Task List is absent (will be added only after spec approval at gate §2 phase 4).
- [x] Initial Traceability Matrix maps every `REQ-NNN` and `NFR-NNN` to `AC-NNN`, `DES-NNN`, and `TEST-NNN`; `TASK-IDs` is `Pending task approval`.
- [x] No placeholders (`TBD`, `TODO`) remain.
- [x] All assumptions explicitly labeled in both the metadata header and the body.
- [x] All code snippets use fenced code blocks with correct syntax highlighting.

## Task List Compliance Checklist (§11.2)

- [x] Task List exists only after Requirements and Plan approval (approved 2026-05-19 with "lets do it").
- [x] Every task follows the §7.1 task format (TASK-NNN, type, action, Paths, Implements, Verifies, Depends, Done when).
- [x] Every implementation task references `REQ-NNN` and `DES-NNN`. (Verification-only tasks TASK-021/TASK-022 use `Implements: N/A` per §7.2 with exact commands in `Done when`.)
- [x] Every test task references `TEST-NNN` and the acceptance criteria it covers.
- [x] Every task has file paths or `Paths: N/A — <reason>` for verification-only steps.
- [x] Every task has `Depends:` set to another task ID or `None`.
- [x] Every task has an observable `Done when:` condition.
- [x] Tasks are ordered in implementation sequence: setup (001) → model (002) → service (003–005) → integration (006–009) → api (010) → tests (011–018) → docs (019–020) → verification (021–022).
- [x] Traceability Matrix updated so every `REQ-NNN` and `NFR-NNN` has at least one `TASK-NNN` and one `TEST-NNN` (NFR-003 is `None — no new UI surface` and so has none, per §10's `None — <reason>` allowance).
- [x] Final verification tasks include exact commands: `make all` (TASK-021) and the six-step manual smoke test (TASK-022).
