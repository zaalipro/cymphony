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
    def init(opts), do: {:ok, opts}

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
    send(view.pid, {:payload_loaded, %{payload | running: [entry | rest], projects: patch_running(payload.projects, entry)}})

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

  defp start_dashboard(opts \\ []) do
    orchestrator_name = Module.concat(__MODULE__, :"Orch#{System.unique_integer([:positive])}")

    start_supervised!({StaticOrchestrator, [name: orchestrator_name, snapshot: static_snapshot(), recipient: Keyword.get(opts, :recipient)]})

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)
    ensure_harness_stream_started()
    orchestrator_name
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
