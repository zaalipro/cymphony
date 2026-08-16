defmodule CymphonyElixir.Orchestrator.Queue do
  @moduledoc """
  Pure waiting-list ranking for the orchestrator.

  Membership (active / blocked / claimed / running / retry) is the caller's
  problem. This module only orders an already-eligible list: initial Linear
  sort, persisted drag order, Linear-priority raises, and new arrivals.

  `saved_order = nil` means the project has never persisted a queue (use
  `Dispatch.sort_for_dispatch/1`). `saved_order = []` is a persisted empty
  list — every current issue is NEW (append, or insert at 0 when Urgent).
  """

  alias CymphonyElixir.Linear.Issue
  alias CymphonyElixir.Orchestrator.Dispatch

  @type issue_key :: String.t()
  @type priority_seen :: %{optional(issue_key()) => integer() | nil}

  @doc """
  Stable queue key: Linear identifier when present, otherwise the issue id.
  """
  @spec issue_key(Issue.t()) :: issue_key() | nil
  def issue_key(%Issue{identifier: identifier})
      when is_binary(identifier) and identifier != "" do
    identifier
  end

  def issue_key(%Issue{id: id}), do: id

  @doc """
  Linear priority rank used for raise/insert: 1..4 as-is, everything else 5
  (none). This is not Cymphony queue rank.
  """
  @spec linear_rank(term()) :: 1..5
  def linear_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  def linear_rank(_priority), do: 5

  @doc """
  Reconciles eligible issues against a persisted identifier order.

  Returns `{ordered_issues, new_priority_seen}` where `new_priority_seen` is
  the current raw priority (`0` / `nil` / `1..4`) for every remaining key.
  Non-`Issue` terms and issues with no key are dropped.
  """
  @spec reconcile([term()], [issue_key()] | nil, priority_seen()) ::
          {[Issue.t()], priority_seen()}
  def reconcile(issues, nil, _priority_seen) when is_list(issues) do
    ordered = issues |> issue_entries() |> Dispatch.sort_for_dispatch()
    {ordered, current_priorities(ordered)}
  end

  def reconcile(issues, saved_order, priority_seen)
      when is_list(issues) and is_list(saved_order) and is_map(priority_seen) do
    eligible = issues |> issue_entries() |> Enum.uniq_by(&issue_key/1)
    by_key = Map.new(eligible, &{issue_key(&1), &1})

    ordered =
      by_key
      |> remaining_issues(saved_order)
      |> apply_raises(priority_seen)
      |> insert_news(new_issues(eligible, saved_order))

    {ordered, current_priorities(ordered)}
  end

  @doc """
  Applies a drag permutation. Unknown keys are dropped; issues not named in
  `new_order_keys` keep their prior relative order at the end.
  """
  @spec apply_drag([term()], [issue_key()]) :: [Issue.t()]
  def apply_drag(issues, new_order_keys) when is_list(issues) and is_list(new_order_keys) do
    eligible = issues |> issue_entries() |> Enum.uniq_by(&issue_key/1)
    by_key = Map.new(eligible, &{issue_key(&1), &1})

    {ordered, taken} =
      Enum.reduce(new_order_keys, {[], MapSet.new()}, fn key, {acc, seen} ->
        case {MapSet.member?(seen, key), Map.fetch(by_key, key)} do
          {false, {:ok, issue}} -> {[issue | acc], MapSet.put(seen, key)}
          _ -> {acc, seen}
        end
      end)

    leftovers = Enum.reject(eligible, &MapSet.member?(taken, issue_key(&1)))
    Enum.reverse(ordered) ++ leftovers
  end

  @doc """
  Index at which a raised card is reinserted among `remaining` (the list
  without that card): Urgent at 0; High before the first rank `> 2`; Medium
  before `> 3`; Low before `> 4`.
  """
  @spec raise_insert_index(Issue.t(), [Issue.t()]) :: non_neg_integer()
  def raise_insert_index(%Issue{} = issue, remaining) when is_list(remaining) do
    case linear_rank(issue.priority) do
      1 ->
        0

      rank ->
        case Enum.find_index(remaining, &(linear_rank(&1.priority) > rank)) do
          nil -> length(remaining)
          index -> index
        end
    end
  end

  defp issue_entries(issues) do
    Enum.filter(issues, fn
      %Issue{} = issue -> is_binary(issue_key(issue))
      _ -> false
    end)
  end

  defp remaining_issues(by_key, saved_order) do
    saved_order
    |> Enum.uniq()
    |> Enum.filter(&Map.has_key?(by_key, &1))
    |> Enum.map(&Map.fetch!(by_key, &1))
  end

  defp new_issues(eligible, saved_order) do
    saved = MapSet.new(saved_order)
    Enum.reject(eligible, &MapSet.member?(saved, issue_key(&1)))
  end

  defp apply_raises(remaining, priority_seen) do
    Enum.reduce(remaining, remaining, fn issue, acc ->
      if raised?(issue, priority_seen) do
        rest = Enum.reject(acc, &(issue_key(&1) == issue_key(issue)))
        List.insert_at(rest, raise_insert_index(issue, rest), issue)
      else
        acc
      end
    end)
  end

  # Raise only when we have a previously seen priority for an already-queued
  # key. A missing map entry is first-seen (NEW), not rank 5.
  defp raised?(%Issue{} = issue, priority_seen) do
    case Map.fetch(priority_seen, issue_key(issue)) do
      {:ok, previous} -> linear_rank(issue.priority) < linear_rank(previous)
      :error -> false
    end
  end

  defp insert_news(ordered, new_issues) do
    Enum.reduce(new_issues, ordered, fn
      %Issue{priority: 1} = issue, acc -> [issue | acc]
      issue, acc -> acc ++ [issue]
    end)
  end

  defp current_priorities(issues) do
    Map.new(issues, &{issue_key(&1), &1.priority})
  end
end
