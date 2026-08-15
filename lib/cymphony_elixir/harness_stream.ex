defmodule CymphonyElixir.HarnessStream do
  @moduledoc """
  Per-issue ring buffer for live agent CLI stdout.

  Lines are truncated to 2048 bytes and stored newest-kept (max 400). Incremental
  broadcasts are coalesced: the first append after a quiet period flushes immediately,
  then at most one `ObservabilityPubSub.broadcast_harness/2` per issue per 80ms,
  carrying at most 40 newly-appended lines.
  """

  use GenServer

  alias CymphonyElixirWeb.ObservabilityPubSub

  @table __MODULE__
  @max_line_bytes 2048
  @max_lines 400
  @max_broadcast_lines 40
  @coalesce_ms 80

  @type line :: %{seq: pos_integer(), at: DateTime.t(), text: String.t()}

  @type snapshot :: %{
          issue_id: String.t(),
          last_seq: non_neg_integer(),
          lines: [line()],
          dropped: non_neg_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Append a raw stdout line for `issue_id`.

  Truncates to 2048 bytes, assigns the next monotonic seq (starting at 1), and
  may broadcast a coalesced `:harness_stream` payload.
  """
  @spec append(String.t(), String.t()) :: :ok
  def append(issue_id, raw) when is_binary(issue_id) and is_binary(raw) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(pid, {:append, issue_id, raw})

      _ ->
        :ok
    end
  end

  @doc """
  Return the current ring for `issue_id`.

  Unknown issues (and a missing table) return `last_seq` 0, empty `lines`, and `dropped` 0.
  """
  @spec snapshot(String.t()) :: snapshot()
  def snapshot(issue_id) when is_binary(issue_id) do
    case lookup_bucket(issue_id) do
      {:ok, bucket} -> public_snapshot(issue_id, bucket)
      :error -> empty_snapshot(issue_id)
    end
  end

  @doc """
  Delete the issue bucket and cancel any pending coalesce timer.
  """
  @spec drop(String.t()) :: :ok
  def drop(issue_id) when is_binary(issue_id) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(pid, {:drop, issue_id})

      _ ->
        :ok
    end
  end

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:append, issue_id, raw}, _from, state) do
    now = System.monotonic_time(:millisecond)
    bucket = issue_id |> get_or_new(state.table) |> append_line(raw, now)
    :ets.insert(state.table, {issue_id, bucket})
    {:reply, :ok, state}
  end

  def handle_call({:drop, issue_id}, _from, state) do
    case :ets.lookup(state.table, issue_id) do
      [{^issue_id, bucket}] ->
        cancel_flush_timer(bucket)
        :ets.delete(state.table, issue_id)

      [] ->
        :ok
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:flush, issue_id}, state) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(state.table, issue_id) do
      [{^issue_id, bucket}] ->
        :ets.insert(state.table, {issue_id, flush(%{bucket | flush_timer: nil}, now)})

      [] ->
        :ok
    end

    {:noreply, state}
  end

  defp lookup_bucket(issue_id) do
    case :ets.whereis(@table) do
      :undefined ->
        :error

      _tid ->
        case :ets.lookup(@table, issue_id) do
          [{^issue_id, bucket}] -> {:ok, bucket}
          [] -> :error
        end
    end
  end

  defp get_or_new(issue_id, table) do
    case :ets.lookup(table, issue_id) do
      [{^issue_id, bucket}] -> bucket
      [] -> new_bucket(issue_id)
    end
  end

  defp new_bucket(issue_id) do
    %{
      issue_id: issue_id,
      last_seq: 0,
      lines: [],
      pending: [],
      dropped: 0,
      last_flush_at: nil,
      flush_timer: nil
    }
  end

  defp append_line(bucket, raw, now) do
    line = %{seq: bucket.last_seq + 1, at: DateTime.utc_now(), text: truncate_text(raw)}
    {lines, pending, dropped} = trim_ring(bucket.lines ++ [line], bucket.pending ++ [line], bucket.dropped)

    bucket
    |> Map.merge(%{last_seq: line.seq, lines: lines, pending: pending, dropped: dropped})
    |> maybe_flush(now)
  end

  defp trim_ring(lines, pending, dropped) do
    overflow = length(lines) - @max_lines

    if overflow > 0 do
      {gone, kept} = Enum.split(lines, overflow)
      gone_seqs = MapSet.new(gone, & &1.seq)
      {kept, Enum.reject(pending, &MapSet.member?(gone_seqs, &1.seq)), dropped + overflow}
    else
      {lines, pending, dropped}
    end
  end

  defp maybe_flush(%{flush_timer: timer} = bucket, _now) when is_reference(timer), do: bucket

  defp maybe_flush(%{last_flush_at: nil} = bucket, now), do: flush(bucket, now)

  defp maybe_flush(%{last_flush_at: last} = bucket, now) do
    if now - last >= @coalesce_ms do
      flush(bucket, now)
    else
      ref = Process.send_after(self(), {:flush, bucket.issue_id}, @coalesce_ms - (now - last))
      %{bucket | flush_timer: ref}
    end
  end

  defp flush(%{pending: []} = bucket, now) do
    %{bucket | last_flush_at: now, flush_timer: nil}
  end

  defp flush(bucket, now) do
    {batch, rest} = Enum.split(bucket.pending, @max_broadcast_lines)

    :ok =
      ObservabilityPubSub.broadcast_harness(bucket.issue_id, %{
        event: :harness_stream,
        issue_id: bucket.issue_id,
        last_seq: List.last(batch).seq,
        lines: batch,
        dropped: bucket.dropped
      })

    bucket = %{bucket | pending: rest, last_flush_at: now, flush_timer: nil}

    if rest == [] do
      bucket
    else
      %{bucket | flush_timer: Process.send_after(self(), {:flush, bucket.issue_id}, @coalesce_ms)}
    end
  end

  defp cancel_flush_timer(%{flush_timer: ref}) when is_reference(ref) do
    _ = Process.cancel_timer(ref)
    :ok
  end

  defp cancel_flush_timer(_bucket), do: :ok

  defp truncate_text(raw) do
    if byte_size(raw) <= @max_line_bytes do
      raw
    else
      raw |> binary_part(0, @max_line_bytes) |> trim_to_valid_utf8()
    end
  end

  defp trim_to_valid_utf8(bin) do
    if String.valid?(bin) do
      bin
    else
      trim_to_valid_utf8(binary_part(bin, 0, byte_size(bin) - 1))
    end
  end

  defp public_snapshot(issue_id, bucket) do
    %{issue_id: issue_id, last_seq: bucket.last_seq, lines: bucket.lines, dropped: bucket.dropped}
  end

  defp empty_snapshot(issue_id) do
    %{issue_id: issue_id, last_seq: 0, lines: [], dropped: 0}
  end
end
