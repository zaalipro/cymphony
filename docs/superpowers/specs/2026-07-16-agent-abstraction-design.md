# Spec A: Agent Abstraction — Claude Code + Codex Support

**Date:** 2026-07-16
**Status:** Approved
**Depends on:** nothing
**Depended on by:** Spec B (per-issue selection), Spec C (dashboard)

## Problem

Cymphony is a rewrite of OpenAI's symphony that swapped Codex for Claude Code — and hard-coded
Claude Code everywhere in the process. The runner (`Claude.AppServer`) builds `claude -p` argv and
parses Claude's JSON output; config lives under a `claude:` section; orchestrator state, API
payloads, and dashboard labels all say `claude_*`. We want the coding agent to be a configurable
choice per project (and, in Spec B, per issue): **Claude Code or Codex CLI**, with a clear path to
adding more agents later.

Compatibility note: this is a **clean break**. Old `~/.cymphony/config.json` shapes
(`claude_command`, top-level `claude:` runtime knobs) are not migrated. Users re-run `cymphony setup`
or hand-edit. No dual-format reading code.

## Key insight from the audit

The coupling is asymmetric:

- **Genuinely Claude-coupled:** argv construction, env-var injection (`ANTHROPIC_*`), output
  parsing (`json` / `stream-json` shapes), resume flag — all in `claude/app_server.ex`.
- **Already agent-neutral:** the token/rate-limit extraction (`Orchestrator.Tokens`) and event
  humanization (`StatusDashboard`) were inherited from symphony and still understand Codex-shaped
  payloads (`turn/completed`, `item/reasoning/*`, `account/rateLimits/updated`). The port
  lifecycle, SSH remoting, timeout handling, line collection, and workspace validation in
  AppServer are agent-agnostic too.

So the design is: extract the shared machinery into a generic runner, and reduce each agent to a
thin adapter (argv in, normalized result out).

## Design

### Module layout

```
lib/cymphony_elixir/agent/
├── agent.ex     # CymphonyElixir.Agent behaviour + kind resolver
├── runner.ex    # CymphonyElixir.Agent.Runner — shared session/turn machinery
├── claude.ex    # CymphonyElixir.Agent.Claude — Claude Code CLI adapter
└── codex.ex     # CymphonyElixir.Agent.Codex — Codex CLI adapter
```

`lib/cymphony_elixir/claude/app_server.ex` is deleted (its body becomes `runner.ex` + `claude.ex`).
`claude/dynamic_tool.ex` (vestigial no-op) is deleted; its only caller goes away with the split.

### The behaviour

```elixir
defmodule CymphonyElixir.Agent do
  @type run_spec :: %{
          kind: String.t(),            # "claude" | "codex"
          command: String.t() | nil,   # binary override from config
          model: String.t() | nil,
          effort: String.t() | nil,
          provider: String.t() | nil,  # auth alias (shell function / config provider)
          session_id: String.t() | nil,# non-nil ⇒ resume
          prompt: String.t(),
          workspace: Path.t(),
          mcp_descriptor: map() | nil, # tracker MCP data; each adapter renders it its own way
          settings: map()              # the agent-kind config section (claude:/codex:)
        }

  @type turn_result :: %{
          session_id: String.t() | nil,
          result: String.t() | nil,      # final assistant text
          usage: map() | nil,            # %{"input_tokens" => n, "output_tokens" => n, ...}
          raw: String.t()
        }

  @callback default_command() :: String.t()
  @callback build_command(run_spec()) :: {:ok, String.t()} | {:error, term()}
  @callback parse_output([String.t()], run_spec(), on_message :: fun()) ::
              {:ok, turn_result()} | {:error, term()}
  @callback auth_env_prefixes() :: [String.t()]
  @callback auth_env_fallback() :: [String.t()]

  @spec module_for(String.t()) :: {:ok, module()} | {:error, {:unknown_agent_kind, String.t()}}
  # "claude" -> Agent.Claude, "codex" -> Agent.Codex
end
```

Notes:

- `build_command/1` returns the full shell command string (same contract the port spawn uses
  today), because the runner wraps it in the rc-sourcing launch script and SSH remoting unchanged.
- `parse_output/3` receives all collected stdout lines after process exit plus the `on_message`
  callback so streaming adapters can emit per-event messages (Claude `stream-json` does today;
  Codex JSONL will too). It returns the normalized `turn_result`.
- `auth_env_prefixes/0` feeds `ShellProvider` filtering (see Providers below).
  `auth_env_fallback/0` lists env vars inherited from the daemon's own environment when no
  provider is set (Claude: `["ANTHROPIC_API_KEY"]`, Codex: `["OPENAI_API_KEY"]`).

### Runner (shared core)

`Agent.Runner` keeps AppServer's public shape so `AgentRunner` changes minimally:

- `start_session(workspace, opts)` → validates workspace under root (moved as-is), resolves the
  agent module from `run_spec.kind`, returns session map (now carrying `agent_module`).
