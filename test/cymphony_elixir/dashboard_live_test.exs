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

    expanded =
      view
      |> element(~s|button[phx-click="toggle_logs"][phx-value-issue="MT-HTTP"]|)
      |> render_click()

    assert expanded =~ ~s(name="agent_kind")
    assert expanded =~ ">keep</option>"
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

    view
    |> form(~s|form[phx-submit="set_issue_run_spec"]|, %{
      issue: "MT-HTTP",
      agent_kind: "antigravity",
      provider: "cv2",
      model: "opus",
      effort: ""
    })
    |> render_submit()

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

    payload_before = view_assigns(view).payload
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
    assert assigns.payload == payload_before
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

    view
    |> form(~s|form[phx-change="preview_project_agent"]|, %{agent_kind: "antigravity"})
    |> render_change()

    assert has_element?(view, ~s|form[phx-submit="set_project_agent"] option[value="antigravity"][selected]|)
    drafts = view_assigns(view).agent_setting_drafts
    assert drafts["default"].kind == "antigravity"

    project_name = hd(view_assigns(view).payload.projects).name

    render_change(view, "preview_project_agent", %{
      "project" => project_name,
      "agent_kind" => "gemini"
    })

    assert has_element?(view, ~s|form[phx-submit="set_project_agent"] option[value="antigravity"][selected]|)
    assert view_assigns(view).agent_setting_drafts["default"].kind == "antigravity"

    html = render_click(view, "toggle_harness_follow", %{"issue" => "MT-HTTP"})
    refute html =~ ~s(id="harness-tail-MT-HTTP")
  end

  test "session tokens show one-decimal t/s and harness follow can pause" do
    start_dashboard()
    {:ok, view, _html} = live(build_conn(), "/")

    payload = view_assigns(view).payload
    [entry | rest] = payload.running
    entry = Map.put(entry, :tokens_per_second, 12.34)

    send(
      view.pid,
      {:payload_loaded, view_assigns(view).payload_seq, %{payload | running: [entry | rest], projects: patch_running(payload.projects, entry)}}
    )

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

    {:ok, config} = CymphonyElixir.Cymphony.Config.load()

    seeded =
      Map.put(config, "projects", [
        %{
          "name" => "Farm",
          "linear_project_slug" => "ailogic-ced4159f70c4",
          "linear_api_key" => "lin_api_fake"
        }
      ])

    assert :ok = CymphonyElixir.Cymphony.Config.save(seeded)

    view
    |> form("#add-project-form", %{name: "Farm", linear_project_slug: "ailogic-ced4159f70c4"})
    |> render_submit()

    assert has_element?(view, "p.settings-error", "A project with that name already exists")
    assert render(view) =~ "A project with that name already exists"

    view
    |> form("#add-project-form", %{name: "Different", linear_project_slug: "ailogic-ced4159f70c4"})
    |> render_submit()

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

    view
    |> form("#add-project-form", %{
      name: "AddedFarm",
      linear_project_slug: "other-slug-aaaaaaaa"
    })
    |> render_submit()

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
    assert has_element?(view, ~s|form[phx-submit="set_project_agent"] option[value="claude"][selected]|)

    view
    |> form(~s|form[phx-change="preview_project_agent"]|, %{agent_kind: "codex"})
    |> render_change()

    assert has_element?(view, ~s|#agent-default|)
    refute has_element?(view, ~s|#agent-default-codex|)
    assert has_element?(view, ~s|form[phx-submit="set_project_agent"] option[value="codex"][selected]|)
    assert render(view) =~ ~s(id="agent-default")
    assert has_element?(view, ~s|form[phx-submit="set_project_agent"] option[value="codex"][selected]|)

    preview_assigns = view_assigns(view)
    preview_payload = preview_assigns.payload
    [preview_project | preview_rest] = preview_payload.projects
    assert preview_project.agent_kind == "claude"

    send(
      view.pid,
      {:payload_loaded, preview_assigns.payload_seq, %{preview_payload | projects: [Map.put(preview_project, :agent_kind, "claude") | preview_rest]}}
    )

    render(view)
    assert has_element?(view, ~s|form[phx-submit="set_project_agent"] option[value="codex"][selected]|)
    refute has_element?(view, ~s|form[phx-submit="set_project_agent"] option[value="claude"][selected]|)
    assert view_assigns(view).agent_setting_drafts[preview_project.name].kind == "codex"

    seq_before = view_assigns(view).payload_seq

    view
    |> form(~s|form[phx-submit="set_project_agent"]|, %{
      agent_kind: "codex",
      model: "gpt-5.2-codex",
      effort: "high"
    })
    |> render_submit()

    assert has_element?(view, ~s|form[phx-submit="set_project_agent"] option[value="codex"][selected]|)
    seq_after = view_assigns(view).payload_seq
    assert seq_after > seq_before

    payload = view_assigns(view).payload
    [project | rest] = payload.projects
    assert project.agent_kind == "claude"

    send(view.pid, {:payload_loaded, seq_after, payload})
    render(view)
    assert has_element?(view, ~s|form[phx-submit="set_project_agent"] option[value="codex"][selected]|)
    refute has_element?(view, ~s|form[phx-submit="set_project_agent"] option[value="claude"][selected]|)

    stale_project =
      project
      |> Map.put(:agent_kind, nil)
      |> Map.put(:agent_model, nil)
      |> Map.put(:agent_effort, nil)

    send(view.pid, {:payload_loaded, seq_before, %{payload | projects: [stale_project | rest]}})
    render(view)

    assert has_element?(view, ~s|form[phx-submit="set_project_agent"] option[value="codex"][selected]|)
    assert has_element?(view, ~s|#agent-default|)

    matching_project =
      project
      |> Map.put(:agent_kind, "codex")
      |> Map.put(:agent_model, "gpt-5.2-codex")
      |> Map.put(:agent_effort, "high")

    send(view.pid, {:payload_loaded, seq_after, %{payload | projects: [matching_project | rest]}})
    render(view)

    assert has_element?(view, ~s|form[phx-submit="set_project_agent"] option[value="codex"][selected]|)
    refute Map.has_key?(view_assigns(view).agent_setting_drafts, project.name)
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

    start_supervised!({StaticOrchestrator, [name: orchestrator_name, snapshot: static_snapshot(), recipient: Keyword.get(opts, :recipient)]})

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
end
