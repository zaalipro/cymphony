# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

Cymphony is an Elixir-based orchestrator that polls Linear for issues and dispatches them as autonomous Claude Code agent runs. It's a rewrite of OpenAI's Cymphony, using Claude Code instead of Codex.

## Build & Development Commands

All commands run from the `elixir/` directory:

```bash
mix setup              # Install deps
make build             # Build the escript binary (elixir/bin/cymphony)
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

## Architecture

The application is an escript CLI (`main_module: CymphonyElixir.CLI`) that starts an OTP supervision tree.

### Core Data Flow

```
CLI → WorkflowStore → Orchestrator (GenServer, per-project) → AgentRunner (Task) → Claude.AppServer (Port)
```

1. **CLI** (`lib/cymphony_elixir/cli.ex`) — Escript entrypoint. Handles onboarding, multi-project mode, background process management, and legacy WORKFLOW.md mode.
2. **Workflow** (`workflow.ex`) + **WorkflowStore** (`workflow_store.ex`) — Loads and hot-reloads `WORKFLOW.md` (YAML front matter + prompt body). `WorkflowStore` is a GenServer that holds the current workflow state per project.
3. **Config** (`config.ex` + `config/schema.ex`) — Validates workflow config via Ecto embedded schemas. Resolves `$ENV_VAR` references and provides typed access to all settings (tracker, polling, workspace, claude, hooks, etc.).
4. **Orchestrator** (`orchestrator.ex`) — Central GenServer. Poll tick loop dispatches issues, reconciles running state, handles retries with exponential backoff, tracks token usage, and detects stalled agents.
5. **AgentRunner** (`agent_runner.ex`) — Spawns a Task per issue. Creates workspace, runs lifecycle hooks, then calls `Claude.AppServer` for multi-turn execution.
6. **Claude.AppServer** (`claude/app_server.ex`) — Spawns `claude` CLI as a Port process. Manages session start/turn/resume lifecycle. Parses JSON and stream-json output.
7. **Workspace** (`workspace.ex`) — Isolated per-issue directories with path safety validation, lifecycle hooks (after_create, before_run, after_run, before_remove), and SSH worker support.
8. **Tracker** (`tracker.ex`) — Behaviour-based adapter for issue trackers. `Linear.Adapter` is the production implementation; `Tracker.Memory` is for testing.

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

## Key Conventions

- All public `def` in `lib/` must have `@spec` — enforced by `mix specs.check`
- `defp` specs are optional; `@impl` callbacks are exempt
- Runtime config comes from `WORKFLOW.md` YAML front matter, accessed through `CymphonyElixir.Config` (never read env vars directly in business logic)
- Workspace safety is critical: Claude Code must never run in the source repo cwd; all workspaces are validated to stay under the configured root
- Regexes must be compiled at runtime with `Regex.compile!/1` (not sigils) for OTP 28 compat
- Keep implementation aligned with `SPEC.md`; update spec when behavior changes meaningfully
- PR body must follow `.github/pull_request_template.md` exactly (validate with `mix pr_body.check`)
