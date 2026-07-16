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
