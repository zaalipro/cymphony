# Per-Issue Agent/Model/Effort Selection (Spec B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Choose agent kind, model, reasoning effort, and provider per issue via Linear labels and a `cymphony:` description directive, resolved at dispatch and pinned per run attempt.

**Architecture:** A pure `RunSpecResolver` module parses labels + description + project config into a per-field-precedence override map. The orchestrator resolves at dispatch time, stamps the resolved values into the running entry (dashboard-visible), and threads them through the existing `spawn_issue_on_worker_host → AgentRunner → Agent.Runner` opts pipeline that Spec A built. The per-session provider override generalizes to a run-spec override.

**Tech Stack:** Elixir/ExUnit. Depends on Spec A being merged (`Agent.Runner` opts `:agent_kind`/`:model`/`:effort`/`:provider_override`; neutral running-entry keys).

**Spec:** `docs/superpowers/specs/2026-07-16-per-issue-selection-design.md`

---

## File map

| File | Role |
|---|---|
| `lib/cymphony_elixir/run_spec_resolver.ex` (new) | Pure parsing + precedence resolution |
| `lib/cymphony_elixir/orchestrator.ex` | Resolve at dispatch, stamp metadata, generalized override call |
| `lib/cymphony_elixir/agent_runner.ex` | Pass-through only (already reads opts — no change expected; verify) |
| `lib/cymphony_elixir_web/presenter.ex` | Expose `agent_kind`/`model`/`effort` on running entries + completions |
| `lib/cymphony_elixir/completion_store.ex` | Add `agent_kind`/`model` columns |
| `lib/cymphony_elixir_web/{control.ex,live/dashboard_live.ex,controllers/observability_api_controller.ex}` | `set_issue_run_spec` plumbing (minimal; full UI is Spec C) |
| `SPEC.md`, `CLAUDE.md`, `README.md` | Document label/directive syntax |

---

### Task 1: `RunSpecResolver` — label parsing

**Files:**
- Create: `lib/cymphony_elixir/run_spec_resolver.ex`
- Test: `test/cymphony_elixir/run_spec_resolver_test.exs`

- [ ] **Step 1: Write failing tests for label extraction**

Create `test/cymphony_elixir/run_spec_resolver_test.exs`:

```elixir
defmodule CymphonyElixir.RunSpecResolverTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CymphonyElixir.Linear.Issue
  alias CymphonyElixir.RunSpecResolver

  defp issue(attrs) do
    struct!(
      %Issue{id: "i-1", identifier: "MT-1", title: "t", state: "Todo"},
      attrs
    )
  end

  describe "from_labels/1" do
    test "extracts agent/model/effort/provider prefixed labels" do
      overrides = RunSpecResolver.from_labels(["agent:codex", "model:gpt-5.2-codex", "effort:high", "provider:cz1", "backend"])

      assert overrides == %{
               agent_kind: "codex",
               model: "gpt-5.2-codex",
               effort: "high",
               provider: "cz1"
             }
    end

    test "ignores unrelated labels and empty values" do
      log =
        capture_log(fn ->
          assert RunSpecResolver.from_labels(["backend", "model:", "urgent"]) == %{}
        end)

      assert log =~ "empty value"
    end

    test "duplicate prefixes pick the sorted-first value and warn" do
      log =
        capture_log(fn ->
          assert %{model: "aaa"} = RunSpecResolver.from_labels(["model:zzz", "model:aaa"])
        end)

      assert log =~ "duplicate"
    end

    test "unknown agent kind falls through with a warning" do
      log =
        capture_log(fn ->
          assert RunSpecResolver.from_labels(["agent:gemini"]) == %{}
        end)

      assert log =~ "unknown agent"
    end
  end
end
```

