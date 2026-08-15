# Cymphony Elixir

The Elixir agent orchestration service that polls Linear, creates per-issue workspaces, and runs a coding-agent CLI (Claude Code, Codex, or Antigravity) in headless mode.

## Environment

- Elixir: `1.19.x` (OTP 28) via `mise`.
- Install deps: `mix setup`.
- Main quality gate: `make all` (format check, lint, coverage, dialyzer).


## Codebase-Specific Conventions

- Runtime config is loaded from `WORKFLOW.md` front matter via `CymphonyElixir.Workflow` and `CymphonyElixir.Config`.
- Agent kinds are the closed set from `CymphonyElixir.Agent.known_kinds/0` (`claude`, `codex`, `antigravity`). Select at run time with `cymphony agent antigravity`, a Linear label `agent:antigravity`, or a description directive `cymphony: agent=antigravity`. Antigravity provider env prefixes are `ANTIGRAVITY_` / `GOOGLE_` / `GEMINI_` (plus `API_TIMEOUT`; fallback keys `GOOGLE_API_KEY` / `GEMINI_API_KEY`).
- The dashboard expanded session row has a live Harness stdout pane (`HarnessStream`) and a per-session agent-kind select on `set_issue_run_spec`.
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
- `CLAUDE.md` / `AGENTS.md` for CLI, labels, dashboard Harness pane, and provider prefixes.
