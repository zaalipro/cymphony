defmodule CymphonyElixir.Orchestrator.RunSpecDispatchTest do
  use CymphonyElixir.TestSupport

  alias CymphonyElixir.Orchestrator

  test "dispatch resolves per-issue run spec from labels and directive" do
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
    assert resolved.source == :labels
  end

  test "dispatch resolves agent:antigravity labels and description directives" do
    labeled = %Issue{
      id: "iss-agy-label",
      identifier: "MT-510",
      title: "Antigravity label",
      description: nil,
      state: "Todo",
      url: "https://example.org/MT-510",
      labels: ["agent:antigravity", "model:gemini-3.7-flash-high"]
    }

    directed = %Issue{
      id: "iss-agy-dir",
      identifier: "MT-511",
      title: "Antigravity directive",
      description: "cymphony: agent=antigravity effort=high",
      state: "Todo",
      url: "https://example.org/MT-511",
      labels: []
    }

    config = Config.settings!()
    from_label = Orchestrator.resolve_run_spec_for_test(labeled, config)
    from_directive = Orchestrator.resolve_run_spec_for_test(directed, config)

    assert from_label.agent_kind == "antigravity"
    assert from_label.model == "gemini-3.7-flash-high"
    assert from_label.source == :labels
    assert from_directive.agent_kind == "antigravity"
    assert from_directive.effort == "high"
    assert from_directive.source == :directive
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

  test "orchestrator running entry stores agent:antigravity from labels" do
    orchestrator_name = Module.concat(__MODULE__, :AntigravityLabelOrch)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    issue = %Issue{
      id: "iss-agy-running",
      identifier: "MT-512",
      title: "Antigravity running",
      description: nil,
      state: "Todo",
      url: "https://example.org/MT-512",
      labels: ["agent:antigravity", "effort:medium"]
    }

    :ok = Orchestrator.dispatch_issue_for_test(pid, issue)

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [entry]} = snapshot
    assert entry.agent_kind == "antigravity"
    assert entry.effort == "medium"
  end

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

  test "set_issue_run_spec restarts the session with a pinned agent_kind" do
    orchestrator_name = Module.concat(__MODULE__, :KindOverrideOrch)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    issue = %Issue{
      id: "iss-kind-override",
      identifier: "MT-513",
      title: "Kind override",
      state: "In Progress",
      url: "https://example.org/MT-513",
      labels: []
    }

    :ok = Orchestrator.dispatch_issue_for_test(pid, issue)
    assert %{running: [first]} = GenServer.call(pid, :snapshot)
    assert first.agent_kind == "claude"

    assert :ok =
             Orchestrator.set_issue_run_spec(pid, "iss-kind-override", %{
               agent_kind: "antigravity",
               model: "gemini-3.7-flash-high",
               effort: "high"
             })

    snapshot = GenServer.call(pid, :snapshot)
    assert %{running: [entry]} = snapshot
    assert entry.agent_kind == "antigravity"
    assert entry.model == "gemini-3.7-flash-high"
    assert entry.effort == "high"
  end

  test "set_providers writes the rotation onto the active kind section" do
    orchestrator_name = Module.concat(__MODULE__, :ProvidersSectionOrch)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    assert :ok = Orchestrator.set_providers(pid, ["cv1", "cz2"])
    state = :sys.get_state(pid)
    assert state.providers == ["cv1", "cz2"]
    assert state.config.claude.provider == "cv1"
    assert state.config.claude.providers == ["cv1", "cz2"]

    assert :ok = Orchestrator.set_agent_settings(pid, %{"agent" => "antigravity"})
    assert :ok = Orchestrator.set_providers(pid, ["g1", "g2"])

    state = :sys.get_state(pid)
    assert state.config.agent.kind == "antigravity"
    assert state.providers == ["g1", "g2"]
    assert state.config.antigravity.provider == "g1"
    assert state.config.antigravity.providers == ["g1", "g2"]
    assert state.config.claude.providers == ["cv1", "cz2"]
  end

  test "set_agent_settings accepts known kinds and ignores unknown ones" do
    orchestrator_name = Module.concat(__MODULE__, :KindSettingOrch)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    assert :ok = Orchestrator.set_agent_settings(pid, %{"agent" => "antigravity"})
    state = :sys.get_state(pid)
    assert state.config.agent.kind == "antigravity"
    assert CymphonyElixir.Agent.section(state.config, "antigravity").command == "agy"

    assert :ok = Orchestrator.set_agent_settings(pid, %{"agent" => "not-a-kind"})
    state = :sys.get_state(pid)
    assert state.config.agent.kind == "antigravity"
  end

  test "snapshot agent_command comes from the active kind section" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "antigravity")

    orchestrator_name = Module.concat(__MODULE__, :AgentCommandOrch)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    snapshot = GenServer.call(pid, :snapshot)
    assert snapshot.agent_kind == "antigravity"
    assert snapshot.agent_command == "agy"
  end

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
end
