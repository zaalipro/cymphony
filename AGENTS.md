# Cymphony Elixir

The Elixir agent orchestration service that polls Linear, creates per-issue workspaces, and runs a coding-agent CLI (Claude Code, Codex, or Antigravity) in headless mode.

## Environment

- Elixir: `1.19.x` (OTP 28) via `mise`.
- Install deps: `mix setup`.
- Main quality gate: `make all` (format check, lint, coverage, dialyzer).


## Codebase-Specific Conventions

- Runtime config is loaded from `WORKFLOW.md` front matter via `CymphonyElixir.Workflow` and `CymphonyElixir.Config`.
- Agent kinds are the closed set from `CymphonyElixir.Agent.known_kinds/0` (`claude`, `codex`, `antigravity`). Select at run time with `cymphony agent antigravity`, a Linear label `agent:antigravity`, or a description directive `cymphony: agent=antigravity`. Antigravity provider env prefixes are `ANTIGRAVITY_` / `GOOGLE_` / `GEMINI_` (plus `API_TIMEOUT`; fallback keys `GOOGLE_API_KEY` / `GEMINI_API_KEY`). Provider prefixes are unchanged by dashboard Linear connect / add-project / agent persist.
- The dashboard expanded session row has a live Harness stdout pane (`HarnessStream`) and a per-session agent-kind select on `set_issue_run_spec`. Restart is `form.restart-form` (`preview_issue_run_spec` / `set_issue_run_spec`); empty/`keep` still skips a field.
- Per-project **queue board** (`section.queue-board.section--board`) sits **above** In Progress; retry stays **below**. Cards are `waiting` (active_states, not blocked Todo, not claimed, not running, not `retry_attempts`). Hide when `waiting == []`. Cymphony rank is row-major index (`0` = next slot), not Linear priority. `Queue.reconcile` owns sticky order (`Dispatch.sort_for_dispatch` is INITIAL ORDER only). Events: `reorder_queue`, `toggle_queue_edit`, `preview_queue_run_spec`, `set_queue_run_spec`. Mount assigns `:queue_edit_ids` and `:queue_run_spec_drafts`. Persist on the project in `~/.cymphony/config.json` (chmod 0600; never WORKFLOW.md / `Config.Schema`): `queue_order`, `queue_pins`, `queue_priority_seen`. Pins overlay `dispatch_run_spec/3` as pin > labels > directive > config; empty/`keep` skips; no provider; do not kill. No Linear writes. Header counts `N/M running · Q queued · R retrying`. Display `{Board, board}`. `QueueBoard` hook on `div#queue-board-<project.name>.queue-board-list` in `layouts.ex` beside `HarnessTail` / `Combobox`.
- Settings drawer (after Experience, before Automation; simple and advanced): Linear connect (`phx-submit="connect_linear"`, `#linear-api-key`) persists `linear_api_key` to `~/.cymphony/config.json` (chmod 0600; never log or flash the raw key) and add-project (`phx-submit="add_project"`) starts the new project without a daemon restart. `#add-project-slug` is a searchable Combobox (not a native select). `preview_add_project` drafts add-project agent/model/effort/provider. Automation includes `#drawer-refresh-interval` (`set_refresh_interval`). Drawer fields use class `settings-field`. `LINEAR_API_KEY` is `Schema.finalize_settings/1` fallback only.
- HTTP: `GET`/`POST /api/v1/linear`, `GET /api/v1/linear/projects`, `POST /api/v1/projects`, `POST /api/v1/queue`, `POST /api/v1/queue-pin`, `POST /api/v1/refresh-interval` (declare before `/api/v1/:issue_identifier`). `POST /refresh-interval` is **not** `POST /refresh` (Linear poll). `POST /queue` and `POST /queue-pin` require `?project=`; `202` / `422` / other methods `405`.
- Project-header agent `<select id="agent-<name>">` and effort `<select id="effort-<name>">` are stable (never embed kind/effort). Header/session/add-project/queue-card **model** is a labeled `.model-switcher` Combobox (`phx-hook="Combobox"` on `.combobox` in `layouts.ex`, beside `HarnessTail` and `QueueBoard`; not `<datalist>`). Changing a known kind persists immediately (kind only). Header Set and `POST /api/v1/agent` rewrite the project `WORKFLOW.md` and overlay `config.json` so `snapshot.agent_kind` survives refresh.
- Provider pills/fields (`#providers-<name>`, `#add-project-provider`, restart `name=provider`) are visible only when the selected kind is `claude`. Hide for `codex`, `antigravity`, empty/default, and unknown. Do not delete persisted providers when hidden. Session provider chips stay visible for all kinds. Queue-card edit has **no** provider field (Claude-only providers unchanged).
- `dashboard_refresh_seconds` is a top-level `~/.cymphony/config.json` key (pos int, min 1, default 3 when missing/unreadable; not env). `Control.set_dashboard_refresh_seconds/1` persists only. LiveView assigns `:payload_refresh_seconds` / `:payload_refresh_ms`. Not `polling.interval_ms`.
- Keep the implementation aligned with [`SPEC.md`](SPEC.md) where practical.
  - The implementation may be a superset of the spec.
  - The implementation must not conflict with the spec.
  - If implementation changes meaningfully alter the intended behavior, update the spec in the same
    change where practical so the spec stays current.
- Prefer adding config access through `CymphonyElixir.Config` instead of ad-hoc env reads.
- Workspace safety is critical:
  - Never run Claude Code turn cwd in source repo.
  - Workspaces must stay under configured workspace root.
- Orchestrator behavior is stateful and concurrency-sensitive; preserve retry, reconciliation, and cleanup semantics.
- Follow `docs/logging.md` for logging conventions and required issue/session context fields.

## Tests and Validation

Run targeted tests while iterating, then run full gates before handoff.

```bash
make all
```

## Required Rules

- Public functions (`def`) in `lib/` must have an adjacent `@spec`.
- `defp` specs are optional.
- `@impl` callback implementations are exempt from local `@spec` requirement.
- Keep changes narrowly scoped; avoid unrelated refactors.
- Follow existing module/style patterns in `lib/cymphony_elixir/*`.

Validation command:

```bash
mix specs.check
```

## PR Requirements

- PR body must follow `.github/pull_request_template.md` exactly.
- Validate PR body locally when needed:

```bash
mix pr_body.check --file /path/to/pr_body.md
```

## Docs Update Policy

If behavior/config changes, update docs in the same PR:

- `README.md` for project concept and goals.
- `README.md` for Elixir implementation and run instructions.
- `WORKFLOW.md` for workflow/config contract changes.
- `CLAUDE.md` / `AGENTS.md` for CLI, labels, dashboard Harness pane, queue board (`section.queue-board`, `reorder_queue` / `set_queue_run_spec`, `queue_order` / `queue_pins` persist), Linear connect / add-project, agent-select persist, Combobox, Claude-only providers, `dashboard_refresh_seconds`, and provider prefixes.
