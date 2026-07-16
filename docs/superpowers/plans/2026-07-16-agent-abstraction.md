# Agent Abstraction (Spec A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the coding agent a configurable choice (Claude Code or Codex CLI) behind a `CymphonyElixir.Agent` behaviour, with a clean-break config restructure and neutral naming.

**Architecture:** Extract the agent-agnostic machinery from `Claude.AppServer` (port lifecycle, SSH, env injection, timeouts, workspace validation) into `Agent.Runner`; reduce each backend to a thin adapter (`Agent.Claude`, `Agent.Codex`) that builds argv and parses output into one normalized shape. Config splits into a neutral `agent:` section (kind/model/effort/timeouts) plus slim `claude:`/`codex:` sections. All `claude_*` state keys become neutral.

**Tech Stack:** Elixir 1.19 / OTP 28, Ecto embedded schemas, Ports, ExUnit. Verified CLIs: Claude Code 2.1.211 (`-p --model --effort low|medium|high|xhigh|max --resume`), codex-cli 0.144.5 (`exec --json`, `exec resume <id> --json`, `-c model_reasoning_effort=…`, `-c sandbox_mode=…` — note `-s` is NOT accepted by `exec resume`, always use `-c sandbox_mode`).

**Spec:** `docs/superpowers/specs/2026-07-16-agent-abstraction-design.md`

**Verification gate for every task:** the repo convention is `make all` before handoff; per-task use the targeted `mix test <file>` commands given below.

---

## File map (who owns what)

| File | Role |
|---|---|
| `lib/cymphony_elixir/agent.ex` (new) | Behaviour + `module_for/1` kind resolver |
| `lib/cymphony_elixir/agent/runner.ex` (new) | Shared session/turn machinery (from AppServer) |
| `lib/cymphony_elixir/agent/claude.ex` (new) | Claude CLI adapter (argv + json/stream-json parsing) |
| `lib/cymphony_elixir/agent/codex.ex` (new) | Codex CLI adapter (argv + JSONL parsing) |
| `lib/cymphony_elixir/claude/app_server.ex` | DELETED (body moves to runner+claude adapter) |
| `lib/cymphony_elixir/claude/dynamic_tool.ex` | DELETED (vestigial no-op) |
| `lib/cymphony_elixir/config/schema.ex` | New `agent`/`claude`/`codex` sections; drop sandbox/approval vestiges |
| `lib/cymphony_elixir/config.ex` | Drop `claude_runtime_settings` type+fn, `claude_turn_sandbox_policy` |
| `lib/cymphony_elixir/cymphony/{defaults,config,onboarding}.ex` | New generation defaults, `to_schema_map` shape, agent question |
| `lib/cymphony_elixir/cymphony/shell_provider.ex` | Prefix list becomes a parameter |
| `lib/cymphony_elixir/mcp/config_writer.ex` | Expose descriptor map builder |
| `lib/cymphony_elixir/agent_runner.ex` | Builds run_spec, neutral naming |
| `lib/cymphony_elixir/orchestrator.ex` + `orchestrator/{stall,tokens}.ex` | Neutral state keys, per-kind providers, `:agent_worker_update` |
| `lib/cymphony_elixir/completion_store.ex` | Column renames w/ tolerant migration |
| `lib/cymphony_elixir/status_dashboard.ex` | `humanize_agent_*`, Codex JSONL vocabulary |
| `lib/cymphony_elixir_web/{presenter.ex,live/dashboard_live.ex}` | Key renames only (UI features are Spec C) |
| `lib/cymphony_elixir/cli.ex` | `--agent/--model/--effort`, `c`→provider, drop `--claude-command` |
| `test/support/test_support.exs` | New workflow YAML shape |
| `mix.exs` | Coverage ignore list: swap AppServer→Agent.Runner, drop DynamicTool |
| `SPEC.md`, `CLAUDE.md`, `README.md` | Doc updates |

Rename sweep cheat-sheet (used by Tasks 8–10):

| Old | New |
|---|---|
| `{:claude_worker_update, id, upd}` | `{:agent_worker_update, id, upd}` |
| `claude_totals` | `token_totals` |
| `claude_rate_limits` | `rate_limits` (state field) |
| `claude_input_tokens` / `claude_output_tokens` / `claude_total_tokens` | `input_tokens` / `output_tokens` / `total_tokens` |
| `claude_last_reported_*_tokens` | `last_reported_*_tokens` |
| `last_claude_message/timestamp/event` | `last_agent_message/timestamp/event` |
| `claude_app_server_pid` | `agent_os_pid` |
| snapshot `claude_command` | `agent_kind` + `agent_command` |
| `integrate_claude_update` / `apply_claude_token_delta` / `apply_claude_rate_limits` | `integrate_agent_update` / `apply_agent_token_delta` / `apply_agent_rate_limits` |
| `humanize_claude_message` (public) | `humanize_agent_message` |

---

### Task 1: Config schema — new `agent` fields, slim `claude`, new `codex`

**Files:**
- Modify: `lib/cymphony_elixir/config/schema.ex`
- Modify: `lib/cymphony_elixir/config.ex`
- Modify: `test/support/test_support.exs`
- Test: `test/cymphony_elixir/config_schema_test.exs` (new)

- [ ] **Step 1: Write the failing schema test**

Create `test/cymphony_elixir/config_schema_test.exs`:

```elixir
defmodule CymphonyElixir.ConfigSchemaTest do
  use ExUnit.Case, async: true

  alias CymphonyElixir.Config.Schema

  test "agent section carries kind/model/effort and moved timeouts with defaults" do
    assert {:ok, settings} = Schema.parse(%{})
    assert settings.agent.kind == "claude"
    assert settings.agent.model == nil
    assert settings.agent.effort == nil
    assert settings.agent.turn_timeout_ms == 3_600_000
    assert settings.agent.stall_timeout_ms == 300_000
  end

  test "agent.kind accepts codex and rejects unknown kinds" do
    assert {:ok, settings} = Schema.parse(%{"agent" => %{"kind" => "codex"}})
    assert settings.agent.kind == "codex"

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"agent" => %{"kind" => "gemini"}})

    assert message =~ "kind"
  end

  test "claude section is slim: providers live here, sandbox/approval vestiges are gone" do
    assert {:ok, settings} =
             Schema.parse(%{"claude" => %{"provider" => "cz", "providers" => ["cz", "cv"]}})

    assert settings.claude.command == "claude"
    assert settings.claude.output_format == "stream-json"
    assert settings.claude.provider == "cz"
    assert settings.claude.providers == ["cz", "cv"]
    refute Map.has_key?(settings.claude, :approval_policy)
    refute Map.has_key?(settings.claude, :thread_sandbox)
    refute Map.has_key?(settings.claude, :turn_sandbox_policy)
    refute Map.has_key?(settings.claude, :model)
  end

  test "codex section defaults and sandbox validation" do
    assert {:ok, settings} = Schema.parse(%{})
    assert settings.codex.command == "codex"
    assert settings.codex.sandbox == "workspace-write"
    assert settings.codex.network_access == true
    assert settings.codex.providers == []

    assert {:ok, settings} = Schema.parse(%{"codex" => %{"sandbox" => "read-only"}})
    assert settings.codex.sandbox == "read-only"

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"codex" => %{"sandbox" => "yolo"}})

    assert message =~ "sandbox"
  end
end
```

- [ ] **Step 2: Run it to verify failure**

Run: `mix test test/cymphony_elixir/config_schema_test.exs`
Expected: FAIL — `agent.kind` key error / `codex` embed missing.

- [ ] **Step 3: Restructure the schema**

In `lib/cymphony_elixir/config/schema.ex`:

a. Delete the whole `defmodule StringOrMap` block (only `approval_policy` used it).

b. Replace the `Agent` submodule body with:

```elixir
  defmodule Agent do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias CymphonyElixir.Config.Schema

    @primary_key false
    embedded_schema do
      field(:kind, :string, default: "claude")
      field(:model, :string)
      field(:effort, :string)
      field(:max_concurrent_agents, :integer, default: 10)
      field(:max_turns, :integer, default: 20)
      field(:max_retry_backoff_ms, :integer, default: 300_000)
      field(:max_retry_attempts, :integer, default: 30)
      field(:failure_state, :string)
      field(:max_concurrent_agents_by_state, :map, default: %{})
      field(:turn_timeout_ms, :integer, default: 3_600_000)
      field(:stall_timeout_ms, :integer, default: 300_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :kind,
          :model,
          :effort,
          :max_concurrent_agents,
          :max_turns,
          :max_retry_backoff_ms,
          :max_retry_attempts,
          :failure_state,
          :max_concurrent_agents_by_state,
          :turn_timeout_ms,
          :stall_timeout_ms
        ],
        empty_values: []
      )
      |> validate_inclusion(:kind, ["claude", "codex"])
      |> validate_number(:max_concurrent_agents, greater_than: 0)
      |> validate_number(:max_turns, greater_than: 0)
      |> validate_number(:max_retry_backoff_ms, greater_than: 0)
      |> validate_number(:max_retry_attempts, greater_than: 0)
      |> validate_number(:turn_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
      |> update_change(:max_concurrent_agents_by_state, &Schema.normalize_state_limits/1)
      |> Schema.validate_state_limits(:max_concurrent_agents_by_state)
    end
  end
```

c. Replace the `Claude` submodule body with:

```elixir
  defmodule Claude do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:command, :string, default: "claude")
      field(:permission_mode, :string, default: "acceptEdits")
      field(:allowed_tools, :string, default: "Bash,Read,Edit")
      field(:output_format, :string, default: "stream-json")
      field(:fallback_model, :string)
      field(:max_turns, :integer)
      field(:max_budget_usd, :decimal)
      field(:bare_mode, :boolean, default: true)
      field(:provider, :string)
      field(:providers, {:array, :string}, default: [])
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :command,
          :permission_mode,
          :allowed_tools,
          :output_format,
          :fallback_model,
          :max_turns,
          :max_budget_usd,
          :bare_mode,
          :provider,
          :providers
        ],
        empty_values: []
      )
      |> validate_required([:command])
      |> validate_number(:max_turns, greater_than: 0)
      |> validate_inclusion(:permission_mode, [
        "default",
        "acceptEdits",
        "plan",
        "auto",
        "dontAsk",
        "bypassPermissions"
      ])
      |> validate_inclusion(:output_format, ["text", "json", "stream-json"])
    end
  end
```

d. Add a new `Codex` submodule right after `Claude`:

```elixir
  defmodule Codex do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:command, :string, default: "codex")
      field(:sandbox, :string, default: "workspace-write")
      field(:network_access, :boolean, default: true)
      field(:provider, :string)
      field(:providers, {:array, :string}, default: [])
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:command, :sandbox, :network_access, :provider, :providers], empty_values: [])
      |> validate_required([:command])
      |> validate_inclusion(:sandbox, ["read-only", "workspace-write", "danger-full-access"])
    end
  end
```

e. In the top-level `embedded_schema`, add after the `:claude` line:

```elixir
    embeds_one(:codex, Codex, on_replace: :update, defaults_to_struct: true)
```

and in the private `changeset/1` add:

```elixir
    |> cast_embed(:codex, with: &Codex.changeset/2)
```

f. Delete `resolve_turn_sandbox_policy/2`, `resolve_runtime_turn_sandbox_policy/3`, and their private helpers `default_turn_sandbox_policy/1`, `default_runtime_turn_sandbox_policy/2` (both clauses), `default_workspace_root/2` (all clauses), `expand_local_workspace_root/1` (both clauses). Remove the now-unused `alias CymphonyElixir.PathSafety`.

