unless Code.ensure_loaded?(CymphonyElixir.HarnessStream) do
  defmodule CymphonyElixir.HarnessStream do
    @moduledoc false

    def snapshot(issue_id) when is_binary(issue_id) do
      %{issue_id: issue_id, last_seq: 0, lines: [], dropped: 0}
    end
  end
end

defmodule CymphonyElixir.DashboardLiveTest do
  use CymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias CymphonyElixir.Agent
  alias CymphonyElixir.Cymphony.Config, as: CymphonyConfig
  alias CymphonyElixirWeb.Presenter

  @endpoint CymphonyElixirWeb.Endpoint

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    @impl true
    def init(opts) do
      if project_name = Keyword.get(opts, :project_name) do
        {:ok, _} = Registry.register(CymphonyElixir.ProjectRegistry, {project_name, :orchestrator}, nil)
      end

      {:ok, opts}
    end

    @impl true
    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(call, _from, state) do
      case Keyword.get(state, :recipient) do
        pid when is_pid(pid) -> send(pid, {:orchestrator_call, call})
        _ -> :ok
      end

      {:reply, :ok, state}
    end
  end

  setup do
    endpoint_config = Application.get_env(:cymphony_elixir, CymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:cymphony_elixir, CymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "known_kinds options render in the project picker, restart form, metrics, and settings" do
    start_dashboard()
    {:ok, view, html} = live(build_conn(), "/")

    for kind <- Agent.known_kinds() do
      assert html =~ ~s(value="#{kind}")
      assert html =~ kind
    end

    assert html =~ ~s(class="metric-pill metric-pill--states section--states advanced-only")
    assert html =~ ~s(class="metric-pill metric-pill--kinds section--kinds advanced-only")
    assert html =~ "States"
    assert html =~ "Kinds"
    assert html =~ "In Progress 1"
    assert html =~ "unknown 1"
    assert html =~ ~s(data-pref-section="states")
    assert html =~ ~s(data-pref-section="kinds")
    assert html =~ ~s(data-pref-section="board")

    expanded =
      view
      |> element(~s|button[phx-click="toggle_logs"][phx-value-issue="MT-HTTP"]|)
      |> render_click()

    assert expanded =~ ~s(name="agent_kind")
    assert expanded =~ ~s(data-value="")
    assert expanded =~ "keep"
    assert expanded =~ "Restart kills the session and redispatches with these overrides."
    assert expanded =~ ~s(id="harness-tail-MT-HTTP")
    assert expanded =~ ~s(phx-hook="HarnessTail")
    assert expanded =~ "Following"

    for kind <- Agent.known_kinds() do
      assert expanded =~ ~s(value="#{kind}")
    end
  end

  test "set_issue_run_spec includes agent_kind when a known kind is selected" do
    start_dashboard(recipient: self())
    {:ok, view, _html} = live(build_conn(), "/")

    view
    |> element(~s|button[phx-click="toggle_logs"][phx-value-issue="MT-HTTP"]|)
    |> render_click()

    render_submit(view, "set_issue_run_spec", %{
      "issue" => "MT-HTTP",
      "agent_kind" => "antigravity",
      "provider" => "cv2",
      "model" => "opus",
      "effort" => ""
    })

    assert_receive {:orchestrator_call, {:set_issue_run_spec, "issue-http", overrides}}, 1_000
    assert overrides.agent_kind == "antigravity"
    assert overrides.provider == "cv2"
    assert overrides.model == "opus"
    refute Map.has_key?(overrides, :effort)
  end

  test "toggle_logs expand puts a harness_tails entry and collapse removes it" do
    start_dashboard()
    {:ok, view, _html} = live(build_conn(), "/")

    assert view_assigns(view).harness_tails == %{}

    view
    |> element(~s|button[phx-click="toggle_logs"][phx-value-issue="MT-HTTP"]|)
    |> render_click()

    tails = view_assigns(view).harness_tails
    assert Map.has_key?(tails, "MT-HTTP")
    assert tails["MT-HTTP"].issue_id == "issue-http"
    assert tails["MT-HTTP"].follow == true
    assert is_list(tails["MT-HTTP"].lines)
    assert tails["MT-HTTP"].last_seq == 0 or is_integer(tails["MT-HTTP"].last_seq)

    view
    |> element(~s|button[phx-click="toggle_logs"][phx-value-issue="MT-HTTP"]|)
    |> render_click()

    assert view_assigns(view).harness_tails == %{}
  end

  test "harness_stream handle_info appends by seq, caps, and does not touch payload" do
    start_dashboard()
    {:ok, view, _html} = live(build_conn(), "/")

    view
    |> element(~s|button[phx-click="toggle_logs"][phx-value-issue="MT-HTTP"]|)
    |> render_click()

    payload_before = view_payload(view)
    refresh_before = view_assigns(view).last_payload_refresh

    send(view.pid, %{
      event: :harness_stream,
      issue_id: "issue-http",
      last_seq: 2,
      lines: [
        %{seq: 1, at: DateTime.utc_now(), text: "first line"},
        %{seq: 2, at: DateTime.utc_now(), text: "second line"}
      ],
      dropped: 0
    })

    html = render(view)
    assert html =~ "first line"
    assert html =~ "second line"
    assert html =~ ~s(data-seq="1")
    assert html =~ ~s(data-seq="2")

    assigns = view_assigns(view)
    assert view_payload(view) == payload_before
    assert assigns.last_payload_refresh == refresh_before
    assert assigns.harness_tails["MT-HTTP"].last_seq == 2
    assert length(assigns.harness_tails["MT-HTTP"].lines) == 2

    send(view.pid, %{
      event: :harness_stream,
      issue_id: "issue-http",
      last_seq: 2,
      lines: [%{seq: 2, at: DateTime.utc_now(), text: "duplicate"}],
      dropped: 0
    })

    html = render(view)
    refute html =~ "duplicate"
    assert length(view_assigns(view).harness_tails["MT-HTTP"].lines) == 2

    send(view.pid, %{
      event: :harness_stream,
      issue_id: "issue-http",
      last_seq: 3,
      lines: [%{seq: 3, at: DateTime.utc_now(), text: "third line"}],
      dropped: 0
    })

    html = render(view)
    assert html =~ "third line"
    assert length(view_assigns(view).harness_tails["MT-HTTP"].lines) == 3

    send(view.pid, %{event: :harness_stream, issue_id: "missing-issue", last_seq: 1, lines: []})
    send(view.pid, %{event: :other_map, issue_id: "issue-http"})
    assert render(view) =~ "third line"
  end

  test "preview_project_agent accepts antigravity and ignores unknown kinds" do
    start_dashboard()
    {:ok, view, _html} = live(build_conn(), "/")

    render_change(view, "preview_project_agent", %{
      "project" => "default",
      "agent_kind" => "antigravity"
    })

    assert has_element?(view, ~s|form[phx-submit="set_project_agent"] input[name="agent_kind"][value="antigravity"]|)
    drafts = view_assigns(view).agent_setting_drafts
    assert drafts["default"].kind == "antigravity"

    project_name = hd(view_assigns(view).projects).name

    render_change(view, "preview_project_agent", %{
      "project" => project_name,
      "agent_kind" => "gemini"
    })

    assert has_element?(view, ~s|form[phx-submit="set_project_agent"] input[name="agent_kind"][value="antigravity"]|)
    assert view_assigns(view).agent_setting_drafts["default"].kind == "antigravity"

    html = render_click(view, "toggle_harness_follow", %{"issue" => "MT-HTTP"})
    refute html =~ ~s(id="harness-tail-MT-HTTP")
  end

  test "session tokens show one-decimal t/s and harness follow can pause" do
    start_dashboard()
    {:ok, view, _html} = live(build_conn(), "/")

    payload = view_payload(view)
    [entry | rest] = payload.running

    # Tokens and the derived rate move together, as they do on a real load: a
    # rate that drifts on its own is ignored by the change-only section split.
    entry =
      entry
      |> Map.put(:tokens, %{entry.tokens | total_tokens: 37})
      |> Map.put(:tokens_per_second, 12.34)

    patched = %{
      payload
      | running: [entry | rest],
        projects: patch_running(payload.projects, entry)
    }

    send(view.pid, {:payload_loaded, view_assigns(view).payload_seq, patched})

    html = render(view)
    assert html =~ "12.3 t/s"
    assert html =~ ~s(class="tps")

    view
    |> element(~s|button[phx-click="toggle_logs"][phx-value-issue="MT-HTTP"]|)
    |> render_click()

    assert render(view) =~ "Following"

    view
    |> element(~s|button[phx-click="toggle_harness_follow"][phx-value-issue="MT-HTTP"]|)
    |> render_click()

    html = render(view)
    assert html =~ "Paused"
    assert html =~ ~s(data-follow="false")
    refute view_assigns(view).harness_tails["MT-HTTP"].follow
  end

  test "settings drawer connects Linear and never echoes the API key" do
    start_dashboard()
    {:ok, view, html} = live(build_conn(), "/")

    assert html =~ "Disconnected"
    assert html =~ "Connect Linear to add a project"
    refute has_element?(view, "#add-project-form")
    assert has_element?(view, "#linear-connect-form")
    assert has_element?(view, "#linear-api-key")

    view
    |> form("#linear-connect-form", %{api_key: ""})
    |> render_submit()

    assert has_element?(view, "p.settings-error", "API key cannot be empty")
    refute render(view) =~ "lin_api_fake"

    stub_linear_graphql(fn _payload, _headers ->
      {:ok, %{status: 401, body: %{}}}
    end)

    view
    |> form("#linear-connect-form", %{api_key: "lin_api_fake"})
    |> render_submit()

    assert has_element?(view, "p.settings-error", "Linear rejected that API key")
    refute render(view) =~ "lin_api_fake"

    stub_linear_graphql(fn _payload, _headers ->
      {:ok, %{status: 200, body: %{"data" => %{}}}}
    end)

    view
    |> form("#linear-connect-form", %{api_key: "lin_api_fake"})
    |> render_submit()

    assert has_element?(view, "p.settings-error", "Linear rejected that API key")
    refute render(view) =~ "lin_api_fake"

    stub_linear_graphql(&linear_success_request/2)

    view
    |> form("#linear-connect-form", %{api_key: "lin_api_fake"})
    |> render_submit()

    html = render(view)
    assert html =~ "Connected"
    assert has_element?(view, "span.linear-key-mask", "••••fake")
    assert html =~ "Linear connected · ••••fake"
    refute html =~ "lin_api_fake"
    refute html =~ "••••••••"

    assert_eventually(fn ->
      render(view) =~ "ailogic-ced4159f70c4"
    end)

    assert has_element?(view, "#add-project-form")
    assert render(view) =~ ~s(value="ailogic-ced4159f70c4")
  end

  test "add_project duplicate error and success after a stubbed start" do
    start_dashboard()
    stub_linear_graphql(&linear_success_request/2)
    {:ok, view, _html} = live(build_conn(), "/")

    view
    |> form("#linear-connect-form", %{api_key: "lin_api_fake"})
    |> render_submit()

    send(
      view.pid,
      {:linear_projects_loaded,
       [
         %{id: "proj-1", name: "Agent Farm", slug_id: "ailogic-ced4159f70c4"},
         %{id: "proj-2", name: "Other Farm", slug_id: "other-slug-aaaaaaaa"}
       ]}
    )

    render(view)

    {:ok, config} = CymphonyConfig.load()

    seeded =
      Map.put(config, "projects", [
        %{
          "name" => "Farm",
          "linear_project_slug" => "ailogic-ced4159f70c4",
          "linear_api_key" => "lin_api_fake"
        }
      ])

    assert :ok = CymphonyConfig.save(seeded)

    render_submit(view, "add_project", %{
      "name" => "Farm",
      "linear_project_slug" => "ailogic-ced4159f70c4"
    })

    assert has_element?(view, "p.settings-error", "A project with that name already exists")
    assert render(view) =~ "A project with that name already exists"

    render_submit(view, "add_project", %{
      "name" => "Different",
      "linear_project_slug" => "ailogic-ced4159f70c4"
    })

    assert render(view) =~ "A project with that Linear slug already exists"

    farm_orch = Module.concat(__MODULE__, :"Farm#{System.unique_integer([:positive])}")

    start_supervised!(%{
      id: {:added_farm_orch, farm_orch},
      start:
        {StaticOrchestrator, :start_link,
         [
           [
             name: farm_orch,
             project_name: "AddedFarm",
             snapshot:
               static_snapshot()
               |> Map.put(:project_name, "AddedFarm")
               |> Map.put(:running, [])
               |> Map.put(:retrying, [])
           ]
         ]}
    })

    test_pid = self()

    dummy_supervisor =
      spawn(fn ->
        {:ok, _} = Registry.register(CymphonyElixir.ProjectRegistry, {"AddedFarm", :supervisor}, nil)
        send(test_pid, :added_farm_supervisor_registered)
        Process.sleep(:infinity)
      end)

    assert_receive :added_farm_supervisor_registered, 1_000

    on_exit(fn ->
      if Process.alive?(dummy_supervisor), do: Process.exit(dummy_supervisor, :kill)
    end)

    render_submit(view, "add_project", %{
      "name" => "AddedFarm",
      "linear_project_slug" => "other-slug-aaaaaaaa"
    })

    html = render(view)
    assert html =~ "AddedFarm added and started"
    assert html =~ "AddedFarm"
    assert has_element?(view, ".project-section-name", "AddedFarm")
    refute html =~ "lin_api_fake"
  end

  test "header agent select id is stable and survives stale payload refresh" do
    start_dashboard()
    {:ok, view, html} = live(build_conn(), "/")

    assert html =~ ~s(id="agent-default")
    assert html =~ ~s(id="effort-default")
    refute html =~ ~s(id="agent-default-claude")
    refute html =~ ~s(id="effort-default-claude")
    assert has_element?(view, ~s|form[phx-submit="set_project_agent"] input[name="agent_kind"][value="claude"]|)

    render_change(view, "preview_project_agent", %{
      "project" => "default",
      "agent_kind" => "codex"
    })

    assert has_element?(view, ~s|#agent-default|)
    refute has_element?(view, ~s|#agent-default-codex|)
    assert has_element?(view, ~s|form[phx-submit="set_project_agent"] input[name="agent_kind"][value="codex"]|)
    assert render(view) =~ ~s(id="agent-default")
    assert has_element?(view, ~s|form[phx-submit="set_project_agent"] input[name="agent_kind"][value="codex"]|)

    preview_assigns = view_assigns(view)
    preview_payload = view_payload(view)
    [preview_project | preview_rest] = preview_payload.projects
    assert preview_project.agent_kind == "claude"

    send(
      view.pid,
      {:payload_loaded, preview_assigns.payload_seq, %{preview_payload | projects: [Map.put(preview_project, :agent_kind, "claude") | preview_rest]}}
    )

    render(view)
    assert has_element?(view, ~s|form[phx-submit="set_project_agent"] input[name="agent_kind"][value="codex"]|)
    refute has_element?(view, ~s|form[phx-submit="set_project_agent"] input[name="agent_kind"][value="claude"]|)
    assert view_assigns(view).agent_setting_drafts[preview_project.name].kind == "codex"

    seq_before = view_assigns(view).payload_seq

    render_submit(view, "set_project_agent", %{
      "project" => preview_project.name,
      "agent_kind" => "codex",
      "model" => "gpt-5.2-codex",
      "effort" => "high"
    })

    assert has_element?(view, ~s|form[phx-submit="set_project_agent"] input[name="agent_kind"][value="codex"]|)
    seq_after = view_assigns(view).payload_seq
    assert seq_after > seq_before

    payload = view_payload(view)
    [project | rest] = payload.projects
    assert project.agent_kind == "claude"

    send(view.pid, {:payload_loaded, seq_after, payload})
    render(view)
    assert has_element?(view, ~s|form[phx-submit="set_project_agent"] input[name="agent_kind"][value="codex"]|)
    refute has_element?(view, ~s|form[phx-submit="set_project_agent"] input[name="agent_kind"][value="claude"]|)

    stale_project =
      project
      |> Map.put(:agent_kind, nil)
      |> Map.put(:agent_model, nil)
      |> Map.put(:agent_effort, nil)

    send(view.pid, {:payload_loaded, seq_before, %{payload | projects: [stale_project | rest]}})
    render(view)

    assert has_element?(view, ~s|form[phx-submit="set_project_agent"] input[name="agent_kind"][value="codex"]|)
    assert has_element?(view, ~s|#agent-default|)

    matching_project =
      project
      |> Map.put(:agent_kind, "codex")
      |> Map.put(:agent_model, "gpt-5.2-codex")
      |> Map.put(:agent_effort, "high")

    send(view.pid, {:payload_loaded, seq_after, %{payload | projects: [matching_project | rest]}})
    render(view)

    assert has_element?(view, ~s|form[phx-submit="set_project_agent"] input[name="agent_kind"][value="codex"]|)
    refute Map.has_key?(view_assigns(view).agent_setting_drafts, project.name)
  end

  test "header model lives under model-switcher combobox without datalist" do
    start_dashboard()
    {:ok, view, html} = live(build_conn(), "/")

    assert has_element?(view, ~s|form.project-agent-form.advanced-only[phx-change="preview_project_agent"][phx-submit="set_project_agent"]|)
    assert has_element?(view, ".model-switcher #model-default")
    assert has_element?(view, ~s|#model-default[name="model"]|)
    assert has_element?(view, "#model-default-trigger")
    assert has_element?(view, "#model-default-input")
    assert has_element?(view, ~s|#model-suggestions-default[role="listbox"]|)
    assert has_element?(view, "#combobox-model-default .combobox-panel")
    assert has_element?(view, "#combobox-model-default .combobox-search")
    assert has_element?(view, ~s|.model-switcher li[role="option"][data-value="sonnet"]|)
    assert has_element?(view, "#agent-default")
    assert has_element?(view, "#effort-default")
    refute html =~ "<datalist"
    refute html =~ ~s(list="model-suggestions)
    refute html =~ ~s(id="agent-default-claude")
  end

  test "preview_project_agent hides providers for non-claude kinds and restores them for claude" do
    start_dashboard(recipient: self())
    {:ok, view, _html} = live(build_conn(), "/")

    {:ok, config} = CymphonyConfig.load()
    projects = Enum.map(config["projects"], &Map.put(&1, "provider", "cv1"))
    assert :ok = CymphonyConfig.save(Map.put(config, "projects", projects))

    assert has_element?(view, ~s|form[phx-submit="set_project_providers"] #providers-default|)

    render_change(view, "preview_project_agent", %{
      "project" => "default",
      "agent_kind" => "codex"
    })

    refute has_element?(view, "#providers-default")
    refute has_element?(view, ~s|form[phx-submit="set_project_providers"]|)
    assert has_element?(view, ~s|form[phx-submit="set_project_agent"] input[name="agent_kind"][value="codex"]|)

    render_change(view, "preview_project_agent", %{
      "project" => "default",
      "agent_kind" => "antigravity"
    })

    refute has_element?(view, "#providers-default")
    refute has_element?(view, ~s|form[phx-submit="set_project_providers"]|)
    assert has_element?(view, ~s|form[phx-submit="set_project_agent"] input[name="agent_kind"][value="antigravity"]|)

    render_change(view, "preview_project_agent", %{
      "project" => "default",
      "agent_kind" => "claude"
    })

    assert has_element?(view, ~s|form[phx-submit="set_project_providers"] #providers-default|)
    assert has_element?(view, ~s|form[phx-submit="set_project_agent"] input[name="agent_kind"][value="claude"]|)

    refute_received {:orchestrator_call, {:set_providers, _}}
    {:ok, persisted} = CymphonyConfig.load()
    assert Enum.any?(persisted["projects"], &(&1["provider"] == "cv1"))
  end

  test "header providers stay hidden for empty and unknown agent kinds" do
    start_dashboard()
    {:ok, view, _html} = live(build_conn(), "/")

    payload = view_payload(view)
    [project | rest] = payload.projects

    send(
      view.pid,
      {:payload_loaded, view_assigns(view).payload_seq, %{payload | projects: [Map.put(project, :agent_kind, nil) | rest]}}
    )

    render(view)
    refute has_element?(view, "#providers-default")
    refute has_element?(view, ~s|form[phx-submit="set_project_providers"]|)

    send(
      view.pid,
      {:payload_loaded, view_assigns(view).payload_seq, %{payload | projects: [Map.put(project, :agent_kind, "gemini") | rest]}}
    )

    render(view)
    refute has_element?(view, "#providers-default")
    refute has_element?(view, ~s|form[phx-submit="set_project_providers"]|)
  end

  test "restart form shows provider only for claude and hides it for codex" do
    start_dashboard()
    {:ok, view, _html} = live(build_conn(), "/")

    view
    |> element(~s|button[phx-click="toggle_logs"][phx-value-issue="MT-HTTP"]|)
    |> render_click()

    assert has_element?(view, ~s|form.restart-form[phx-change="preview_issue_run_spec"][phx-submit="set_issue_run_spec"]|)
    assert has_element?(view, ~s|label[for="restart-agent-MT-HTTP-trigger"]|, "Harness")
    assert has_element?(view, "#restart-agent-MT-HTTP")
    assert has_element?(view, ".model-switcher #restart-model-MT-HTTP")
    assert has_element?(view, ~s|#restart-model-MT-HTTP[name="model"]|)
    assert has_element?(view, "#restart-model-MT-HTTP-input")
    assert has_element?(view, "#model-suggestions-session-MT-HTTP")
    assert has_element?(view, "#restart-effort-MT-HTTP")
    assert has_element?(view, ~s|#harness-tail-MT-HTTP[phx-hook="HarnessTail"]|)
    assert render(view) =~ ">Provider<"

    render_change(view, "preview_issue_run_spec", %{"issue" => "MT-HTTP", "agent_kind" => "claude"})

    assert has_element?(view, ~s|#restart-provider-MT-HTTP[name="provider"]|)

    render_change(view, "preview_issue_run_spec", %{"issue" => "MT-HTTP", "agent_kind" => "codex"})

    refute has_element?(view, "#restart-provider-MT-HTTP")
    refute has_element?(view, ~s|form.restart-form input[name="provider"]|)
    assert has_element?(view, ~s|form[phx-submit="set_issue_run_spec"] input[name="agent_kind"][value="codex"]|)

    render_change(view, "preview_issue_run_spec", %{"issue" => "MT-HTTP", "agent_kind" => "antigravity"})

    refute has_element?(view, "#restart-provider-MT-HTTP")
    refute has_element?(view, ~s|form.restart-form input[name="provider"]|)
    assert has_element?(view, "#restart-agent-MT-HTTP")
    assert has_element?(view, ~s|form[phx-submit="set_issue_run_spec"] input[name="agent_kind"][value="antigravity"]|)

    render_change(view, "preview_issue_run_spec", %{"issue" => "MT-HTTP", "agent_kind" => ""})

    refute has_element?(view, "#restart-provider-MT-HTTP")
    assert render(view) =~ ">Provider<"
  end

  test "session provider chip stays visible when the session kind is not claude" do
    start_dashboard()
    {:ok, view, _html} = live(build_conn(), "/")

    payload = view_payload(view)
    [entry | rest] = payload.running
    entry = entry |> Map.put(:provider, "cz2") |> Map.put(:agent_kind, "codex")

    patched = %{
      payload
      | running: [entry | rest],
        projects: patch_running(payload.projects, entry)
    }

    send(view.pid, {:payload_loaded, view_assigns(view).payload_seq, patched})

    html = render(view)
    assert html =~ ~s(class="chip chip--accent advanced-only")
    assert html =~ "cz2"
    assert html =~ ~s(class="chip chip--agent advanced-only")
    assert html =~ "codex"
    assert has_element?(view, ~s|form[phx-submit="set_project_providers"] #providers-default|)
  end

  test "preview_add_project shows provider only for claude" do
    start_dashboard()
    {:ok, config} = CymphonyConfig.load()
    assert :ok = CymphonyConfig.save(Map.put(config, "linear_api_key", "lin_api_fake"))

    {:ok, view, _html} = live(build_conn(), "/")

    assert has_element?(view, "#add-project-form")
    assert has_element?(view, "#add-project-slug")
    assert has_element?(view, "#add-project-slug-input")
    assert has_element?(view, "#linear-project-slugs")
    assert has_element?(view, "#add-project-model")
    assert has_element?(view, "#add-project-model-input")
    assert has_element?(view, ".model-switcher #add-project-model")
    assert has_element?(view, ~s|#add-project-effort[name="effort"]|)
    refute has_element?(view, ~s|#add-project-effort[type="text"]|)
    refute has_element?(view, "#add-project-provider")
    assert view_assigns(view).add_project_kind == ""

    render_change(view, "preview_add_project", %{"agent" => "claude"})

    assert view_assigns(view).add_project_kind == "claude"
    assert has_element?(view, "#add-project-provider")

    render_change(view, "preview_add_project", %{"agent" => "codex"})

    assert view_assigns(view).add_project_kind == "codex"
    refute has_element?(view, "#add-project-provider")

    render_change(view, "preview_add_project", %{"agent" => "antigravity"})

    assert view_assigns(view).add_project_kind == "antigravity"
    refute has_element?(view, "#add-project-provider")

    render_change(view, "preview_add_project", %{"agent" => ""})

    assert view_assigns(view).add_project_kind == ""
    refute has_element?(view, "#add-project-provider")
  end

  test "refresh interval defaults to 3 and set_refresh_interval updates assign and config.json" do
    start_dashboard()
    {:ok, view, html} = live(build_conn(), "/")

    assert html =~ ~s(id="drawer-refresh-interval")
    assert has_element?(view, ~s|#drawer-refresh-interval[type="number"][min="1"][name="value"]|)
    assert has_element?(view, ~s|#drawer-refresh-interval.settings-field|)
    assert has_element?(view, ~s|#linear-api-key.settings-field|)
    assert has_element?(view, ~s|#drawer-global-concurrency.settings-field|)
    assert has_element?(view, ~s|form.settings-form[phx-submit="set_refresh_interval"]|)
    assert has_element?(view, ~s|form.settings-form[phx-submit="set_concurrency"]|)
    assert view_assigns(view).payload_refresh_seconds == 3
    assert view_assigns(view).payload_refresh_ms == 3_000
    assert has_element?(view, ~s|#drawer-refresh-interval[value="3"]|)

    {:ok, initial_config} = CymphonyConfig.load()
    refute Map.get(initial_config, "dashboard_refresh_seconds")

    view
    |> form(~s|form[phx-submit="set_refresh_interval"]|, %{value: "7"})
    |> render_submit()

    assert view_assigns(view).payload_refresh_seconds == 7
    assert view_assigns(view).payload_refresh_ms == 7_000
    assert render(view) =~ "Dashboard refresh set to 7s"

    {:ok, updated} = CymphonyConfig.load()
    assert updated["dashboard_refresh_seconds"] == 7
    assert is_list(updated["projects"])

    view
    |> form(~s|form[phx-submit="set_refresh_interval"]|, %{value: "0"})
    |> render_submit()

    assert view_assigns(view).payload_refresh_seconds == 7
    assert render(view) =~ "Refresh interval must be a positive integer"
  end

  test "queue board is hidden when waiting is empty" do
    start_dashboard()
    {:ok, view, html} = live(build_conn(), "/")

    assert view_assigns(view).queue_edit_ids == MapSet.new()
    assert view_assigns(view).queue_run_spec_drafts == %{}
    refute has_element?(view, "section.queue-board")
    refute has_element?(view, ".queue-board-list")
    refute html =~ ~s(id="queue-board-default")
    assert has_element?(view, ~s|[data-pref-section="board"]|)
    assert html =~ ~s(class="metric-pill metric-pill--queue section--queue advanced-only")
  end

  test "queue board shows title, identifier, and Edit when waiting is present" do
    start_dashboard(
      snapshot:
        static_snapshot()
        |> Map.put(:waiting, [
          waiting_snapshot_entry(%{identifier: "LLM-51", title: "Pin the queue"}),
          waiting_snapshot_entry(%{identifier: "LLM-12", title: "Later card", priority: 4})
        ])
    )

    {:ok, view, html} = live(build_conn(), "/")

    assert has_element?(view, "section.queue-board.section--board")
    assert has_element?(view, "#queue-board-default.queue-board-list")
    assert has_element?(view, ~s|#queue-card-default-LLM-51[data-issue="LLM-51"][data-rank="0"]|)
    assert has_element?(view, ~s|#queue-card-default-LLM-51.queue-card--next|)
    assert has_element?(view, "#queue-card-default-LLM-51 .queue-next-badge", "Next")
    refute has_element?(view, ~s|#queue-card-default-LLM-12.queue-card--next|)
    assert has_element?(view, ~s|a.session-row-link.queue-card-link|, "LLM-51")
    assert html =~ "Pin the queue"
    assert has_element?(view, "button.queue-card-edit-toggle", "Edit")
    assert html =~ "queued"
    assert html =~ "Leftmost starts next"

    card = view |> element("#queue-card-default-LLM-51") |> render()
    refute card =~ "chip"
    refute card =~ "Urgent"
    refute card =~ "High"
    refute card =~ "Todo"
    refute card =~ "In Progress"
  end

  test "only one queue edit sheet is open and dismiss_overlays closes it" do
    start_dashboard(
      snapshot:
        static_snapshot()
        |> Map.put(:waiting, [
          waiting_snapshot_entry(%{identifier: "LLM-51", title: "First"}),
          waiting_snapshot_entry(%{identifier: "LLM-12", title: "Second"})
        ])
    )

    {:ok, view, _html} = live(build_conn(), "/")

    view
    |> element(~s|button.queue-card-edit-toggle[phx-value-issue="LLM-51"]|)
    |> render_click()

    assert has_element?(view, "#queue-edit-default-LLM-51")
    refute has_element?(view, "#queue-edit-default-LLM-12")

    view
    |> element(~s|button.queue-card-edit-toggle[phx-value-issue="LLM-12"]|)
    |> render_click()

    refute has_element?(view, "#queue-edit-default-LLM-51")
    assert has_element?(view, "#queue-edit-default-LLM-12")

    render_click(view, "dismiss_overlays", %{})
    refute has_element?(view, "#queue-edit-default-LLM-12")
    assert view_assigns(view).queue_edit_ids == MapSet.new()
  end

  test "empty-state is absent when waiting is nonempty" do
    start_dashboard(
      snapshot:
        static_snapshot()
        |> Map.put(:running, [])
        |> Map.put(:retrying, [])
        |> Map.put(:waiting, [waiting_snapshot_entry(%{identifier: "LLM-51", title: "Ready next"})])
    )

    {:ok, view, html} = live(build_conn(), "/")

    assert has_element?(view, "section.queue-board.section--board")
    assert html =~ "Ready next"
    refute html =~ "No active sessions."
    refute html =~ "Nothing is running right now."
    refute has_element?(view, "p.empty-state")
  end

  test "queue edit preselects project header spec when the card has no pin" do
    start_dashboard(
      snapshot:
        static_snapshot()
        |> Map.put(:agent_kind, "antigravity")
        |> Map.put(:agent_model, "gpt-5.6-luna")
        |> Map.put(:agent_effort, "max")
        |> Map.put(:waiting, [waiting_snapshot_entry(%{identifier: "LLM-51", title: "Ready next"})])
    )

    {:ok, view, _html} = live(build_conn(), "/")

    view
    |> element(~s|button.queue-card-edit-toggle[phx-value-issue="LLM-51"]|)
    |> render_click()

    assert has_element?(view, ~s|form.queue-edit-form input[name="agent_kind"][value="antigravity"]|)
    assert has_element?(view, ~s|form.queue-edit-form input[name="model"][value="gpt-5.6-luna"]|)
    assert has_element?(view, ~s|form.queue-edit-form input[name="effort"][value="max"]|)

    form = view |> element("form.queue-edit-form") |> render()
    refute form =~ ~s(data-value="")
    refute form =~ ">keep<"
  end

  test "queue edit preselects a card pin over the project header" do
    start_dashboard(
      snapshot:
        static_snapshot()
        |> Map.put(:agent_kind, "antigravity")
        |> Map.put(:agent_model, "gpt-5.6-luna")
        |> Map.put(:agent_effort, "max")
        |> Map.put(:waiting, [
          waiting_snapshot_entry(%{
            identifier: "LLM-51",
            title: "Pinned card",
            agent_kind: "codex",
            model: "gpt-5.2-codex",
            effort: "high"
          })
        ])
    )

    {:ok, view, _html} = live(build_conn(), "/")

    view
    |> element(~s|button.queue-card-edit-toggle[phx-value-issue="LLM-51"]|)
    |> render_click()

    assert has_element?(view, ~s|form.queue-edit-form input[name="agent_kind"][value="codex"]|)
    assert has_element?(view, ~s|form.queue-edit-form input[name="model"][value="gpt-5.2-codex"]|)
    assert has_element?(view, ~s|form.queue-edit-form input[name="effort"][value="high"]|)
    refute has_element?(view, ~s|form.queue-edit-form input[name="agent_kind"][value="antigravity"]|)
  end

  test "preview_queue_run_spec drafts kind and clears model and effort when kind changes" do
    start_dashboard(
      snapshot:
        static_snapshot()
        |> Map.put(:waiting, [
          waiting_snapshot_entry(%{
            identifier: "LLM-51",
            title: "Ready next",
            agent_kind: "claude",
            model: "sonnet",
            effort: "high"
          })
        ])
    )

    {:ok, view, _html} = live(build_conn(), "/")

    view
    |> element(~s|button.queue-card-edit-toggle[phx-value-issue="LLM-51"]|)
    |> render_click()

    render_change(view, "preview_queue_run_spec", %{
      "project" => "default",
      "issue" => "LLM-51",
      "agent_kind" => "codex",
      "model" => "sonnet",
      "effort" => "high"
    })

    draft = view_assigns(view).queue_run_spec_drafts[{"default", "LLM-51"}]
    assert draft.kind == "codex"
    assert draft.model == ""
    assert draft.effort == ""
    refute has_element?(view, ~s|form.queue-edit-form input[name="provider"]|)
  end

  test "empty-state is shown when running, retrying, and waiting are empty" do
    start_dashboard(snapshot: static_snapshot() |> Map.put(:running, []) |> Map.put(:retrying, []) |> Map.put(:waiting, []))

    {:ok, view, html} = live(build_conn(), "/")

    refute has_element?(view, "section.queue-board")
    assert html =~ "No active sessions."
    assert has_element?(view, "p.empty-state")
  end

  test "time-derived values carry LiveClock anchors instead of absolute wall times" do
    start_dashboard()

    {:ok, view, html} = live(build_conn(), "/")

    assert html =~ ~s(<div id="live-clock" phx-hook="LiveClock">)

    # Poll countdown anchors on remaining milliseconds and matches the server text.
    assert html =~ ~s(<span data-clock="countdown" data-remaining-ms="5000">5s</span>)

    # Global runtime, per-session runtime and retry due-in all anchor on amounts.
    assert has_element?(view, ~s|span.metric-pill-value[data-clock="elapsed"][data-base-seconds][data-rate="1"]|)
    assert has_element?(view, ~s|.session-row-runtime span[data-clock="elapsed"][data-base-seconds]|)
    assert has_element?(view, ~s|span[data-clock="due"][data-remaining-ms]|)
  end

  test "the stalled banner anchors on elapsed seconds" do
    start_dashboard()

    {:ok, view, _html} = live(build_conn(), "/")

    payload = view_payload(view)
    [entry | rest] = payload.running
    stalled_at = DateTime.add(DateTime.utc_now(), -125, :second)

    stalled =
      entry
      |> Map.put(:stalled, true)
      |> Map.put(:last_event_at, DateTime.to_iso8601(stalled_at))

    send(view.pid, {:payload_loaded, view_assigns(view).payload_seq, %{payload | running: [stalled | rest]}})

    html = render(view)

    # The anchor is the elapsed amount as of the render, and the visible text is
    # that same amount formatted the way the LiveClock hook formats it.
    seconds = DateTime.diff(view_assigns(view).now, stalled_at, :second)
    assert seconds >= 125

    assert html =~
             ~s(<span data-clock="elapsed" data-base-seconds="#{seconds}">#{div(seconds, 60)}m #{rem(seconds, 60)}s</span>)
  end

  test "clock spans drop their anchor when the amount is unknown, keeping the server text" do
    start_dashboard()

    {:ok, view, _html} = live(build_conn(), "/")

    payload = view_payload(view)
    [entry | rest] = payload.running
    stalled = entry |> Map.put(:stalled, true) |> Map.put(:last_event_at, "not-a-timestamp")

    projects =
      Enum.map(payload.projects, fn project ->
        %{project | retrying: Enum.map(project.retrying, &Map.put(&1, :due_at, "not-a-timestamp"))}
      end)

    unclocked = %{
      payload
      | running: [stalled | rest],
        projects: projects,
        polling: %{payload.polling | next_poll_in_ms: nil}
    }

    send(view.pid, {:payload_loaded, view_assigns(view).payload_seq, unclocked})

    html = render(view)

    # No anchor attribute at all, so the hook skips the span and the
    # server-rendered text is what a JS-off (or bad-data) browser keeps showing.
    assert html =~ ~s(<span data-clock="elapsed">unknown</span>)
    assert html =~ ~s(<span data-clock="due">n/a</span>)
    assert html =~ ~s(<span data-clock="countdown">n/a</span>)
  end

  test "the runtime tile anchors on completed seconds and advances once per running session" do
    start_dashboard(snapshot: Map.put(static_snapshot(), :running, []))

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ ~s(data-base-seconds="42.5")
    assert html =~ ~s(data-rate="0")
  end

  test "runtime_tick no longer re-renders time strings" do
    start_dashboard()

    {:ok, view, _html} = live(build_conn(), "/")

    html_before = render(view)
    assigns_before = view_assigns(view)
    payload_before = view_payload(view)

    send(view.pid, :runtime_tick)

    assert render(view) == html_before

    assigns_after = view_assigns(view)
    assert assigns_after.now == assigns_before.now
    assert view_payload(view) == payload_before
    assert assigns_after.last_payload_refresh == assigns_before.last_payload_refresh

    # Identical HTML alone is weak: the second-resolution strings only move once
    # a second. The real acceptance is that *no* assign moved, because LiveView
    # only ships a diff for assigns it marked as changed — so the tick costs zero
    # websocket traffic, not merely zero visible change.
    assert changed_assign_keys(assigns_before, assigns_after) == []
  end

  test "runtime_tick still drives the periodic payload refresh" do
    start_dashboard()

    {:ok, view, _html} = live(build_conn(), "/")

    view
    |> form(~s|form[phx-submit="set_refresh_interval"]|, %{value: "1"})
    |> render_submit()

    assigns_before = view_assigns(view)

    assert wait_until(fn ->
             assigns = view_assigns(view)

             assigns.last_payload_refresh > assigns_before.last_payload_refresh and
               assigns.payload_seq > assigns_before.payload_seq
           end)
  end

  test "a payload load re-anchors :now only when a clock-bearing section moved" do
    start_dashboard()

    {:ok, view, _html} = live(build_conn(), "/")

    payload = view_payload(view)
    now_before = view_assigns(view).now

    # Nothing moved. `:now` is read inside the per-project comprehension (session
    # runtime, retry due-in), and a HEEx comprehension is one change-tracked
    # slot: re-anchoring here would re-evaluate and re-serialize every project
    # header, queue card, session row and restart form — the exact re-render the
    # section split exists to skip.
    send(view.pid, {:payload_loaded, view_assigns(view).payload_seq, payload})
    render(view)

    assert view_assigns(view).now == now_before

    # A real move: the sections re-render anyway, so the clocks they carry have
    # to be anchored as of *this* render, not as of the last one.
    [entry | rest] = payload.running
    moved = %{entry | tokens: %{entry.tokens | total_tokens: entry.tokens.total_tokens + 1}}
    patched = %{payload | running: [moved | rest], projects: patch_running(payload.projects, moved)}

    send(view.pid, {:payload_loaded, view_assigns(view).payload_seq, patched})
    render(view)

    assert DateTime.compare(view_assigns(view).now, now_before) == :gt
  end

  test "the payload is split into one assign per section, with no monolithic payload assign" do
    start_dashboard()

    {:ok, view, _html} = live(build_conn(), "/")

    assigns = view_assigns(view)

    refute Map.has_key?(assigns, :payload)

    assert assigns.counts.running == 1
    assert assigns.counts.retrying == 1
    assert assigns.token_totals.total_tokens == 12
    assert assigns.rate_limits == %{"primary" => %{"remaining" => 11}}
    assert assigns.polling.next_poll_in_ms == 5_000
    assert [%{name: "default"}] = assigns.projects
    assert [%{issue_identifier: "MT-HTTP"}] = assigns.running
    assert [%{issue_identifier: "MT-RETRY"}] = assigns.retrying
    assert assigns.completions == []
    assert assigns.payload_error == nil
  end

  test "re-delivering an identical payload leaves every section assign and the render untouched" do
    # No running/retrying rows: the render then carries no wall-clock-derived
    # value, so an unchanged payload must produce byte-identical HTML.
    orchestrator = start_dashboard(snapshot: static_snapshot() |> Map.put(:running, []) |> Map.put(:retrying, []))

    {:ok, view, _html} = live(build_conn(), "/")

    # The throughput sparkline is seeded from the mount token sample and grows a
    # column on the first load, so take the baseline after one payload load.
    send(view.pid, {:payload_loaded, view_assigns(view).payload_seq, Presenter.state_payload(orchestrator, 1_000)})
    render(view)

    assigns_before = view_assigns(view)
    payload_before = view_payload(view)
    html_before = render(view)

    # Rebuilt from the orchestrator rather than echoed back out of the view's own
    # assigns, so the sections have to come out equal on their own — echoing the
    # assigns would make the assertions below true by construction.
    send(view.pid, {:payload_loaded, assigns_before.payload_seq, Presenter.state_payload(orchestrator, 1_000)})

    assert render(view) == html_before
    assert view_payload(view) == payload_before

    # `:token_samples` grows the throughput window; nothing else may move. Not
    # one payload section, and not `:now` either — the per-project comprehension
    # reads `:now`, so re-anchoring it would re-serialize every project subtree
    # and put the whole board back on the wire for a poll that changed nothing.
    assert changed_assign_keys(assigns_before, view_assigns(view)) -- [:token_samples] == []
  end

  test "a poll whose only movement is generated_at leaves every section assign untouched" do
    # This is the shape of a real idle poll: the orchestrator snapshot is
    # re-read every few seconds and comes back with a fresh `generated_at` and
    # otherwise identical sections. Under the old monolithic `@payload` assign
    # that alone re-rendered the whole template.
    orchestrator = start_dashboard(snapshot: static_snapshot() |> Map.put(:running, []) |> Map.put(:retrying, []))

    {:ok, view, _html} = live(build_conn(), "/")

    send(view.pid, {:payload_loaded, view_assigns(view).payload_seq, Presenter.state_payload(orchestrator, 1_000)})
    render(view)

    assigns_before = view_assigns(view)
    html_before = render(view)

    payload = Map.put(Presenter.state_payload(orchestrator, 1_000), :generated_at, "2026-08-16T00:00:00.000000Z")
    send(view.pid, {:payload_loaded, assigns_before.payload_seq, payload})

    assert render(view) == html_before
    assert changed_assign_keys(assigns_before, view_assigns(view)) -- [:token_samples] == []
  end

  test "a poll that only moves the countdown leaves :now and the per-project section alone" do
    start_dashboard()

    {:ok, view, _html} = live(build_conn(), "/")

    payload = view_payload(view)
    assigns_before = view_assigns(view)

    # The poll countdown is the one thing that moves on an otherwise idle poll.
    # It carries its own `data-remaining-ms` anchor and reads no wall clock, so
    # it must not drag `:now` — and through `:now`, the whole per-project
    # comprehension — onto the wire with it.
    ticked = %{payload | polling: %{payload.polling | next_poll_in_ms: 4_000}}

    send(view.pid, {:payload_loaded, assigns_before.payload_seq, ticked})
    render(view)

    assigns = view_assigns(view)

    assert assigns.polling.next_poll_in_ms == 4_000
    assert assigns.now == assigns_before.now
    assert assigns.projects == assigns_before.projects
    assert changed_assign_keys(assigns_before, assigns) -- [:polling, :token_samples] == []
  end

  test "a payload that only moves one section leaves the other section assigns alone" do
    start_dashboard()

    {:ok, view, _html} = live(build_conn(), "/")

    payload = view_payload(view)
    counts = %{payload.counts | running: 41}

    send(view.pid, {:payload_loaded, view_assigns(view).payload_seq, %{payload | counts: counts}})

    render(view)
    assigns = view_assigns(view)

    assert assigns.counts.running == 41
    assert assigns.projects == payload.projects
    assert assigns.running == payload.running
    assert assigns.retrying == payload.retrying
    assert assigns.polling == payload.polling
    assert assigns.rate_limits == payload.rate_limits
    assert assigns.token_totals == payload.token_totals
  end

  test "a poll where only the wall-clock-derived rate moved leaves the entry sections alone" do
    start_dashboard()

    {:ok, view, _html} = live(build_conn(), "/")

    payload = view_payload(view)
    [entry | rest] = payload.running

    # What an idle poll actually looks like for a running agent: the tokens did
    # not move, but `tokens_per_second` divides them by a wider window every
    # load, so it drifts on its own. Without this being ignored, `:running` and
    # `:projects` would be reassigned on every single refresh and the whole
    # per-project section would re-render — the churn the split exists to remove.
    drifted = Map.update!(entry, :tokens_per_second, &(&1 + 1.5))
    refute drifted == entry

    assigns_before = view_assigns(view)

    patched = %{payload | running: [drifted | rest], projects: patch_running(payload.projects, drifted)}

    send(view.pid, {:payload_loaded, assigns_before.payload_seq, patched})

    render(view)
    assigns = view_assigns(view)

    assert assigns.running == assigns_before.running
    assert assigns.projects == assigns_before.projects

    # The frozen rate is the deliberate trade-off: the row keeps the `t/s` from
    # the last load that moved a real field rather than re-rendering the whole
    # board to show a rate the server re-derived from nothing but the clock.
    assert changed_assign_keys(assigns_before, assigns) -- [:token_samples] == []
  end

  test "an error payload resets every section to its default" do
    start_dashboard()

    {:ok, view, _html} = live(build_conn(), "/")

    send(
      view.pid,
      {:payload_loaded, view_assigns(view).payload_seq,
       %{
         generated_at: "2026-08-16T00:00:00Z",
         error: %{code: "snapshot_timeout", message: "Snapshot timed out"}
       }}
    )

    html = render(view)
    assert html =~ "Snapshot unavailable"
    assert html =~ "snapshot_timeout"
    assert has_element?(view, ".status-badge-payload.status-badge-offline", "Unavailable")

    assigns = view_assigns(view)
    assert assigns.payload_error == %{code: "snapshot_timeout", message: "Snapshot timed out"}
    assert assigns.counts == %{running: 0, retrying: 0, waiting: 0, by_state: %{}, by_kind: %{}}
    assert assigns.token_totals == %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    assert assigns.rate_limits == nil
    assert assigns.polling == nil
    assert assigns.projects == []
    assert assigns.running == []
    assert assigns.retrying == []
    assert assigns.completions == []
  end

  test "a stale payload load cannot overwrite the split section assigns" do
    start_dashboard()

    {:ok, view, _html} = live(build_conn(), "/")

    payload = view_payload(view)
    stale_seq = view_assigns(view).payload_seq - 1

    send(view.pid, {:payload_loaded, stale_seq, %{payload | counts: %{payload.counts | running: 99}}})

    render(view)
    assert view_assigns(view).counts == payload.counts
  end

  # Assign keys whose value moved between two snapshots of the socket. LiveView
  # only re-evaluates (and only ships a diff for) assigns it marked as changed,
  # so an empty list is the server-side proxy for "no websocket traffic".
  defp changed_assign_keys(before_assigns, after_assigns) do
    before_assigns
    |> Map.merge(after_assigns)
    |> Map.keys()
    |> Enum.reject(&(Map.fetch(before_assigns, &1) == Map.fetch(after_assigns, &1)))
    |> Enum.sort()
  end

  defp wait_until(fun), do: wait_until(fun, System.monotonic_time(:millisecond) + 3_000)

  defp wait_until(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        :timer.sleep(25)
        wait_until(fun, deadline)
    end
  end

  defp start_dashboard(opts \\ []) do
    isolate_cymphony_home()
    stub_linear_graphql(fn _payload, _headers -> {:error, :stub_unused} end)

    previous_fetcher = Application.fetch_env(:cymphony_elixir, :codex_catalog_fetcher)
    Application.put_env(:cymphony_elixir, :codex_catalog_fetcher, fn -> {:ok, ~s({"models": []})} end)
    CymphonyElixir.AgentCatalog.clear_cache()

    on_exit(fn ->
      case previous_fetcher do
        {:ok, fetcher} -> Application.put_env(:cymphony_elixir, :codex_catalog_fetcher, fetcher)
        :error -> Application.delete_env(:cymphony_elixir, :codex_catalog_fetcher)
      end

      CymphonyElixir.AgentCatalog.clear_cache()
    end)

    orchestrator_name = Module.concat(__MODULE__, :"Orch#{System.unique_integer([:positive])}")

    snapshot = Keyword.get(opts, :snapshot, static_snapshot())

    start_supervised!({StaticOrchestrator, [name: orchestrator_name, snapshot: snapshot, recipient: Keyword.get(opts, :recipient)]})

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)
    ensure_harness_stream_started()
    orchestrator_name
  end

  defp isolate_cymphony_home do
    tmp = Path.join(System.tmp_dir!(), "cymphony-dash-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "config.json"), ~s({"projects":[{"name":"default"}]}))

    previous_dir = Application.get_env(:cymphony_elixir, :config_dir_override)
    previous_opts = Application.get_env(:cymphony_elixir, :linear_graphql_opts)
    previous_key = System.get_env("LINEAR_API_KEY")
    System.delete_env("LINEAR_API_KEY")
    Application.put_env(:cymphony_elixir, :config_dir_override, tmp)

    on_exit(fn ->
      restore_env("LINEAR_API_KEY", previous_key)

      if is_nil(previous_dir) do
        Application.delete_env(:cymphony_elixir, :config_dir_override)
      else
        Application.put_env(:cymphony_elixir, :config_dir_override, previous_dir)
      end

      if is_nil(previous_opts) do
        Application.delete_env(:cymphony_elixir, :linear_graphql_opts)
      else
        Application.put_env(:cymphony_elixir, :linear_graphql_opts, previous_opts)
      end

      File.rm_rf!(tmp)
    end)
  end

  defp stub_linear_graphql(fun) when is_function(fun, 2) do
    Application.put_env(:cymphony_elixir, :linear_graphql_opts, request_fun: fun)
  end

  defp linear_success_request(payload, _headers) do
    query = payload["query"] || ""

    cond do
      String.contains?(query, "CymphonyLinearViewer") ->
        {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"id" => "usr_test"}}}}}

      String.contains?(query, "CymphonyLinearProjects") ->
        {:ok,
         %{
           status: 200,
           body: %{
             "data" => %{
               "projects" => %{
                 "nodes" => [
                   %{"id" => "proj-1", "name" => "Agent Farm", "slugId" => "ailogic-ced4159f70c4"}
                 ],
                 "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
               }
             }
           }
         }}

      true ->
        {:ok, %{status: 200, body: %{"data" => %{}}}}
    end
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, _attempts) do
    flunk("condition was not met in time")
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :cymphony_elixir
      |> Application.get_env(CymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:cymphony_elixir, CymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({CymphonyElixirWeb.Endpoint, []})
  end

  defp ensure_harness_stream_started do
    mod = CymphonyElixir.HarnessStream

    cond do
      Process.whereis(mod) ->
        :ok

      Code.ensure_loaded?(mod) and function_exported?(mod, :start_link, 1) ->
        start_supervised!({mod, []})
        :ok

      true ->
        :ok
    end
  end

  defp static_snapshot do
    %{
      running: [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 7,
          agent_os_pid: nil,
          last_agent_message: "rendered",
          last_agent_timestamp: nil,
          last_agent_event: :notification,
          input_tokens: 4,
          output_tokens: 8,
          total_tokens: 12,
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [
        %{
          issue_id: "issue-retry",
          identifier: "MT-RETRY",
          attempt: 2,
          due_in_ms: 2_000,
          error: "boom"
        }
      ],
      waiting: [],
      token_totals: %{input_tokens: 4, output_tokens: 8, total_tokens: 12, seconds_running: 42.5},
      rate_limits: %{"primary" => %{"remaining" => 11}},
      agent_kind: "claude",
      agent_model: nil,
      agent_effort: nil,
      polling: %{
        next_poll_in_ms: 5_000,
        poll_interval_ms: 30_000,
        paused: false,
        checking?: false
      }
    }
  end

  defp view_assigns(view) do
    case :sys.get_state(view.pid) do
      %{socket: %{assigns: assigns}} -> assigns
      %{assigns: assigns} -> assigns
    end
  end

  # The LiveView keeps one assign per payload section instead of a single
  # `:payload` map, so rebuild the payload shape the `{:payload_loaded, seq,
  # payload}` contract still carries.
  defp view_payload(view) do
    assigns = view_assigns(view)

    %{
      counts: assigns.counts,
      running: assigns.running,
      retrying: assigns.retrying,
      token_totals: assigns.token_totals,
      rate_limits: assigns.rate_limits,
      polling: assigns.polling,
      projects: assigns.projects,
      recent_completed: assigns.completions
    }
  end

  defp patch_running(projects, entry) do
    Enum.map(projects, fn project ->
      %{project | running: patch_running_entries(project.running, entry)}
    end)
  end

  defp patch_running_entries(running, entry) do
    Enum.map(running, fn current ->
      if current.issue_identifier == entry.issue_identifier, do: entry, else: current
    end)
  end

  defp waiting_snapshot_entry(overrides) do
    identifier = Map.get(overrides, :identifier, "LLM-51")
    title = Map.get(overrides, :title, "Queue card title")
    priority = Map.get(overrides, :priority, 2)
    created_at = Map.get(overrides, :created_at, ~U[2026-03-01 12:00:00Z])

    %{
      issue_id: Map.get(overrides, :issue_id, "issue-#{identifier}"),
      identifier: identifier,
      issue: %{
        title: title,
        url: Map.get(overrides, :url, "https://linear.app/test/issue/#{identifier}"),
        priority: priority,
        created_at: created_at
      },
      priority: priority,
      state: Map.get(overrides, :state, "Todo"),
      created_at: created_at,
      agent_kind: Map.get(overrides, :agent_kind),
      model: Map.get(overrides, :model),
      effort: Map.get(overrides, :effort)
    }
  end
end
