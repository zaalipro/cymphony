# Dashboard Overhaul (Spec C) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reorganize the dashboard (settings drawer, metrics strip, project cards) and make it configurable: agent/model/effort controls per project, per-session restart-with-overrides, collapsible/hideable sections, density/column/completions-length display prefs.

**Architecture:** Server-side controls follow the existing `Control` → `Orchestrator` + `CymphonyConfig` persistence pattern (one new `set_agent_settings` verb + `POST /api/v1/agent`). Display preferences are pure client-side: a small vanilla-JS block in `layouts.ex` (same pattern as the shipped theme toggle) sets `data-*` attributes on `<html>` persisted in localStorage under `cymphony-prefs`; CSS keys off the attributes, so LiveView patches never clobber them.

**Tech Stack:** Phoenix LiveView 1.1, vanilla JS in `layouts.ex`, CSS in `priv/static/dashboard.css`. Depends on Specs A+B merged (`agent_kind`/`model`/`effort` in config, running entries, completions; `set_issue_run_spec`).

**Spec:** `docs/superpowers/specs/2026-07-16-dashboard-overhaul-design.md`

---

## File map

| File | Role |
|---|---|
| `lib/cymphony_elixir/cymphony/config.ex` | `update_agent_settings/2` persistence |
| `lib/cymphony_elixir/orchestrator.ex` | `set_agent_settings/2` runtime update |
| `lib/cymphony_elixir_web/control.ex` | `set_agent_settings/2` + `parse_agent_settings/1` |
| `lib/cymphony_elixir_web/controllers/observability_api_controller.ex` | `POST /api/v1/agent` |
| `lib/cymphony_elixir_web/router.ex` | route |
| `lib/cymphony_elixir_web/presenter.ex` | project-level `agent_kind`/`model`/`effort` for prefills |
| `lib/cymphony_elixir_web/live/dashboard_live.ex` | drawer, metrics strip, header controls, chips, override form, completions |
| `lib/cymphony_elixir_web/components/layouts.ex` | prefs JS |
| `priv/static/dashboard.css` | drawer, density, visibility, column CSS |

---

### Task 1: Persistence + orchestrator verb (`agent`/`model`/`effort`)

**Files:**
- Modify: `lib/cymphony_elixir/cymphony/config.ex`, `lib/cymphony_elixir/orchestrator.ex`
- Test: `test/cymphony_elixir/cymphony_config_agent_settings_test.exs` (new; async: false because it mutates `:config_dir_override`)

- [ ] **Step 1: Write failing config test**

Note: `cymphony_config_test.exs` is `async: true`, and these tests mutate the global `:config_dir_override` — async is module-level in ExUnit, so put them in a NEW file `test/cymphony_elixir/cymphony_config_agent_settings_test.exs` with `use ExUnit.Case, async: false` (setup copied from `control_test.exs`):

```elixir
  describe "update_agent_settings/2" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "cymphony-agentcfg-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      File.write!(
        Path.join(tmp, "config.json"),
        ~s({"projects": [{"name": "alpha"}, {"name": "beta"}]})
      )

      Application.put_env(:cymphony_elixir, :config_dir_override, tmp)

      on_exit(fn ->
        Application.delete_env(:cymphony_elixir, :config_dir_override)
        File.rm_rf!(tmp)
      end)

      :ok
    end

    test "writes agent/model/effort keys onto the named project" do
      assert :ok =
               CymphonyElixir.Cymphony.Config.update_agent_settings("alpha", %{
                 "agent" => "codex",
                 "model" => "gpt-5.2-codex",
                 "effort" => "high"
               })

      {:ok, config} = CymphonyElixir.Cymphony.Config.load()
      {:ok, alpha} = CymphonyElixir.Cymphony.Config.find_project(config, "alpha")
      assert alpha["agent"] == "codex"
      assert alpha["model"] == "gpt-5.2-codex"
      assert alpha["effort"] == "high"
    end

    test "omitted keys are left untouched; empty string clears" do
      assert :ok = CymphonyElixir.Cymphony.Config.update_agent_settings("alpha", %{"model" => "opus"})
      assert :ok = CymphonyElixir.Cymphony.Config.update_agent_settings("alpha", %{"model" => ""})

      {:ok, config} = CymphonyElixir.Cymphony.Config.load()
      {:ok, alpha} = CymphonyElixir.Cymphony.Config.find_project(config, "alpha")
      refute Map.has_key?(alpha, "model")
    end

    test "rejects unknown agent kinds" do
      assert {:error, :invalid_agent_kind} =
               CymphonyElixir.Cymphony.Config.update_agent_settings("alpha", %{"agent" => "gemini"})
    end
  end
```

Run: `mix test test/cymphony_elixir/cymphony_config_agent_settings_test.exs`
Expected: FAIL — `update_agent_settings/2` undefined.

- [ ] **Step 2: Implement `update_agent_settings/2`**

In `lib/cymphony_elixir/cymphony/config.ex`, modeled on `update_concurrency/2`:

