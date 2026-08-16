# Calm Dashboard — design

Date: 2026-08-16
Scope: web dashboard only (terminal status box explicitly out of scope).
Branch: `calm-dashboard`

## Problem

The LiveView dashboard *feels* like it does a whole-page refresh every few seconds. Verified against the live deployment (v2.6.3 at cymphony.llmotions.com): there are **no actual page reloads** — the websocket stays connected, DOM nodes are patched in place, a JS marker survives indefinitely. What users see is **churn**: measured ~55 DOM mutations *every second* on a fully idle dashboard (0 running agents), with bursts of ~165 on every Linear poll tick.

Two causes, both in `lib/cymphony_elixir_web/live/dashboard_live.ex`:

1. **The 1-second `:runtime_tick` reassigns `:now`**, which re-renders every time-derived string (poll countdown, session runtimes, stall durations, retry due-in) across the whole template, every second, shipping a diff over the websocket each time.
2. **Every payload update replaces the single giant `@payload` assign.** All template sections reference `@payload.…`, so LiveView must re-evaluate the entire template on every poll/pubsub event even when most sections are byte-identical.

## Goals (measurable)

- Idle dashboard: **< 5 DOM mutations/sec** (from ~55) and **zero per-second render traffic** over the websocket.
- A poll tick that returns no data changes: **~0 mutations** (from ~165).
- A real data change patches only the affected rows/tiles.
- No change to data-pipeline behavior: poll cadence, pubsub events, `dashboard_refresh_seconds` semantics, API responses all stay as documented in `SPEC.md`.
- No new dependencies; no binary-size change.

## Non-goals

- Terminal status box (`status_dashboard.ex` clears the screen every second; user chose to leave it for now).
- Purely event-driven refresh (dropping the periodic snapshot re-read) — unnecessary once re-renders are change-only.
- Changing any refresh/poll intervals or their configuration.

## Design

### 1. Client-side clocks (`LiveClock` hook)

Stop re-rendering time strings from the server every second. Instead:

- Server renders each time-derived value **once per payload refresh**, wrapped in a span carrying data attributes, e.g.
  - countdown: `<span data-clock="countdown" data-remaining-ms="12340">12s</span>` (poll countdown, retry due-in)
  - elapsed: `<span data-clock="elapsed" data-base-seconds="222" data-turns="3">3m 42s / 3</span>` (session runtime, stall duration, global runtime)
- One `LiveClock` JS hook (registered in `layouts.ex` beside `HarnessTail`/`QueueBoard`/`Combobox`, attached to a single wrapper element around the dashboard) runs one 1-second interval that rewrites only those spans' `textContent` locally. On its `updated()` lifecycle it re-reads the (freshly patched) data attributes, so every payload refresh re-anchors the clocks — client clock skew cannot accumulate because anchors are *remaining/elapsed amounts*, not absolute wall times.
- The JS formatting mirrors the existing Elixir formatting exactly (`"#{mins}m #{secs}s"`, `"#{seconds}s"`, `"… / turns"`); parity is pinned by tests listing the expected strings.
- Server-side `:runtime_tick` **keeps ticking** (it schedules the periodic payload refresh) but **stops assigning `:now`**. `:now` is assigned only when a payload is (re)loaded, so server-rendered values are correct at render time and the hook takes over between refreshes.
- The "checking now…" poll state stays server-rendered (it is data, not time).
- Without JS the page degrades to values-as-of-last-refresh, same as the rest of the dashboard's no-JS story.

### 2. Change-only re-renders (assign splitting)

Split the monolithic `@payload` into per-section assigns and only reassign sections that actually changed:

- New `assign_payload_sections(socket, payload)` assigns `:counts`, `:token_totals`, `:rate_limits`, `:polling`, `:projects` (per-project running/waiting/retrying live inside each project entry), `:completions`, comparing each section with `==` against the current assign and **skipping identical ones**. LiveView's change tracking then skips re-evaluating those sections entirely.
- The template switches from `@payload.x` to the split assigns (`@counts`, `@polling`, …) — required, because nested `@payload.x` access defeats change tracking.
- Both `reload_payload_now/1` and the async `{:payload_loaded, seq, payload}` path go through the same function; `payload_seq` guarding is unchanged.
- Lists stay plain comprehensions for now (running ≤ concurrency limit, queue tens, completions ≤ 100 — small). LiveView streams are a follow-up *only if* measurement still shows a visible burst on single-row changes; they complicate queue drag-reorder and expanded-row state and are not needed to hit the goals above.

### 3. Verification

- Browser probe (same as diagnosis): count `MutationObserver` records/sec for 50s against a locally running build — acceptance: idle < 5/sec, no-change poll ≈ 0.
- LiveView tests: (a) `:runtime_tick` with an unchanged payload produces identical rendered HTML; (b) re-delivering an identical payload changes no section assigns (rendered HTML identical); (c) time spans carry the `data-clock` attributes; (d) existing `dashboard_live_test.exs` suite still passes.
- `make all` (fmt, credo, specs.check, 100% coverage on tracked modules, dialyzer) green before handoff.

## Error handling

- Malformed/missing data attributes: hook skips the span (no throw), leaving server-rendered text.
- Hook interval is a single timer; it clears on `destroyed()` to avoid leaks across live navigation.
- If a payload section is absent (older orchestrator snapshot shape), `assign_payload_sections` falls back to the section default currently in `@default_payload`.

## Documentation updates (with implementation)

- `SPEC.md` + `CLAUDE.md` dashboard sections: describe client-side clocks and change-only refresh behavior (the "Refresh behavior" section changes meaningfully).
- After merge, redeploy the GCP instance behind cymphony.llmotions.com to pick it up.
