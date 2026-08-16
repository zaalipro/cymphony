# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

Cymphony is an Elixir-based orchestrator that polls Linear for issues and dispatches them as autonomous Claude Code agent runs. It supports multi-project orchestration, configurable concurrency limits (`cr N`), and provider rotation (`c cv1,cz2,ck1`) to distribute sessions across multiple Claude backends. A Phoenix LiveView dashboard provides real-time observability.

It's a rewrite of OpenAI's Cymphony, using Claude Code instead of Codex.

## Build & Development Commands

All commands run from the project root:

```bash
mix setup              # Install deps
make build             # Build the escript binary (bin/cymphony)
make test              # Run tests
mix test test/path/to_test.exs  # Run a single test file
make coverage          # Run tests with coverage (100% threshold on tracked modules)
make fmt               # Auto-format code
make fmt-check         # Check formatting without changes
make lint              # Run specs.check + credo --strict
make dialyzer          # Run type analysis
make all               # Full CI gate (setup, build, fmt-check, lint, coverage, dialyzer)
```

- Elixir 1.19.x (OTP 28), managed via `mise`
- Quality gate: `make all` must pass before handoff

## CLI Commands

Defined in `lib/cymphony_elixir/cli.ex`.

### Shorthand expansions

| Command | Expands to | Description |
|---------|-----------|-------------|
| `project <name>` / `projects <name>` | `--project <name>` | Run a specific project |
| `agent <kind>` | `--agent <kind>` | Coding agent: `claude`, `codex`, or `antigravity` |
| `model <name>` | `--model <name>` | Model override passed to the agent CLI |
| `effort <level>` | `--effort <level>` | Reasoning effort passed to the agent CLI |
| `c <value>` | `--provider <value>` | Provider rotation (comma-separated auth aliases) |
| `cr <n>` | `--concurrency <n>` | Set max concurrent agents |
| `port <n>` | `--port <n>` | Set HTTP server / dashboard port |
| `setup` | `--setup` | Run onboarding wizard |
| `add` | `add-project` | Add a project to config |
| `list` | — | List configured projects |
| `v` | `--version` | Show version |
| `h` | `--help` | Show help |
| `start` | `--background` | Run in background |
| `stop` | `--background-stop` | Stop background process |
| `restart` | `--restart` | Restart background process |
| `logs [n]` | — | Show last n lines of log (default: all) |

The short forms `b`, `bs`, `r`, `s`, `p`, `a`, `l` / `ls`, `log`, and the long flag `--port` still work as aliases for backward compatibility but are no longer documented in `--help`.

### Concurrency control

```bash
cymphony cr 3                    # Limit to 3 concurrent sessions
cymphony cr 1                    # Run one session at a time
cymphony project AgentFarm cr 5  # 5 sessions for "AgentFarm" project
```

Limits how many Claude sessions run simultaneously. Default is 10. As sessions complete, waiting issues auto-dispatch on the next poll tick.

### Provider rotation

```bash
cymphony c cv1,cz2,ck1                # Rotate across 3 providers
cymphony project Farm cr 6 c cv1,cz2  # 6 sessions split across 2 providers (~3 each)
```

Comma-separated provider names are randomly assigned per session. Each provider must be defined in `~/.cymphony/config.json` under `providers` or as a shell function in `~/.cld`.

### Agent selection

```bash
cymphony agent codex                       # Run every project with the Codex CLI
cymphony agent antigravity                 # Run every project with the Antigravity CLI (`agy`)
cymphony agent codex model gpt-5.2-codex   # Codex with an explicit model
cymphony effort high                       # Reasoning effort for the configured agent
```

`agent <kind>` picks the coding-agent backend (`claude`, `codex`, or `antigravity`) for this run; `model` and
`effort` are passed through to the agent CLI verbatim (Claude / Antigravity: `--model`/`--effort`;
Codex: `-m`/`-c model_reasoning_effort=…`). Per-project defaults live in
`~/.cymphony/config.json` as `agent`, `model`, `effort` keys.

### Per-issue agent/model/effort

Choose the agent, model, effort, or provider for a single issue from Linear itself — add labels:

```
agent:codex   agent:antigravity   model:gpt-5.2-codex   effort:high   provider:cz1
```

or a directive line anywhere in the issue description:

