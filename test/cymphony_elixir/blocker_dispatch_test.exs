defmodule CymphonyElixir.BlockerDispatchTest do
  @moduledoc """
  Regression coverage for the SPEC §8.2 dispatch rule:

    > "If state is `Todo`, do not dispatch when any blocker is non-terminal."

  Verifies `Orchestrator.should_dispatch_issue_for_test/2` against the four
  cases listed in TEST-003 of `.specs/01_orchestrator_hardening_spec.md`.
  """

  use CymphonyElixir.TestSupport

  alias CymphonyElixir.Orchestrator.State

  defp seed_state do
    settings = Config.settings!()

    %State{
      config: settings,
      project_name: "blocker-test",
      max_concurrent_agents: settings.agent.max_concurrent_agents,
      running: %{},
      claimed: MapSet.new(),
      retry_attempts: %{},
      recent_completed: [],
      claude_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }
  end

  defp issue(state, blockers, opts \\ []) do
    %Issue{
      id: Keyword.get(opts, :id, "iss-#{System.unique_integer([:positive])}"),
      identifier: Keyword.get(opts, :identifier, "MT-100"),
      title: "Blocker test",
      description: "n/a",
      state: state,
      blocked_by: blockers,
      url: "https://example.org/MT-100"
    }
  end

  test "AC-006: Todo with a non-terminal blocker is NOT dispatched" do
    issue = issue("Todo", [%{id: "b1", identifier: "MT-1", state: "In Progress"}])
    refute Orchestrator.should_dispatch_issue_for_test(issue, seed_state())
  end

  test "AC-007: Todo with all-terminal blockers IS dispatched" do
    issue =
      issue("Todo", [
        %{id: "b1", identifier: "MT-1", state: "Done"},
        %{id: "b2", identifier: "MT-2", state: "Canceled"}
      ])

    assert Orchestrator.should_dispatch_issue_for_test(issue, seed_state())
  end

  test "AC-008: In Progress with a non-terminal blocker IS dispatched (rule applies to Todo only)" do
    issue = issue("In Progress", [%{id: "b1", identifier: "MT-1", state: "In Progress"}])
    assert Orchestrator.should_dispatch_issue_for_test(issue, seed_state())
  end

  test "AC-009: Todo with empty blockers IS dispatched" do
    issue = issue("Todo", [])
    assert Orchestrator.should_dispatch_issue_for_test(issue, seed_state())
  end
end
