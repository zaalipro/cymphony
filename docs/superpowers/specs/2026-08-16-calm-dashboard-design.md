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
  - elapsed: `<span data-clock="elapsed" data-base-seconds="222">3m 42s</span>` (session runtime, stall duration). The global runtime tile is the sum over all running sessions, so it advances one second per running session per wall second and adds a multiplier: `<span data-clock="elapsed" data-base-seconds="222" data-rate="3">3m 42s</span>`. Nothing in the dashboard renders a turns suffix.
- One `LiveClock` JS hook (registered in `layouts.ex` beside `HarnessTail`/`QueueBoard`/`Combobox`, attached to a single wrapper element around the dashboard) runs one 1-second interval that rewrites only those spans' `textContent` locally. On its `updated()` lifecycle it re-reads the (freshly patched) data attributes, so every payload refresh re-anchors the clocks — client clock skew cannot accumulate because anchors are *remaining/elapsed amounts*, not absolute wall times.
- The JS formatting mirrors the existing Elixir formatting exactly (`"#{mins}m #{secs}s"`, `"#{seconds}s"`, `"now"`); parity is pinned by tests listing the expected strings.
- Server-side `:runtime_tick` **keeps ticking** (it schedules the periodic payload refresh) but **stops assigning `:now`**. `:now` is assigned only when a payload is (re)loaded, so server-rendered values are correct at render time and the hook takes over between refreshes. (Narrowed as built — see Deviations.)
- The "checking now…" poll state stays server-rendered (it is data, not time).
- Without JS the page degrades to values-as-of-last-refresh, same as the rest of the dashboard's no-JS story.

### 2. Change-only re-renders (assign splitting)

Split the monolithic `@payload` into per-section assigns and only reassign sections that actually changed:

- New `assign_payload_sections(socket, payload)` assigns `:counts`, `:token_totals`, `:rate_limits`, `:polling`, `:projects` (per-project running/waiting/retrying live inside each project entry), `:completions`, comparing each section with `==` against the current assign and **skipping identical ones**. LiveView's change tracking then skips re-evaluating those sections entirely. (As built the split also carries `:running`, `:retrying` and `:payload_error`, and the comparison is not raw `==` — see Deviations.)
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

## Deviations (as built)

Recorded so a reviewer diffing the branch against this document does not read a mismatch. `SPEC.md` and `CLAUDE.md` describe the shipped behavior; this section only says where it departs from the plan above and why.

1. **`:now` is re-anchored on a *changed* payload load, not on every load.** §1 says `:now` is assigned "when a payload is (re)loaded". That alone does not deliver §2's stated effect: `:now` is read inside the per-project comprehension (session runtime, retry due-in), a HEEx comprehension is a single change-tracked slot, and a recomputed comprehension is serialized into the diff in full. Moving `:now` on every load therefore re-serialized every project header, queue card, session row and restart form on every poll, no matter which sections were skipped. As built, `assign_payload_sections/2` re-anchors `:now` only when a section a clock reads (`:token_totals`, `:running`, `:projects`) actually moved, and the poll countdown was changed to read no wall clock at all (`next_poll_in_ms` is already a remaining amount). Consequence: server-rendered clock text is correct as of the last *changed* load rather than the last load; the hook advances it in between, and a no-JS reader sees values-as-of-last-change instead of values-as-of-last-refresh.

2. **Sections are compared with a signature, not raw `==`.** §2 says "comparing each section with `==`". A running entry's `tokens_per_second` is re-derived by the presenter from the wall clock on every load, so raw `==` would make `:running` and `:projects` differ on every single refresh and the skip would never fire while an agent runs. The comparison drops that one field, and on a match the previous section value is retained. Display trade-off: the per-session `t/s` chip holds the value from the last load that moved a real field — during a long tool call it does not decay, and it catches up as soon as anything else about the session moves. This was judged preferable to re-rendering the whole board to animate a rate the server derives from nothing but the clock.

3. **`due_at` is stabilized, not made exactly stable.** `Presenter.due_at_iso8601/1` now adds the offset in milliseconds and truncates once (`floor(now + due_in_ms)`) instead of truncating the clock and adding whole seconds, because the old form flipped between two adjacent seconds on roughly half of all loads and made an unchanged retry queue look changed. `due_in_ms` is measured against the orchestrator's monotonic clock and `now` is sampled later in the presenter, so the sum still jitters by the snapshot round-trip and can straddle a second boundary. This is a large reduction in flip rate, not a guarantee. `retrying[].due_at` in `GET /api/v1/state` keeps its documented shape (an ISO8601 second); only the exact second it lands on shifts.

4. **Collateral edits outside the web dashboard.** The scope line above says "web dashboard only", and the pipeline's *behavior* does not move — but the branch also touches `orchestrator.ex`, `linear/client.ex`, `cymphony/config.ex`, `control.ex` and `project_supervisor.ex`. These are behavior-preserving: unreachable defensive clauses removed (each proven unreachable by its call sites or by dialyzer) and closures extracted to named functions. They are there because the repo's `make all` gate gives no room to leave them: coverage has a 100% threshold on tracked modules, so a clause no test can reach fails the build, and `credo --strict` rejects the nesting the extracted closures used to have. `ProjectSupervisor.await_unregistered/1,2` was promoted from a private default-arg helper to two `@doc`/`@spec`'d public functions for the same reason — its budget-exhaustion branch is not reachable through any other public entry point. Reverting them would break the gate, so they stay; they are called out here because they widen the blast radius of a change whose goal is that the pipeline does not move.