```
cymphony: agent=codex model=gpt-5.2-codex effort=high
cymphony: agent=antigravity model=gemini-3.7-flash-high effort=high
```

Queue pins (card Edit / `POST /api/v1/queue-pin`) win over labels; labels win over the
directive; all win over project config. Resolution happens at dispatch and
is pinned for the run attempt; changes apply on the next dispatch/retry (running sessions keep
their spec). Unknown `agent:` values fall back with a warning; model/effort are pass-through
(bad values fail the run visibly and land in the retry queue).

### Combined usage

```bash
cymphony project AgentFarm agent codex cr 3 c oa1,oa2 port 4089
```

Runs project "AgentFarm" on Codex with 3 concurrent sessions rotating across oa1 and oa2 providers, with dashboard on port 4089.

## Architecture

The application is an escript CLI (`main_module: CymphonyElixir.CLI`) that starts an OTP supervision tree.

### Core Data Flow

```
CLI → CymphonyConfig → WorkflowStore → Orchestrator (GenServer, per-project) → AgentRunner (Task) → Agent.Runner (Port) → Agent.Claude | Agent.Codex | Agent.Antigravity adapter
```

1. **CLI** (`cli.ex`) — Escript entrypoint. Handles onboarding, multi-project mode, background process management, concurrency control, provider rotation, and legacy WORKFLOW.md mode.
2. **CymphonyConfig** (`cymphony/config.ex`) — Reads/writes `~/.cymphony/config.json`, generates temporary `WORKFLOW.md` with YAML front matter from project config. Converts `--concurrency` and `c` flags into workflow YAML.
3. **WorkflowStore** (`workflow_store.ex`) — GenServer that loads and hot-reloads `WORKFLOW.md`. Holds current workflow state per project.
4. **Config** (`config.ex` + `config/schema.ex`) — Validates workflow config via Ecto embedded schemas. Resolves `$ENV_VAR` references and provides typed access to all settings (tracker, polling, workspace, agent, claude, codex, antigravity, hooks, etc.).
5. **Orchestrator** (`orchestrator.ex`) — Central GenServer per project. Poll tick loop reconciles `waiting` via `Queue.reconcile`, dispatches the leftmost waiting card, enforces concurrency via `available_slots/1`, selects providers via `select_provider/1` (random rotation from `providers` list), handles retries with exponential backoff, tracks token usage, and detects stalled agents.
6. **AgentRunner** (`agent_runner.ex`) — Spawns a Task per issue. Creates workspace, runs lifecycle hooks, then calls `Agent.Runner` for multi-turn execution. Accepts `agent_kind`/`model`/`effort`/`provider_override` opts for this session.
7. **ShellProvider** (`cymphony/shell_provider.ex`) — Reads provider env vars (API keys, model config) from shell functions in `~/.cld`, `~/.zshrc`, or `~/.bashrc`. Sources the rc files in a zsh subprocess with `claude`/`codex`/`agy`/`antigravity` noop'd, calls the provider function, and captures env vars matching the active agent's prefixes (Claude: `ANTHROPIC_*`/`CLAUDE_CODE_*`; Codex: `OPENAI_*`/`CODEX_*`; Antigravity: `ANTIGRAVITY_*`/`GOOGLE_*`/`GEMINI_*` plus `API_TIMEOUT`; fallback keys `GOOGLE_API_KEY`/`GEMINI_API_KEY`). Results are cached via `persistent_term`.
8. **Agent behaviour** (`agent.ex`, `agent/runner.ex`, `agent/claude.ex`, `agent/codex.ex`, `agent/antigravity.ex`) — `Agent.Runner` owns the shared machinery (port spawn, SSH remoting, env injection, timeouts, workspace validation) and delegates argv construction + output parsing to the `CymphonyElixir.Agent` adapter for `agent.kind`. The Claude adapter drives `claude --bare -p … --resume`; the Codex adapter drives `codex exec --json` / `codex exec resume <id>` and parses its JSONL events; the Antigravity adapter drives `agy -p … --output-format stream-json` and resumes with `--conversation <id>` (never `-c`/`--continue`).
9. **Workspace** (`workspace.ex`) — Isolated per-issue directories with path safety validation, lifecycle hooks (after_create, before_run, after_run, before_remove), and SSH worker support. Optional retention sweep (`workspace.retention_days` in config) deletes stale workspaces every 6 hours, skipping currently-running ones.
10. **Tracker** (`tracker.ex`) — Behaviour-based adapter for issue trackers. `Linear.Adapter` is the production implementation; `Tracker.Memory` is for testing.