g. In `finalize_settings/1`, drop the `claude` normalization (approval/turn policy no longer exist):

```elixir
  defp finalize_settings(settings) do
    tracker = %{
      settings.tracker
      | api_key: resolve_secret_setting(settings.tracker.api_key, System.get_env("LINEAR_API_KEY")),
        assignee: resolve_secret_setting(settings.tracker.assignee, System.get_env("LINEAR_ASSIGNEE"))
    }

    workspace = %{
      settings.workspace
      | root: resolve_path_value(settings.workspace.root, Path.join(System.tmp_dir!(), "cymphony_workspaces"))
    }

    %{settings | tracker: tracker, workspace: workspace}
  end
```

h. In `lib/cymphony_elixir/config.ex`: delete the `@type claude_runtime_settings`, `claude_turn_sandbox_policy/1`, and `claude_runtime_settings/2` (type + both functions; nothing calls them).

- [ ] **Step 4: Update the test workflow generator**

In `test/support/test_support.exs` `workflow_content/1`:

Replace the defaults keyword entries from `claude_command:` through `claude_fallback_model:` with:

```elixir
          agent_kind: "claude",
          agent_model: nil,
          agent_effort: nil,
          turn_timeout_ms: 3_600_000,
          stall_timeout_ms: 300_000,
          claude_command: "claude",
          claude_permission_mode: "acceptEdits",
          claude_allowed_tools: "Bash,Read,Edit",
          claude_output_format: "json",
          claude_max_budget_usd: nil,
          claude_max_turns: nil,
          claude_bare_mode: true,
          claude_fallback_model: nil,
          claude_provider: nil,
          claude_providers: [],
          codex_command: "codex",
          codex_sandbox: "workspace-write",
          codex_network_access: true,
```

(Keep `claude_output_format: "json"` as the test default — existing AppServer tests fake a claude binary that prints one JSON line.)

Replace the corresponding variable bindings and YAML `sections` entries: under `"agent:"` add

```elixir
        "  kind: #{yaml_value(agent_kind)}",
        "  model: #{yaml_value(agent_model)}",
        "  effort: #{yaml_value(agent_effort)}",
        "  turn_timeout_ms: #{yaml_value(turn_timeout_ms)}",
        "  stall_timeout_ms: #{yaml_value(stall_timeout_ms)}",
```

and replace the whole `"claude:"` block with

```elixir
        "claude:",
        "  command: #{yaml_value(claude_command)}",
        "  permission_mode: #{yaml_value(claude_permission_mode)}",
        "  allowed_tools: #{yaml_value(claude_allowed_tools)}",
        "  output_format: #{yaml_value(claude_output_format)}",
        "  max_budget_usd: #{yaml_value(claude_max_budget_usd)}",
        "  max_turns: #{yaml_value(claude_max_turns)}",
        "  bare_mode: #{yaml_value(claude_bare_mode)}",
        "  fallback_model: #{yaml_value(claude_fallback_model)}",
        "  provider: #{yaml_value(claude_provider)}",
        "  providers: #{yaml_value(claude_providers)}",
        "codex:",
        "  command: #{yaml_value(codex_command)}",
        "  sandbox: #{yaml_value(codex_sandbox)}",
        "  network_access: #{yaml_value(codex_network_access)}",
```

Delete the removed bindings (`claude_approval_policy`, `claude_thread_sandbox`, `claude_turn_sandbox_policy`, `claude_turn_timeout_ms`, `claude_read_timeout_ms`, `claude_stall_timeout_ms`, `claude_model`). Grep tests for the removed override keys and update call sites: `claude_model:` → `agent_model:`, `claude_turn_timeout_ms:` → `turn_timeout_ms:`, `claude_stall_timeout_ms:` → `stall_timeout_ms:` (files: `test/cymphony_elixir/core_test.exs`, `live_e2e_test.exs`, `workspace_and_config_test.exs`, `app_server_test.exs`, `extensions_test.exs` — find with `grep -rn "claude_model\|claude_turn_timeout\|claude_stall_timeout\|claude_approval\|claude_thread_sandbox\|claude_turn_sandbox\|claude_read_timeout" test/`).

- [ ] **Step 5: Run the new test + full suite**

Run: `mix test test/cymphony_elixir/config_schema_test.exs`
Expected: PASS.

Run: `mix test`
Expected: failures ONLY in files referencing `config.claude.model` / `config.claude.turn_timeout_ms` / `stall_timeout_ms` readers in lib (AppServer, orchestrator, presenter). Fix the lib readers now:
- `lib/cymphony_elixir/claude/app_server.ex:152` `settings.model` usages: change `maybe_add_flag(settings.model, "--model", settings.model)` to read `agent = if config, do: config.agent, else: Config.settings!().agent` and use `agent.model`; same file line 392 `config.claude.turn_timeout_ms` → `config.agent.turn_timeout_ms`.
- `lib/cymphony_elixir/orchestrator.ex:480` `state_config(state).claude.stall_timeout_ms` → `.agent.stall_timeout_ms`.
- `lib/cymphony_elixir_web/presenter.ex:480` `Config.settings!().claude.stall_timeout_ms` → `.agent.stall_timeout_ms`.

Run: `mix test`
Expected: PASS (0 failures).

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "config: neutral agent section (kind/model/effort/timeouts), slim claude, new codex section"
```

---

### Task 2: Generation layer — Defaults, `to_schema_map`, onboarding

**Files:**
- Modify: `lib/cymphony_elixir/cymphony/defaults.ex`
- Modify: `lib/cymphony_elixir/cymphony/config.ex`
- Modify: `lib/cymphony_elixir/cymphony/onboarding.ex`
- Test: `test/cymphony_elixir/cymphony_config_test.exs`

- [ ] **Step 1: Write failing tests**

Add to `test/cymphony_elixir/cymphony_config_test.exs`:

```elixir
  describe "to_schema_map/1 agent shape" do
    test "maps agent/model/effort project keys and routes providers to the active kind section" do
      config = %{
        "name" => "P",
        "agent" => "codex",
        "model" => "gpt-5.2-codex",
        "effort" => "high",
        "providers" => ["oa1", "oa2"]
      }

      schema_map = CymphonyElixir.Cymphony.Config.to_schema_map(config)

      assert schema_map["agent"]["kind"] == "codex"
      assert schema_map["agent"]["model"] == "gpt-5.2-codex"
      assert schema_map["agent"]["effort"] == "high"
      assert schema_map["codex"]["providers"] == ["oa1", "oa2"]
      assert schema_map["codex"]["provider"] == "oa1"
      refute Map.has_key?(schema_map["claude"], "providers")
      refute Map.has_key?(schema_map["claude"], "approval_policy")
    end

    test "defaults to claude kind and routes providers to claude section" do
      schema_map = CymphonyElixir.Cymphony.Config.to_schema_map(%{"provider" => "cz"})
      assert schema_map["agent"]["kind"] == "claude"
      assert schema_map["claude"]["provider"] == "cz"
      assert schema_map["claude"]["command"] == "claude"
      assert schema_map["codex"]["command"] == "codex"
    end
  end
```

Run: `mix test test/cymphony_elixir/cymphony_config_test.exs`
Expected: FAIL (`agent` map has no `"kind"`).

- [ ] **Step 2: Implement**

`lib/cymphony_elixir/cymphony/defaults.ex`: delete `@claude_command`/`claude_command/0`, `@approval_policy`/`approval_policy/0`, `@thread_sandbox`/`thread_sandbox/0`, `@turn_sandbox_policy`/`turn_sandbox_policy/0`. Add:

```elixir
  @agent_kind "claude"
  @claude_command "claude"
  @codex_command "codex"
  @codex_sandbox "workspace-write"

  @spec agent_kind() :: String.t()
  def agent_kind, do: @agent_kind

  @spec claude_command() :: String.t()
  def claude_command, do: @claude_command

  @spec codex_command() :: String.t()
  def codex_command, do: @codex_command

  @spec codex_sandbox() :: String.t()
  def codex_sandbox, do: @codex_sandbox
```

`lib/cymphony_elixir/cymphony/config.ex`: replace the `"agent"` entry and `claude_schema_map/put_provider_keys` with:

```elixir
      "agent" => %{
        "kind" => agent_kind(config),
        "model" => Map.get(config, "model"),
        "effort" => Map.get(config, "effort"),
        "max_concurrent_agents" => Map.get(config, "max_concurrent_agents", Defaults.max_concurrent_agents()),
        "max_turns" => Defaults.max_turns()
      },
      "claude" => agent_section_map(config, "claude"),
      "codex" => agent_section_map(config, "codex")
```

```elixir
  defp agent_kind(config) do
    case Map.get(config, "agent") do
      kind when kind in ["claude", "codex"] -> kind
      _ -> Defaults.agent_kind()
    end
  end

  defp agent_section_map(config, "claude") do
    %{"command" => Defaults.claude_command(), "output_format" => Defaults.output_format()}
    |> maybe_put_provider_keys(config, "claude")
  end

  defp agent_section_map(config, "codex") do
    %{"command" => Defaults.codex_command(), "sandbox" => Defaults.codex_sandbox()}
    |> maybe_put_provider_keys(config, "codex")
  end

  # Providers are auth aliases for a specific backend: they belong to the
  # active kind's section only.
  defp maybe_put_provider_keys(section, config, kind) do
    if agent_kind(config) == kind do
      providers = Map.get(config, "providers", [])
      provider = Map.get(config, "provider")

      cond do
        is_list(providers) and providers != [] ->
          section |> Map.put("providers", providers) |> Map.put("provider", hd(providers))

        is_binary(provider) and provider != "" ->
          Map.put(section, "provider", provider)

        true ->
          section
      end
    else
      section
    end
  end
```

Drop the schema-map keys `"approval_policy"`, `"thread_sandbox"`, `"turn_sandbox_policy"` (gone from Defaults).

`lib/cymphony_elixir/cymphony/onboarding.ex` `collect_project/2`: replace the `ask_optional("Claude command [claude]: ", "claude")` line with:

```elixir
         {:ok, agent_kind} <- ask_agent_kind(),
```

put `"agent" => agent_kind` into the project map instead of `"claude_command"`, and add:

```elixir
  defp ask_agent_kind do
    case IO.gets("Coding agent (claude/codex) [claude]: ") do
      :eof ->
        {:ok, "claude"}

      {:error, _} ->
        {:ok, "claude"}

      input ->
        case input |> String.trim() |> String.downcase() do
          "" -> {:ok, "claude"}
          kind when kind in ["claude", "codex"] -> {:ok, kind}
          other ->
            IO.puts("  Unknown agent '#{other}'. Choose claude or codex.")
            ask_agent_kind()
        end
    end
  end
```

- [ ] **Step 3: Run tests, fix fallout, commit**

Run: `mix test test/cymphony_elixir/cymphony_config_test.exs && mix test`
Expected: PASS. If `cymphony_config_test.exs` has assertions on the old `"claude"` map shape (grep for `claude_schema_map\|claude_command` in that file), update them to the new shape.

```bash
git add -A && git commit -m "config generation: agent kind/model/effort project keys, per-kind provider routing, onboarding agent question"
```

---

### Task 3: `CymphonyElixir.Agent` behaviour + kind resolver

**Files:**
- Create: `lib/cymphony_elixir/agent.ex`
- Test: `test/cymphony_elixir/agent/agent_test.exs` (new dir `test/cymphony_elixir/agent/`)

- [ ] **Step 1: Write the failing test**

```elixir
defmodule CymphonyElixir.AgentTest do
  use ExUnit.Case, async: true

  alias CymphonyElixir.Agent

  test "module_for resolves known kinds" do
    assert {:ok, CymphonyElixir.Agent.Claude} = Agent.module_for("claude")
    assert {:ok, CymphonyElixir.Agent.Codex} = Agent.module_for("codex")
  end

  test "module_for rejects unknown kinds" do
    assert {:error, {:unknown_agent_kind, "gemini"}} = Agent.module_for("gemini")
    assert {:error, {:unknown_agent_kind, nil}} = Agent.module_for(nil)
  end

  test "known_kinds lists the supported vocabulary" do
    assert Agent.known_kinds() == ["claude", "codex"]
  end
