defmodule CymphonyElixir.ObservabilityPubSubTest do
  use CymphonyElixir.TestSupport

  alias CymphonyElixirWeb.ObservabilityPubSub

  test "subscribe and broadcast_update deliver dashboard updates" do
    assert :ok = ObservabilityPubSub.subscribe()
    assert :ok = ObservabilityPubSub.broadcast_update()
    assert_receive :observability_updated
  end

  test "broadcast_update is a no-op when pubsub is unavailable" do
    pubsub_child_id = Phoenix.PubSub.Supervisor

    on_exit(fn ->
      if Process.whereis(CymphonyElixir.PubSub) == nil do
        assert {:ok, _pid} =
                 Supervisor.restart_child(CymphonyElixir.Supervisor, pubsub_child_id)
      end
    end)

    assert is_pid(Process.whereis(CymphonyElixir.PubSub))
    assert :ok = Supervisor.terminate_child(CymphonyElixir.Supervisor, pubsub_child_id)
    refute Process.whereis(CymphonyElixir.PubSub)

    assert :ok = ObservabilityPubSub.broadcast_update()
  end

  test "subscribe_issue and broadcast_issue_update deliver issue updates" do
    issue_id = "issue-#{System.unique_integer([:positive])}"
    assert :ok = ObservabilityPubSub.subscribe_issue(issue_id)
    assert :ok = ObservabilityPubSub.broadcast_issue_update(issue_id)
    assert_receive :observability_updated
  end

  test "unsubscribe_issue stops delivery" do
    issue_id = "issue-#{System.unique_integer([:positive])}"
    assert :ok = ObservabilityPubSub.subscribe_issue(issue_id)
    assert :ok = ObservabilityPubSub.unsubscribe_issue(issue_id)
    assert :ok = ObservabilityPubSub.unsubscribe_issue(issue_id)

    assert :ok = ObservabilityPubSub.broadcast_issue_update(issue_id)
    refute_receive :observability_updated
  end

  test "broadcast_issue_update is a no-op when pubsub is unavailable" do
    pubsub_child_id = Phoenix.PubSub.Supervisor

    on_exit(fn ->
      if Process.whereis(CymphonyElixir.PubSub) == nil do
        assert {:ok, _pid} =
                 Supervisor.restart_child(CymphonyElixir.Supervisor, pubsub_child_id)
      end
    end)

    assert is_pid(Process.whereis(CymphonyElixir.PubSub))
    assert :ok = Supervisor.terminate_child(CymphonyElixir.Supervisor, pubsub_child_id)
    refute Process.whereis(CymphonyElixir.PubSub)

    assert :ok = ObservabilityPubSub.broadcast_issue_update("issue-down")
  end

  test "subscribe_harness receives the harness stream map" do
    issue_id = "harness-#{System.unique_integer([:positive])}"
    assert :ok = ObservabilityPubSub.subscribe_harness(issue_id)

    payload = %{
      event: :harness_stream,
      issue_id: issue_id,
      last_seq: 1,
      lines: [%{seq: 1, at: DateTime.utc_now(), text: "hello"}],
      dropped: 0
    }

    assert :ok = ObservabilityPubSub.broadcast_harness(issue_id, payload)
    assert_receive ^payload
  end

  test "unsubscribe_harness stops delivery" do
    issue_id = "harness-#{System.unique_integer([:positive])}"
    assert :ok = ObservabilityPubSub.subscribe_harness(issue_id)
    assert :ok = ObservabilityPubSub.unsubscribe_harness(issue_id)
    assert :ok = ObservabilityPubSub.unsubscribe_harness(issue_id)

    assert :ok =
             ObservabilityPubSub.broadcast_harness(issue_id, %{
               event: :harness_stream,
               issue_id: issue_id,
               last_seq: 1,
               lines: [],
               dropped: 0
             })

    refute_receive %{event: :harness_stream}
  end

  test "broadcast_harness is a no-op when pubsub is unavailable" do
    pubsub_child_id = Phoenix.PubSub.Supervisor

    on_exit(fn ->
      if Process.whereis(CymphonyElixir.PubSub) == nil do
        assert {:ok, _pid} =
                 Supervisor.restart_child(CymphonyElixir.Supervisor, pubsub_child_id)
      end
    end)

    assert is_pid(Process.whereis(CymphonyElixir.PubSub))
    assert :ok = Supervisor.terminate_child(CymphonyElixir.Supervisor, pubsub_child_id)
    refute Process.whereis(CymphonyElixir.PubSub)

    assert :ok =
             ObservabilityPubSub.broadcast_harness("issue-down", %{
               event: :harness_stream,
               issue_id: "issue-down"
             })
  end
end
