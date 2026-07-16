defmodule CymphonyElixir.Orchestrator.StallTest do
  use ExUnit.Case, async: true

  alias CymphonyElixir.Orchestrator.Stall

  @now ~U[2026-05-29 12:00:10Z]

  describe "last_activity_timestamp/1" do
    test "prefers :last_agent_timestamp over :started_at" do
      entry = %{started_at: ~U[2026-05-29 12:00:00Z], last_agent_timestamp: ~U[2026-05-29 12:00:08Z]}
      assert Stall.last_activity_timestamp(entry) == ~U[2026-05-29 12:00:08Z]
    end

    test "falls back to :started_at when no :last_agent_timestamp" do
      entry = %{started_at: ~U[2026-05-29 12:00:00Z]}
      assert Stall.last_activity_timestamp(entry) == ~U[2026-05-29 12:00:00Z]
    end

    test "returns nil when neither key is present" do
      assert Stall.last_activity_timestamp(%{}) == nil
    end

    test "returns nil for a non-map entry" do
      assert Stall.last_activity_timestamp(nil) == nil
    end
  end

  describe "elapsed_ms/2" do
    test "computes milliseconds since the last activity" do
      entry = %{last_agent_timestamp: ~U[2026-05-29 12:00:08Z]}
      assert Stall.elapsed_ms(entry, @now) == 2_000
    end

    test "uses :started_at when that is the only timestamp" do
      entry = %{started_at: ~U[2026-05-29 12:00:00Z]}
      assert Stall.elapsed_ms(entry, @now) == 10_000
    end

    test "clamps a future timestamp to 0" do
      entry = %{started_at: ~U[2026-05-29 12:00:20Z]}
      assert Stall.elapsed_ms(entry, @now) == 0
    end

    test "returns nil when there is no activity timestamp" do
      assert Stall.elapsed_ms(%{}, @now) == nil
    end
  end

  describe "stalled?/3" do
    test "true when silent longer than the timeout" do
      entry = %{started_at: ~U[2026-05-29 12:00:00Z]}
      assert Stall.stalled?(entry, @now, 5_000)
    end

    test "false when within the timeout" do
      entry = %{started_at: ~U[2026-05-29 12:00:00Z]}
      refute Stall.stalled?(entry, @now, 30_000)
    end

    test "false when the timeout is disabled (non-positive)" do
      entry = %{started_at: ~U[2026-05-29 12:00:00Z]}
      refute Stall.stalled?(entry, @now, 0)
      refute Stall.stalled?(entry, @now, -1)
    end

    test "false when the entry has no activity timestamp" do
      refute Stall.stalled?(%{}, @now, 1_000)
    end
  end
end