```elixir
  @agent_setting_keys ["agent", "model", "effort"]

  @doc """
  Merges agent settings (`"agent"`, `"model"`, `"effort"`) onto the named
  project (or all projects when `project_name` is nil) and saves. Keys absent
  from `settings` are untouched; empty-string values delete the key.
  """
  @spec update_agent_settings(String.t() | nil, map()) ::
          :ok | {:error, :invalid_agent_kind | term()}
  def update_agent_settings(project_name, settings) when is_map(settings) do
    with :ok <- validate_agent_kind(Map.get(settings, "agent")),
         {:ok, config} <- load(),
         {:ok, updated} <- apply_agent_settings(config, project_name, settings) do
      save(updated)
    end
  end

  defp validate_agent_kind(nil), do: :ok
  defp validate_agent_kind(kind) when kind in ["claude", "codex"], do: :ok
  defp validate_agent_kind(_kind), do: {:error, :invalid_agent_kind}

  defp apply_agent_settings(%{"projects" => projects} = config, project_name, settings)
       when is_list(projects) do
    updated_projects =
      Enum.map(projects, fn project ->
        if project_name == nil or Map.get(project, "name") == project_name do
          merge_agent_settings(project, settings)
        else
          project
        end
      end)

    {:ok, Map.put(config, "projects", updated_projects)}
  end

  defp apply_agent_settings(config, _project_name, settings) when is_map(config) do
    {:ok, merge_agent_settings(config, settings)}
  end

  defp merge_agent_settings(map, settings) do
    Enum.reduce(@agent_setting_keys, map, fn key, acc ->
      case Map.fetch(settings, key) do
        {:ok, ""} -> Map.delete(acc, key)
        {:ok, value} when is_binary(value) -> Map.put(acc, key, value)
        _ -> acc
      end
    end)
  end
```

- [ ] **Step 3: Orchestrator runtime verb**

In `lib/cymphony_elixir/orchestrator.ex` (next to `set_providers`):

```elixir
  @spec set_agent_settings(GenServer.server(), map()) :: :ok | :unavailable
  def set_agent_settings(server, settings) when is_map(settings) do
    GenServer.call(server, {:set_agent_settings, settings})
  catch
    :exit, _ -> :unavailable
  end
```

```elixir
  def handle_call({:set_agent_settings, settings}, _from, state) do
    new_config =
      case state.config do
        nil ->
          state.config

        config ->
          agent = config.agent

          agent = %{
            agent
            | kind: normalized_setting(settings, "agent", agent.kind),
              model: cleared_setting(settings, "model", agent.model),
              effort: cleared_setting(settings, "effort", agent.effort)
          }

          %{config | agent: agent}
      end

    Logger.info("Agent settings updated: #{inspect(Map.take(settings, ["agent", "model", "effort"]))}")
    notify_dashboard()
    {:reply, :ok, %{state | config: new_config, providers: extract_providers(new_config)}}
  end
```

```elixir
  # "agent" must stay a valid kind; absent/invalid keeps the current value.
  defp normalized_setting(settings, key, current) do
    case Map.get(settings, key) do
      value when value in ["claude", "codex"] -> value
      _ -> current
    end
  end

  # model/effort: absent keeps current; "" clears to nil (agent default).
  defp cleared_setting(settings, key, current) do
    case Map.fetch(settings, key) do
      {:ok, ""} -> nil
      {:ok, value} when is_binary(value) -> value
      _ -> current
    end
  end
```

(`providers` re-extracted because switching kinds switches the rotation source section.)

- [ ] **Step 4: Run, commit**

Run: `mix test test/cymphony_elixir/cymphony_config_agent_settings_test.exs && mix test`
Expected: PASS.

```bash
git add -A && git commit -m "config+orchestrator: set_agent_settings (kind/model/effort) with persistence"
```

---

### Task 2: `Control.set_agent_settings` + `POST /api/v1/agent`

**Files:**
- Modify: `lib/cymphony_elixir_web/control.ex`, `lib/cymphony_elixir_web/controllers/observability_api_controller.ex`, `lib/cymphony_elixir_web/router.ex`
- Test: `test/cymphony_elixir/control_test.exs` (Control fan-out) and `test/cymphony_elixir/extensions_test.exs` (endpoint: it already exercises `/api/v1/*` with `build_conn()`/`json_response`; put the `/api/v1/agent` cases beside those)

- [ ] **Step 1: Failing Control test**

Add to `test/cymphony_elixir/control_test.exs` (reusing its FakeOrch harness):

```elixir
    test "set_agent_settings fans out to orchestrators and persists", %{tmp: tmp} do
      start_orch!("alpha")
      start_orch!("beta")

      assert :ok = Control.set_agent_settings(:all, %{"agent" => "codex", "effort" => "high"})

      assert_receive {:orch, _, {:set_agent_settings, %{"agent" => "codex", "effort" => "high"}}}
      assert_receive {:orch, _, {:set_agent_settings, %{"agent" => "codex", "effort" => "high"}}}

      config = tmp |> Path.join("config.json") |> File.read!() |> Jason.decode!()
      assert Enum.all?(config["projects"], &(&1["agent"] == "codex"))
    end

    test "parse_agent_settings validates kind and normalizes params" do
      assert {:ok, %{"agent" => "codex", "model" => "m", "effort" => "high"}} =
               Control.parse_agent_settings(%{"kind" => "codex", "model" => "m", "effort" => "high"})

      assert {:ok, %{"model" => "m"}} = Control.parse_agent_settings(%{"model" => "m"})
      assert :error = Control.parse_agent_settings(%{"kind" => "gemini"})
      assert :error = Control.parse_agent_settings(%{})
    end
```

