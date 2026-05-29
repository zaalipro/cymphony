defmodule CymphonyElixir.Orchestrator.DispatchTest do
  use ExUnit.Case, async: true

  alias CymphonyElixir.Linear.Issue
  alias CymphonyElixir.Orchestrator.Dispatch

  describe "sort_for_dispatch/1" do
    test "orders by priority, then oldest-created, then identifier" do
      high_newer = %Issue{id: "a", identifier: "MT-201", title: "t", state: "Todo", priority: 1, created_at: ~U[2026-01-02 00:00:00Z]}
      high_older = %Issue{id: "b", identifier: "MT-200", title: "t", state: "Todo", priority: 1, created_at: ~U[2026-01-01 00:00:00Z]}
      low_older = %Issue{id: "c", identifier: "MT-199", title: "t", state: "Todo", priority: 2, created_at: ~U[2025-12-01 00:00:00Z]}

      sorted = Dispatch.sort_for_dispatch([low_older, high_newer, high_older])
      assert Enum.map(sorted, & &1.identifier) == ["MT-200", "MT-201", "MT-199"]
    end

    test "sorts missing or invalid priority last" do
      ranked = %Issue{id: "a", identifier: "MT-1", title: "t", state: "Todo", priority: 3, created_at: ~U[2026-01-01 00:00:00Z]}
      unranked = %Issue{id: "b", identifier: "MT-2", title: "t", state: "Todo", priority: nil, created_at: ~U[2025-01-01 00:00:00Z]}

      assert Dispatch.sort_for_dispatch([unranked, ranked]) == [ranked, unranked]
    end

    test "sorts issues without a created_at after those with one, within a priority" do
      with_date = %Issue{id: "a", identifier: "MT-1", title: "t", state: "Todo", priority: 1, created_at: ~U[2026-01-01 00:00:00Z]}
      no_date = %Issue{id: "b", identifier: "MT-2", title: "t", state: "Todo", priority: 1, created_at: nil}

      assert Dispatch.sort_for_dispatch([no_date, with_date]) == [with_date, no_date]
    end

    test "tolerates non-Issue terms by sorting them last" do
      issue = %Issue{id: "a", identifier: "MT-1", title: "t", state: "Todo", priority: 1, created_at: ~U[2026-01-01 00:00:00Z]}
      assert Dispatch.sort_for_dispatch([:junk, issue]) == [issue, :junk]
    end
  end

  describe "select_worker_host/4" do
    test "returns nil when no hosts are configured (local execution)" do
      assert Dispatch.select_worker_host(%{}, [], 1, nil) == nil
    end

    test "skips hosts that are full under the per-host cap" do
      running = %{"i1" => %{worker_host: "worker-a"}}
      assert Dispatch.select_worker_host(running, ["worker-a", "worker-b"], 1, nil) == "worker-b"
    end

    test "returns :no_worker_capacity when every host is full" do
      running = %{"i1" => %{worker_host: "worker-a"}, "i2" => %{worker_host: "worker-b"}}
      assert Dispatch.select_worker_host(running, ["worker-a", "worker-b"], 1, nil) == :no_worker_capacity
    end

    test "keeps the preferred host when it still has capacity" do
      running = %{"i1" => %{worker_host: "worker-a"}, "i2" => %{worker_host: "worker-b"}}
      assert Dispatch.select_worker_host(running, ["worker-a", "worker-b"], 2, "worker-a") == "worker-a"
    end

    test "ignores a full preferred host and picks the least-loaded" do
      running = %{"i1" => %{worker_host: "worker-a"}, "i2" => %{worker_host: "worker-a"}}
      assert Dispatch.select_worker_host(running, ["worker-a", "worker-b"], 2, "worker-a") == "worker-b"
    end

    test "breaks least-loaded ties by host order" do
      assert Dispatch.select_worker_host(%{}, ["worker-a", "worker-b"], 5, nil) == "worker-a"
    end

    test "treats a nil or non-positive limit as unlimited capacity" do
      running = %{"i1" => %{worker_host: "worker-a"}, "i2" => %{worker_host: "worker-a"}}
      assert Dispatch.select_worker_host(running, ["worker-a"], nil, nil) == "worker-a"
      assert Dispatch.select_worker_host(running, ["worker-a"], 0, nil) == "worker-a"
    end
  end

  describe "running_count_for_host/2" do
    test "counts running sessions placed on a host" do
      running = %{
        "i1" => %{worker_host: "worker-a"},
        "i2" => %{worker_host: "worker-a"},
        "i3" => %{worker_host: "worker-b"}
      }

      assert Dispatch.running_count_for_host(running, "worker-a") == 2
      assert Dispatch.running_count_for_host(running, "worker-b") == 1
      assert Dispatch.running_count_for_host(running, "worker-c") == 0
    end
  end
end