### Concurrency

- `max_concurrent_agents` stored in Orchestrator `%State{}` struct (default: 10)
- `available_slots/1` computes `max_concurrent_agents - running_count` to limit dispatches per tick
- `cr N` CLI shorthand sets concurrency at startup and persists to config
- Per-host limit: `max_concurrent_agents_per_host` caps concurrent sessions per worker
- Auto-dispatch: as sessions finish, waiting issues fill open slots on next poll tick

### Provider Rotation

- `providers` list stored in Orchestrator `%State{}` struct
- `extract_providers/1` reads from the **active agent kind's** section (`config.claude.*`, `config.codex.*`, or `config.antigravity.*`): `providers` list first, single `provider` fallback
- `select_provider/1` picks randomly via `Enum.random(providers)` for even distribution
- `spawn_issue_on_worker_host/6` selects a provider per dispatch and passes it as `provider_override` to AgentRunner
- Dashboard can change a running session's provider (kill & restart with new provider)

### OTP Supervision Tree

```
CymphonyElixir.Supervisor (one_for_one)
├── Phoenix.PubSub
├── HarnessStream (ETS ring of live CLI stdout; after PubSub, before HttpServer)
├── Registry (ProjectRegistry, :unique)
├── Task.Supervisor (for AgentRunner tasks)
├── DynamicSupervisor (ProjectDynamicSupervisor)
│   └── ProjectSupervisor (per project)
│       ├── WorkflowStore
│       └── Orchestrator
├── HttpServer (Bandit + Phoenix)
└── StatusDashboard
```

Each project gets its own `ProjectSupervisor` with a `WorkflowStore` and `Orchestrator`, registered via `ProjectRegistry` for lookup by `{project_name, role}`.

## Web Dashboard

The Phoenix LiveView dashboard (`lib/cymphony_elixir_web/live/dashboard_live.ex`) provides real-time observability. Enabled with `cymphony port <n>` (or `--port <n>`).

### Sections