end
```

Run: `mix test test/cymphony_elixir/agent/agent_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 2: Implement the behaviour**

Create `lib/cymphony_elixir/agent.ex`:

```elixir
defmodule CymphonyElixir.Agent do
  @moduledoc """
  Behaviour for coding-agent CLI adapters (Claude Code, Codex).

  An adapter turns a normalized `run_spec` into a shell command and parses the
  process output back into one normalized `turn_result`, so the shared
  `Agent.Runner` stays agnostic of which CLI is running.
  """

  @type run_spec :: %{
          kind: String.t(),
          command: String.t() | nil,
          model: String.t() | nil,
          effort: String.t() | nil,
          provider: String.t() | nil,
          session_id: String.t() | nil,
          prompt: String.t(),
          workspace: Path.t() | nil,
          mcp_descriptor: map() | nil,
          settings: map()
        }

  @type turn_result :: %{
          session_id: String.t() | nil,
          result: String.t() | nil,
          usage: map() | nil,
          raw: String.t()
        }

  @callback default_command() :: String.t()
  @callback build_command(run_spec()) :: {:ok, String.t()} | {:error, term()}
  @callback parse_output([String.t()], run_spec(), (map() -> any())) ::
              {:ok, turn_result()} | {:error, term()}
  @callback auth_env_prefixes() :: [String.t()]
  @callback auth_env_fallback() :: [String.t()]

  @known_kinds ["claude", "codex"]

  @spec known_kinds() :: [String.t()]
  def known_kinds, do: @known_kinds

  @spec module_for(term()) :: {:ok, module()} | {:error, {:unknown_agent_kind, term()}}
  def module_for("claude"), do: {:ok, CymphonyElixir.Agent.Claude}
  def module_for("codex"), do: {:ok, CymphonyElixir.Agent.Codex}
  def module_for(kind), do: {:error, {:unknown_agent_kind, kind}}
end
```

Note: `module_for/1` references adapters that don't exist yet — Elixir compiles this fine (module resolution is runtime), and the adapter modules land in Tasks 4–5. The `agent_test.exs` assertions on module names pass without the modules being loaded.

- [ ] **Step 3: Run test, commit**

Run: `mix test test/cymphony_elixir/agent/agent_test.exs`
Expected: PASS.

```bash
git add -A && git commit -m "agent: behaviour + kind resolver"
```

---

### Task 4: Claude adapter (pure functions first)

**Files:**
- Create: `lib/cymphony_elixir/agent/claude.ex`
- Modify: `lib/cymphony_elixir/mcp/config_writer.ex` (expose descriptor map)
- Test: `test/cymphony_elixir/agent/claude_adapter_test.exs`

The adapter is a pure extraction of `build_claude_command/6` + `parse_json_output/3` + `parse_stream_json_output/3` from `lib/cymphony_elixir/claude/app_server.ex` (lines 148–203, 420–505), re-keyed to `run_spec`. AppServer keeps working untouched until Task 6 swaps it out — the two coexist during Tasks 4–5.

- [ ] **Step 1: Write the failing test**

Create `test/cymphony_elixir/agent/claude_adapter_test.exs`:

```elixir
defmodule CymphonyElixir.Agent.ClaudeAdapterTest do
  use ExUnit.Case, async: true

  alias CymphonyElixir.Agent.Claude

  defp spec(overrides \\ %{}) do
    Map.merge(
      %{
        kind: "claude",
        command: nil,
        model: nil,
        effort: nil,
        provider: nil,
        session_id: nil,
        prompt: "do the thing",
        workspace: "/tmp/ws",
        mcp_descriptor: nil,
        settings: %{
          command: "claude",
          permission_mode: "acceptEdits",
          allowed_tools: "Bash,Read,Edit",
          output_format: "json",
          fallback_model: nil,
          max_turns: nil,
          max_budget_usd: nil,
          bare_mode: true,
          provider: nil,
          providers: []
        }
      },
      overrides
    )
  end

  describe "build_command/1" do
    test "base command carries bare/-p/prompt/output-format/permission-mode/allowedTools" do
      assert {:ok, cmd} = Claude.build_command(spec())
      assert cmd =~ "claude --bare -p 'do the thing'"
      assert cmd =~ "--output-format json"
      assert cmd =~ "--permission-mode acceptEdits"
      assert cmd =~ "--allowedTools Bash,Read,Edit"
      refute cmd =~ "--model"
      refute cmd =~ "--effort"
      refute cmd =~ "--resume"
    end

    test "model and effort come from the run_spec, not settings" do
      assert {:ok, cmd} = Claude.build_command(spec(%{model: "opus", effort: "xhigh"}))
      assert cmd =~ "--model opus"
      assert cmd =~ "--effort xhigh"
    end

    test "stream-json adds --verbose; resume adds --resume" do
      settings = %{spec().settings | output_format: "stream-json"}
      assert {:ok, cmd} = Claude.build_command(spec(%{settings: settings, session_id: "sess-1"}))
      assert cmd =~ "--verbose"
      assert cmd =~ "--resume sess-1"
    end

    test "command override from run_spec wins over settings" do
      assert {:ok, cmd} = Claude.build_command(spec(%{command: "cm"}))
      assert String.starts_with?(cmd, "cm ")
    end

    test "prompt is shell-escaped" do
      assert {:ok, cmd} = Claude.build_command(spec(%{prompt: "it's; rm -rf /"}))
      refute cmd =~ "; rm -rf /'"
      assert cmd =~ "'it'\\''s; rm -rf /'"
    end
  end

  describe "parse_output/3 json" do
    test "reads the last JSON object line" do
      lines = ["noise", ~s({"result":"done","session_id":"s1","usage":{"input_tokens":3,"output_tokens":2}})]

      assert {:ok, %{session_id: "s1", result: "done", usage: %{"input_tokens" => 3}}} =
               Claude.parse_output(lines, spec(), fn _ -> :ok end)
    end

    test "no JSON line is an error" do
      assert {:error, {:no_json_output, _}} = Claude.parse_output(["nope"], spec(), fn _ -> :ok end)
    end
  end

  describe "parse_output/3 stream-json" do
    test "emits stream events and returns the last result event" do
      settings = %{spec().settings | output_format: "stream-json"}
      me = self()

      lines = [
        ~s({"type":"system","subtype":"init"}),
        ~s({"type":"result","result":"ok","session_id":"s2","usage":{"input_tokens":5,"output_tokens":1}})
      ]

      assert {:ok, %{session_id: "s2", result: "ok"}} =
               Claude.parse_output(lines, spec(%{settings: settings}), fn msg -> send(me, {:msg, msg}) end)

      assert_received {:msg, %{event: :stream_event}}
      assert_received {:msg, %{event: :stream_event}}
    end

    test "stream with no result event is an error" do
      settings = %{spec().settings | output_format: "stream-json"}

      assert {:error, {:no_result_in_stream, _}} =
               Claude.parse_output([~s({"type":"system"})], spec(%{settings: settings}), fn _ -> :ok end)
    end
  end

  test "auth env callbacks" do
    assert Claude.default_command() == "claude"
    assert Claude.auth_env_prefixes() == ["ANTHROPIC_", "API_TIMEOUT", "CLAUDE_CODE_"]
    assert Claude.auth_env_fallback() == ["ANTHROPIC_API_KEY"]
  end
end
```

Run: `mix test test/cymphony_elixir/agent/claude_adapter_test.exs`
Expected: FAIL — `CymphonyElixir.Agent.Claude` undefined.

- [ ] **Step 2: Implement the adapter**

Create `lib/cymphony_elixir/agent/claude.ex`:

```elixir
defmodule CymphonyElixir.Agent.Claude do
  @moduledoc """
  Claude Code CLI adapter: builds `claude -p …` commands and parses its
  `json` / `stream-json` output into the normalized turn result.
  """

  @behaviour CymphonyElixir.Agent

  alias CymphonyElixir.Mcp.ConfigWriter

  @impl true
  def default_command, do: "claude"

  @impl true
  def auth_env_prefixes, do: ["ANTHROPIC_", "API_TIMEOUT", "CLAUDE_CODE_"]

  @impl true
  def auth_env_fallback, do: ["ANTHROPIC_API_KEY"]

  @impl true
  def build_command(%{settings: settings} = run_spec) do
    args =
      []
      |> maybe_add_flag(settings.bare_mode, "--bare")
      |> maybe_add_flag(true, "-p")
      |> then(fn args -> args ++ [shell_escape(run_spec.prompt)] end)
      |> maybe_add_flag(settings.output_format, "--output-format", settings.output_format)
      |> maybe_add_flag(settings.output_format == "stream-json", "--verbose")
      |> maybe_add_flag(settings.permission_mode, "--permission-mode", settings.permission_mode)
      |> maybe_add_flag(settings.allowed_tools, "--allowedTools", settings.allowed_tools)
      |> maybe_add_flag(run_spec.model, "--model", run_spec.model)
      |> maybe_add_flag(run_spec.effort, "--effort", run_spec.effort)
      |> maybe_add_flag(settings.fallback_model, "--fallback-model", settings.fallback_model)
      |> maybe_add_flag(settings.max_turns, "--max-turns", settings.max_turns)
      |> maybe_add_flag(settings.max_budget_usd, "--max-budget-usd", settings.max_budget_usd)
      |> maybe_add_mcp_config(run_spec)
      |> maybe_add_resume_flag(run_spec.session_id)

    command =
      case run_spec.command || settings.command do
        cmd when is_binary(cmd) and cmd != "" -> cmd
        _ -> default_command()
      end

    {:ok, Enum.join([command | args], " ")}
  end

  @impl true
  def parse_output(lines, %{settings: settings}, on_message) do
    case settings.output_format do
      "stream-json" -> parse_stream_json_output(lines, on_message)
      _ -> parse_json_output(lines)
    end
  end

  # — argv helpers (moved from Claude.AppServer) —

  defp maybe_add_flag(args, nil, _flag), do: args
  defp maybe_add_flag(args, false, _flag), do: args
  defp maybe_add_flag(args, true, flag), do: args ++ [flag]
  defp maybe_add_flag(args, value, flag, value) when is_binary(value), do: args ++ [flag, shell_escape(value)]
  defp maybe_add_flag(args, value, flag, value) when is_integer(value), do: args ++ [flag, to_string(value)]
  defp maybe_add_flag(args, value, flag, _display) when is_binary(value) and value != "", do: args ++ [flag, shell_escape(value)]
  defp maybe_add_flag(args, %Decimal{} = value, flag, _display), do: args ++ [flag, to_string(Decimal.to_string(value))]
  defp maybe_add_flag(args, _value, _flag, _display), do: args

  defp maybe_add_resume_flag(args, nil), do: args
  defp maybe_add_resume_flag(args, ""), do: args
  defp maybe_add_resume_flag(args, session_id) when is_binary(session_id), do: args ++ ["--resume", shell_escape(session_id)]

  # Claude receives MCP servers as a JSON descriptor file (written 0600 inside
  # the workspace so the API key never appears in argv).
  defp maybe_add_mcp_config(args, %{mcp_descriptor: %{} = descriptor, workspace: workspace})
       when is_binary(workspace) do
    case ConfigWriter.write(workspace, descriptor) do
      {:ok, path} -> args ++ ["--mcp-config", shell_escape(path)]
      {:error, _reason} -> args
    end
  end

  defp maybe_add_mcp_config(args, _run_spec), do: args

  # — output parsing (moved from Claude.AppServer) —

  defp parse_json_output(lines) do
    case find_last_json_line(lines) do
      nil ->
        {:error, {:no_json_output, Enum.join(lines, "\n")}}

      line ->
        case Jason.decode(line) do
          {:ok, %{} = payload} ->
            {:ok,
             %{
               session_id: payload["session_id"],
               result: payload["result"],
               usage: payload["usage"],
               raw: line
             }}

          {:error, decode_error} ->
            {:error, {:json_decode_failed, decode_error, line}}
        end
    end
  end

  defp parse_stream_json_output(lines, on_message) do
    result =
      Enum.reduce(lines, %{last_result: nil}, fn line, acc ->
        case Jason.decode(line) do
          {:ok, %{} = event} ->
            emit(on_message, %{event: :stream_event, payload: event, raw: line})

            if event["type"] == "result", do: %{acc | last_result: event}, else: acc

          {:error, _} ->
            acc
        end
      end)

    case result.last_result do
      nil ->
        {:error, {:no_result_in_stream, Enum.join(lines, "\n")}}

      last_result ->
        {:ok,
         %{
           session_id: last_result["session_id"],
           result: last_result["result"],
           usage: last_result["usage"],
           raw: Jason.encode!(last_result)
         }}
    end
  end

  defp find_last_json_line(lines) when is_list(lines) do
    lines |> Enum.reverse() |> Enum.find(&json_line?/1)
  end

  defp json_line?(line) when is_binary(line) do
    trimmed = String.trim(line)
    String.starts_with?(trimmed, "{") and String.ends_with?(trimmed, "}")
  end

  defp json_line?(_), do: false

  defp emit(on_message, details) when is_function(on_message, 1) do
    on_message.(Map.put(details, :timestamp, DateTime.utc_now()))
  end

  defp shell_escape(value) when is_binary(value), do: CymphonyElixir.Shell.escape(value)
end
```