- `run_turn(session, prompt, issue, opts)` → asks the adapter for the command, spawns the port
  (local `zsh/bash -c` with rc-sourcing wrapper, or SSH remote — moved as-is), injects env,
  collects lines with `turn_timeout_ms`, delegates to `adapter.parse_output/3`, emits the same
  lifecycle events (`:session_started`, `:turn_completed`, `:turn_ended_with_error`,
  `:startup_failed`, `:stream_event`).
- `stop_session(session)` → unchanged port cleanup.

Env construction generalizes: `provider_env` consults the adapter's prefixes;
`integration_auth_env` (LINEAR_API_KEY, GH_TOKEN/GITHUB_TOKEN) stays shared.

### Claude adapter

Argv (verified against Claude Code 2.1.211):

```
claude --bare -p <prompt> --output-format <fmt> [--verbose] --permission-mode <mode>
       --allowedTools <csv> [--model <m>] [--effort <low|medium|high|xhigh|max>]
       [--fallback-model <m>] [--max-turns <n>] [--max-budget-usd <d>]
       [--mcp-config <path>] [--resume <session_id>]
```

New vs today: `--effort` (from `run_spec.effort`). Parsing: unchanged (`json` last-object /
`stream-json` last `type=="result"`), moved into the adapter.

### Codex adapter

Argv (verified against codex-cli 0.144.5; probed live):

```
# first turn
codex exec --json --skip-git-repo-check [-m <model>] [-c model_reasoning_effort=<effort>]
      [-s <sandbox>] [-c mcp_servers.cymphony-linear...] <prompt>
# resume
codex exec resume <session_id> --json --skip-git-repo-check [same flags] <prompt>
```

- Sandbox: from `codex.sandbox` config (`read-only` | `workspace-write` | `danger-full-access`,
  default `workspace-write`). Network for workspace-write via
  `-c sandbox_workspace_write.network_access=true` when `codex.network_access` (default true —
  agents need git push).
- Approvals: headless exec never prompts interactively; no approval flag needed.
- MCP: Codex takes MCP servers via `-c mcp_servers.<name>.*=...` config overrides, not a JSON
  file. The adapter renders the same descriptor data (`Mcp.ConfigWriter` learns to return the raw
  descriptor map; the Claude adapter keeps writing the JSON file, the Codex adapter renders `-c`
  args). Secrets never hit argv: Codex supports
  `mcp_servers.<id>.env_vars = ["LINEAR_API_KEY", ...]` (verified against the Codex config
  reference) — an array of env-var *names* whitelisted to inherit from the codex process
  environment, which the runner already populates with `LINEAR_API_KEY`. The non-secret
  `LINEAR_ENDPOINT` goes in the `mcp_servers.<id>.env` map inline.
- Output (probed): JSONL events `{"type":"thread.started","thread_id":...}`, `{"type":"turn.started"}`,
  `{"type":"item.completed","item":{"type":"agent_message","text":...}}`,
  `{"type":"turn.completed","usage":{"input_tokens":...,"cached_input_tokens":...,"output_tokens":...}}`.
  Adapter maps: `thread_id` → `session_id`; last `agent_message` text → `result`;
  `turn.completed.usage` → `usage` (with `total_tokens` computed as input+output). Every event
  line is also forwarded through `on_message` as a `:stream_event` so tokens/humanizer see it.
- `turn.failed` / process nonzero exit → `{:error, ...}` mirroring Claude adapter semantics.

### Config schema (clean break)

`Config.Schema` restructured:

```yaml
agent:                        # shared, agent-neutral (extends existing section)
  kind: "claude"              # "claude" | "codex"  (default "claude")
  model: null                 # passed through to the CLI; nil = agent's own default
  effort: null                # passed through; nil = agent's own default
  max_concurrent_agents: 10   # (existing fields stay)
  max_turns: 20
  max_retry_backoff_ms: 300000
  max_retry_attempts: 30
  failure_state: null
  max_concurrent_agents_by_state: {}
  # runtime knobs moved here from claude:
  turn_timeout_ms: 3600000
  stall_timeout_ms: 300000

claude:                       # Claude-CLI-specific only
  command: "claude"
  permission_mode: "acceptEdits"
  allowed_tools: "Bash,Read,Edit"
  output_format: "stream-json"   # schema default unified with Defaults (was "json" in schema)
  fallback_model: null
  max_turns: null                # Claude CLI's internal --max-turns cap, distinct from agent.max_turns (AgentRunner loop)
  max_budget_usd: null
  bare_mode: true
  provider: null              # auth alias default
  providers: []               # auth alias rotation list

codex:                        # Codex-CLI-specific only
  command: "codex"
  sandbox: "workspace-write"  # read-only | workspace-write | danger-full-access
  network_access: true
  provider: null
  providers: []
```

Dropped entirely (Codex-app-server vestiges with no effect on the `claude -p` path):
`approval_policy`, `thread_sandbox`, `turn_sandbox_policy`, `read_timeout_ms` (configured the
removed JSON-RPC handshake wait; nothing reads it) and the schema's
`resolve_turn_sandbox_policy` / `resolve_runtime_turn_sandbox_policy` helpers.
`Defaults` and `CymphonyConfig.to_schema_map` regenerate the new shape; project JSON keys become
`agent`, `model`, `effort`, `claude: {...}`, `codex: {...}` (flat `claude_command` dies).