- **Top bar** — Status badge (Live/Offline), version, theme toggle (light / dark / system; CSS geometry on `.theme-toggle-button`, no ☀☾⌂ emoji), Settings drawer toggle (CSS geometry on `[data-drawer-toggle]`, no ⚙), Refresh button
- **Metrics strip** — One row of stat tiles: running count, retrying count, total tokens (input/output), runtime, throughput sparkline (10-minute window), plus compact polling-countdown and rate-limit (Primary/Secondary/Credits) tiles. Advanced adds `.metric-pill--queue.section--queue` = `counts.waiting`. Simple Waiting pill stays `counts.retrying`.
- **Per-project sections** — One section per project. Header shows project name, counts (`N/M running · Q queued · R retrying`), paused state, and inline controls: concurrency input (`cr`), wrapping `form.project-agent-form` (`phx-change="preview_project_agent"`, `phx-submit="set_project_agent"`) with labeled pills `.agent-switcher` (`claude`/`codex`/`antigravity`, stable id `agent-<project>` — never embed kind), `.model-switcher` Combobox (type-to-filter; `AgentCatalog.models/1`; not `<datalist>`), `.effort-switcher` (native `#effort-<project>` select), and **Set**. Providers input (`form[phx-submit=set_project_providers]`, `#providers-<project.name>`) is visible only when the selected kind is `claude` (`agent_settings.kind`). Changing the agent kind persists immediately (kind only; do not persist model/effort on preview) and hides/shows providers on the next render — do not delete persisted providers when hidden. Header **Set** still saves kind+model+effort. Both paths rewrite the project's generated `WORKFLOW.md` and overlay `config.json` so `snapshot.agent_kind` survives refresh. **Up next / Queue** (`section.queue-board.section--board`) sits **above** In Progress (`.session-row-list`): `div#queue-board-<project.name>.queue-board-list` (`phx-hook="QueueBoard"`) of `article.queue-card` rows. Hide the board when `waiting == []`. Empty-state iff `running`, `retrying`, **and** `waiting` are empty. Card face is id + title + Edit only (no Linear priority/state/agent chips). Edit (`div.queue-card-edit`, `form.queue-edit-form`) pins `agent_kind` / model / effort for the next dispatch — empty/`keep` skips; no provider; do not kill. Each running session is a compact one-line row with issue identifier (linked), title (or last activity), state/provider/agent/model/effort/host chips, runtime, tokens, and a Kill button. Click a row to expand and see session ID (copyable), workspace path (copyable), recent log events, a live **Harness** stdout pane (Follow/Paused; `HarnessStream` ring of 400 × 2048-byte lines; `section#harness-tail-<id>` unchanged), and `form.restart-form` (`phx-change="preview_issue_run_spec"`, `phx-submit="set_issue_run_spec"`) with labeled Harness / Provider (Claude only via `session_spec.suggestion_kind`) / Model Combobox / Effort pills. Session provider chips and the read-only Provider stat stay visible for every kind. The retry queue lives inline **below** In Progress (not on the board).
- **Recent completions** — Last 100 sessions that wrapped up: identifier, agent/model chips, runtime, total tokens, ended-at timestamp. Collapsible; backed by the persistent completion store.
- **Settings drawer** — Right-side panel. After Experience and before Automation (simple and advanced): **Linear** (`#linear-connect-form`, `phx-submit="connect_linear"`, `#linear-api-key`) and **Projects** (`#add-project-form`, `phx-submit="add_project"`; `#add-project-slug` is a searchable Combobox, not a native select; `#add-project-provider` visible only when assign `:add_project_kind` is `claude`, drafted by `preview_add_project`). Then orchestrator controls (global Pause/Resume, global concurrency, `#drawer-refresh-interval` / `set_refresh_interval` persisting `dashboard_refresh_seconds`) and client-side display preferences (density, section visibility including `{Board, board}`, session-row columns, completions length). Drawer fields use class `settings-field`. Display prefs persist per browser in localStorage (`cymphony-prefs`) as `data-*` attributes on `<html>` (`html[data-hidden-sections~=board] .section--board { display: none }`); no server state. Never put the raw Linear key in assigns or flashes. Model and slug Comboboxes use the LiveSocket `Combobox` hook (`layouts.ex`, beside `HarnessTail` and `QueueBoard`; root `.combobox` `phx-hook="Combobox"`). `Combobox.setChrome` also toggles the closest `.queue-card`.

### User actions

| Event | Description |
|-------|-------------|
| `toggle_logs` | Expand/collapse a session row to reveal session ID, workspace path, recent logs, Harness stdout pane, restart-with-overrides form |
| `dismiss_stalled_alert` | Dismiss stalled-agent warning |
| `kill_issue` | Terminate a running session |
| `retry_issue` | Immediately retry a queued issue |
| `refresh_now` | Trigger Linear refresh from dashboard |
| `set_issue_run_spec` | Kill a running session and restart it with pinned `agent_kind`/provider/model/effort overrides (empty / "keep" skips a field) |
| `preview_issue_run_spec` | Draft the restart Harness/provider/model/effort pills. Switching kind hide/shows the Provider field (visible only when `session_spec.suggestion_kind` is `claude`). |
| `reorder_queue` | Params `project` + full identifier `order` list. Optimistic client reorder, then `Control.set_queue_order`, reload. Persists `queue_order` (not Linear). |
| `toggle_queue_edit` | Params `project` + `issue`. Toggle `{project, identifier}` in assign `:queue_edit_ids`. |
| `preview_queue_run_spec` | Draft `:queue_run_spec_drafts[{project, id}]` like `preview_issue_run_spec`. Kind change clears model/effort. No persist. No provider. |
| `set_queue_run_spec` | Hidden `project` + `issue`. Comboboxes preselect the card pin or the project header spec (no `keep`). Empty / keep in the payload still skip. `Control.set_queue_pin`. Does **not** kill (issue is not running). |
| `toggle_harness_follow` | Flip Follow/Paused on the expanded session's Harness stdout pane |
| `pause_dispatch` / `resume_dispatch` | Stop/start dispatching new issues for **all** projects; running sessions complete normally |
| `toggle_project_pause` | Pause or resume dispatching for a single project from its section header |
| `set_concurrency` | Update `max_concurrent_agents` for **all** projects (legacy global form); persists to `~/.cymphony/config.json` |
| `set_project_concurrency` | Update `max_concurrent_agents` for a single project from its section header; persists to config |
| `set_project_providers` | Update the provider list (`provider` + `providers`) for a single project from its section header; persists to config and applies to next dispatch (running sessions unchanged) |
| `set_project_agent` | Update agent kind/model/effort for a single project from its section header; persists to `config.json`, rewrites the project `WORKFLOW.md`, applies to next dispatch |
| `preview_project_agent` | Draft the header agent/model/effort controls. When the kind actually changes to a known kind, persist kind only (`Control.set_agent_settings`), increment payload seq, and reload. Persist error keeps the draft and flashes; does not revert the select. |
| `connect_linear` | Settings drawer: validate + persist Linear API key to `config.json` `linear_api_key`; rewrite each project's `WORKFLOW.md` `tracker.api_key`; flash last-4 mask only |
| `add_project` | Settings drawer: add Linear project to `config.json`, write temp `WORKFLOW.md`, start supervisor (no daemon restart). Hidden/disabled until Linear is connected. |
| `preview_add_project` | Draft add-project agent/model/effort/provider. Switching kind hide/shows `#add-project-provider` (visible only when kind is `claude`). Default kind `""` hides provider. |
| `set_refresh_interval` | Settings Automation: persist top-level `dashboard_refresh_seconds` from `#drawer-refresh-interval` (min 1, default 3). Does **not** change Linear `polling.interval_ms` or `POST /api/v1/refresh`. Open dashboards keep their assign until remount or this event. |