In `lib/cymphony_elixir/mcp/config_writer.ex`, add a descriptor builder so callers stop constructing tracker maps ad hoc (used by Runner in Task 6 and Codex in Task 5):

```elixir
  @doc """
  Build the tracker MCP descriptor data from a parsed config, or `nil` when the
  tracker has no usable Linear credentials.
  """
  @spec descriptor_from_config(term()) :: tracker_config() | nil
  def descriptor_from_config(%{tracker: %{kind: "linear", api_key: key} = tracker})
      when is_binary(key) and key != "" do
    %{api_key: key, endpoint: Map.get(tracker, :endpoint)}
  end

  def descriptor_from_config(_config), do: nil
```

- [ ] **Step 3: Run tests, commit**

Run: `mix test test/cymphony_elixir/agent/claude_adapter_test.exs && mix test test/cymphony_elixir/mcp`
Expected: PASS.

```bash
git add -A && git commit -m "agent: Claude adapter (argv build + json/stream-json parsing)"
```

---

### Task 5: Codex adapter

**Files:**
- Create: `lib/cymphony_elixir/agent/codex.ex`
- Test: `test/cymphony_elixir/agent/codex_adapter_test.exs`

CLI facts (verified live against codex-cli 0.144.5):
- First turn: `codex exec --json --skip-git-repo-check … <prompt>`; resume: `codex exec resume <session_id> --json --skip-git-repo-check … <prompt>`.
- Sandbox MUST go via `-c sandbox_mode="<value>"` (the `-s` alias is not accepted by `exec resume`).
- Output JSONL: `{"type":"thread.started","thread_id":"…"}`, `{"type":"turn.started"}`, `{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"…"}}`, `{"type":"turn.completed","usage":{"input_tokens":N,"cached_input_tokens":N,"output_tokens":N,"reasoning_output_tokens":N}}`. Failure event: `{"type":"turn.failed","error":{…}}`.

- [ ] **Step 1: Write the failing test**

Create `test/cymphony_elixir/agent/codex_adapter_test.exs`:

```elixir
defmodule CymphonyElixir.Agent.CodexAdapterTest do
  use ExUnit.Case, async: true

  alias CymphonyElixir.Agent.Codex

  defp spec(overrides \\ %{}) do
    Map.merge(
      %{
        kind: "codex",
        command: nil,
        model: nil,
        effort: nil,
        provider: nil,
        session_id: nil,
        prompt: "do the thing",
        workspace: "/tmp/ws",
        mcp_descriptor: nil,
        settings: %{
          command: "codex",
          sandbox: "workspace-write",
          network_access: true,
          provider: nil,
          providers: []
        }
      },
      overrides
    )
  end

  describe "build_command/1" do
    test "first turn uses exec --json with sandbox_mode and network access" do
      assert {:ok, cmd} = Codex.build_command(spec())
      assert cmd =~ "codex exec --json --skip-git-repo-check"
      assert cmd =~ ~s(-c 'sandbox_mode="workspace-write"')
      assert cmd =~ ~s(-c 'sandbox_workspace_write.network_access=true')
      assert String.ends_with?(cmd, "'do the thing'")
      refute cmd =~ " resume "
    end

    test "model and effort map to -m and -c model_reasoning_effort" do
      assert {:ok, cmd} = Codex.build_command(spec(%{model: "gpt-5.2-codex", effort: "high"}))
      assert cmd =~ "-m gpt-5.2-codex"
      assert cmd =~ ~s(-c 'model_reasoning_effort="high"')
    end

    test "resume inserts the subcommand with session id before flags" do
      assert {:ok, cmd} = Codex.build_command(spec(%{session_id: "0199-abc"}))
      assert cmd =~ "codex exec resume 0199-abc --json --skip-git-repo-check"
    end

    test "read-only sandbox omits network access override" do
      settings = %{spec().settings | sandbox: "read-only"}
      assert {:ok, cmd} = Codex.build_command(spec(%{settings: settings}))
      assert cmd =~ ~s(-c 'sandbox_mode="read-only"')
      refute cmd =~ "network_access"
    end

    test "mcp descriptor renders -c overrides with env_vars whitelist, never the key itself" do
      descriptor = %{api_key: "lin_api_SECRET", endpoint: "https://api.linear.app/graphql"}
      assert {:ok, cmd} = Codex.build_command(spec(%{mcp_descriptor: descriptor}))
      assert cmd =~ "mcp_servers.cymphony-linear.command"
      assert cmd =~ ~s(env_vars=["LINEAR_API_KEY"])
      assert cmd =~ "LINEAR_ENDPOINT"
      refute cmd =~ "lin_api_SECRET"
    end

    test "prompt is shell-escaped" do
      assert {:ok, cmd} = Codex.build_command(spec(%{prompt: "it's; rm -rf /"}))
      assert cmd =~ "'it'\\''s; rm -rf /'"
    end
  end

  describe "parse_output/3" do
    test "collects thread id, last agent message, and turn.completed usage" do
      me = self()

      lines = [
        ~s({"type":"thread.started","thread_id":"t-1"}),
        ~s({"type":"turn.started"}),
        ~s({"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"pong"}}),
        ~s({"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":4,"output_tokens":5,"reasoning_output_tokens":0}})
      ]

      assert {:ok, result} = Codex.parse_output(lines, spec(), fn msg -> send(me, {:msg, msg}) end)
      assert result.session_id == "t-1"
      assert result.result == "pong"
      assert result.usage == %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15}

      assert_received {:msg, %{event: :stream_event, payload: %{"type" => "thread.started"}}}
    end

    test "turn.failed is an error carrying the failure payload" do
      lines = [
        ~s({"type":"thread.started","thread_id":"t-2"}),
        ~s({"type":"turn.failed","error":{"message":"boom"}})
      ]

      assert {:error, {:turn_failed, %{"message" => "boom"}}} =
               Codex.parse_output(lines, spec(), fn _ -> :ok end)
    end

    test "missing turn.completed is an error" do
      lines = [~s({"type":"thread.started","thread_id":"t-3"})]
      assert {:error, {:no_result_in_stream, _}} = Codex.parse_output(lines, spec(), fn _ -> :ok end)
    end
  end

  test "auth env callbacks" do
    assert Codex.default_command() == "codex"
    assert Codex.auth_env_prefixes() == ["OPENAI_", "CODEX_", "API_TIMEOUT"]
    assert Codex.auth_env_fallback() == ["OPENAI_API_KEY"]
  end
end
```

Run: `mix test test/cymphony_elixir/agent/codex_adapter_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 2: Implement**

Create `lib/cymphony_elixir/agent/codex.ex`:

```elixir
defmodule CymphonyElixir.Agent.Codex do
  @moduledoc """
  Codex CLI adapter: builds `codex exec --json` (or `codex exec resume <id>`)
  commands and parses the JSONL event stream into the normalized turn result.

  Sandbox is always passed as `-c sandbox_mode=…` because `codex exec resume`
  does not accept the `-s` shorthand.
  """

  @behaviour CymphonyElixir.Agent

  @mcp_server_name "cymphony-linear"

  @impl true
  def default_command, do: "codex"

  @impl true
  def auth_env_prefixes, do: ["OPENAI_", "CODEX_", "API_TIMEOUT"]

  @impl true
  def auth_env_fallback, do: ["OPENAI_API_KEY"]

  @impl true
  def build_command(%{settings: settings} = run_spec) do
    command =
      case run_spec.command || settings.command do
        cmd when is_binary(cmd) and cmd != "" -> cmd
        _ -> default_command()
      end

    subcommand =
      case run_spec.session_id do
        session_id when is_binary(session_id) and session_id != "" ->
          ["exec", "resume", shell_escape(session_id)]

        _ ->
          ["exec"]
      end

    args =
      ["--json", "--skip-git-repo-check"]
      |> maybe_add_model(run_spec.model)
      |> add_config_override("sandbox_mode", toml_string(settings.sandbox))
      |> maybe_add_network_access(settings)
      |> maybe_add_effort(run_spec.effort)
      |> maybe_add_mcp_overrides(run_spec.mcp_descriptor)

    {:ok, Enum.join([command | subcommand] ++ args ++ [shell_escape(run_spec.prompt)], " ")}
  end

  @impl true
  def parse_output(lines, _run_spec, on_message) do
    initial = %{session_id: nil, last_message: nil, completed: nil, failed: nil}

    state =
      Enum.reduce(lines, initial, fn line, acc ->
        case Jason.decode(line) do
          {:ok, %{} = event} ->
            emit(on_message, %{event: :stream_event, payload: event, raw: line})
            integrate_event(acc, event)

          {:error, _} ->
            acc
        end
      end)

    cond do
      is_map(state.failed) ->
        {:error, {:turn_failed, state.failed}}

      is_map(state.completed) ->
        {:ok,
         %{
           session_id: state.session_id,
           result: state.last_message,
           usage: normalize_usage(state.completed["usage"]),
           raw: Jason.encode!(state.completed)
         }}

      true ->
        {:error, {:no_result_in_stream, Enum.join(lines, "\n")}}
    end
  end

  defp integrate_event(acc, %{"type" => "thread.started"} = event),
    do: %{acc | session_id: event["thread_id"] || acc.session_id}

  defp integrate_event(acc, %{"type" => "item.completed", "item" => %{"type" => "agent_message", "text" => text}})
       when is_binary(text),
       do: %{acc | last_message: text}

  defp integrate_event(acc, %{"type" => "turn.completed"} = event), do: %{acc | completed: event}
  defp integrate_event(acc, %{"type" => "turn.failed"} = event), do: %{acc | failed: event["error"] || event}
  defp integrate_event(acc, _event), do: acc

  defp normalize_usage(%{} = usage) do
    input = integer_or_zero(usage["input_tokens"])
    output = integer_or_zero(usage["output_tokens"])

    %{"input_tokens" => input, "output_tokens" => output, "total_tokens" => input + output}
  end

  defp normalize_usage(_usage), do: nil

  defp integer_or_zero(value) when is_integer(value) and value >= 0, do: value
  defp integer_or_zero(_value), do: 0

  defp maybe_add_model(args, model) when is_binary(model) and model != "",
    do: args ++ ["-m", shell_escape(model)]

  defp maybe_add_model(args, _model), do: args

  defp maybe_add_effort(args, effort) when is_binary(effort) and effort != "",
    do: add_config_override(args, "model_reasoning_effort", toml_string(effort))

  defp maybe_add_effort(args, _effort), do: args

  defp maybe_add_network_access(args, %{sandbox: "workspace-write", network_access: true}),
    do: add_config_override(args, "sandbox_workspace_write.network_access", "true")

  defp maybe_add_network_access(args, _settings), do: args

  # Codex takes MCP servers as -c config overrides. The API key is NEVER put
  # on the command line: `env_vars=["LINEAR_API_KEY"]` whitelists it to inherit
  # from the codex process environment, which the Runner populates.
  defp maybe_add_mcp_overrides(args, %{api_key: key} = descriptor)
       when is_binary(key) and key != "" do
    endpoint = Map.get(descriptor, :endpoint) || "https://api.linear.app/graphql"
    prefix = "mcp_servers.#{@mcp_server_name}"

    args
    |> add_config_override("#{prefix}.command", toml_string("elixir"))
    |> add_config_override("#{prefix}.args", ~s(["-S", "mix", "cymphony.mcp.linear_graphql"]))
    |> add_config_override("#{prefix}.env", ~s({LINEAR_ENDPOINT = "#{endpoint}"})
    )
    |> add_config_override("#{prefix}.env_vars", ~s(["LINEAR_API_KEY"]))
  end

  defp maybe_add_mcp_overrides(args, _descriptor), do: args

  defp add_config_override(args, key, toml_value),
    do: args ++ ["-c", shell_escape("#{key}=#{toml_value}")]

  defp toml_string(value), do: ~s("#{value}")

  defp emit(on_message, details) when is_function(on_message, 1) do
    on_message.(Map.put(details, :timestamp, DateTime.utc_now()))
  end

  defp shell_escape(value) when is_binary(value), do: CymphonyElixir.Shell.escape(value)