Run: `mix test test/cymphony_elixir/run_spec_resolver_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 2: Implement label parsing**

Create `lib/cymphony_elixir/run_spec_resolver.ex`:

```elixir
defmodule CymphonyElixir.RunSpecResolver do
  @moduledoc """
  Resolves the per-issue run spec (agent kind, model, effort, provider) from,
  in descending precedence per field:

  1. Linear labels — `agent:<kind>`, `model:<name>`, `effort:<level>`, `provider:<alias>`
  2. A `cymphony:` directive line in the issue description —
     `cymphony: agent=codex model=gpt-5.2 effort=high`
  3. Project config (`agent.kind` / `agent.model` / `agent.effort`)

  Pure functions only; the orchestrator calls `resolve/2` at dispatch time and
  pins the result for the whole run attempt.
  """

  require Logger

  alias CymphonyElixir.Agent
  alias CymphonyElixir.Linear.Issue

  @override_keys %{
    "agent" => :agent_kind,
    "model" => :model,
    "effort" => :effort,
    "provider" => :provider
  }

  @type overrides :: %{
          optional(:agent_kind) => String.t(),
          optional(:model) => String.t(),
          optional(:effort) => String.t(),
          optional(:provider) => String.t()
        }

  @type resolved :: %{
          agent_kind: String.t(),
          model: String.t() | nil,
          effort: String.t() | nil,
          provider: String.t() | nil,
          source: :labels | :directive | :config
        }

  @doc "Extract overrides from Linear labels (already downcased by the adapter)."
  @spec from_labels([String.t()]) :: overrides()
  def from_labels(labels) when is_list(labels) do
    labels
    |> Enum.flat_map(&parse_label/1)
    |> Enum.group_by(fn {key, _value} -> key end, fn {_key, value} -> value end)
    |> Enum.reduce(%{}, fn {key, values}, acc ->
      value =
        case Enum.sort(values) do
          [single] ->
            single

          [first | _] = all ->
            Logger.warning("run_spec: duplicate #{key} labels #{inspect(all)} — using #{inspect(first)}")
            first
        end

      put_validated(acc, key, value)
    end)
  end

  defp parse_label(label) when is_binary(label) do
    case String.split(label, ":", parts: 2) do
      [prefix, value] when is_map_key(@override_keys, prefix) ->
        trimmed = String.trim(value)

        if trimmed == "" do
          Logger.warning("run_spec: label #{inspect(label)} has an empty value — ignored")
          []
        else
          [{Map.fetch!(@override_keys, prefix), trimmed}]
        end

      _ ->
        []
    end
  end

  defp parse_label(_label), do: []

  defp put_validated(acc, :agent_kind, value) do
    if value in Agent.known_kinds() do
      Map.put(acc, :agent_kind, value)
    else
      Logger.warning("run_spec: unknown agent kind #{inspect(value)} — falling back to next source")
      acc
    end
  end

  defp put_validated(acc, key, value), do: Map.put(acc, key, value)
end
```

- [ ] **Step 3: Run, commit**

Run: `mix test test/cymphony_elixir/run_spec_resolver_test.exs`
Expected: PASS.

```bash
git add -A && git commit -m "run spec: label-based per-issue overrides (agent/model/effort/provider)"
```

---

### Task 2: `RunSpecResolver` — description directive

**Files:**
- Modify: `lib/cymphony_elixir/run_spec_resolver.ex`
- Test: `test/cymphony_elixir/run_spec_resolver_test.exs`

- [ ] **Step 1: Write failing tests**

Add to the test file:

```elixir
  describe "from_description/1" do
    test "parses the first cymphony: directive line" do
      description = """
      Some intro text.

      cymphony: agent=codex model=gpt-5.2-codex effort=high provider=oa1

      More text. cymphony: model=ignored-not-line-start
      """

      assert RunSpecResolver.from_description(description) == %{
               agent_kind: "codex",
               model: "gpt-5.2-codex",
               effort: "high",
               provider: "oa1"
             }
    end

    test "only the first directive line wins" do
      description = """
      cymphony: model=first
      cymphony: model=second
      """

      assert %{model: "first"} = RunSpecResolver.from_description(description)
    end

    test "agent and effort values are lowercased; model/provider preserved" do
      assert %{agent_kind: "codex", effort: "high", model: "GPT-5.2-Codex"} =
               RunSpecResolver.from_description("cymphony: agent=CODEX effort=HIGH model=GPT-5.2-Codex")
    end

    test "unknown keys are ignored, malformed lines yield nothing" do
      assert %{model: "m1"} = RunSpecResolver.from_description("cymphony: model=m1 fuel=diesel")
      assert RunSpecResolver.from_description("cymphony: not_kv_pairs at all!") == %{}
      assert RunSpecResolver.from_description(nil) == %{}
      assert RunSpecResolver.from_description("no directive here") == %{}
    end

    test "unknown agent kind in directive falls through" do
      assert RunSpecResolver.from_description("cymphony: agent=gemini") == %{}
    end
  end
