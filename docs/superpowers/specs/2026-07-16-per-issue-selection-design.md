# Spec B: Per-Issue Agent / Model / Effort Selection

**Date:** 2026-07-16
**Status:** Approved
**Depends on:** Spec A (agent abstraction — supplies the `run_spec` knobs)
**Depended on by:** Spec C (dashboard shows the resolved values)

## Problem

Today every dispatch in a project runs with the same backend and model. We want to choose the
coding agent (claude/codex), the model, the reasoning effort, and optionally the auth provider
**per issue**, controlled from Linear itself — so a heavy architectural ticket can run
`codex`+`gpt-5.2-codex`+`effort:xhigh` while a typo fix on the same board runs claude/haiku, with
no config edits or restarts.

## Sources and precedence

Resolution happens in the orchestrator at dispatch time. Highest source wins per **field**
(not per source-block):

1. **Linear labels** — `agent:<kind>`, `model:<name>`, `effort:<level>`, `provider:<alias>`
2. **Description directive** — a `cymphony:` line in the issue description
3. **Project config** — `agent.kind`, `agent.model`, `agent.effort`, active agent section's
   `provider`/`providers` rotation
4. **Built-ins** — kind `"claude"`, model/effort nil (agent's own defaults)

So an issue labeled `effort:high` whose description says `cymphony: model=opus` runs with
effort from the label, model from the directive, agent kind from project config.

### Label syntax

- Exact prefixes `agent:`, `model:`, `effort:`, `provider:` — value is everything after the first
  colon, trimmed. Labels arrive already-downcased from `Linear.Adapter`, which is fine: agent
  kinds, effort levels, and model ids are lowercase in both CLIs; provider aliases are
  conventionally lowercase shell function names.
- Multiple labels with the same prefix: first after sorting wins, and a warning is logged
  (deterministic rather than list-order-dependent).

### Description directive syntax

- Line-based: the **first** line in the description matching
  `cymphony:` followed by `key=value` pairs separated by whitespace.
- Grammar: `cymphony:\s+(key=value\s*)+` with keys in `agent|model|effort|provider`;
  values match `[A-Za-z0-9._\/-]+`. Case-insensitive key match; values lowercased for `agent`
  and `effort`, preserved for `model` and `provider`.
- Example: `cymphony: agent=codex model=gpt-5.2-codex effort=high`
- Unknown keys in the directive are ignored with a debug log (forward compat).
- Parsing lives in a new pure module `CymphonyElixir.RunSpecResolver` — trivially unit-testable,
  no GenServer dependencies.

## Resolution semantics

- **Validation posture:** `agent` must be a known kind (`claude`/`codex`) — an unknown kind logs
  a warning and falls back to the next source (never fails dispatch). `model`, `effort`,
  `provider` are pass-through; a bad model fails the run visibly and lands in the retry queue,
  which is the desired feedback loop. A `provider` alias that resolves to no env vars behaves as
  today (falls back to inherited auth env).
- **Pinned per run attempt:** the resolved `%RunSpec{kind, model, effort, provider}` is computed
  once at dispatch and threaded through `Dispatch → spawn_issue_on_worker_host → AgentRunner`
  as opts (extending today's `provider_override` mechanism to a full spec). Multi-turn resume
  within one attempt never re-resolves — an agent switch mid-session is impossible.
- **Re-resolved on retry:** each retry attempt re-reads issue labels/description (the poller
  refreshes issues anyway), so editing labels in Linear changes behavior on the next attempt.
- **Provider interaction:** when the issue pins `provider:x`, rotation is bypassed for that
  issue. When the issue pins only `agent:codex`, provider rotation draws from the **codex**
  section's `providers` list.
- **Concurrency:** unchanged — slots are global per project regardless of agent kind.

## State & observability plumbing

- Running-entry metadata gains `agent_kind`, `model`, `effort` next to the existing `provider`
  (all stamped at spawn). Presenter/API/CompletionStore expose them; Spec C renders them.
- Log line at dispatch: `... agent=codex model=gpt-5.2 effort=high provider=cz source=labels`
  (source = highest source that set any field, for debuggability).
- The dashboard kill-and-restart override (`{:set_issue_provider, ...}`) generalizes to
  `{:set_issue_run_spec, issue_id, %{provider, model, effort}}` — agent kind is intentionally
  NOT runtime-overridable per running session (a kind switch invalidates the session id; kill
  and let labels drive the retry instead).

## Interaction with prompt

None. The prompt template already renders labels; directive lines are part of the description
and flow into the prompt harmlessly. No template changes.

## Error handling

- Malformed directive line (regex mismatch) → ignored entirely, debug log; issue dispatches on
  lower-precedence sources.
- Label value empty (`model:`) → treated as absent, warning logged.
- Conflicting duplicate labels → deterministic pick (sorted first) + warning, never a dispatch
  failure.

## Testing

- `RunSpecResolver` pure unit tests: precedence matrix (label > directive > config > default,
  per-field mixing), syntax edge cases (duplicates, empties, unknown kinds, unknown directive
  keys, directive not on first line, multiple directive lines).
- Orchestrator dispatch test: issue with `agent:codex` label spawns with codex run_spec while a
  sibling issue in the same tick uses project default (Tracker.Memory fixtures).
- Retry re-resolution test: label added between attempt 1 failure and attempt 2 changes the spec.
- Provider pin test: `provider:cz` bypasses rotation.

## Non-goals

- No per-issue concurrency or timeout overrides (YAGNI — revisit if a real need appears).
- No mid-session agent switching.
- No Linear webhook push; resolution stays poll-driven.
