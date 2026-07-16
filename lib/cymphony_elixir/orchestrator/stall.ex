defmodule CymphonyElixir.Orchestrator.Stall do
  @moduledoc """
  Pure stall-detection helpers for the orchestrator.

  Given a running-issue entry (the per-session map the orchestrator keeps in
  `State.running`) and the current time, these functions decide whether the
  agent has gone silent past the configured timeout. The orchestrator owns the
  impure reaction — terminating the session and rescheduling it with backoff.

  A running entry is treated loosely as a map; the only keys consulted are
  `:last_agent_timestamp` (most recent observed Claude activity) and
  `:started_at` (session start), in that order of preference.
  """

  @doc """
  Returns the most recent activity timestamp for a running entry: the last
  observed Claude event, falling back to when the session started. Returns `nil`
  when the entry carries neither (or is not a map).
  """
  @spec last_activity_timestamp(map()) :: DateTime.t() | nil
  def last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_agent_timestamp) || Map.get(running_entry, :started_at)
  end

  def last_activity_timestamp(_running_entry), do: nil

  @doc """
  Milliseconds elapsed since the entry's last activity relative to `now`, or
  `nil` when no activity timestamp is available. Never negative (a future
  timestamp clamps to `0`).
  """
  @spec elapsed_ms(map(), DateTime.t()) :: non_neg_integer() | nil
  def elapsed_ms(running_entry, %DateTime{} = now) do
    case last_activity_timestamp(running_entry) do
      %DateTime{} = timestamp -> max(0, DateTime.diff(now, timestamp, :millisecond))
      _ -> nil
    end
  end

  @doc """
  True when the entry has been silent longer than `timeout_ms`.

  A non-positive `timeout_ms` disables detection (always `false`); an entry with
  no activity timestamp is never considered stalled.
  """
  @spec stalled?(map(), DateTime.t(), integer()) :: boolean()
  def stalled?(_running_entry, %DateTime{}, timeout_ms) when timeout_ms <= 0, do: false

  def stalled?(running_entry, %DateTime{} = now, timeout_ms) when is_integer(timeout_ms) do
    case elapsed_ms(running_entry, now) do
      ms when is_integer(ms) -> ms > timeout_ms
      _ -> false
    end
  end
end