```

Run: `mix test test/cymphony_elixir/run_spec_resolver_test.exs`
Expected: FAIL — `from_description/1` undefined.

- [ ] **Step 2: Implement**

Add to `run_spec_resolver.ex`:

```elixir
  @doc """
  Extract overrides from the first `cymphony:` directive line in the issue
  description. Keys: agent|model|effort|provider as `key=value` pairs.
  `agent` and `effort` values are lowercased; `model`/`provider` preserved.
  """
  @spec from_description(String.t() | nil) :: overrides()
  def from_description(description) when is_binary(description) do
    description
    |> String.split(["\n", "\r\n"], trim: true)
    |> Enum.find_value(%{}, fn line ->
      case parse_directive_line(String.trim(line)) do
        overrides when map_size(overrides) > 0 -> overrides
        _ -> nil
      end
    end)
  end

  def from_description(_description), do: %{}

  defp parse_directive_line("cymphony:" <> rest), do: parse_directive_pairs(rest)
  defp parse_directive_line("Cymphony:" <> rest), do: parse_directive_pairs(rest)
  defp parse_directive_line("CYMPHONY:" <> rest), do: parse_directive_pairs(rest)
  defp parse_directive_line(_line), do: %{}

  defp parse_directive_pairs(rest) do
    pair_pattern = Regex.compile!("^([A-Za-z]+)=([A-Za-z0-9._/-]+)$")

    rest
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reduce(%{}, fn token, acc ->
      case Regex.run(pair_pattern, token) do
        [_, raw_key, raw_value] ->
          key = String.downcase(raw_key)

          case Map.fetch(@override_keys, key) do
            {:ok, field} ->
              value = if field in [:agent_kind, :effort], do: String.downcase(raw_value), else: raw_value
              put_validated(acc, field, value)

            :error ->
              Logger.debug("run_spec: unknown directive key #{inspect(raw_key)} — ignored")
              acc
          end

        nil ->
          acc
      end
    end)
  end
```

Note the `~r/\s+/` sigil for splitting is fine (sigils on whitespace classes are not the OTP 28 issue); the value pattern uses `Regex.compile!/1` per the repo convention for anything beyond trivial splits. Keep it consistent: if credo/convention flags the sigil, switch to `Regex.compile!("\\s+")`.

- [ ] **Step 3: Run, commit**

Run: `mix test test/cymphony_elixir/run_spec_resolver_test.exs`
Expected: PASS.

```bash
git add -A && git commit -m "run spec: cymphony: description directive parsing"
```

---

### Task 3: `RunSpecResolver.resolve/2` — per-field precedence

**Files:**
- Modify: `lib/cymphony_elixir/run_spec_resolver.ex`
- Test: `test/cymphony_elixir/run_spec_resolver_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
  describe "resolve/2" do
    defp config_with(agent_overrides) do
      {:ok, settings} = CymphonyElixir.Config.Schema.parse(%{"agent" => agent_overrides})
      settings
    end

    test "per-field precedence: labels > directive > config" do
      issue =
        issue(
          labels: ["effort:xhigh"],
          description: "cymphony: model=directive-model effort=low"
        )

      config = config_with(%{"kind" => "claude", "model" => "config-model", "effort" => "medium"})

      resolved = RunSpecResolver.resolve(issue, config)

      assert resolved.agent_kind == "claude"
      assert resolved.model == "directive-model"
      assert resolved.effort == "xhigh"
      assert resolved.source == :labels
    end

    test "config-only issue resolves to project defaults with source :config" do
      resolved = RunSpecResolver.resolve(issue(labels: [], description: "plain"), config_with(%{"kind" => "codex"}))

      assert resolved.agent_kind == "codex"
      assert resolved.model == nil
      assert resolved.effort == nil
      assert resolved.provider == nil
      assert resolved.source == :config
    end

    test "label agent switch pulls provider default from that kind's section" do
      {:ok, settings} =
        CymphonyElixir.Config.Schema.parse(%{
          "agent" => %{"kind" => "claude"},
          "claude" => %{"provider" => "cz"},
          "codex" => %{"provider" => "oa"}
        })

      resolved = RunSpecResolver.resolve(issue(labels: ["agent:codex"]), settings)
      assert resolved.agent_kind == "codex"
      # provider stays nil here: rotation/config provider selection is the
      # orchestrator's job; the resolver only pins EXPLICIT provider overrides.
      assert resolved.provider == nil
    end

    test "explicit provider label pins the provider" do
      resolved = RunSpecResolver.resolve(issue(labels: ["provider:cz1"]), config_with(%{}))
      assert resolved.provider == "cz1"
      assert resolved.source == :labels
    end
  end