end
```

- [ ] **Step 3: Run tests**

Run: `mix test test/cymphony_elixir/agent/codex_adapter_test.exs`
Expected: PASS. (If the `env` TOML inline-table assertion fails on quoting, adjust the test to match the exact escaped form the implementation produces — the invariants that MUST hold are: `env_vars=["LINEAR_API_KEY"]` present, raw key absent.)

- [ ] **Step 4: One-shot smoke against the real binary (manual, not CI)**

Run: `cd /tmp && mkdir -p codex_smoke && cd codex_smoke && codex exec --json --skip-git-repo-check -c 'sandbox_mode="read-only"' "Reply with exactly: pong" | tail -2`
Expected: an `item.completed` agent_message line and a `turn.completed` usage line (shape matching the fixtures above).

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "agent: Codex adapter (exec --json argv + JSONL parsing, secrets via env_vars whitelist)"
```

---

### Task 6: ShellProvider prefix parameterization

**Files:**
- Modify: `lib/cymphony_elixir/cymphony/shell_provider.ex`
- Test: `test/cymphony_elixir/shell_provider_prefix_test.exs` (new)

Small and independent — do it before the Runner so the Runner can pass prefixes.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule CymphonyElixir.ShellProviderPrefixTest do
  use ExUnit.Case, async: true

  alias CymphonyElixir.Cymphony.ShellProvider

  test "filter_env_lines keeps only lines matching the given prefixes" do
    lines = """
    ANTHROPIC_API_KEY=a
    OPENAI_API_KEY=o
    CODEX_HOME=/x
    PATH=/usr/bin
    API_TIMEOUT=30
    """

    claude = ShellProvider.parse_env_output(lines, ["ANTHROPIC_", "API_TIMEOUT", "CLAUDE_CODE_"])
    assert claude == %{"ANTHROPIC_API_KEY" => "a", "API_TIMEOUT" => "30"}

    codex = ShellProvider.parse_env_output(lines, ["OPENAI_", "CODEX_", "API_TIMEOUT"])
    assert codex == %{"OPENAI_API_KEY" => "o", "CODEX_HOME" => "/x", "API_TIMEOUT" => "30"}
  end
end
```

Run: `mix test test/cymphony_elixir/shell_provider_prefix_test.exs`
Expected: FAIL — `parse_env_output/2` undefined (today it's a private 1-arity).

- [ ] **Step 2: Implement**

In `lib/cymphony_elixir/cymphony/shell_provider.ex`:
- Change `@env_prefix ~w(ANTHROPIC_ API_TIMEOUT CLAUDE_CODE_)` to `@default_env_prefixes ~w(ANTHROPIC_ API_TIMEOUT CLAUDE_CODE_)`.
- Change `load_env/1` to `load_env/2`:

```elixir
  @spec load_env(String.t(), [String.t()]) :: {:ok, map()} | {:error, :not_found}
  def load_env(provider_name, prefixes \\ @default_env_prefixes) when is_binary(provider_name) do
    case cached({provider_name, prefixes}) do
      {:ok, _} = result -> result
      :miss -> fetch_and_cache(provider_name, prefixes)
    end
  end
```

- Thread `prefixes` through `fetch_and_cache/2` (cache key `{provider_name, prefixes}`) and make the parser public:

```elixir
  @doc false
  @spec parse_env_output(String.t(), [String.t()]) :: map()
  def parse_env_output(output, prefixes) do
    output
    |> String.split("\n", trim: true)
    |> Enum.filter(fn line ->
      String.contains?(line, "=") and Enum.any?(prefixes, &String.starts_with?(line, &1))
    end)
    |> Enum.into(%{}, fn line ->
      [k | rest] = String.split(line, "=", parts: 2)
      {k, Enum.join(rest, "=")}
    end)
  end
```

Delete the old private `parse_env_output/1` and `env_var?/1`. Keep the zsh script that stubs `claude()` — also stub `codex()` the same way (add `codex() { :; }` next to `claude() { :; }` in both scripts) so a provider function that *invokes* codex doesn't actually launch it during env capture.

- [ ] **Step 3: Run tests, commit**

Run: `mix test test/cymphony_elixir/shell_provider_prefix_test.exs && mix test`
Expected: PASS (existing `load_env/1` call sites still compile via the default arg).

```bash
git add -A && git commit -m "shell provider: parameterize env-var prefixes per agent kind, stub codex during capture"
```

---

### Task 7: `Agent.Runner` — shared core replaces `Claude.AppServer`

**Files:**
- Create: `lib/cymphony_elixir/agent/runner.ex`
- Modify: `lib/cymphony_elixir/agent_runner.ex`
- Delete: `lib/cymphony_elixir/claude/app_server.ex`, `lib/cymphony_elixir/claude/dynamic_tool.ex`, `test/cymphony_elixir/dynamic_tool_test.exs`
- Rename: `test/cymphony_elixir/app_server_test.exs` → `test/cymphony_elixir/agent/runner_test.exs`; `test/cymphony_elixir/app_server_mcp_test.exs` → `test/cymphony_elixir/agent/runner_mcp_test.exs`
- Modify: `mix.exs` (coverage ignore list)

This is a structured move. `Agent.Runner` keeps AppServer's public API shape (`run/4`, `start_session/2`, `run_turn/4`, `stop_session/1`) and its port/env/timeout/workspace machinery **verbatim**; everything argv/parse-specific is delegated to the adapter resolved from the run_spec.

- [ ] **Step 1: Create `lib/cymphony_elixir/agent/runner.ex`**

Start from a copy of `lib/cymphony_elixir/claude/app_server.ex` and apply exactly these changes:

a. Header:

```elixir
defmodule CymphonyElixir.Agent.Runner do
  @moduledoc """
  Shared coding-agent session runner.

  Owns everything that is identical across agent CLIs — workspace validation,
  port spawn (local shell with rc-file sourcing, or SSH remote), env-var
  injection, output collection with turn timeout, lifecycle events — and
  delegates command construction and output parsing to the
  `CymphonyElixir.Agent` adapter for the session's agent kind.
  """

  require Logger
  alias CymphonyElixir.{Agent, Config, Mcp.ConfigWriter, PathSafety, SSH}
  alias CymphonyElixir.Cymphony.ShellProvider

  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000
  @shell_env_name_pattern ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @type session :: %{
          port: port() | nil,
          metadata: map(),
          session_id: String.t() | nil,
          workspace: Path.t(),
          worker_host: String.t() | nil,
          config: term(),
          run_spec: Agent.run_spec(),
          agent_module: module()
        }
```

b. `start_session/2` gains run-spec resolution. Replace the existing body with:

```elixir
  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    config = Keyword.get(opts, :config)

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host, config),
         {:ok, run_spec} <- build_run_spec(expanded_workspace, config, opts),
         {:ok, agent_module} <- Agent.module_for(run_spec.kind) do
      {:ok,
       %{
         port: nil,
         metadata: %{},
         session_id: nil,
         workspace: expanded_workspace,
         worker_host: worker_host,
         config: config,
         run_spec: run_spec,
         agent_module: agent_module
       }}
    end
  end

  # The run_spec snapshots everything the adapter needs. Per-issue overrides
  # (Spec B) arrive via opts and win over config.
  defp build_run_spec(workspace, config, opts) do
    settings = config || Config.settings!()
    kind = Keyword.get(opts, :agent_kind) || settings.agent.kind
    section = agent_section(settings, kind)

    {:ok,
     %{
       kind: kind,
       command: nil,
       model: Keyword.get(opts, :model) || settings.agent.model,
       effort: Keyword.get(opts, :effort) || settings.agent.effort,
       provider: Keyword.get(opts, :provider_override) || section.provider,
       session_id: nil,
       prompt: "",
       workspace: workspace,
       mcp_descriptor: mcp_descriptor(settings, Keyword.get(opts, :worker_host)),
       settings: Map.from_struct(section)
     }}
  end

  defp agent_section(settings, "codex"), do: settings.codex
  defp agent_section(settings, _kind), do: settings.claude

  # MCP injection is local-only today (remote workspaces can't read a local
  # descriptor file) — preserve that behavior for both agents.
  defp mcp_descriptor(_settings, worker_host) when is_binary(worker_host), do: nil
  defp mcp_descriptor(settings, _worker_host), do: ConfigWriter.descriptor_from_config(settings)