Model/effort values are **pass-through**: no inclusion validation, because both CLIs evolve their
model lists faster than we release. Bad values fail the run visibly (CLI errors on stderr are
captured in the collected output and land in the retry queue error).

### Providers (auth aliases) per agent kind

`provider`/`providers` move under each agent section because they are auth mechanisms specific to
the backend (`ANTHROPIC_*` shell functions vs `OPENAI_*`). `ShellProvider`'s hardcoded
`@env_prefix ~w(ANTHROPIC_ API_TIMEOUT CLAUDE_CODE_)` becomes a parameter supplied by the adapter's
`auth_env_prefixes/0` (Codex: `~w(OPENAI_ CODEX_)`; `API_TIMEOUT` stays in both). The
config-based providers map in `~/.cymphony/config.json` (top-level `providers` key) is untouched —
it already just maps names to env-var maps.

Orchestrator provider rotation (`extract_providers/select_provider`) reads from the **active
agent kind's** section.

### Neutral renames (state, messages, API, docs)

One mechanical sweep, no behavior change:

| Old | New |
|---|---|
| `:claude_worker_update` message | `:agent_worker_update` |
| state `claude_totals`, `claude_rate_limits` | `token_totals`, `rate_limits` |
| running-entry `claude_{input,output,total}_tokens` (+ `_last_reported_*`) | `{input,output,total}_tokens` (+ `last_reported_*`) |
| `last_claude_{message,timestamp,event}` | `last_agent_{message,timestamp,event}` |
| `claude_app_server_pid` | `agent_os_pid` |
| snapshot `claude_command` | `agent_kind` + `agent_command` |
| `integrate_claude_update`, `apply_claude_token_delta`, … | `integrate_agent_update`, … |
| API JSON fields mirroring the above | same new names (breaking; API consumers = the dashboard) |

`CompletionStore` rows, `Presenter`, `StatusDashboard` labels, and SPEC.md sections 5.3.6/10
update to match. `humanize_claude_*` → `humanize_agent_*`; the humanizer gains cases for the
Codex JSONL vocabulary (`thread.started`, `turn.started/completed/failed`,
`item.started/completed` with `agent_message`/`command_execution`/`reasoning` item types).

### CLI & onboarding

- `--claude-command` / `c <value>`-as-command-override dies. `c` remains **provider rotation
  only** (its documented behavior).
- New shorthands: `agent <kind>` → `--agent <kind>`, `model <name>` → `--model <name>`,
  `effort <level>` → `--effort <level>`. Each persists to the project's config like `cr` does.
- Onboarding wizard asks "Coding agent? [claude/codex]" and stores `agent: <kind>` per project.
- Help text and CLAUDE.md / README command tables updated.

### AgentRunner changes

`AgentRunner.run_claude_turns` → `run_agent_turns`; it builds the `run_spec` from
config + opts (Spec B threads per-issue overrides through the same opts) and calls
`Agent.Runner`. The continuation-guidance prompt drops the word "Claude"
("The previous agent turn completed normally…"). The multi-turn resume loop is unchanged —
`session_id` from turn N feeds turn N+1; the adapter decides what "resume" means in argv.

## Error handling

- Unknown `agent.kind` in config → `{:invalid_workflow_config, ...}` at parse time (inclusion
  validation on `kind` only, since we own that vocabulary).
- Agent binary not found → port spawn fails as today; error lands in retry queue with the
  command name in the reason.
- Codex `turn.failed` event or missing `turn.completed` → `{:error, {:turn_failed, details}}` /
  `{:error, {:no_result_in_stream, raw}}`, symmetric with Claude's `{:no_json_output, _}`.
- Session resume of an expired/unknown Codex session id → codex exits nonzero; run fails and
  retries fresh (retry path never reuses session ids — already true today).

## Testing

- Behaviour conformance: one shared test module run against both adapters (command contains
  model/effort when set; omits when nil; resume argv correct; secrets never in argv).
- Adapter parse tests with canned transcripts: Claude `json` + `stream-json` fixtures (existing
  tests move), Codex JSONL fixture captured from the live probe (thread.started → turn.completed,
  plus a `turn.failed` variant).
- Runner tests (port lifecycle, timeout, env filtering) keep existing AppServer coverage,
  re-pointed.
- `ShellProvider` prefix-parameterization test (codex prefixes captured, anthropic excluded).
- Schema tests for the new sections + kind inclusion validation.
- `make coverage` 100% threshold holds on tracked modules.

## Non-goals

- No Codex app-server JSON-RPC client (decided: `codex exec --json` per turn).
- No config auto-migration from the old format.
- No per-issue selection (Spec B) or dashboard changes (Spec C) — but the `run_spec` carries
  `kind/model/effort/provider` so both bolt on without re-touching the runner.