```

Run: `mix test test/cymphony_elixir/run_spec_resolver_test.exs`
Expected: FAIL — `resolve/2` undefined.

- [ ] **Step 2: Implement**

```elixir
  @doc """
  Resolve the effective run spec for an issue against the project config.
  Field-level precedence: labels > description directive > config defaults.
  `source` reports the highest source that contributed any field (for logs).
  """
  @spec resolve(Issue.t(), term()) :: resolved()
  def resolve(%Issue{} = issue, config) do
    label_overrides = from_labels(issue.labels || [])
    directive_overrides = from_description(issue.description)

    merged = Map.merge(directive_overrides, label_overrides)

    %{
      agent_kind: merged[:agent_kind] || config.agent.kind,
      model: merged[:model] || config.agent.model,
      effort: merged[:effort] || config.agent.effort,
      provider: merged[:provider],
      source: source_of(label_overrides, directive_overrides)
    }
  end

  defp source_of(labels, _directive) when map_size(labels) > 0, do: :labels
  defp source_of(_labels, directive) when map_size(directive) > 0, do: :directive
  defp source_of(_labels, _directive), do: :config
```

- [ ] **Step 3: Run, commit**

Run: `mix test test/cymphony_elixir/run_spec_resolver_test.exs`
Expected: PASS.

```bash
git add -A && git commit -m "run spec: resolve/2 per-field precedence over issue + config"
```

---

### Task 4: Orchestrator — resolve at dispatch, stamp metadata

**Files:**
- Modify: `lib/cymphony_elixir/orchestrator.ex`
- Test: `test/cymphony_elixir/orchestrator/run_spec_dispatch_test.exs` (new)

- [ ] **Step 1: Write the failing test**

The orchestrator exposes `spawn_issue_on_worker_host` only indirectly; test via the running-entry stamping using the same `:sys.replace_state` + fake-task pattern the status tests use is heavyweight. Instead expose the resolution seam as a `_for_test` helper (repo convention) and assert dispatch metadata through `do_dispatch_issue`:

```elixir
defmodule CymphonyElixir.Orchestrator.RunSpecDispatchTest do
  use CymphonyElixir.TestSupport

  alias CymphonyElixir.Orchestrator

  test "dispatch resolves per-issue run spec from labels and stamps running-entry metadata" do
    issue = %Issue{
      id: "iss-runspec-1",
      identifier: "MT-500",
      title: "Run spec dispatch",
      description: "cymphony: effort=low",
      state: "Todo",
      url: "https://example.org/MT-500",
      labels: ["agent:codex", "model:gpt-5.2-codex"]
    }

    resolved = Orchestrator.resolve_run_spec_for_test(issue, Config.settings!())

    assert resolved.agent_kind == "codex"
    assert resolved.model == "gpt-5.2-codex"
    assert resolved.effort == "low"
  end

  test "orchestrator running entry carries agent_kind/model/effort after dispatch" do
    orchestrator_name = Module.concat(__MODULE__, :RunSpecOrch)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    issue = %Issue{
      id: "iss-runspec-2",
      identifier: "MT-501",
      title: "Stamped",
      description: nil,
      state: "Todo",
      url: "https://example.org/MT-501",
      labels: ["effort:high"]
    }

    :ok = Orchestrator.dispatch_issue_for_test(pid, issue)

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [entry]} = snapshot
    assert entry.effort == "high"
    assert entry.agent_kind == "claude"
    assert entry.model == nil
  end
end
```

If `dispatch_issue_for_test/2` doesn't exist, add it beside the other `_for_test` helpers in `orchestrator.ex`:

```elixir
  @doc false
  @spec dispatch_issue_for_test(GenServer.server(), Issue.t()) :: :ok
  def dispatch_issue_for_test(server, %Issue{} = issue) do
    GenServer.call(server, {:dispatch_issue_for_test, issue})
  end