```

c. `run_turn/4`: replace `spawn_claude_turn/6` usage. New body of the success path (everything else — emit_message calls, logging, error tuple shape — stays exactly as in AppServer lines 55–133, with log strings "Claude session …" → "Agent session …"):

```elixir
  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ []) do
    %{
      workspace: workspace,
      worker_host: worker_host,
      session_id: session_id,
      config: session_config,
      run_spec: run_spec,
      agent_module: agent_module
    } = session

    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    config = Keyword.get(opts, :config, session_config)
    run_spec = %{run_spec | prompt: prompt, session_id: session_id}

    with {:ok, command} <- agent_module.build_command(run_spec),
         {:ok, port} <- start_port_for_command(command, workspace, worker_host, run_spec, config) do
      metadata = port_metadata(port, worker_host)
      display_session_id = "#{session_id || "new"}"

      emit_message(
        on_message,
        :session_started,
        %{session_id: display_session_id, thread_id: display_session_id, turn_id: 1},
        metadata
      )

      case await_process_completion(port, on_message, metadata, run_spec, config) do
        {:ok, result} ->
          new_session_id = result[:session_id] || session_id

          Logger.info("Agent session completed for #{issue_context(issue)} session_id=#{new_session_id}")

          emit_message(
            on_message,
            :turn_completed,
            %{
              session_id: new_session_id,
              result: result[:result],
              usage: result[:usage],
              raw: result[:raw]
            },
            metadata
          )

          {:ok,
           %{
             result: result,
             session_id: new_session_id,
             thread_id: new_session_id,
             turn_id: 1
           }}

        {:error, reason} ->
          Logger.warning("Agent session ended with error for #{issue_context(issue)} session_id=#{display_session_id}: #{inspect(reason)}")

          emit_message(
            on_message,
            :turn_ended_with_error,
            %{session_id: display_session_id, reason: reason},
            metadata
          )

          {:error, reason}
      end
    else
      {:error, reason} ->
        Logger.error("Agent session failed for #{issue_context(issue)}: #{inspect(reason)}")
        emit_message(on_message, :startup_failed, %{reason: reason}, %{})
        {:error, reason}
    end
  end
```

with `await_process_completion/5` now delegating the parse:

```elixir
  defp await_process_completion(port, on_message, metadata, run_spec, config) do
    agent_module = run_spec_module!(run_spec)

    case collect_output(port, config) do
      {:ok, lines} -> agent_module.parse_output(lines, run_spec, wrap_on_message(on_message, metadata))
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_spec_module!(%{kind: kind}) do
    {:ok, module} = Agent.module_for(kind)
    module
  end

  # Adapters emit bare %{event:, payload:, raw:, timestamp:} maps; decorate
  # them with port metadata exactly like AppServer's emit_message did.
  defp wrap_on_message(on_message, metadata) do
    fn details -> on_message.(Map.merge(metadata, details)) end
  end
```

d. Env layer: rename `claude_env/1` → `agent_env/2`, `claude_process_env/2` → `agent_process_env/3`, `claude_auth_env/1` → `agent_auth_env/2`, threading the adapter module. Replace `provider_env/1` + fallback with:

```elixir
  defp agent_auth_env(run_spec, agent_module) do
    case provider_env(run_spec.provider, agent_module) do
      provider_env when map_size(provider_env) > 0 -> provider_env
      _ -> inherited_env(agent_module.auth_env_fallback())
    end
  end

  defp provider_env(provider_name, agent_module)
       when is_binary(provider_name) and provider_name != "" do
    case ShellProvider.load_env(provider_name, agent_module.auth_env_prefixes()) do
      {:ok, env_map} when is_map(env_map) -> normalize_env_map(env_map)
      {:error, :not_found} -> %{}
    end
  end

  defp provider_env(_provider, _agent_module), do: %{}
```

`start_port_for_command/5` passes `env: agent_env(run_spec, config)` locally and `remote_env_exports(run_spec, config)` over SSH — both build on `agent_process_env` which keeps `integration_auth_env` (LINEAR_API_KEY, GH_TOKEN/GITHUB_TOKEN) and base PATH/HOME exactly as today.

e. `port_metadata/2`: key `claude_app_server_pid` → `agent_os_pid`.

f. `local_launch_script/1`: unchanged except the comment ("claude" → "agent"); the rc-sourcing behavior applies to both CLIs.

g. Move verbatim, renaming only log prefixes ("Claude output:" → "Agent output:"): `collect_output/2..4` (timeout now `config.agent.turn_timeout_ms`), `validate_workspace_cwd/3`, `stop_port/1`, `stop_session/1`, `pick_local_shell/0`, `remote_launch_command/3`, `emit_message/4`, `log_stream_line/1`, `issue_context/1`, `default_on_message/1`, `shell_escape/1`, `inherited_env/1`, `normalize_env_map/1`, `maybe_put_env/3`, `valid_env_map/1`, `run/4`. Delete `build_claude_command/6`, `maybe_add_*`, `parse_*`, `find_last_json_line/1`, `json_line?/1`, `log_non_json_stream_line/2` (all now adapter-owned).

- [ ] **Step 2: Rewire `AgentRunner`**

In `lib/cymphony_elixir/agent_runner.ex`:
- `alias CymphonyElixir.Claude.AppServer` → `alias CymphonyElixir.Agent.Runner`.
- All `AppServer.` calls → `Runner.` (same arities; `start_session` opts now additionally pass `Keyword.take(opts, [:agent_kind, :model, :effort, :provider_override])` through — they already ride in `opts`).
- Delete the provider-override config mutation block (lines 35–40, `%{config | claude: %{config.claude | provider: provider_override}}`) — the Runner reads `provider_override` from opts directly now.
- Rename `run_claude_turns` → `run_agent_turns`, `do_run_claude_turns` → `do_run_agent_turns`, `claude_message_handler` → `agent_message_handler`, `send_claude_update` → `send_agent_update`, and the message tag `{:claude_worker_update, …}` → `{:agent_worker_update, …}` (orchestrator side updates in Task 8 — do both in one commit? NO: to keep the suite green this task ALSO updates the receive side: in `lib/cymphony_elixir/orchestrator.ex` change the two `handle_info({:claude_worker_update, …})` heads to `{:agent_worker_update, …}` and the test senders in `test/cymphony_elixir/orchestrator_status_test.exs`, `core_test.exs`, `live_e2e_test.exs`. Internal key renames inside orchestrator wait for Task 8.)
- Moduledoc: "Executes a single Linear issue in its workspace with the configured coding agent."
- Continuation prompt text (line 168): "The previous Claude turn completed normally" → "The previous agent turn completed normally".

- [ ] **Step 3: Delete dead modules, re-point tests, coverage list**

```bash
git rm lib/cymphony_elixir/claude/app_server.ex lib/cymphony_elixir/claude/dynamic_tool.ex test/cymphony_elixir/dynamic_tool_test.exs
git mv test/cymphony_elixir/app_server_test.exs test/cymphony_elixir/agent/runner_test.exs
git mv test/cymphony_elixir/app_server_mcp_test.exs test/cymphony_elixir/agent/runner_mcp_test.exs
```

In the moved tests: `defmodule CymphonyElixir.AppServerTest` → `CymphonyElixir.Agent.RunnerTest` (and MCP one accordingly); `AppServer.` → `Runner.` (add `alias CymphonyElixir.Agent.Runner`); workflow overrides `claude_model:` → `agent_model:` where used. The fake-binary fixtures (`fake-claude` printing a JSON line) still work because default test `output_format` stays `"json"`.

In `mix.exs` `ignore_modules`: replace `CymphonyElixir.Claude.AppServer` with `CymphonyElixir.Agent.Runner`, delete `CymphonyElixir.Claude.DynamicTool`.

- [ ] **Step 4: Full suite**

Run: `mix test`
Expected: PASS. Common fallout to fix here: any remaining `AppServer` references (grep `grep -rn "AppServer\|DynamicTool" lib test`), the orchestrator's `:claude_worker_update` senders in tests.

Run: `make fmt && make lint`
Expected: PASS (specs.check requires `@spec` on all new public functions — Runner's public API keeps AppServer's specs).

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "agent: shared Runner replaces Claude.AppServer; AgentRunner emits :agent_worker_update"
```

---

### Task 8: Orchestrator neutral renames + per-kind providers

**Files:**
- Modify: `lib/cymphony_elixir/orchestrator.ex`, `lib/cymphony_elixir/orchestrator/stall.ex`, `lib/cymphony_elixir/orchestrator/tokens.ex`
- Modify: `test/cymphony_elixir/orchestrator_status_test.exs`, `test/cymphony_elixir/orchestrator/stall_test.exs`, `test/cymphony_elixir/orchestrator/tokens_test.exs`, `test/cymphony_elixir/blocker_dispatch_test.exs`, `test/cymphony_elixir/core_test.exs`, `test/cymphony_elixir/extensions_test.exs`, `test/cymphony_elixir/workspace_and_config_test.exs`

- [ ] **Step 1: Mechanical rename sweep (sed-assisted, then review)**

Apply the cheat-sheet table (top of this plan) across the three lib files and the listed tests:

```bash
for f in lib/cymphony_elixir/orchestrator.ex lib/cymphony_elixir/orchestrator/stall.ex lib/cymphony_elixir/orchestrator/tokens.ex \
         test/cymphony_elixir/orchestrator_status_test.exs test/cymphony_elixir/orchestrator/stall_test.exs \
         test/cymphony_elixir/orchestrator/tokens_test.exs test/cymphony_elixir/blocker_dispatch_test.exs \
         test/cymphony_elixir/core_test.exs test/cymphony_elixir/extensions_test.exs test/cymphony_elixir/workspace_and_config_test.exs; do
  sed -i '' \
    -e 's/claude_last_reported_input_tokens/last_reported_input_tokens/g' \
    -e 's/claude_last_reported_output_tokens/last_reported_output_tokens/g' \
    -e 's/claude_last_reported_total_tokens/last_reported_total_tokens/g' \
    -e 's/claude_input_tokens/input_tokens/g' \
    -e 's/claude_output_tokens/output_tokens/g' \
    -e 's/claude_total_tokens/total_tokens/g' \
    -e 's/claude_totals/token_totals/g' \
    -e 's/claude_rate_limits/rate_limits/g' \
    -e 's/last_claude_message/last_agent_message/g' \
    -e 's/last_claude_timestamp/last_agent_timestamp/g' \
    -e 's/last_claude_event/last_agent_event/g' \
    -e 's/claude_app_server_pid/agent_os_pid/g' \
    -e 's/integrate_claude_update/integrate_agent_update/g' \
    -e 's/apply_claude_token_delta/apply_agent_token_delta/g' \
    -e 's/apply_claude_rate_limits/apply_agent_rate_limits/g' \
    -e 's/summarize_claude_update/summarize_agent_update/g' \
    -e 's/@empty_claude_totals/@empty_token_totals/g' \
    "$f"
done
```

Then hand-review the orchestrator diff for collisions: the running-entry map now has `input_tokens` (entry key) while `Tokens.extract_token_delta` returns a map that ALSO has `input_tokens` — that was already true; the delta struct keys were never `claude_`-prefixed, so no clash. In `orchestrator.ex` snapshot function (line ~1394), `claude_command: state.config.claude.command` becomes:

```elixir
       agent_kind: state.config.agent.kind,
       agent_command: agent_command(state.config),
```

with:

```elixir
  defp agent_command(%{agent: %{kind: "codex"}, codex: %{command: command}}), do: command
  defp agent_command(%{claude: %{command: command}}), do: command
  defp agent_command(_config), do: nil
```

- [ ] **Step 2: Per-kind provider extraction**

Replace `extract_providers/1` and `select_provider/1` (orchestrator.ex lines 1266–1279):

```elixir
  defp extract_providers(%{agent: %{kind: kind}} = config) do
    section = agent_provider_section(config, kind)

    case section do
      %{providers: [_ | _] = providers} -> providers
      %{provider: provider} when is_binary(provider) and provider != "" -> [provider]
      _ -> []
    end
  end

  defp extract_providers(_config), do: []

  defp agent_provider_section(config, "codex"), do: config.codex
  defp agent_provider_section(config, _kind), do: config.claude

  defp select_provider(%State{providers: [_ | _] = providers}) do
    Enum.random(providers)
  end

  defp select_provider(%State{config: config}) when is_map(config) do
    case extract_providers(config) do
      [provider | _] -> provider
      [] -> nil
    end
  end

  defp select_provider(_state), do: nil
```