Each running session row shows the Linear issue identifier (linked to the issue), title (or last activity message when no title), state, provider, host, runtime, and total tokens at a glance. Expanding the row reveals priority badge, session ID, workspace path, and recent log events.

Theme toggle is purely client-side (CSS geometry on `.theme-toggle-button`, no emoji) — sets `data-theme` on `<html>` and persists to localStorage; system mode clears it to follow the OS `prefers-color-scheme` setting. Display preferences in the settings drawer follow the same pattern (`cymphony-prefs` in localStorage → `data-density`/`data-hidden-sections`/`data-hidden-cols`/`data-collapsed-sections`/`data-completions-limit` attributes on `<html>`, including `{Board, board}`), so LiveView patches never clobber them and the page degrades gracefully without JS. Mount assigns `:queue_edit_ids` (`MapSet.new()`) and `:queue_run_spec_drafts` (`%{}`).

### Refresh behavior

- Runtime tick: every 1 second
- Pubsub-driven payload reload on orchestrator updates (real-time via `ObservabilityPubSub`)
- Periodic payload refresh: `dashboard_refresh_seconds` from `~/.cymphony/config.json` (positive int, min 1, default 3 when missing/unreadable; not read from env). LiveView assigns `:payload_refresh_seconds` and `:payload_refresh_ms` (seconds × 1000). `:runtime_tick` compares now-`last_payload_refresh` against that assign — never a compile-time `@payload_refresh_ms`. Open dashboards keep their assign until remount or `set_refresh_interval` (`POST /api/v1/refresh-interval`). This is **not** Linear poll timing.
- Payload loads carry a generation token (`payload_seq`). After Connect / add-project / agent persist, increment seq and ignore stale `{:payload_loaded, seq, payload}` so an in-flight snapshot cannot revert `agent_kind` or Linear status.

### Auth (optional)

Set `CYMPHONY_API_TOKEN=<secret>` in the environment before starting the daemon to require a bearer token on all dashboard and API routes. When unset, all routes are public (default for backward compat).

- API: `Authorization: Bearer <secret>` header.
- Browser: open `http://host:port/?token=<secret>` once — token is stored in the session cookie and the URL is cleaned up via redirect.
- 401 JSON response when missing/wrong.

Plug: `lib/cymphony_elixir_web/plugs/api_auth.ex`. Applied via `:browser` and `:api` pipelines in `router.ex`.

### API endpoints

Routes defined in `lib/cymphony_elixir_web/router.ex`:

| Route | Method | Description |
|-------|--------|-------------|
| `/` | GET | LiveView dashboard |
| `/api/v1/state` | GET | Full state snapshot JSON (`waiting` rows + `counts.waiting` / per-project `waiting_count`) |
| `/api/v1/linear` | GET | Linear connect status JSON (`connected`, `masked_key`, `source`). Never the raw key. Must be declared before the issue catch-all. |
| `/api/v1/linear` | POST | Body `{"api_key":"..."}`. Validate + persist `linear_api_key`. `202` status or `422` (`empty_api_key` / `invalid_api_key` / `linear_unauthorized` / `linear_error`). Never echo `api_key`. |
| `/api/v1/linear/projects` | GET | Accessible Linear projects `{"projects":[{"id","name","slug_id"}]}`. `422` `linear_not_connected` if no key. |
| `/api/v1/projects` | GET | Project list with running/retrying counts |
| `/api/v1/projects` | POST | Add + start a project (no daemon restart). Body `name` + `linear_project_slug` (+ optional github/workspace/agent/model/effort/provider). `202` `{name,linear_project_slug,started}`. `422`: `not_connected` / `invalid_project` / `duplicate_project_name` / `duplicate_project_slug` / `project_start_failed`. |
| `/api/v1/:issue_identifier/harness` | GET | Live CLI stdout ring (`HarnessStream.snapshot`); optional `?project=`. Must be declared before the issue catch-all. |
| `/api/v1/:issue_identifier` | GET | Single issue details (optional `?project=` filter) |
| `/api/v1/refresh` | POST | Trigger Linear refresh (returns 202). **Not** `POST /refresh-interval`. |
| `/api/v1/refresh-interval` | POST | Body `{"value": N}` (pos int ≥ 1). Persist top-level `dashboard_refresh_seconds`. `202` `{"dashboard_refresh_seconds":N}` or `422` `{"error":{"code":"invalid_refresh_interval","message":"..."}}`. Declare (and `match :*`) **before** `/api/v1/:issue_identifier`. Other methods `405`. Does not change Linear poll timing. |
| `/api/v1/pause` | POST | Stop dispatching new issues; running sessions continue. Optional `?project=<name>` to scope to one project. Returns 202. |
| `/api/v1/resume` | POST | Resume dispatching new issues. Optional `?project=<name>`. Returns 202. |
| `/api/v1/concurrency` | POST | Update `max_concurrent_agents` at runtime. JSON body `{"value": <int>}`, optional `?project=<name>`. Persists to `~/.cymphony/config.json`. Returns 202. |
| `/api/v1/providers` | POST | Update provider list at runtime. JSON body `{"value": "cv1,cz2,ck1"}` (comma-separated aliases), optional `?project=<name>`. Persists `provider` (head) + `providers` (full list) to `~/.cymphony/config.json`. Applies to next dispatch only — running sessions unchanged. Returns 202 with `{"providers": [...]}`. |
| `/api/v1/agent` | POST | Update agent settings at runtime. JSON body `{"kind": "codex", "model": "...", "effort": "..."}` (each optional, at least one required; `kind` must be one of `claude`, `codex`, `antigravity`; empty string clears model/effort), optional `?project=<name>`. Persists to `~/.cymphony/config.json`, rewrites the project's generated `WORKFLOW.md`, and overlays `config.json` so `snapshot.agent_kind` survives refresh. Applies to next dispatch. Returns 202. |
| `/api/v1/queue` | POST | Sticky waiting order. Body `{"order":["LLM-51","LLM-12"]}`. Query `?project=` **required**. `202` `{"order":[...],"project":"Name"}` or `422` `{"error":{"code":"invalid_queue_order","message":"..."}}`. Declare (and `match :*`) **before** `/api/v1/:issue_identifier`. Other methods `405`. No Linear writes. |
| `/api/v1/queue-pin` | POST | Pin `agent_kind` / model / effort for a waiting issue. Body `{"issue":"LLM-51","kind":"codex","model":"...","effort":"..."}` (each of kind/model/effort optional; empty/`keep` skipped; at least one real field). Query `?project=` **required**. `202` `{"issue","agent_kind","model","effort","project"}` or `422` `invalid_queue_pin`. Declare (and `match :*`) **before** `/api/v1/:issue_identifier`. Other methods `405`. Does not kill. No provider. No Linear writes. |
| `/api/v1/completed` | GET | Recent completed sessions (last 100, in-memory ring buffer). Optional `?project=<name>` and `?limit=N`. |