```

with a `handle_call` that runs `do_dispatch_issue(state, issue, nil, nil, [])` and replies `:ok`. (The AgentRunner task will fail fast against the fake workflow config — that's fine; the running entry is stamped synchronously at spawn before any task failure unwinds it. Mirror how existing tests tolerate this; if flaky, point `claude_command`/`codex.command` at `/usr/bin/true` via `write_workflow_file!`.)

Run: `mix test test/cymphony_elixir/orchestrator/run_spec_dispatch_test.exs`
Expected: FAIL.

- [ ] **Step 2: Implement**

In `lib/cymphony_elixir/orchestrator.ex`:

a. `alias CymphonyElixir.RunSpecResolver` at the top.

b. Add the test seam:

```elixir
  @doc false
  @spec resolve_run_spec_for_test(Issue.t(), term()) :: RunSpecResolver.resolved()
  def resolve_run_spec_for_test(issue, config), do: RunSpecResolver.resolve(issue, config)
```

c. In `spawn_issue_on_worker_host/6` — resolve, then thread. Replace the head:

```elixir
  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host, opts) do
    resolved = RunSpecResolver.resolve(issue, state_config(state))

    selected_provider =
      Keyword.get(opts, :provider_override) || resolved.provider || select_provider_for_kind(state, resolved.agent_kind)

    model = Keyword.get(opts, :model_override) || resolved.model
    effort = Keyword.get(opts, :effort_override) || resolved.effort

    case Task.Supervisor.start_child(CymphonyElixir.TaskSupervisor, fn ->
           AgentRunner.run(issue, recipient,
             attempt: attempt,
             worker_host: worker_host,
             config: state.config,
             prompt_template: state.prompt_template,
             provider_override: selected_provider,
             agent_kind: resolved.agent_kind,
             model: model,
             effort: effort
           )
         end) do
```

and in the running-entry map add, next to `provider: selected_provider`:

```elixir
                agent_kind: resolved.agent_kind,
                model: model,
                effort: effort,
```

and extend the dispatch log line:

```elixir
              "worker_host=#{worker_host || "local"} provider=#{selected_provider || "default"} agent=#{resolved.agent_kind} model=#{model || "default"} effort=#{effort || "default"} source=#{resolved.source} attempt=#{inspect(attempt)}"
```

d. Provider rotation becomes kind-aware when an issue switches kinds. Replace `select_provider/1` call sites with `select_provider_for_kind/2`:

```elixir
  # When the issue's resolved kind matches the project's configured kind, use
  # the rotating provider list; when a label switches kinds, fall back to that
  # kind's configured provider (rotation lists are per-kind config).
  defp select_provider_for_kind(%State{config: config} = state, kind) do
    if is_map(config) and config.agent.kind == kind do
      select_provider(state)
    else
      case config do
        %{} -> agent_provider_section(config, kind).provider
        _ -> select_provider(state)
      end
    end
  end
```

(`agent_provider_section/2` exists from Spec A Task 8. `select_provider/1` stays for the matching-kind path.)

e. Snapshot: the running-entry pass-through in `snapshot` (the map built around line 1357) gains:

```elixir
          agent_kind: Map.get(metadata, :agent_kind),
          model: Map.get(metadata, :model),
          effort: Map.get(metadata, :effort),
```

- [ ] **Step 3: Run, commit**

Run: `mix test test/cymphony_elixir/orchestrator/run_spec_dispatch_test.exs && mix test`
Expected: PASS. Verify AgentRunner passes the new opts through to `Runner.start_session` — Spec A's Task 7 already forwards `Keyword.take(opts, [:agent_kind, :model, :effort, :provider_override])`; if it forwards blindly via `opts`, nothing to do.

```bash
git add -A && git commit -m "orchestrator: per-issue run spec resolution at dispatch; kind-aware provider selection; metadata stamping"
```

---

### Task 5: Generalized per-session override (`set_issue_run_spec`)

**Files:**
- Modify: `lib/cymphony_elixir/orchestrator.ex`, `lib/cymphony_elixir_web/live/dashboard_live.ex`, `lib/cymphony_elixir_web/presenter.ex`
- Test: `test/cymphony_elixir/orchestrator/run_spec_dispatch_test.exs`

- [ ] **Step 1: Write failing test**

```elixir
  test "set_issue_run_spec kills and re-dispatches with pinned overrides" do
    orchestrator_name = Module.concat(__MODULE__, :OverrideOrch)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    issue = %Issue{
      id: "iss-override-1",
      identifier: "MT-502",
      title: "Override",
      state: "In Progress",
      url: "https://example.org/MT-502",
      labels: []
    }

    :ok = Orchestrator.dispatch_issue_for_test(pid, issue)

    assert :ok =
             Orchestrator.set_issue_run_spec(pid, "iss-override-1", %{
               provider: "cz2",
               model: "opus",
               effort: "max"
             })

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [entry]} = snapshot
    assert entry.provider == "cz2"
    assert entry.model == "opus"
    assert entry.effort == "max"

    assert {:error, :not_running} =
             Orchestrator.set_issue_run_spec(pid, "missing-id", %{provider: "x"})
  end
