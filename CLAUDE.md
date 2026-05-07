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
| `c <value>` | `--claude-command <value>` | Override provider or Claude command |
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

### Combined usage

```bash
cymphony project AgentFarm cr 3 c cv1,cz2 port 4089
```

Runs project "AgentFarm" with 3 concurrent sessions rotating across cv1 and cz2 providers, with dashboard on port 4089.

## Architecture

The application is an escript CLI (`main_module: CymphonyElixir.CLI`) that starts an OTP supervision tree.

### Core Data Flow

```
CLI → CymphonyConfig → WorkflowStore → Orchestrator (GenServer, per-project) → AgentRunner (Task) → Claude.AppServer (Port)
```

1. **CLI** (`cli.ex`) — Escript entrypoint. Handles onboarding, multi-project mode, background process management, concurrency control, provider rotation, and legacy WORKFLOW.md mode.
2. **CymphonyConfig** (`cymphony/config.ex`) — Reads/writes `~/.cymphony/config.json`, generates temporary `WORKFLOW.md` with YAML front matter from project config. Converts `--concurrency` and `c` flags into workflow YAML.
3. **WorkflowStore** (`workflow_store.ex`) — GenServer that loads and hot-reloads `WORKFLOW.md`. Holds current workflow state per project.
4. **Config** (`config.ex` + `config/schema.ex`) — Validates workflow config via Ecto embedded schemas. Resolves `$ENV_VAR` references and provides typed access to all settings (tracker, polling, workspace, claude, hooks, etc.).
5. **Orchestrator** (`orchestrator.ex`) — Central GenServer per project. Poll tick loop dispatches issues, enforces concurrency via `available_slots/1`, selects providers via `select_provider/1` (random rotation from `providers` list), handles retries with exponential backoff, tracks token usage, and detects stalled agents.
6. **AgentRunner** (`agent_runner.ex`) — Spawns a Task per issue. Creates workspace, runs lifecycle hooks, then calls `Claude.AppServer` for multi-turn execution. Accepts `provider_override` opt to use a specific provider for this session.
7. **ShellProvider** (`cymphony/shell_provider.ex`) — Reads provider env vars (API keys, model config) from shell functions in `~/.cld`, `~/.zshrc`, or `~/.bashrc`. Sources the rc files in a zsh subprocess with `claude` noop'd, calls the provider function, and captures the resulting `ANTHROPIC_*`/`CLAUDE_CODE_*` env vars. Results are cached via `persistent_term`.
8. **Claude.AppServer** (`claude/app_server.ex`) — Spawns `claude` CLI as a Port process. Manages session start/turn/resume lifecycle. Parses JSON and stream-json output. Uses `ShellProvider` to inject provider env vars into the spawned process.
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
- `extract_providers/1` reads from `config.claude.providers` (list) or falls back to single `config.claude.provider`
- `select_provider/1` picks randomly via `Enum.random(providers)` for even distribution
- `spawn_issue_on_worker_host/6` selects a provider per dispatch and passes it as `provider_override` to AgentRunner
- Dashboard can change a running session's provider (kill & restart with new provider)

### OTP Supervision Tree

```
CymphonyElixir.Supervisor (one_for_one)
├── Phoenix.PubSub
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

- **Header** — Status badge (Live/Offline), version, Refresh button
- **Project grid** — Per-project mini-cards showing running/retrying counts
- **Metrics** — Running count, retrying count, total tokens (input/output/total), runtime, throughput with sparkline chart (10-minute window)
- **Polling** — Next poll countdown and interval
- **Rate limits** — Primary/Secondary/Credits buckets with remaining/limit and reset timers
- **Running sessions** — Per-session cards with issue ID, state, stall badge, worker host, provider badge, project badge, runtime, tokens, session ID (copyable), workspace path (copyable), collapsible recent logs
- **Retry queue** — Per-retry cards with attempt number, due-at countdown, error details, Retry Now button
- **Recent completions** — Last 100 sessions that wrapped up: identifier, runtime, total tokens, ended-at timestamp. In-memory ring buffer; cleared on daemon restart.

### User actions

| Event | Description |
|-------|-------------|
| `toggle_logs` | Expand/collapse log drawer for a session |
| `dismiss_stalled_alert` | Dismiss stalled-agent warning |
| `filter_project` | Filter running/retrying sessions by project |
| `kill_issue` | Terminate a running session |
| `retry_issue` | Immediately retry a queued issue |
| `refresh_now` | Trigger Linear refresh from dashboard |
| `set_provider` | Change provider for a running session (kills and restarts with new provider) |
| `pause_dispatch` / `resume_dispatch` | Stop/start dispatching new issues; running sessions complete normally |

### Refresh behavior

- Runtime tick: every 1 second
- Pubsub-driven payload reload on orchestrator updates (real-time via `ObservabilityPubSub`)
- Periodic payload refresh: every 3 seconds (async via Task.Supervisor)

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
| `/api/v1/state` | GET | Full state snapshot JSON |
| `/api/v1/projects` | GET | Project list with running/retrying counts |
| `/api/v1/:issue_identifier` | GET | Single issue details (optional `?project=` filter) |
| `/api/v1/refresh` | POST | Trigger Linear refresh (returns 202) |
| `/api/v1/pause` | POST | Stop dispatching new issues; running sessions continue. Returns 202. |
| `/api/v1/resume` | POST | Resume dispatching new issues. Returns 202. |
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

Providers supply the `ANTHROPIC_*` env vars that Claude Code uses. Two sources:

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

Cymphony resolves these via `ShellProvider`: shells out to zsh, noop's `claude`, calls the function, and captures the resulting env vars. Results are cached via `persistent_term`.

### Provider rotation

```bash
cymphony c cv1,cz2,ck1    # Distribute sessions across 3 providers
```

Comma-separated providers are randomly assigned per session. The first provider is set as the default; the full list is stored as `providers` in config. At dispatch time, `select_provider/1` picks randomly from the list for even distribution.

### Dashboard provider change

On the dashboard, each running session has a provider input field. Submitting a new provider kills the session and immediately re-dispatches it with the new provider via `{:set_issue_provider, issue_id, provider}` GenServer call.