`{:set_providers, providers}` handler: the config mutation `%{config.claude | provider: hd(providers), providers: providers}` becomes kind-aware:

```elixir
        config ->
          case config.agent.kind do
            "codex" ->
              %{config | codex: %{config.codex | provider: hd(providers), providers: providers}}

            _ ->
              %{config | claude: %{config.claude | provider: hd(providers), providers: providers}}
          end
```

- [ ] **Step 3: Run the orchestrator-affected suite**

Run: `mix test test/cymphony_elixir/orchestrator test/cymphony_elixir/orchestrator_status_test.exs test/cymphony_elixir/blocker_dispatch_test.exs test/cymphony_elixir/core_test.exs`
Expected: FAIL only where presenter/status_dashboard still read old keys — note the failures, they're Task 9's checklist. If orchestrator-internal tests fail, fix here.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "orchestrator: neutral token/state key names, per-kind provider rotation, agent_kind in snapshot"
```

---

### Task 9: Presenter, StatusDashboard, CompletionStore renames

**Files:**
- Modify: `lib/cymphony_elixir_web/presenter.ex`, `lib/cymphony_elixir/status_dashboard.ex`, `lib/cymphony_elixir/completion_store.ex`, `lib/cymphony_elixir_web/live/dashboard_live.ex`
- Modify: `test/cymphony_elixir/status_dashboard_snapshot_test.exs`, `test/cymphony_elixir/completion_store_test.exs`, `test/cymphony_elixir/extensions_test.exs`, `test/cymphony_elixir/orchestrator_status_test.exs` (presenter assertions)

- [ ] **Step 1: Sweep the same sed table over these files** (same command as Task 8 Step 1 with this file list), plus:

```bash
for f in lib/cymphony_elixir_web/presenter.ex lib/cymphony_elixir/status_dashboard.ex lib/cymphony_elixir_web/live/dashboard_live.ex \
         test/cymphony_elixir/status_dashboard_snapshot_test.exs test/cymphony_elixir/extensions_test.exs; do
  sed -i '' \
    -e 's/humanize_claude_message/humanize_agent_message/g' \
    -e 's/humanize_claude_event/humanize_agent_event/g' \
    -e 's/humanize_claude_payload/humanize_agent_payload/g' \
    -e 's/humanize_claude_method/humanize_agent_method/g' \
    -e 's/humanize_claude_wrapper_event/humanize_agent_wrapper_event/g' \
    -e 's/unwrap_claude_message_payload/unwrap_agent_message_payload/g' \
    "$f"
done
```

Hand-fixes after the sweep:
- `presenter.ex`: the snapshot field pass-throughs now read `token_totals` / `input_tokens` etc. Keep the **web payload JSON field names** in lockstep (the dashboard is the only API consumer; Spec A allows the break): `claude_totals` key in payload → `token_totals`.
- `dashboard_live.ex`: `@default_payload` key `claude_totals:` → `token_totals:`, and the metrics strip reads `@payload.token_totals.*`. The "claude command" label/providers form is Spec C's business — leave markup otherwise untouched.
- `status_dashboard.ex`: the literal strings `"no claude message yet"` → `"no agent message yet"`, `"malformed JSON event from claude"` → `"malformed JSON event from agent"`. The `"claude/event/"` wrapper-method prefix handling STAYS (that vocabulary is emitted by tooling and humanized as-is).

- [ ] **Step 2: CompletionStore schema rename with tolerant read**

In `lib/cymphony_elixir/completion_store.ex` — new DBs get neutral columns; existing DBs migrate in place (SQLite `ALTER TABLE … RENAME COLUMN` is supported on the bundled exqlite):

```elixir
  @schema [
    """
    CREATE TABLE IF NOT EXISTS sessions (
      issue_id           TEXT NOT NULL,
      identifier         TEXT,
      project_name       TEXT,
      ended_at           TEXT NOT NULL,
      started_at         TEXT,
      runtime_seconds    INTEGER,
      input_tokens       INTEGER DEFAULT 0,
      output_tokens      INTEGER DEFAULT 0,
      total_tokens       INTEGER DEFAULT 0,
      worker_host        TEXT,
      workspace_path     TEXT,
      PRIMARY KEY (issue_id, ended_at)
    )
    """,
    """
    CREATE INDEX IF NOT EXISTS idx_sessions_project_ended
      ON sessions(project_name, ended_at DESC)
    """,
    """
    CREATE INDEX IF NOT EXISTS idx_sessions_ended
      ON sessions(ended_at DESC)
    """
  ]

  # Pre-rename databases have claude_* token columns; rename in place.
  @column_renames [
    {"claude_input_tokens", "input_tokens"},
    {"claude_output_tokens", "output_tokens"},
    {"claude_total_tokens", "total_tokens"}
  ]
```

and in `open_and_migrate/1` add `:ok <- run_column_renames(db)` after `run_migrations(db)`:

```elixir
  defp run_column_renames(db) do
    Enum.each(@column_renames, fn {old, new} ->
      # Errors mean the old column doesn't exist (fresh DB) — ignore.
      _ = Sqlite3.execute(db, "ALTER TABLE sessions RENAME COLUMN #{old} TO #{new}")
    end)

    :ok
  end
```

Update `write_record/2` SQL column list, `record_to_params/1` (`Map.get(record, :input_tokens) || 0` etc.), `read_recent/3` SELECT list, and `row_to_map/1` keys to the neutral names.

- [ ] **Step 3: Run affected tests, fix assertion keys**

Run: `mix test test/cymphony_elixir/completion_store_test.exs test/cymphony_elixir/status_dashboard_snapshot_test.exs test/cymphony_elixir/extensions_test.exs && mix test`
Expected: PASS after updating test assertion keys (`claude_input_tokens` → `input_tokens`, payload `claude_totals` → `token_totals`).

Add one migration regression test to `test/cymphony_elixir/completion_store_test.exs`:

```elixir
  test "opens a pre-rename database and reads old rows through new column names", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "legacy.db")
    {:ok, db} = Exqlite.Sqlite3.open(path, [])

    :ok =
      Exqlite.Sqlite3.execute(db, """
      CREATE TABLE sessions (
        issue_id TEXT NOT NULL, identifier TEXT, project_name TEXT,
        ended_at TEXT NOT NULL, started_at TEXT, runtime_seconds INTEGER,
        claude_input_tokens INTEGER DEFAULT 0, claude_output_tokens INTEGER DEFAULT 0,
        claude_total_tokens INTEGER DEFAULT 0, worker_host TEXT, workspace_path TEXT,
        PRIMARY KEY (issue_id, ended_at))
      """)

    :ok =
      Exqlite.Sqlite3.execute(
        db,
        "INSERT INTO sessions (issue_id, ended_at, claude_input_tokens, claude_output_tokens, claude_total_tokens) VALUES ('i1', '2026-07-16T00:00:00Z', 7, 3, 10)"
      )

    :ok = Exqlite.Sqlite3.close(db)

    name = :"legacy_store_#{System.unique_integer([:positive])}"
    {:ok, _pid} = CymphonyElixir.CompletionStore.start_link(path: path, name: name)

    assert [row] = CymphonyElixir.CompletionStore.recent(:all, 10, name)
    assert row.input_tokens == 7
    assert row.total_tokens == 10
  end
```

(Match the existing test file's setup style for `tmp_dir`; it already creates per-test temp DB paths.)

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "web/store/tui: neutral token key names; sessions.db column rename migration"
```

---

### Task 10: Humanizer gains Codex JSONL vocabulary

**Files:**
- Modify: `lib/cymphony_elixir/status_dashboard.ex`
- Test: `test/cymphony_elixir/status_dashboard_snapshot_test.exs`

Codex `exec --json` events use `{"type":"…"}` (dot-separated) instead of `{"method":"…"}` (slash-separated). The humanizer's `humanize_agent_payload/1` currently only dispatches on `"method"`.

- [ ] **Step 1: Write failing tests**

Add to `test/cymphony_elixir/status_dashboard_snapshot_test.exs`:

```elixir
  describe "codex JSONL event humanization" do
    test "thread.started / turn lifecycle / agent_message / usage" do
      assert StatusDashboard.humanize_agent_message(%{
               event: :stream_event,
               message: %{"type" => "thread.started", "thread_id" => "t-12345678"}
             }) =~ "thread started"

      assert StatusDashboard.humanize_agent_message(%{
               event: :stream_event,
               message: %{"type" => "turn.started"}
             }) == "turn started"

      assert StatusDashboard.humanize_agent_message(%{
               event: :stream_event,
               message: %{
                 "type" => "item.completed",
                 "item" => %{"id" => "item_0", "type" => "agent_message", "text" => "did the thing"}
               }
             }) =~ "did the thing"

      assert StatusDashboard.humanize_agent_message(%{
               event: :stream_event,
               message: %{
                 "type" => "item.started",
                 "item" => %{"id" => "item_1", "type" => "command_execution", "command" => "mix test"}
               }
             }) =~ "mix test"

      assert StatusDashboard.humanize_agent_message(%{
               event: :stream_event,
               message: %{
                 "type" => "turn.completed",
                 "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
               }
             }) =~ "turn completed"

      assert StatusDashboard.humanize_agent_message(%{
               event: :stream_event,
               message: %{"type" => "turn.failed", "error" => %{"message" => "boom"}}
             }) =~ "boom"
    end
  end
```

Run: `mix test test/cymphony_elixir/status_dashboard_snapshot_test.exs`
Expected: FAIL — falls through to inspect-dump output, not the friendly strings.

- [ ] **Step 2: Implement**

In `lib/cymphony_elixir/status_dashboard.ex`, in `humanize_agent_payload/1` (the `%{} = payload` clause), dispatch on `"type"` before the fallthrough `cond`:

```elixir
  defp humanize_agent_payload(%{} = payload) do
    case {map_value(payload, ["method", :method]), map_value(payload, ["type", :type])} do
      {method, _} when is_binary(method) ->
        humanize_agent_method(method, payload)

      {_, type} when is_binary(type) ->
        humanize_codex_event(type, payload)

      _ ->
        humanize_agent_payload_fallback(payload)
    end
  end

  # The body of this function is the existing `cond do` block from today's
  # humanize_agent_payload/1 (session_id → "session started (…)", "error" key
  # → "error: …", otherwise inspect-dump), moved verbatim into a named helper
  # so the new dispatch head above stays readable.
  defp humanize_agent_payload_fallback(payload) do
    cond do
      is_binary(map_value(payload, ["session_id", :session_id])) ->
        "session started (#{map_value(payload, ["session_id", :session_id])})"

      match?(%{"error" => _}, payload) ->
        "error: #{format_error_value(Map.get(payload, "error"))}"

      true ->
        payload
        |> inspect(pretty: true, limit: 30)
        |> String.replace("\n", " ")
        |> sanitize_ansi_and_control_bytes()
        |> String.trim()
    end
  end
```

Add the Codex event clauses (place near `humanize_agent_method/2`):