All other methods return 405; all other paths return 404.

## Key Conventions

- All public `def` in `lib/` must have `@spec` — enforced by `mix specs.check`
- `defp` specs are optional; `@impl` callbacks are exempt
- Runtime config comes from `WORKFLOW.md` YAML front matter, accessed through `CymphonyElixir.Config` (never read env vars directly in business logic)
- Workspace safety is critical: Claude Code must never run in the source repo cwd; all workspaces are validated to stay under the configured root
- Regexes must be compiled at runtime with `Regex.compile!/1` (not sigils) for OTP 28 compat
- Keep implementation aligned with `SPEC.md`; update spec when behavior changes meaningfully
- PR body must follow `.github/pull_request_template.md` exactly (validated by `.github/workflows/pr-description-lint.yml`)

## Release Process

### CI (`make-all.yml`)

- Triggered on PRs and pushes to `main`
- Runs `make all` (setup, build, fmt-check, lint, coverage, dialyzer)

### Release (`release.yml`)

Triggered by pushing a `v*` tag. Three jobs:

1. **`build`** — Sets up mise + Zig, runs `MIX_ENV=prod mix release` with `BURRITO_BUILD=1`. Produces 3 Burrito binaries:
   - `linux` (x86_64)
   - `macos_intel` (x86_64)
   - `macos_arm` (aarch64)

2. **`package-deb`** — Builds `.deb` package from linux binary using `fpm`. Output: `cymphony_<version>_amd64.deb`

3. **`release`** — Downloads all artifacts, creates GitHub Release with `--generate-notes`

### Step-by-step release

1. Bump version in `mix.exs`
2. Commit and push to `main`
3. Tag and push: `git tag vX.Y.Z && git push origin vX.Y.Z`
4. Wait for CI (`make-all.yml`) to pass on `main`
5. Release workflow (`release.yml`) builds binaries + `.deb` and creates GitHub Release
6. Update Homebrew tap (`zaalipro/homebrew-cymphony`):
   ```bash
   curl -sL https://github.com/zaalipro/cymphony/archive/refs/tags/vX.Y.Z.tar.gz | shasum -a 256
   # Update Formula/cymphony.rb with new url and sha256
   ```
7. Commit and push to the tap repo
8. Users install/upgrade via `brew update && brew upgrade zaalipro/cymphony/cymphony`

## Provider System

Providers supply the auth env vars the agent CLI uses (`ANTHROPIC_*` for Claude Code, `OPENAI_*` for Codex, `ANTIGRAVITY_*` / `GOOGLE_*` / `GEMINI_*` for Antigravity). Two sources:

### 1. Config-based providers (`~/.cymphony/config.json`)

Stored under the top-level `providers` key. Each provider maps to a set of env vars:

```json
{
  "providers": {
    "cz": {
      "ANTHROPIC_BASE_URL": "https://api.z.ai/coding/v4",
      "ANTHROPIC_API_KEY": "sk-zai-...",
      "ANTHROPIC_MODEL": "glm5-.1"
    }
  }
}
```

Set `provider` on a project to use one by default. Override per-run with `cymphony c <name>`.

### 2. Shell function providers (`~/.cld`)

Shell functions (e.g., `ck`, `ck1`, `cz`) sourced by `.zshrc`. Each calls `_unset` to clear `ANTHROPIC_*` vars, then sets new exports.

Cymphony resolves these via `ShellProvider`: shells out to zsh, noops `claude`/`codex`/`agy`/`antigravity`, calls the function, and captures the resulting env vars for the active agent's prefixes. Results are cached via `persistent_term`.

### Provider rotation

```bash
cymphony c cv1,cz2,ck1    # Distribute sessions across 3 providers
```

Comma-separated providers are randomly assigned per session. The first provider is set as the default; the full list is stored as `providers` in config. At dispatch time, `select_provider/1` picks randomly from the list for even distribution.

### Dashboard provider change

On the dashboard, each running session has a restart-with-overrides form (agent kind, provider, model, effort). Submitting it kills the session and immediately re-dispatches it via `set_issue_run_spec` (`:agent_kind`, `:provider`, `:model`, `:effort`).
