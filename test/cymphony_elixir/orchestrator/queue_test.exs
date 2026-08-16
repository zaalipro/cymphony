defmodule CymphonyElixir.Orchestrator.QueueTest do
  use ExUnit.Case, async: true

  alias CymphonyElixir.Linear.Issue
  alias CymphonyElixir.Orchestrator.Dispatch
  alias CymphonyElixir.Orchestrator.Queue

  describe "issue_key/1" do
    test "prefers a present identifier over id" do
      issue = %Issue{id: "id-1", identifier: "LLM-51", title: "t", state: "Todo"}
      assert Queue.issue_key(issue) == "LLM-51"
    end

    test "falls back to id when identifier is missing or blank" do
      missing = %Issue{id: "id-2", identifier: nil, title: "t", state: "Todo"}
      blank = %Issue{id: "id-3", identifier: "", title: "t", state: "Todo"}

      assert Queue.issue_key(missing) == "id-2"
      assert Queue.issue_key(blank) == "id-3"
    end
  end

  describe "linear_rank/1" do
    test "keeps Linear 1..4 and maps none/invalid to 5" do
      assert Queue.linear_rank(1) == 1
      assert Queue.linear_rank(2) == 2
      assert Queue.linear_rank(3) == 3
      assert Queue.linear_rank(4) == 4
      assert Queue.linear_rank(0) == 5
      assert Queue.linear_rank(nil) == 5
      assert Queue.linear_rank(99) == 5
    end
  end

  describe "raise_insert_index/2" do
    test "places Urgent at 0 and High/Medium/Low before the first weaker card" do
      urgent = %Issue{id: "u", identifier: "U", title: "t", state: "Todo", priority: 1}
      high = %Issue{id: "h", identifier: "H", title: "t", state: "Todo", priority: 2}
      medium = %Issue{id: "m", identifier: "M", title: "t", state: "Todo", priority: 3}
      low = %Issue{id: "l", identifier: "L", title: "t", state: "Todo", priority: 4}
      none = %Issue{id: "n", identifier: "N", title: "t", state: "Todo", priority: nil}
      remaining = [urgent, high, medium, low, none]

      assert Queue.raise_insert_index(urgent, remaining) == 0
      assert Queue.raise_insert_index(high, remaining) == 2
      assert Queue.raise_insert_index(medium, remaining) == 3
      assert Queue.raise_insert_index(low, remaining) == 4
      assert Queue.raise_insert_index(none, remaining) == 5
    end

    test "appends when no remaining card is weaker, and uses 0 when remaining is empty" do
      high = %Issue{id: "h", identifier: "H", title: "t", state: "Todo", priority: 2}
      urgent = %Issue{id: "u", identifier: "U", title: "t", state: "Todo", priority: 1}
      other_high = %Issue{id: "h2", identifier: "H2", title: "t", state: "Todo", priority: 2}

      assert Queue.raise_insert_index(high, [urgent, other_high]) == 2
      assert Queue.raise_insert_index(high, []) == 0
    end
  end

  describe "reconcile/3" do
    test "initial sort with no saved order equals Dispatch.sort_for_dispatch" do
      high_newer = %Issue{
        id: "a",
        identifier: "MT-201",
        title: "t",
        state: "Todo",
        priority: 1,
        created_at: ~U[2026-01-02 00:00:00Z]
      }

      high_older = %Issue{
        id: "b",
        identifier: "MT-200",
        title: "t",
        state: "Todo",
        priority: 1,
        created_at: ~U[2026-01-01 00:00:00Z]
      }

      low_older = %Issue{
        id: "c",
        identifier: "MT-199",
        title: "t",
        state: "Todo",
        priority: 2,
        created_at: ~U[2025-12-01 00:00:00Z]
      }

      issues = [low_older, high_newer, high_older]
      {ordered, seen} = Queue.reconcile(issues, nil, %{})

      assert ordered == Dispatch.sort_for_dispatch(issues)
      assert keys(ordered) == ["MT-200", "MT-201", "MT-199"]

      assert seen == %{
               "MT-200" => 1,
               "MT-201" => 1,
               "MT-199" => 2
             }
    end

    test "empty-saved treats every issue as NEW (append unless Urgent)" do
      medium = %Issue{id: "a", identifier: "A", title: "t", state: "Todo", priority: 3}
      urgent = %Issue{id: "b", identifier: "B", title: "t", state: "Todo", priority: 1}
      low = %Issue{id: "c", identifier: "C", title: "t", state: "Todo", priority: 4}

      {ordered, seen} = Queue.reconcile([medium, urgent, low], [], %{})

      assert keys(ordered) == ["B", "A", "C"]
      assert seen == %{"A" => 3, "B" => 1, "C" => 4}
    end

    test "drag permutation persists until a raise" do
      a = %Issue{id: "a", identifier: "A", title: "t", state: "Todo", priority: 1}
      b = %Issue{id: "b", identifier: "B", title: "t", state: "Todo", priority: 2}
      c = %Issue{id: "c", identifier: "C", title: "t", state: "Todo", priority: 3}
      dragged = Queue.apply_drag([a, b, c], ["C", "B", "A"])
      seen = %{"A" => 1, "B" => 2, "C" => 3}

      {held, _} = Queue.reconcile(dragged, ["C", "B", "A"], seen)
      assert keys(held) == ["C", "B", "A"]

      c_raised = %{c | priority: 2}
      {raised, new_seen} = Queue.reconcile([a, b, c_raised], ["C", "B", "A"], seen)

      # High before first remaining rank > 2; B is High and A is Urgent, so C appends.
      assert keys(raised) == ["B", "A", "C"]
      assert new_seen == %{"B" => 2, "A" => 1, "C" => 2}
    end

    test "3->2 reinserts that card without reshuffling others" do
      a = %Issue{id: "a", identifier: "A", title: "t", state: "Todo", priority: 3}
      b = %Issue{id: "b", identifier: "B", title: "t", state: "Todo", priority: 4}
      c = %Issue{id: "c", identifier: "C", title: "t", state: "Todo", priority: 2}
      seen = %{"A" => 3, "B" => 4, "C" => 3}

      {ordered, _} = Queue.reconcile([a, b, c], ["A", "B", "C"], seen)
      assert keys(ordered) == ["C", "A", "B"]
    end

    test "2->1 reinserts that card without reshuffling others" do
      a = %Issue{id: "a", identifier: "A", title: "t", state: "Todo", priority: 2}
      b = %Issue{id: "b", identifier: "B", title: "t", state: "Todo", priority: 3}
      c = %Issue{id: "c", identifier: "C", title: "t", state: "Todo", priority: 1}
      seen = %{"A" => 2, "B" => 3, "C" => 2}

      {ordered, _} = Queue.reconcile([a, b, c], ["A", "B", "C"], seen)
      assert keys(ordered) == ["C", "A", "B"]
    end

    test "2->3 and High->Low after a drag do not move the card" do
      a = %Issue{id: "a", identifier: "A", title: "t", state: "Todo", priority: 3}
      b = %Issue{id: "b", identifier: "B", title: "t", state: "Todo", priority: 3}
      c = %Issue{id: "c", identifier: "C", title: "t", state: "Todo", priority: 4}
      seen = %{"A" => 2, "B" => 3, "C" => 2}

      {ordered, new_seen} = Queue.reconcile([a, b, c], ["C", "B", "A"], seen)
      assert keys(ordered) == ["C", "B", "A"]
      assert new_seen == %{"C" => 4, "B" => 3, "A" => 3}
    end

    test "new issues append unless Linear Urgent, which inserts at 0" do
      a = %Issue{id: "a", identifier: "A", title: "t", state: "Todo", priority: 3}
      b = %Issue{id: "b", identifier: "B", title: "t", state: "Todo", priority: 3}
      new_medium = %Issue{id: "c", identifier: "C", title: "t", state: "Todo", priority: 3}
      new_urgent = %Issue{id: "d", identifier: "D", title: "t", state: "Todo", priority: 1}
      seen = %{"A" => 3, "B" => 3}

      {appended, _} = Queue.reconcile([a, b, new_medium], ["A", "B"], seen)
      assert keys(appended) == ["A", "B", "C"]

      {front, _} = Queue.reconcile([a, b, new_urgent], ["A", "B"], seen)
      assert keys(front) == ["D", "A", "B"]
    end

    test "0/nil -> 2 is a raise (rank 5 -> 2)" do
      a = %Issue{id: "a", identifier: "A", title: "t", state: "Todo", priority: 3}
      from_nil = %Issue{id: "b", identifier: "B", title: "t", state: "Todo", priority: 2}
      from_zero = %Issue{id: "c", identifier: "C", title: "t", state: "Todo", priority: 2}
      d = %Issue{id: "d", identifier: "D", title: "t", state: "Todo", priority: 4}

      {nil_raised, _} =
        Queue.reconcile([a, from_nil, d], ["A", "B", "D"], %{"A" => 3, "B" => nil, "D" => 4})

      assert keys(nil_raised) == ["B", "A", "D"]

      {zero_raised, _} =
        Queue.reconcile([a, from_zero, d], ["A", "C", "D"], %{"A" => 3, "C" => 0, "D" => 4})

      assert keys(zero_raised) == ["C", "A", "D"]
    end

    test "first-seen key is NEW not raise" do
      a = %Issue{id: "a", identifier: "A", title: "t", state: "Todo", priority: 3}
      first_seen_high = %Issue{id: "b", identifier: "B", title: "t", state: "Todo", priority: 2}

      {ordered, seen} = Queue.reconcile([a, first_seen_high], ["A"], %{"A" => 3})
      assert keys(ordered) == ["A", "B"]
      assert seen == %{"A" => 3, "B" => 2}
    end

    test "a saved key without a seen priority is not a raise" do
      a = %Issue{id: "a", identifier: "A", title: "t", state: "Todo", priority: 3}
      b = %Issue{id: "b", identifier: "B", title: "t", state: "Todo", priority: 2}

      {ordered, _} = Queue.reconcile([a, b], ["A", "B"], %{"A" => 3})
      assert keys(ordered) == ["A", "B"]
    end

    test "dropped ineligible keys disappear from order and seen" do
      a = %Issue{id: "a", identifier: "A", title: "t", state: "Todo", priority: 3}
      c = %Issue{id: "c", identifier: "C", title: "t", state: "Todo", priority: 3}
      seen = %{"A" => 3, "B" => 2, "C" => 3}

      {ordered, new_seen} = Queue.reconcile([a, c], ["A", "B", "C"], seen)
      assert keys(ordered) == ["A", "C"]
      assert new_seen == %{"A" => 3, "C" => 3}
    end

    test "tolerates non-Issue terms and keyless issues by dropping them" do
      issue = %Issue{id: "a", identifier: "A", title: "t", state: "Todo", priority: 2}
      keyless = %Issue{id: nil, identifier: nil, title: "t", state: "Todo", priority: 1}

      {initial, initial_seen} = Queue.reconcile([:junk, issue, keyless], nil, %{})
      assert initial == [issue]
      assert initial_seen == %{"A" => 2}

      {held, _} = Queue.reconcile([:junk, issue, keyless], ["A"], %{"A" => 2})
      assert held == [issue]
    end

    test "ignores stale saved_order keys and duplicate saved keys" do
      a = %Issue{id: "a", identifier: "A", title: "t", state: "Todo", priority: 3}
      b = %Issue{id: "b", identifier: "B", title: "t", state: "Todo", priority: 3}

      {ordered, _} = Queue.reconcile([a, b], ["GONE", "A", "A", "B"], %{"A" => 3, "B" => 3})
      assert keys(ordered) == ["A", "B"]
    end
  end

  describe "apply_drag/2" do
    test "full-order contract permutes the waiting list" do
      a = %Issue{id: "a", identifier: "A", title: "t", state: "Todo", priority: 3}
      b = %Issue{id: "b", identifier: "B", title: "t", state: "Todo", priority: 2}
      c = %Issue{id: "c", identifier: "C", title: "t", state: "Todo", priority: 1}

      assert keys(Queue.apply_drag([a, b, c], ["C", "A", "B"])) == ["C", "A", "B"]
    end

    test "drops unknown keys and keeps leftovers in prior relative order at the end" do
      a = %Issue{id: "a", identifier: "A", title: "t", state: "Todo", priority: 3}
      b = %Issue{id: "b", identifier: "B", title: "t", state: "Todo", priority: 3}
      c = %Issue{id: "c", identifier: "C", title: "t", state: "Todo", priority: 3}
      d = %Issue{id: "d", identifier: "D", title: "t", state: "Todo", priority: 3}

      ordered = Queue.apply_drag([a, b, c, d], ["C", "NOPE", "A", "A"])
      assert keys(ordered) == ["C", "A", "B", "D"]
    end

    test "empty order leaves every issue as a leftover" do
      a = %Issue{id: "a", identifier: "A", title: "t", state: "Todo", priority: 3}
      b = %Issue{id: "b", identifier: "B", title: "t", state: "Todo", priority: 3}

      assert Queue.apply_drag([:junk, a, b], []) == [a, b]
    end
  end

  defp keys(issues), do: Enum.map(issues, &Queue.issue_key/1)
end
