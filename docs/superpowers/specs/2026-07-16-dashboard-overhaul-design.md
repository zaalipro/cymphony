# Spec C: Dashboard Reorganization + Configurability

**Date:** 2026-07-16
**Status:** Approved
**Depends on:** Spec A (agent config sections), Spec B (per-issue resolved run specs in metadata)

## Problem

The dashboard grew organically: controls are scattered across headers (global concurrency form,
per-project inline forms, pause buttons in the ops row), every section is always visible at full
density, and there is nothing about agents/models — the provider input is even mislabeled
"claude command". We want it organized (clear hierarchy, controls in predictable places) and
configurable (per-browser display preferences + the new agent knobs).

## Layout (top to bottom)

1. **Top bar** — status badge, project count, version, theme toggle, Refresh, and a new **⚙
   Settings** button that opens the settings drawer.
2. **Metrics strip** — one row of stat tiles: Running, Retrying, Tokens (in/out detail), Runtime,
   Throughput + sparkline, and the rate-limit buckets compacted into small labeled meters
   (primary/secondary/credits with reset countdowns). Polling status + next-poll countdown lives
   at the strip's right edge.
3. **Alert banners** — flash + stalled-agent alerts, unchanged position.
4. **Project cards** — the primary content, one per project (existing sections, reorganized
   header — see below).
5. **Recent completions** — collapsed by default.

### Settings drawer

A right-side panel (CSS-driven open/close, `data-drawer="open"` on `<html>`) with two groups:

- **Orchestrator** (server-side, LiveView forms — these move out of the page body):
  - Pause/Resume all (from ops row)
  - Global concurrency (the legacy `set_concurrency` all-projects form)
- **Display** (client-side, localStorage):
  - Section visibility checkboxes: Metrics, Rate limits, Polling, Completions
  - Density: Comfortable / Compact
  - Session-row columns: Title, Chips, Runtime, Tokens (identifier + Kill always shown)
  - Completions length: 25 / 50 / 100

### Client-side preference mechanism

Same pattern as the existing theme toggle (`layouts.ex` script): delegated click/change handlers
set `data-*` attributes on `<html>` and persist to localStorage under `cymphony-prefs`; CSS rules
key off the attributes. Because the attributes live on `<html>` — outside the LiveView container —
LiveView DOM patches never clobber them, and no server round-trip or server state is involved.

- `data-density="compact"` → tighter paddings/font sizes via CSS.
- `data-hidden-sections="ratelimits completions"` → `html[data-hidden-sections~="completions"]
  .section--completions { display: none }` (token-list attribute selector per section).
- `data-collapsed-sections="metrics"` → hides section bodies, keeps headers with a ▸/▾ marker.
  Every section header gets a collapse control.
- `data-hidden-cols="title runtime"` → hides session-row cells.
- `data-completions-limit="25"` → `.completion-row:nth-child(n+26) { display: none }` (payload
  keeps sending up to 100; trimming is visual).

The per-session expand (`toggle_logs`) stays server-side as today (it reveals data-bearing detail,
not a display pref).

## Project card header (reorganized)

Left: project name, paused chip, running/cap + retrying counts (as today).
Right, one aligned control cluster:

- `concurrency` number input (existing)
- **`agent` select** — claude / codex
- **`model` text input** with `<datalist>` suggestions (claude: sonnet/opus/haiku aliases;
  codex: gpt-5.2-codex etc. — suggestions only, free text allowed since values are pass-through)
- **`effort` select** — (default) / low / medium / high / xhigh / max for claude; (default) /
  minimal / low / medium / high / xhigh for codex; rendered options switch with the agent select
  via a tiny LiveView re-render (the select posts `phx-change`)
- `providers` text input — **relabeled "providers"** (fixing the "claude command" mislabel),
  writes to the active agent kind's section
- Pause/Resume button (existing)

Agent/model/effort submit as one `set_project_agent` form: updates the orchestrator state and
persists to `~/.cymphony/config.json` (`agent`, `model`, `effort` project keys), applying to next
dispatch. Running sessions are unaffected (same semantics as provider changes today).

## Session rows

- Chips gain **agent kind** (`claude`/`codex`), **model**, and **effort** (when set) next to the
  existing state/provider/host chips — populated from the run-spec metadata Spec B stamps at
  dispatch. Model chips truncate with full value in `title`.
- Expanded detail: the per-session provider form generalizes to a **restart-with-overrides** form
  (provider + model + effort inputs, one Set button) driving Spec B's
  `{:set_issue_run_spec, ...}` kill-and-restart. Agent kind is deliberately not offered here
  (kind switches invalidate sessions; use labels/config and let the retry pick it up).
- Completions rows gain agent kind + model columns (CompletionStore already extended in Spec B).

## Web plumbing

- `Presenter` passes through `agent_kind`, `model`, `effort` on running entries, completions, and
  project payloads (project-level: the config defaults, for prefilling header controls).
- `Control.set_agent_settings(scope, %{kind, model, effort})` — mirrors `set_concurrency`
  (orchestrator call + `CymphonyConfig.update_agent_settings/2` persistence).
- New API endpoint: `POST /api/v1/agent` — JSON body
  `{"kind": "codex", "model": "gpt-5.2-codex", "effort": "high"}` (all keys optional, omitted =
  unchanged), optional `?project=<name>`, 202 response. Documented in CLAUDE.md/README tables
  alongside `/concurrency` and `/providers`.
- LiveView events added: `set_project_agent`, `set_issue_run_spec` (replacing `set_provider`);
  removed: none otherwise. `set_concurrency` (global) moves into the drawer markup unchanged.

## Error handling

- `set_project_agent` with unknown kind → flash error, no write (kind is validated; model/effort
  pass through).
- localStorage unavailable (private mode) → prefs work for the tab session via the DOM attributes,
  silently skip persistence (same try/catch style as the theme script).
- Old localStorage keys absent → defaults: all sections visible, comfortable density, all columns,
  completions 100, drawer closed.

## Testing

- LiveView tests: drawer renders both control groups; `set_project_agent` round-trips to config
  and orchestrator (async-safe via the existing test endpoint/orchestrator injection);
  `set_issue_run_spec` sends the kill-and-restart command; effort options switch with agent
  select; providers label reads "providers".
- Controller tests for `POST /api/v1/agent` (global + per-project + validation errors + 401 with
  auth token).
- Presenter tests for the new pass-through fields.
- Client-side pref behavior is CSS/vanilla-JS keyed off `<html>` attributes — covered by a
  lightweight LiveView test asserting the data-attribute hooks/classes exist in rendered markup
  (the JS itself follows the already-shipped theme pattern and stays test-exempt like the theme
  toggle).

## Non-goals

- No server-persisted user profiles or multi-user pref sync (localStorage per browser).
- No project tabs/filtering (revisit when someone runs >4 projects).
- No auth changes; drawer respects the existing token model.
- No charting library; sparkline stays text-based.