```

Run: `mix test test/cymphony_elixir/orchestrator/run_spec_dispatch_test.exs`
Expected: FAIL — `set_issue_run_spec/3` undefined.

- [ ] **Step 2: Implement**

In `orchestrator.ex`, generalize the existing `{:set_issue_provider, …}` machinery (keep the old public function as a delegator so nothing breaks mid-stack):

```elixir
  @spec set_issue_run_spec(GenServer.server(), String.t(), map()) ::
          :ok | {:error, :not_running} | :unavailable
  def set_issue_run_spec(server, issue_id, overrides)
      when is_binary(issue_id) and is_map(overrides) do
    GenServer.call(server, {:set_issue_run_spec, issue_id, overrides})
  catch
    :exit, _ -> :unavailable
  end
```

Replace the `{:set_issue_provider, issue_id, provider}` handle_call with:

```elixir
  def handle_call({:set_issue_run_spec, issue_id, overrides}, _from, state) do
    case Map.get(state.running, issue_id) do
      nil ->
        {:reply, {:error, :not_running}, state}

      running_entry ->
        issue = running_entry.issue
        worker_host = Map.get(running_entry, :worker_host)

        state = terminate_running_issue(state, issue_id, false)

        Logger.info(
          "Run-spec override for #{issue_context(issue)}: #{inspect(Map.take(overrides, [:provider, :model, :effort]))}"
        )

        dispatch_opts =
          []
          |> maybe_override(:provider_override, overrides[:provider])
          |> maybe_override(:model_override, overrides[:model])
          |> maybe_override(:effort_override, overrides[:effort])

        new_state = do_dispatch_issue(state, issue, nil, worker_host, dispatch_opts)
        notify_dashboard()
        {:reply, :ok, new_state}
    end
  end
```

with:

```elixir
  defp maybe_override(opts, _key, nil), do: opts
  defp maybe_override(opts, _key, ""), do: opts
  defp maybe_override(opts, key, value) when is_binary(value), do: Keyword.put(opts, key, value)
```

Update the dashboard's existing `set_provider` path: in `dashboard_live.ex`, `send_set_provider/4` (grep for it — it issues `{:set_issue_provider, …}`) now calls `Orchestrator.set_issue_run_spec(orch, issue_id, %{provider: provider})`. Delete the old `set_issue_provider` public function + handle_call once no caller remains (`grep -rn "set_issue_provider" lib test`). Agent kind is deliberately NOT accepted in overrides (spec decision: kind switches invalidate sessions; use labels + retry).

- [ ] **Step 3: Run, commit**

Run: `mix test test/cymphony_elixir/orchestrator/run_spec_dispatch_test.exs && mix test`
Expected: PASS.

```bash
git add -A && git commit -m "orchestrator: set_issue_run_spec generalizes per-session provider override to model/effort"
```

---

### Task 6: Retry re-resolution proof + presenter/store surfacing

**Files:**
- Modify: `lib/cymphony_elixir_web/presenter.ex`, `lib/cymphony_elixir/completion_store.ex`, `lib/cymphony_elixir/orchestrator.ex` (completion record)
- Test: `test/cymphony_elixir/orchestrator/run_spec_dispatch_test.exs`, `test/cymphony_elixir/completion_store_test.exs`

- [ ] **Step 1: Retry re-resolution test**

Because resolution happens inside `spawn_issue_on_worker_host` on EVERY dispatch (initial or retry) from the issue object the poller refreshed, re-resolution is structural. Pin it with a test that dispatches the same issue twice with changed labels:

```elixir
  test "a retry dispatch re-resolves labels (label edits take effect on next attempt)" do
    orchestrator_name = Module.concat(__MODULE__, :RetryResolveOrch)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    base = %Issue{
      id: "iss-retry-1",
      identifier: "MT-503",
      title: "Retry resolve",
      state: "Todo",
      url: "https://example.org/MT-503",
      labels: []
    }

    :ok = Orchestrator.dispatch_issue_for_test(pid, base)
    assert %{running: [first]} = GenServer.call(pid, :snapshot)
    assert first.effort == nil

    :ok = Orchestrator.kill_issue_for_test(pid, "iss-retry-1")

    :ok = Orchestrator.dispatch_issue_for_test(pid, %{base | labels: ["effort:max"]})
    assert %{running: [second]} = GenServer.call(pid, :snapshot)
    assert second.effort == "max"
  end
