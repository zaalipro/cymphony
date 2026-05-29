defmodule CymphonyElixir.Orchestrator.Dispatch do
  @moduledoc """
  Pure dispatch decisions for the orchestrator: the order issues are considered
  in, and which worker host a new session is placed on.

  Every function here is pure. It takes the issues, the current `running` map,
  and configuration-derived primitives (host list, per-host cap), and returns a
  decision. The orchestrator extracts these inputs from its `%State{}` and owns
  the side effects (spawning the agent task).

  Eligibility predicates (`candidate?`, `should_dispatch?`) still live in the
  orchestrator because they share issue state-name normalization with the
  reconcile path; factoring that out into a shared module is the natural next
  step before they move here too.
  """

  alias CymphonyElixir.Linear.Issue

  # Sorts missing/invalid created_at timestamps last (max signed 64-bit int).
  @max_sort_key 9_223_372_036_854_775_807

  @doc """
  Orders issues for dispatch consideration: ascending priority rank (1 is most
  urgent; missing or invalid priorities sort last), then oldest-created first,
  then identifier as a stable tiebreaker. Non-`Issue` terms sort last.
  """
  @spec sort_for_dispatch([Issue.t()]) :: [Issue.t()]
  def sort_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), created_at_sort_key(nil), ""}
    end)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp created_at_sort_key(_issue), do: @max_sort_key

  @doc """
  Selects a worker host for a new session.

  Given the current `running` map, the configured `hosts`, the optional per-host
  concurrency `limit`, and an optional `preferred` host, returns:

  - `nil` when no SSH hosts are configured (local execution),
  - `:no_worker_capacity` when every host is at the per-host limit,
  - `preferred` when it is configured and still has capacity,
  - otherwise the least-loaded host with capacity (ties broken by host order).
  """
  @spec select_worker_host(map(), [String.t()], pos_integer() | nil, String.t() | nil) ::
          String.t() | nil | :no_worker_capacity
  def select_worker_host(running, hosts, limit, preferred)
      when is_map(running) and is_list(hosts) do
    case hosts do
      [] ->
        nil

      hosts ->
        available = Enum.filter(hosts, &host_has_capacity?(running, &1, limit))

        cond do
          available == [] -> :no_worker_capacity
          preferred_available?(preferred, available) -> preferred
          true -> least_loaded_host(running, available)
        end
    end
  end

  @doc """
  Number of running sessions currently placed on `worker_host`.
  """
  @spec running_count_for_host(map(), String.t()) :: non_neg_integer()
  def running_count_for_host(running, worker_host)
      when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp host_has_capacity?(running, host, limit) when is_binary(host) do
    case limit do
      limit when is_integer(limit) and limit > 0 -> running_count_for_host(running, host) < limit
      _ -> true
    end
  end

  defp preferred_available?(preferred, hosts) when is_binary(preferred) and is_list(hosts) do
    preferred != "" and preferred in hosts
  end

  defp preferred_available?(_preferred, _hosts), do: false

  defp least_loaded_host(running, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} -> {running_count_for_host(running, host), index} end)
    |> elem(0)
  end
end