Run: `mix test test/cymphony_elixir/control_test.exs`
Expected: FAIL.

- [ ] **Step 2: Implement Control + controller + route**

`control.ex`:

```elixir
  @spec set_agent_settings(scope(), map()) :: :ok | {:error, :not_found}
  def set_agent_settings(scope, settings) when is_map(settings) do
    apply_scope(
      scope,
      &Orchestrator.set_agent_settings(&1, settings),
      fn project -> CymphonyConfig.update_agent_settings(project, settings) end
    )
  end

  @doc """
  Parses API/LiveView agent-settings params (`kind`/`model`/`effort`, all
  optional but at least one required) into the settings map `update_agent_settings`
  accepts. Returns `:error` on unknown kind or no recognized keys.
  """
  @spec parse_agent_settings(map()) :: {:ok, map()} | :error
  def parse_agent_settings(params) when is_map(params) do
    settings =
      %{}
      |> put_param(params, "kind", "agent")
      |> put_param(params, "model", "model")
      |> put_param(params, "effort", "effort")

    cond do
      map_size(settings) == 0 -> :error
      Map.get(settings, "agent") not in [nil, "claude", "codex"] -> :error
      true -> {:ok, settings}
    end
  end

  defp put_param(settings, params, from_key, to_key) do
    case Map.get(params, from_key) do
      value when is_binary(value) -> Map.put(settings, to_key, String.trim(value))
      _ -> settings
    end
  end
```

`observability_api_controller.ex` (beside `concurrency/2`):

```elixir
  @spec agent(Conn.t(), map()) :: Conn.t()
  def agent(conn, params) do
    project = params["project"]

    case Control.parse_agent_settings(params) do
      {:ok, settings} ->
        Control.set_agent_settings(Control.scope(project), settings)

        conn
        |> put_status(202)
        |> json(%{agent: settings["agent"], model: settings["model"], effort: settings["effort"], project: project})

      :error ->
        error_response(
          conn,
          422,
          "invalid_agent_settings",
          "body must include at least one of kind/model/effort; kind must be claude or codex"
        )
    end
  end
```

`router.ex`, after the `/api/v1/providers` pair:

```elixir
    post("/api/v1/agent", ObservabilityApiController, :agent)
    match(:*, "/api/v1/agent", ObservabilityApiController, :method_not_allowed)
```

(Order matters: it must precede the `get("/api/v1/:issue_identifier", …)` catch-all — the providers block already does, put it adjacent.)

- [ ] **Step 3: Controller test**

Beside the existing concurrency-endpoint test (grep `"/api/v1/concurrency"` under test/):

```elixir
  test "POST /api/v1/agent updates settings and 202s; validates kind" do
    conn = post(build_conn(), "/api/v1/agent", %{"kind" => "codex", "effort" => "high"})
    assert conn.status == 202
    assert %{"agent" => "codex", "effort" => "high"} = Jason.decode!(conn.resp_body)

    conn = post(build_conn(), "/api/v1/agent", %{"kind" => "gemini"})
    assert conn.status == 422
  end
```

(`extensions_test.exs` already imports the ConnTest helpers — `post(build_conn(), "/api/v1/refresh", %{})` is an existing pattern in that file; mirror it.)

- [ ] **Step 4: Run, commit**

Run: `mix test test/cymphony_elixir/control_test.exs && mix test`
Expected: PASS.

```bash
git add -A && git commit -m "web: Control.set_agent_settings + POST /api/v1/agent"
```

---

### Task 3: Project-card header controls (agent select, model input, effort select) + providers relabel

**Files:**
- Modify: `lib/cymphony_elixir_web/presenter.ex`, `lib/cymphony_elixir_web/live/dashboard_live.ex`
- Test: `test/cymphony_elixir/extensions_test.exs` — the repo's ConnTest+LiveViewTest harness (`build_conn()`, `json_response/2`, `live(build_conn(), "/")`); add the new cases beside the existing dashboard tests there

- [ ] **Step 1: Presenter prefill fields**

In `presenter.ex`, where each project map is built (grep `max_concurrent_agents:` in the projects assembly), add from the project's orchestrator snapshot config:

```elixir
        agent_kind: get_in_snapshot(snapshot, :agent_kind),
        agent_model: get_in_snapshot(snapshot, :agent_model),
        agent_effort: get_in_snapshot(snapshot, :agent_effort),
```

backed by extending the orchestrator `:snapshot` reply (Spec A already added `agent_kind:`; add `agent_model: state.config.agent.model, agent_effort: state.config.agent.effort` beside it).

