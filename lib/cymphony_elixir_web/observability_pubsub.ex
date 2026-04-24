defmodule CymphonyElixirWeb.ObservabilityPubSub do
  @moduledoc """
  PubSub helpers for observability dashboard updates.
  """

  @pubsub CymphonyElixir.PubSub
  @topic "observability:dashboard"
  @update_message :observability_updated

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  @spec broadcast_update() :: :ok
  def broadcast_update do
    case Process.whereis(@pubsub) do
      pid when is_pid(pid) ->
        Phoenix.PubSub.broadcast(@pubsub, @topic, @update_message)

      _ ->
        :ok
    end
  end

  @spec subscribe_issue(String.t()) :: :ok | {:error, term()}
  def subscribe_issue(issue_id) when is_binary(issue_id) do
    Phoenix.PubSub.subscribe(@pubsub, issue_topic(issue_id))
  end

  @spec unsubscribe_issue(String.t()) :: :ok
  def unsubscribe_issue(issue_id) when is_binary(issue_id) do
    Phoenix.PubSub.unsubscribe(@pubsub, issue_topic(issue_id))
  end

  @spec broadcast_issue_update(String.t()) :: :ok
  def broadcast_issue_update(issue_id) when is_binary(issue_id) do
    case Process.whereis(@pubsub) do
      pid when is_pid(pid) ->
        Phoenix.PubSub.broadcast(@pubsub, issue_topic(issue_id), @update_message)

      _ ->
        :ok
    end
  end

  defp issue_topic(issue_id), do: "observability:issue:#{issue_id}"
end