```

(`kill_issue_for_test/2`: if absent, add a `@doc false` helper delegating to the existing kill/terminate call the dashboard's `kill_issue` uses — grep `handle_call({:kill_issue` in orchestrator.ex and reuse that message.)

- [ ] **Step 2: Presenter + completion record fields**

- `presenter.ex`: running-entry map pass-through gains `agent_kind`, `model`, `effort` (same `Map.get(entry, :agent_kind)` style as `provider`); apply in BOTH the LiveView payload path and the API JSON path (grep for where `provider:` is copied — 3 places from the audit: lines ~126, ~372, ~433 pre-rename).
- `orchestrator.ex` `build_completed_record/3` gains:

```elixir
      agent_kind: Map.get(running_entry, :agent_kind),
      model: Map.get(running_entry, :model),
```

- `completion_store.ex`: add columns `agent_kind TEXT` and `model TEXT` to `@schema` CREATE TABLE, plus additive migration entries (same ignore-errors pattern as the Spec A column renames):

```elixir
  @column_adds [
    "ALTER TABLE sessions ADD COLUMN agent_kind TEXT",
    "ALTER TABLE sessions ADD COLUMN model TEXT"
  ]
```

executed in `open_and_migrate/1` (`Enum.each(@column_adds, &(_ = Sqlite3.execute(db, &1)))`, errors ignored — "duplicate column" on fresh DBs that already have it). Extend `write_record`/`record_to_params`/`read_recent` SELECT/`row_to_map` with the two fields.

Completion-store test — the file already has `start_store!/1`, `put_record/2`, and `sync/1` helpers; note `put_record`'s base map uses the post-Spec-A key names (`input_tokens` etc. after that rename lands — if executing B before A's Task 9, keep `claude_*`):

```elixir
  test "persists and reads agent_kind and model", %{path: path, name: name} do
    {_pid, name} = start_store!(path: path, name: name)

    put_record(name, issue_id: "spec-b", agent_kind: "codex", model: "gpt-5.2-codex")
    :ok = sync(name)

    assert [row] = CompletionStore.recent("p1", 10, name)
    assert row.agent_kind == "codex"
    assert row.model == "gpt-5.2-codex"
  end

  test "rows written before the agent columns existed read back as nil", %{path: path, name: name} do
    {_pid, name} = start_store!(path: path, name: name)
    put_record(name, issue_id: "old-row")
    :ok = sync(name)

    assert [row] = CompletionStore.recent("p1", 10, name)
    assert row.agent_kind == nil
    assert row.model == nil
  end
```

- [ ] **Step 3: Run, docs, commit**

Run: `mix test && make fmt && make lint`
Expected: PASS.

Docs: `SPEC.md` §8.2 (candidate selection) gains a "Per-issue run spec resolution" subsection with the precedence list and label/directive grammar from the spec; `CLAUDE.md` + `README.md` get a "Per-issue overrides" section:

```markdown
### Per-issue agent/model/effort

Add Linear labels — `agent:codex`, `model:gpt-5.2-codex`, `effort:high`, `provider:cz1` —
or a directive line in the issue description:

    cymphony: agent=codex model=gpt-5.2-codex effort=high

Labels win over the directive; both win over project config. Changes apply on
the next dispatch/retry (running sessions keep their spec).
```

Run: `make all`
Expected: PASS.

```bash
git add -A && git commit -m "run spec: retry re-resolution pinned by test; presenter/store expose agent_kind+model; docs"
```

---

## Plan self-review notes

- Spec coverage: labels (T1), directive (T2), precedence+resolve (T3), dispatch resolution + pinning + kind-aware provider + logging with source (T4), generalized override minus agent-kind (T5), retry re-resolution + observability surfacing + docs (T6). "Pinned per run attempt" is structural (resolution only in spawn path; resume loop never re-resolves) and additionally locked by T6's test pair.
- Prompt untouched per spec ("Interaction with prompt: none").
- Type consistency: `overrides`/`resolved` maps defined in T1/T3 and used as-is in T4–T6; override opt keys (`:model_override`/`:effort_override`/`:provider_override`) consistent between T4 and T5.