```elixir
  defp humanize_codex_event("thread.started", payload) do
    case map_value(payload, ["thread_id", :thread_id]) do
      thread_id when is_binary(thread_id) -> "thread started (#{short_id(thread_id)})"
      _ -> "thread started"
    end
  end

  defp humanize_codex_event("turn.started", _payload), do: "turn started"

  defp humanize_codex_event("turn.completed", payload) do
    usage = map_value(payload, ["usage", :usage])

    case usage do
      %{} ->
        input = map_value(usage, ["input_tokens", :input_tokens]) || 0
        output = map_value(usage, ["output_tokens", :output_tokens]) || 0
        "turn completed (tokens in #{input} / out #{output})"

      _ ->
        "turn completed"
    end
  end

  defp humanize_codex_event("turn.failed", payload) do
    reason =
      map_path(payload, ["error", "message"]) ||
        map_path(payload, [:error, :message]) ||
        "unknown error"

    "turn failed: #{reason}"
  end

  defp humanize_codex_event("item." <> lifecycle, payload) do
    item = map_value(payload, ["item", :item]) || %{}
    item_type = map_value(item, ["type", :type])

    detail =
      case item_type do
        "agent_message" -> map_value(item, ["text", :text])
        "command_execution" -> map_value(item, ["command", :command])
        "reasoning" -> map_value(item, ["text", :text])
        _ -> nil
      end

    base = "item #{lifecycle}: #{humanize_item_type(item_type)}"
    if is_binary(detail) and detail != "", do: "#{base} — #{truncate(detail, 80)}", else: base
  end

  defp humanize_codex_event(type, _payload), do: type
```

(`short_id/1`, `map_value/2`, `map_path/2`, `humanize_item_type/1`, `truncate/2` already exist in this module — reuse them.)

- [ ] **Step 3: Run, commit**

Run: `mix test test/cymphony_elixir/status_dashboard_snapshot_test.exs`
Expected: PASS.

```bash
git add -A && git commit -m "tui: humanize codex exec --json event vocabulary"
```

---

### Task 11: CLI — `agent`/`model`/`effort` shorthands, retire `--claude-command`

**Files:**
- Modify: `lib/cymphony_elixir/cli.ex`
- Test: `test/cymphony_elixir/cli_test.exs`

- [ ] **Step 1: Write failing tests**

Add to `test/cymphony_elixir/cli_test.exs` (match the file's existing style of driving `CLI.evaluate/2` or the exposed parse helpers — grep the file for how `cr`/`c` expansions are asserted today and mirror it; the essential assertions):

```elixir
  test "agent/model/effort shorthands expand to long flags" do
    assert ["--agent", "codex" | _] = CymphonyElixir.CLI.expand_shorthands_for_test(["agent", "codex"])
    assert ["--model", "opus" | _] = CymphonyElixir.CLI.expand_shorthands_for_test(["model", "opus"])
    assert ["--effort", "high" | _] = CymphonyElixir.CLI.expand_shorthands_for_test(["effort", "high"])
  end

  test "bare agent/model/effort shorthand falls back to help" do
    assert ["--help"] = CymphonyElixir.CLI.expand_shorthands_for_test(["agent"])
  end

  test "c remains provider rotation and --claude-command is gone" do
    assert ["--provider", "cv1,cz2" | _] = CymphonyElixir.CLI.expand_shorthands_for_test(["c", "cv1,cz2"])
    refute Enum.any?(CymphonyElixir.CLI.switches_for_test(), fn {k, _} -> k == :claude_command end)
  end
```

If the CLI test file has no `expand_shorthands_for_test` hook yet, add these to `cli.ex` alongside the existing test helpers (grep for `_for_test` in the file; the codebase uses this convention):

```elixir
  @doc false
  @spec expand_shorthands_for_test([String.t()]) :: [String.t()]
  def expand_shorthands_for_test(args), do: expand_shorthands(args)

  @doc false
  @spec switches_for_test() :: keyword()
  def switches_for_test, do: @switches
```

Run: `mix test test/cymphony_elixir/cli_test.exs`
Expected: FAIL.

- [ ] **Step 2: Implement**

In `lib/cymphony_elixir/cli.ex`:

a. `@switches`: delete `claude_command: :string`; add `agent: :string, model: :string, effort: :string` (keep `provider: :string`).

b. Shorthands: replace the `c`→`--claude-command` pair with:

```elixir
  defp expand_shorthands(["c", value | rest]), do: ["--provider", value | expand_shorthands(rest)]
  defp expand_shorthands(["c" | _]), do: ["--help"]
  defp expand_shorthands(["agent", value | rest]), do: ["--agent", value | expand_shorthands(rest)]
  defp expand_shorthands(["agent" | _]), do: ["--help"]
  defp expand_shorthands(["model", value | rest]), do: ["--model", value | expand_shorthands(rest)]
  defp expand_shorthands(["model" | _]), do: ["--help"]
  defp expand_shorthands(["effort", value | rest]), do: ["--effort", value | expand_shorthands(rest)]
  defp expand_shorthands(["effort" | _]), do: ["--help"]
```

c. `cymphony_mode?` (line ~307): replace `Keyword.has_key?(opts, :claude_command)` with `Keyword.has_key?(opts, :agent) or Keyword.has_key?(opts, :model) or Keyword.has_key?(opts, :effort)` (keeping the other existing disjuncts).

d. Project-override pipeline (lines ~375–395): DELETE the whole `resolve_command_override/2` + its `case Keyword.get(opts, :claude_command)` block. The `--provider` block already exists and now also absorbs comma lists:

```elixir
        filtered_projects =
          case Keyword.get(opts, :provider) do
            nil ->
              filtered_projects

            value ->
              providers = parse_provider_list(value)

              Enum.map(filtered_projects, fn project ->
                project
                |> Map.put("provider", hd(providers))
                |> Map.put("providers", providers)
              end)
          end

        filtered_projects =
          case Keyword.get(opts, :agent) do
            kind when kind in ["claude", "codex"] ->
              Enum.map(filtered_projects, &Map.put(&1, "agent", kind))

            nil ->
              filtered_projects

            other ->
              IO.puts(:stderr, "Unknown agent '#{other}' — using configured agent")
              filtered_projects
          end

        filtered_projects =
          case Keyword.get(opts, :model) do
            model when is_binary(model) and model != "" ->
              Enum.map(filtered_projects, &Map.put(&1, "model", model))

            _ ->
              filtered_projects
          end

        filtered_projects =
          case Keyword.get(opts, :effort) do
            effort when is_binary(effort) and effort != "" ->
              Enum.map(filtered_projects, &Map.put(&1, "effort", effort))

            _ ->
              filtered_projects
          end
```

(`parse_provider_list/1` already exists — keep it. Remove the now-unused `alias …ShellProvider` if nothing else in cli.ex uses it — `grep -n ShellProvider lib/cymphony_elixir/cli.ex` first.)

e. Help text: in the `--help` output replace the `c <value>` line's description with "Provider rotation (comma-separated auth aliases)" and add:

```
  agent <kind>       Coding agent: claude or codex
  model <name>       Model override passed to the agent CLI
  effort <level>     Reasoning effort passed to the agent CLI
```

- [ ] **Step 3: Run, fix, commit**

Run: `mix test test/cymphony_elixir/cli_test.exs && mix test`
Expected: PASS. Grep for leftovers: `grep -rn "claude_command\|claude-command" lib/ test/` — remaining hits should only be `cymphony/config.ex`'s legacy project-key reading if any (delete those too; clean break) and docs (Task 12).

```bash
git add -A && git commit -m "cli: agent/model/effort shorthands; c = provider rotation; retire --claude-command"
```

---

### Task 12: End-to-end codex-path test, docs, final gate

**Files:**
- Test: `test/cymphony_elixir/agent/runner_test.exs` (add codex fake-binary case)
- Modify: `SPEC.md` (§5.3.6, §10), `CLAUDE.md`, `README.md`, `docs/token_accounting.md`

- [ ] **Step 1: Fake-codex end-to-end runner test**

Add to `test/cymphony_elixir/agent/runner_test.exs`, following the existing fake-claude test pattern (temp workspace root + fake executable + `write_workflow_file!`):

```elixir
  test "runner drives a codex-kind session through the codex adapter" do
    test_root = Path.join(System.tmp_dir!(), "cymphony-runner-codex-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-3001")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-args.trace")

      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      echo "$@" > "#{trace_file}"
      echo '{"type":"thread.started","thread_id":"t-e2e"}'
      echo '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"done"}}'
      echo '{"type":"turn.completed","usage":{"input_tokens":8,"output_tokens":2}}'
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_kind: "codex",
        agent_model: "gpt-5.2-codex",
        agent_effort: "high",
        codex_command: codex_binary
      )

      issue = %Issue{
        id: "issue-codex-e2e",
        identifier: "MT-3001",
        title: "Codex path",
        description: "drive codex adapter",
        state: "In Progress",
        url: "https://example.org/issues/MT-3001"
      }

      assert {:ok, %{session_id: "t-e2e", result: %{result: "done", usage: usage}}} =
               Runner.run(workspace, "do it", issue)

      assert usage["total_tokens"] == 10

      args = File.read!(trace_file)
      assert args =~ "exec"
      assert args =~ "--json"
      assert args =~ "-m gpt-5.2-codex"
      assert args =~ "model_reasoning_effort"
    after
      File.rm_rf(test_root)
    end
  end
```

(Adjust the `{:ok, …}` pattern to Runner's actual return shape — it mirrors AppServer's `%{result: result_map, session_id: …}`; assert on the fields the existing json-format test asserts.)

Run: `mix test test/cymphony_elixir/agent/runner_test.exs`
Expected: PASS.

- [ ] **Step 2: Docs**

- `SPEC.md` §5.3.6: retitle `claude (object)` to three subsections documenting `agent` (kind/model/effort/timeouts), `claude`, `codex` exactly as the schema in Task 1. §10 launch contract: command comes from the active agent section; add the codex JSONL completion conditions (`turn.completed` success / `turn.failed` failure) beside the existing ones. §6.4 cheat-sheet rows updated.
- `CLAUDE.md`: command table — replace the `c <value>` row description with provider rotation; add `agent`/`model`/`effort` rows; architecture section: `Claude.AppServer` → `Agent.Runner` + adapters; provider system section: note per-kind prefixes (ANTHROPIC_* vs OPENAI_*).
- `README.md`: same command-table updates; quick example `cymphony project Farm agent codex model gpt-5.2-codex effort high`.
- `docs/token_accounting.md`: add a short "Codex" section — usage arrives once per `codex exec` invocation on `turn.completed` as `{input_tokens, cached_input_tokens, output_tokens, reasoning_output_tokens}`; cymphony sums input+output for `total_tokens`.

- [ ] **Step 3: Full gate**

Run: `make all`
Expected: PASS (setup, build, fmt-check, lint incl. specs.check, coverage at 100% on tracked modules, dialyzer). Fix any `@spec` gaps on new public functions (`Agent.module_for/1`, `Agent.known_kinds/0`, `Runner` publics, `ShellProvider.load_env/2`, `parse_env_output/2`, `ConfigWriter.descriptor_from_config/1`).

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "docs+spec: agent abstraction (claude/codex) documented; make all green"
```

---

## Plan self-review notes

- Spec coverage: behaviour+resolver (T3), runner (T7), claude adapter (T4), codex adapter incl. sandbox `-c sandbox_mode` and MCP env_vars secret handling (T5), schema clean break + dropped vestiges (T1), generation/onboarding (T2), ShellProvider prefixes (T6), orchestrator renames + per-kind providers (T8), presenter/store/tui renames + DB migration (T9), codex humanizer vocabulary (T10), CLI surface (T11), e2e + docs + gate (T12). Spec's "no config auto-migration" honored — the only migration is the sessions.db column rename, which is a local artifact store, not user config (kept deliberately: silently losing completion history would look like data loss).
- Type consistency: `run_spec`/`turn_result` shapes defined once in T3 and used identically in T4/T5/T7; rename table applied uniformly in T8/T9.
- Ordering: every task leaves `mix test` green except T8 Step 3's explicitly-scoped known failures, which T9 resolves; T8+T9 can be one PR if preferred.
