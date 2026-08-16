defmodule CymphonyElixir.Tracker.MemoryTest do
  use ExUnit.Case, async: false

  alias CymphonyElixir.Linear.Issue
  alias CymphonyElixir.Tracker.Memory

  setup do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}
    todo = %Issue{id: "issue-2", identifier: "MT-2", state: "Todo"}

    Application.put_env(:cymphony_elixir, :memory_tracker_issues, [issue, todo, %{id: "ignored"}, :junk])

    on_exit(fn ->
      Application.delete_env(:cymphony_elixir, :memory_tracker_issues)
      Application.delete_env(:cymphony_elixir, :memory_tracker_error)
      Application.delete_env(:cymphony_elixir, :memory_tracker_recipient)
    end)

    {:ok, issue: issue, todo: todo}
  end

  test "fetch_candidate_issues/0 and /1 return only Issue structs", %{issue: issue, todo: todo} do
    assert {:ok, [^issue, ^todo]} = Memory.fetch_candidate_issues()
    assert {:ok, [^issue, ^todo]} = Memory.fetch_candidate_issues(:unused_config)
  end

  test "fetch_candidate_issues returns a configured error" do
    Application.put_env(:cymphony_elixir, :memory_tracker_error, :linear_unavailable)
    assert Memory.fetch_candidate_issues() == {:error, :linear_unavailable}
    assert Memory.fetch_candidate_issues(:unused_config) == {:error, :linear_unavailable}
  end

  test "fetch_issues_by_states matches trimmed, case-insensitive names and ignores non-binaries", %{
    issue: issue,
    todo: todo
  } do
    assert {:ok, [^issue]} = Memory.fetch_issues_by_states([" in progress ", 42])
    assert {:ok, [^todo]} = Memory.fetch_issues_by_states(["TODO"], :unused_config)
    assert {:ok, []} = Memory.fetch_issues_by_states([:not_a_state, 99])
  end

  test "fetch_issue_states_by_ids/1 and /2 filter by id", %{issue: issue} do
    assert {:ok, [^issue]} = Memory.fetch_issue_states_by_ids(["issue-1"])
    assert {:ok, []} = Memory.fetch_issue_states_by_ids(["missing"], :unused_config)
  end

  test "create_comment and update_issue_state notify a pid recipient" do
    Application.put_env(:cymphony_elixir, :memory_tracker_recipient, self())

    assert :ok = Memory.create_comment("issue-1", "hello")
    assert :ok = Memory.update_issue_state("issue-1", "Done")
    assert_receive {:memory_tracker_comment, "issue-1", "hello"}
    assert_receive {:memory_tracker_state_update, "issue-1", "Done"}
  end

  test "create_comment/3 and update_issue_state/3 wrap the zero-arity writers" do
    Application.put_env(:cymphony_elixir, :memory_tracker_recipient, self())

    assert :ok = Memory.create_comment("issue-1", "via-config", :unused_config)
    assert :ok = Memory.update_issue_state("issue-1", "Human Review", :unused_config)
    assert_receive {:memory_tracker_comment, "issue-1", "via-config"}
    assert_receive {:memory_tracker_state_update, "issue-1", "Human Review"}
  end

  test "create_comment and update_issue_state succeed without a pid recipient" do
    Application.delete_env(:cymphony_elixir, :memory_tracker_recipient)
    assert :ok = Memory.create_comment("issue-1", "quiet")
    assert :ok = Memory.update_issue_state("issue-1", "Quiet")
    refute_received {:memory_tracker_comment, _, _}
    refute_received {:memory_tracker_state_update, _, _}

    Application.put_env(:cymphony_elixir, :memory_tracker_recipient, :not_a_pid)
    assert :ok = Memory.create_comment("issue-1", "still-quiet")
    assert :ok = Memory.update_issue_state("issue-1", "Still Quiet")
    refute_received {:memory_tracker_comment, _, _}
    refute_received {:memory_tracker_state_update, _, _}
  end
end