- [ ] **Step 2: Failing LiveView test**

```elixir
  test "project header renders agent controls and submits set_project_agent" do
    orchestrator_name = Module.concat(__MODULE__, :AgentControlsOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: static_snapshot())
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")

    assert html =~ ~s(name="agent_kind")
    assert html =~ ~s(list="model-suggestions-)
    assert html =~ "providers</label>" or html =~ ">providers<"
    refute html =~ "claude command"

    view
    |> form("form[phx-submit=set_project_agent]", %{
      "project" => project_name_from_fixture(),
      "agent_kind" => "codex",
      "model" => "gpt-5.2-codex",
      "effort" => "high"
    })
    |> render_submit()

    # assert flash or payload reflects the change per the harness's pattern
  end
```

(Shape this against the file's existing `set_project_concurrency` test — same fixtures, same submit helper. The load-bearing assertions: the three inputs exist, the old "claude command" label is gone, submit routes to `Control.set_agent_settings`.)

- [ ] **Step 3: Implement markup + handler**

In `dashboard_live.ex` project-section-controls `<div>`, after the concurrency form, replace the providers form label `claude command` with `providers`, and insert:

```heex
                <form phx-submit="set_project_agent" class="inline-form inline-form--agent">
                  <input type="hidden" name="project" value={project.name} />
                  <label class="inline-label" for={"agent-#{project.name}"}>agent</label>
                  <select id={"agent-#{project.name}"} name="agent_kind" class="inline-input inline-input--narrow" phx-change="noop">
                    <option value="claude" selected={Map.get(project, :agent_kind) != "codex"}>claude</option>
                    <option value="codex" selected={Map.get(project, :agent_kind) == "codex"}>codex</option>
                  </select>

                  <label class="inline-label" for={"model-#{project.name}"}>model</label>
                  <input
                    id={"model-#{project.name}"}
                    type="text"
                    name="model"
                    value={Map.get(project, :agent_model) || ""}
                    placeholder="default"
                    list={"model-suggestions-#{project.name}"}
                    class="inline-input"
                  />
                  <datalist id={"model-suggestions-#{project.name}"}>
                    <%= for m <- model_suggestions(Map.get(project, :agent_kind)) do %>
                      <option value={m}></option>
                    <% end %>
                  </datalist>

                  <label class="inline-label" for={"effort-#{project.name}"}>effort</label>
                  <select id={"effort-#{project.name}"} name="effort" class="inline-input inline-input--narrow">
                    <option value="" selected={Map.get(project, :agent_effort) in [nil, ""]}>default</option>
                    <%= for level <- effort_levels(Map.get(project, :agent_kind)) do %>
                      <option value={level} selected={Map.get(project, :agent_effort) == level}><%= level %></option>
                    <% end %>
                  </select>

                  <button type="submit" class="subtle-button">Set</button>
                </form>
```

Handler + helpers:

```elixir
  @impl true
  def handle_event("set_project_agent", %{"project" => project_name} = params, socket) do
    case Control.parse_agent_settings(Map.take(params, ["model", "effort"]) |> Map.put("kind", params["agent_kind"])) do
      {:ok, settings} ->
        case Control.set_agent_settings({:project, project_name}, settings) do
          :ok ->
            {:noreply, reload_payload_now(put_flash(socket, :info, "#{project_name}: agent settings updated"))}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Project not found: #{project_name}")}
        end

      :error ->
        {:noreply, put_flash(socket, :error, "Agent must be claude or codex")}
    end
  end

  @impl true
  def handle_event("noop", _params, socket), do: {:noreply, socket}
```

```elixir
  defp model_suggestions("codex"), do: ["gpt-5.2-codex", "gpt-5.2", "o4-mini"]
  defp model_suggestions(_kind), do: ["sonnet", "opus", "haiku"]

  defp effort_levels("codex"), do: ["minimal", "low", "medium", "high", "xhigh"]
  defp effort_levels(_kind), do: ["low", "medium", "high", "xhigh", "max"]
```

(Suggestions are convenience only — free text is allowed since values are pass-through. The `phx-change="noop"` on the kind select triggers a re-render so effort options follow the kind; simplest correct wiring without JS.)

Note: `phx-change` on a `<select>` inside a form posts the whole form params; `noop` just re-renders with current assigns. For the effort options to actually switch on kind change without submitting, upgrade later if needed — acceptable v1 behavior: options switch after Set (documented in the test).

- [ ] **Step 4: Run, commit**

Run: `mix test test/cymphony_elixir/extensions_test.exs && mix test`
Expected: PASS.

```bash
git add -A && git commit -m "dashboard: per-project agent/model/effort controls; providers input relabeled"
```

---

### Task 4: Session-row chips + restart-with-overrides form + completions columns

**Files:**
- Modify: `lib/cymphony_elixir_web/live/dashboard_live.ex`, `lib/cymphony_elixir_web/presenter.ex`
- Test: `test/cymphony_elixir/extensions_test.exs`

- [ ] **Step 1: Failing test**

```elixir
  test "running rows show agent/model/effort chips and expanded row has override form" do
    orchestrator_name = Module.concat(__MODULE__, :ChipsOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: static_snapshot())
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ ~s(chip chip--agent)
    assert html =~ "gpt-5.2-codex"

    expanded =
      view
      |> element(~s|button[phx-click="toggle_logs"][phx-value-issue="MT-HTTP"]|)
      |> render_click()

    assert expanded =~ ~s(phx-submit="set_issue_run_spec")
    assert expanded =~ ~s(name="provider")
    assert expanded =~ ~s(name="model")
    assert expanded =~ ~s(name="effort")
    refute expanded =~ ~s(name="agent_kind" phx-submit="set_issue_run_spec")
  end
```

(Seed via the mechanism `extensions_test.exs` already uses for its `/api/v1/state` and `live(build_conn(), "/")` tests: a `StaticOrchestrator` started with the `static_snapshot()` fixture plus `start_test_endpoint(orchestrator: name, snapshot_timeout_ms: 50)`. Add `agent_kind: "codex", model: "gpt-5.2-codex", effort: "high"` to the running entry inside `static_snapshot()` — the existing `/api/v1/state` assertion map then needs the same three keys added, which doubles as the API pass-through test.)

- [ ] **Step 2: Implement**

Chips row (`session-row-chips` div), after the provider chip:

```heex
                        <%= if Map.get(entry, :agent_kind) do %>
                          <span class="chip chip--agent"><%= entry.agent_kind %></span>
                        <% end %>
                        <%= if Map.get(entry, :model) do %>
                          <span class="chip chip--muted chip--truncate" title={entry.model}><%= entry.model %></span>
                        <% end %>
                        <%= if Map.get(entry, :effort) do %>
                          <span class="chip chip--muted"><%= entry.effort %></span>
                        <% end %>
```

Expanded detail: replace the per-session provider form (`phx-submit="set_provider"` block) with:

```heex
                          <div class="session-stat session-stat--wide">
                            <span class="session-stat-label">Restart with</span>
                            <form phx-submit="set_issue_run_spec" class="inline-form">
                              <input type="hidden" name="issue" value={entry.issue_identifier} />
                              <input type="text" name="provider" value={entry.provider || ""} placeholder="provider" class="inline-input inline-input--narrow" />
                              <input type="text" name="model" value={Map.get(entry, :model) || ""} placeholder="model" class="inline-input inline-input--narrow" />
                              <input type="text" name="effort" value={Map.get(entry, :effort) || ""} placeholder="effort" class="inline-input inline-input--narrow" />
                              <button type="submit" class="subtle-button">Set</button>
                            </form>
                          </div>
```

Handler (replaces `set_provider`; Spec B already generalized the orchestrator side):

```elixir
  @impl true
  def handle_event("set_issue_run_spec", %{"issue" => issue_identifier} = params, socket) do
    entry =
      Enum.find(socket.assigns.payload.running, &(&1.issue_identifier == issue_identifier)) || %{}

    issue_id = Map.get(entry, :issue_id)

    overrides =
      %{}
      |> maybe_override_param(:provider, params["provider"])
      |> maybe_override_param(:model, params["model"])
      |> maybe_override_param(:effort, params["effort"])

    if is_binary(issue_id) and map_size(overrides) > 0 do
      send_issue_run_spec(socket, entry, issue_id, overrides)
    end

    {:noreply, socket}
  end

  defp maybe_override_param(map, _key, nil), do: map
  defp maybe_override_param(map, _key, ""), do: map
  defp maybe_override_param(map, key, value) when is_binary(value), do: Map.put(map, key, String.trim(value))
```

`send_issue_run_spec/4`: copy `send_set_provider/4`'s project-scoped orchestrator lookup, calling `Orchestrator.set_issue_run_spec(orch_pid, issue_id, overrides)`.

Completions rows: add after the Done chip:

```heex
                      <%= if Map.get(entry, :agent_kind) do %>
                        <span class="chip chip--agent"><%= entry.agent_kind %></span>
                      <% end %>
                      <%= if Map.get(entry, :model) do %>
                        <span class="chip chip--muted chip--truncate" title={entry.model}><%= entry.model %></span>
                      <% end %>
```

(`entry.claude_total_tokens` in completions is already `total_tokens` after Spec A's rename — verify while here.) Presenter: ensure completions maps pass `agent_kind`/`model` through (Spec B added them to the store; grep the completions assembly in presenter.ex and add the two `Map.get`s if missing).

- [ ] **Step 3: Run, commit**

Run: `mix test && make fmt`
Expected: PASS.

```bash
git add -A && git commit -m "dashboard: agent/model/effort chips, restart-with-overrides form, completions columns"
```

---

### Task 5: Layout reorganization — settings drawer + metrics strip

**Files:**
- Modify: `lib/cymphony_elixir_web/live/dashboard_live.ex`, `priv/static/dashboard.css`
- Test: `test/cymphony_elixir/extensions_test.exs`

- [ ] **Step 1: Failing test**

```elixir
  test "settings drawer exists with orchestrator controls; ops row controls moved out of header" do
    orchestrator_name = Module.concat(__MODULE__, :DrawerOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: static_snapshot())
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ ~s(class="settings-drawer")
    assert html =~ ~s(data-drawer-toggle)
    # global pause + global concurrency now render inside the drawer:
    assert html =~ ~s(id="drawer-global-concurrency")
    # display prefs section present:
    assert html =~ ~s(data-pref="density")
    assert html =~ ~s(data-pref-section="completions")
  end
```

- [ ] **Step 2: Implement markup**

a. Top bar: add before the Refresh button:

```heex
            <button type="button" class="subtle-button" data-drawer-toggle aria-label="Settings">⚙</button>
```

b. Drawer markup, inserted directly after the `</header>` close of `command-bar` (sibling, so it overlays):

```heex
      <aside class="settings-drawer" aria-label="Dashboard settings">
        <div class="settings-drawer-header">
          <h2 class="section-title">Settings</h2>
          <button type="button" class="subtle-button" data-drawer-toggle>Close</button>
        </div>

        <section class="settings-group">
          <h3 class="settings-group-title">Orchestrator</h3>

          <%= if @payload.polling do %>
            <%= if Map.get(@payload.polling, :paused, false) do %>
              <button type="button" class="subtle-button subtle-button--accent" phx-click="resume_dispatch">Resume all projects</button>
            <% else %>
              <button type="button" class="subtle-button" phx-click="pause_dispatch">Pause all projects</button>
            <% end %>
          <% end %>

          <form phx-submit="set_concurrency" class="inline-form">
            <label class="inline-label" for="drawer-global-concurrency">global concurrency</label>
            <input id="drawer-global-concurrency" type="number" name="value" min="1" class="inline-input inline-input--narrow" />
            <button type="submit" class="subtle-button">Set</button>
          </form>
        </section>

        <section class="settings-group" data-prefs>
          <h3 class="settings-group-title">Display</h3>

          <div class="settings-row">
            <span class="inline-label">density</span>
            <label><input type="radio" name="pref-density" data-pref="density" value="comfortable" checked /> comfortable</label>
            <label><input type="radio" name="pref-density" data-pref="density" value="compact" /> compact</label>
          </div>

          <div class="settings-row">
            <span class="inline-label">sections</span>
            <%= for {label, key} <- [{"Metrics", "metrics"}, {"Rate limits", "ratelimits"}, {"Polling", "polling"}, {"Completions", "completions"}] do %>
              <label><input type="checkbox" data-pref-section={key} checked /> <%= label %></label>
            <% end %>
          </div>

          <div class="settings-row">
            <span class="inline-label">columns</span>
            <%= for {label, key} <- [{"Title", "title"}, {"Chips", "chips"}, {"Runtime", "runtime"}, {"Tokens", "tokens"}] do %>
              <label><input type="checkbox" data-pref-col={key} checked /> <%= label %></label>
            <% end %>
          </div>

          <div class="settings-row">
            <span class="inline-label">completions shown</span>
            <select data-pref="completions-limit" class="inline-input inline-input--narrow">
              <option value="25">25</option>
              <option value="50">50</option>
              <option value="100" selected>100</option>
            </select>
          </div>
        </section>
      </aside>
```

c. Remove the global Pause/Resume cluster from the ops row (it moved into the drawer). The metrics row and ops row merge into one `command-bar-row--metrics` strip: keep the five metric pills, append the polling cluster and the rate-limit cluster as compact `metric-pill` variants (`metric-pill--ops`), each wrapped with a section marker class for hideability:

This is a **move, not a rewrite**: keep the five existing `metric-pill` divs (Run, Retry, Tokens, Runtime, Tput — dashboard_live.ex renders them today inside `command-bar-row--metrics`) byte-identical, and relocate the two `ops-cluster` blocks (the `@payload.polling` countdown cluster and the `Presenter.format_rate_limits_for_web` limits cluster) from the now-deleted `command-bar-row--ops` row into the same strip, rewrapped:

```heex
          <div class="command-bar-row command-bar-row--metrics section--metrics">
            <!-- five existing metric-pill divs, unchanged -->
            <div class="metric-pill metric-pill--ops section--polling">
              <!-- body of today's polling ops-cluster, unchanged: label, paused/checking/countdown span, interval -->
            </div>
            <div class="metric-pill metric-pill--ops section--ratelimits">
              <!-- body of today's limits ops-cluster, unchanged: primary/secondary/credits spans -->
            </div>
          </div>
```

The `command-bar-row--ops` wrapper div is then deleted entirely (its third child, the global Pause/Resume cluster, moved into the drawer in step b).

d. Wrap the completions `<section class="section-card">` as `class="section-card section--completions"` and give every collapsible section header a `data-collapse-toggle={key}` button (`▾`). Sections with markers: `metrics`, `polling`, `ratelimits`, `completions` (project cards always show).

e. CSS in `priv/static/dashboard.css` (append; adjust palette vars to the file's existing custom properties):

```css
/* — settings drawer — */
.settings-drawer {
  position: fixed;
  top: 0;
  right: 0;
  height: 100vh;
  width: 320px;
  transform: translateX(100%);
  transition: transform 160ms ease;
  z-index: 40;
  overflow-y: auto;
  padding: 16px;
  background: var(--surface, #fff);
  border-left: 1px solid var(--border, #ddd);
}

html[data-drawer="open"] .settings-drawer { transform: translateX(0); }

.settings-group { margin-top: 20px; display: flex; flex-direction: column; gap: 10px; }
.settings-group-title { font-size: 12px; text-transform: uppercase; letter-spacing: 0.08em; opacity: 0.7; }
.settings-row { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }

/* — density — */
html[data-density="compact"] .session-row-summary { padding-top: 2px; padding-bottom: 2px; font-size: 12px; }
html[data-density="compact"] .metric-pill { padding: 2px 8px; }
html[data-density="compact"] .project-section { margin-bottom: 8px; }

/* — section visibility + collapse — */
html[data-hidden-sections~="metrics"] .section--metrics,
html[data-hidden-sections~="polling"] .section--polling,
html[data-hidden-sections~="ratelimits"] .section--ratelimits,
html[data-hidden-sections~="completions"] .section--completions { display: none; }

html[data-collapsed-sections~="completions"] .section--completions .session-row-list { display: none; }
html[data-collapsed-sections~="metrics"] .section--metrics > :not(.section-collapse-header) { display: none; }

/* — column visibility — */
html[data-hidden-cols~="title"] .session-row-title { display: none; }
html[data-hidden-cols~="chips"] .session-row-chips { display: none; }
html[data-hidden-cols~="runtime"] .session-row-runtime { display: none; }
html[data-hidden-cols~="tokens"] .session-row-tokens { display: none; }

/* — completions length — */
html[data-completions-limit="25"] .section--completions .session-row:nth-child(n+26) { display: none; }
html[data-completions-limit="50"] .section--completions .session-row:nth-child(n+51) { display: none; }

/* — chips — */
.chip--agent { background: var(--accent-soft, #e8f0fe); }
.chip--truncate { max-width: 140px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
```

- [ ] **Step 3: Run, commit**

Run: `mix test`
Expected: PASS.

```bash
git add -A && git commit -m "dashboard: settings drawer, unified metrics strip, section markers + css hooks"
```

---

### Task 6: Client-side prefs JS (localStorage ↔ data-attributes)

**Files:**
- Modify: `lib/cymphony_elixir_web/components/layouts.ex`
- Test: LiveView render assertion only (JS is test-exempt like the theme toggle)

- [ ] **Step 1: Implement the prefs script**

In `layouts.ex`, extend the existing inline `<script>` blocks (same file section as the theme code). Head script (runs before paint, avoids pref-flash — beside the theme restore):

```javascript
            try {
              var prefs = JSON.parse(localStorage.getItem('cymphony-prefs') || '{}');
              var html = document.documentElement;
              if (prefs.density) html.setAttribute('data-density', prefs.density);
              if (prefs.hiddenSections && prefs.hiddenSections.length) html.setAttribute('data-hidden-sections', prefs.hiddenSections.join(' '));
              if (prefs.collapsedSections && prefs.collapsedSections.length) html.setAttribute('data-collapsed-sections', prefs.collapsedSections.join(' '));
              if (prefs.hiddenCols && prefs.hiddenCols.length) html.setAttribute('data-hidden-cols', prefs.hiddenCols.join(' '));
              if (prefs.completionsLimit) html.setAttribute('data-completions-limit', prefs.completionsLimit);
            } catch (e) {}
```

Body script (delegated listeners, beside the theme click handler):

```javascript
            (function () {
              var html = document.documentElement;

              function readPrefs() {
                try { return JSON.parse(localStorage.getItem('cymphony-prefs') || '{}'); } catch (e) { return {}; }
              }

              function writePrefs(prefs) {
                try { localStorage.setItem('cymphony-prefs', JSON.stringify(prefs)); } catch (e) {}
              }

              function setToken(attr, key, on) {
                var tokens = (html.getAttribute(attr) || '').split(' ').filter(Boolean);
                var idx = tokens.indexOf(key);
                if (on && idx === -1) tokens.push(key);
                if (!on && idx !== -1) tokens.splice(idx, 1);
                if (tokens.length) html.setAttribute(attr, tokens.join(' ')); else html.removeAttribute(attr);
                return tokens;
              }

              function syncControls() {
                var prefs = readPrefs();
                document.querySelectorAll('[data-pref="density"]').forEach(function (el) {
                  el.checked = (prefs.density || 'comfortable') === el.value;
                });
                document.querySelectorAll('[data-pref-section]').forEach(function (el) {
                  el.checked = !(prefs.hiddenSections || []).includes(el.getAttribute('data-pref-section'));
                });
                document.querySelectorAll('[data-pref-col]').forEach(function (el) {
                  el.checked = !(prefs.hiddenCols || []).includes(el.getAttribute('data-pref-col'));
                });
                document.querySelectorAll('[data-pref="completions-limit"]').forEach(function (el) {
                  el.value = prefs.completionsLimit || '100';
                });
              }

              document.addEventListener('click', function (e) {
                if (e.target.closest('[data-drawer-toggle]')) {
                  var open = html.getAttribute('data-drawer') === 'open';
                  if (open) html.removeAttribute('data-drawer'); else html.setAttribute('data-drawer', 'open');
                  if (!open) syncControls();
                  return;
                }

                var collapse = e.target.closest('[data-collapse-toggle]');
                if (collapse) {
                  var key = collapse.getAttribute('data-collapse-toggle');
                  var prefs = readPrefs();
                  var collapsed = prefs.collapsedSections || [];
                  var now = collapsed.includes(key) ? collapsed.filter(function (k) { return k !== key; }) : collapsed.concat([key]);
                  prefs.collapsedSections = now;
                  writePrefs(prefs);
                  setToken('data-collapsed-sections', key, now.includes(key));
                }
              });

              document.addEventListener('change', function (e) {
                var prefs = readPrefs();

                if (e.target.matches('[data-pref="density"]')) {
                  prefs.density = e.target.value;
                  if (prefs.density === 'compact') html.setAttribute('data-density', 'compact');
                  else html.removeAttribute('data-density');
                }

                if (e.target.matches('[data-pref-section]')) {
                  var key = e.target.getAttribute('data-pref-section');
                  prefs.hiddenSections = setToken('data-hidden-sections', key, !e.target.checked);
                }

                if (e.target.matches('[data-pref-col]')) {
                  var col = e.target.getAttribute('data-pref-col');
                  prefs.hiddenCols = setToken('data-hidden-cols', col, !e.target.checked);
                }

                if (e.target.matches('[data-pref="completions-limit"]')) {
                  prefs.completionsLimit = e.target.value;
                  if (prefs.completionsLimit === '100') html.removeAttribute('data-completions-limit');
                  else html.setAttribute('data-completions-limit', prefs.completionsLimit);
                }

                writePrefs(prefs);
              });
            })();
```

- [ ] **Step 2: Render-hook assertions**

Add to the LiveView test (markup contract the JS depends on — keeps refactors honest):

```elixir
  test "pref hooks present in rendered layout" do
    orchestrator_name = Module.concat(__MODULE__, :PrefHooksOrchestrator)
    {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: static_snapshot())
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")
    for hook <- ["data-drawer-toggle", ~s(data-pref="density"), "data-pref-section", "data-pref-col", ~s(data-pref="completions-limit")] do
      assert html =~ hook
    end
  end
```

- [ ] **Step 3: Manual smoke (browser)**

Run: `mix run --no-halt` with a configured port (or `bin/cymphony port 4089` after `make build`), open the dashboard: toggle drawer, flip density/sections/columns/limit, reload page — prefs persist; kill JS (private window) — page still renders with defaults.

- [ ] **Step 4: Run gate, commit**

Run: `make all`
Expected: PASS.

```bash
git add -A && git commit -m "dashboard: client-side display prefs (density/sections/columns/completions) via localStorage data-attrs"
```

---

### Task 7: Docs

**Files:**
- Modify: `CLAUDE.md`, `README.md`, `SPEC.md`

- [ ] **Step 1: Update docs**

- `CLAUDE.md` Web Dashboard section: new Sections list (top bar / metrics strip / project cards / completions / settings drawer); user-actions table adds `set_project_agent`, `set_issue_run_spec` (replacing `set_provider`), drawer/display prefs note ("client-side, localStorage, per browser"); API table adds the `/api/v1/agent` row:

```markdown
| `/api/v1/agent` | POST | Update agent settings at runtime. JSON body `{"kind": "codex", "model": "...", "effort": "..."}` (each optional), optional `?project=<name>`. Persists to `~/.cymphony/config.json`. Applies to next dispatch. Returns 202. |
```

- `README.md`: refresh the dashboard feature bullets + screenshot note (screenshot refresh itself is a follow-up).
- `SPEC.md`: observability section gains the agent-settings control surface and the note that display preferences are client-side only (no server state).

- [ ] **Step 2: Final gate + commit**

Run: `make all`
Expected: PASS.

```bash
git add -A && git commit -m "docs: dashboard overhaul (drawer, agent controls, display prefs, /api/v1/agent)"
```

---

## Plan self-review notes

- Spec coverage: persistence+runtime verb (T1), Control+API (T2), header controls with datalist + per-kind effort vocab + providers relabel (T3), chips + restart-with-overrides + completions columns (T4), drawer + metrics strip + section markers + density/columns/limit CSS (T5), localStorage JS + no-JS graceful default (T6), docs (T7). Spec's "agent kind not offered per-session" honored in T4 (no kind input in the override form).
- Consistency: `Control.parse_agent_settings/1` params (`kind`/`model`/`effort`) match both the controller (T2) and LiveView handler (T3); `set_issue_run_spec` override keys match Spec B Task 5's map keys (`:provider`/`:model`/`:effort`).
- Known simplification (documented in T3): effort `<select>` options follow the project's *persisted* kind; they refresh after Set rather than live on kind-select change. Acceptable because values are pass-through free text anyway.