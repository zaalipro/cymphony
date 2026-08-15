defmodule CymphonyElixir.HarnessStreamTest do
  use ExUnit.Case, async: false

  alias CymphonyElixir.HarnessStream
  alias CymphonyElixirWeb.ObservabilityPubSub

  @coalesce_ms 80
  @max_line_bytes 2048
  @max_lines 400
  @max_broadcast_lines 40

  setup do
    ensure_started()
    :ok
  end

  test "application starts HarnessStream after PubSub and before HttpServer" do
    modules =
      Enum.map(CymphonyElixir.Application.children(), fn
        {mod, _opts} -> mod
        mod when is_atom(mod) -> mod
      end)

    pubsub_idx = Enum.find_index(modules, &(&1 == Phoenix.PubSub))
    harness_idx = Enum.find_index(modules, &(&1 == HarnessStream))
    http_idx = Enum.find_index(modules, &(&1 == CymphonyElixir.HttpServer))

    assert is_integer(pubsub_idx)
    assert is_integer(harness_idx)
    assert is_integer(http_idx)
    assert pubsub_idx < harness_idx
    assert harness_idx < http_idx
  end

  test "start_link/0 and start_link/1 are the named singleton" do
    pid = Process.whereis(HarnessStream)
    assert is_pid(pid)
    assert {:error, {:already_started, ^pid}} = HarnessStream.start_link()
    assert {:error, {:already_started, ^pid}} = HarnessStream.start_link([])
  end

  test "snapshot/1 is empty for an unknown issue" do
    issue_id = unique_issue()

    assert HarnessStream.snapshot(issue_id) == %{
             issue_id: issue_id,
             last_seq: 0,
             lines: [],
             dropped: 0
           }
  end

  test "append/2 stores truncated lines, assigns seq from 1, and snapshot/1 returns them" do
    issue_id = track_issue()
    exact = String.duplicate("b", @max_line_bytes)
    long = String.duplicate("a", @max_line_bytes + 500)
    split = String.duplicate("c", @max_line_bytes - 1) <> "é"
    # 4-byte codepoint so truncation may walk back more than one byte.
    four_byte = String.duplicate("d", @max_line_bytes - 1) <> "𐍈"

    assert :ok = HarnessStream.append(issue_id, "hello")
    assert :ok = HarnessStream.append(issue_id, "")
    assert :ok = HarnessStream.append(issue_id, exact)
    assert :ok = HarnessStream.append(issue_id, long)
    assert :ok = HarnessStream.append(issue_id, split)
    assert :ok = HarnessStream.append(issue_id, four_byte)

    %{issue_id: ^issue_id, last_seq: 6, dropped: 0, lines: lines} = HarnessStream.snapshot(issue_id)
    assert Enum.map(lines, & &1.seq) == [1, 2, 3, 4, 5, 6]
    assert Enum.all?(lines, &match?(%DateTime{}, &1.at))

    assert Enum.map(lines, & &1.text) == [
             "hello",
             "",
             exact,
             String.duplicate("a", @max_line_bytes),
             String.duplicate("c", @max_line_bytes - 1),
             String.duplicate("d", @max_line_bytes - 1)
           ]

    assert byte_size(Enum.at(lines, 3).text) == @max_line_bytes
    assert String.valid?(Enum.at(lines, 4).text)
    assert String.valid?(Enum.at(lines, 5).text)
  end

  test "ring keeps the newest 400 lines and counts dropped" do
    issue_id = track_issue()

    for i <- 1..(@max_lines + 1) do
      assert :ok = HarnessStream.append(issue_id, "n-#{i}")
    end

    snap = HarnessStream.snapshot(issue_id)
    assert snap.last_seq == @max_lines + 1
    assert snap.dropped == 1
    assert length(snap.lines) == @max_lines
    assert hd(snap.lines).seq == 2
    assert hd(snap.lines).text == "n-2"
    assert List.last(snap.lines).seq == @max_lines + 1
    assert List.last(snap.lines).text == "n-#{@max_lines + 1}"
  end

  test "overflow drops oldest pending lines from the coalesced batch" do
    issue_id = track_issue()
    extra = 5

    assert :ok = HarnessStream.append(issue_id, "first")

    assert_receive %{event: :harness_stream, issue_id: ^issue_id, last_seq: 1}, 50

    for i <- 1..(@max_lines + extra) do
      assert :ok = HarnessStream.append(issue_id, "p-#{i}")
    end

    snap = HarnessStream.snapshot(issue_id)
    assert snap.last_seq == @max_lines + extra + 1
    assert snap.dropped == extra + 1
    assert length(snap.lines) == @max_lines
    assert hd(snap.lines).seq == extra + 2
    assert List.last(snap.lines).seq == snap.last_seq
    assert Enum.map(snap.lines, & &1.seq) == Enum.to_list((extra + 2)..snap.last_seq)
  end

  test "first append after a quiet period flushes immediately" do
    issue_id = track_issue()

    assert :ok = HarnessStream.append(issue_id, "one")

    assert_receive %{
                     event: :harness_stream,
                     issue_id: ^issue_id,
                     last_seq: 1,
                     dropped: 0,
                     lines: [%{seq: 1, text: "one"}]
                   },
                   50

    Process.sleep(@coalesce_ms + 10)
    assert :ok = HarnessStream.append(issue_id, "two")

    assert_receive %{
                     event: :harness_stream,
                     issue_id: ^issue_id,
                     last_seq: 2,
                     lines: [%{seq: 2, text: "two"}]
                   },
                   50
  end

  test "appends within 80ms are coalesced into one broadcast of at most 40 new lines" do
    issue_id = track_issue()

    assert :ok = HarnessStream.append(issue_id, "first")

    assert_receive %{event: :harness_stream, issue_id: ^issue_id, last_seq: 1, lines: [%{seq: 1}]},
                   50

    for i <- 1..(@max_broadcast_lines + 5) do
      assert :ok = HarnessStream.append(issue_id, "c-#{i}")
    end

    refute_receive %{event: :harness_stream, issue_id: ^issue_id}, 20

    assert_receive %{
                     event: :harness_stream,
                     issue_id: ^issue_id,
                     last_seq: last_seq,
                     lines: batch1,
                     dropped: 0
                   },
                   @coalesce_ms + 80

    assert length(batch1) == @max_broadcast_lines
    assert hd(batch1).seq == 2
    assert last_seq == 1 + @max_broadcast_lines
    assert List.last(batch1).seq == last_seq

    assert_receive %{event: :harness_stream, issue_id: ^issue_id, last_seq: 46, lines: batch2},
                   @coalesce_ms + 80

    assert length(batch2) == 5
    assert hd(batch2).seq == 42
    assert List.last(batch2).seq == 46
    refute_receive %{event: :harness_stream, issue_id: ^issue_id}, 30
  end

  test "drop/1 deletes the bucket and cancels a pending coalesce flush" do
    issue_id = track_issue()
    assert :ok = HarnessStream.drop("never-#{issue_id}")

    assert :ok = HarnessStream.append(issue_id, "keep")
    assert_receive %{event: :harness_stream, issue_id: ^issue_id, last_seq: 1}, 50
    assert :ok = HarnessStream.append(issue_id, "pending")
    assert :ok = HarnessStream.drop(issue_id)

    assert HarnessStream.snapshot(issue_id) == %{
             issue_id: issue_id,
             last_seq: 0,
             lines: [],
             dropped: 0
           }

    refute_receive %{event: :harness_stream, issue_id: ^issue_id}, @coalesce_ms + 40

    assert :ok = HarnessStream.append(issue_id, "again")
    assert %{last_seq: 1, lines: [%{seq: 1, text: "again"}]} = HarnessStream.snapshot(issue_id)
  end

  test "late flush messages are ignored when the bucket is gone or already flushed" do
    issue_id = track_issue()
    pid = Process.whereis(HarnessStream)
    assert is_pid(pid)

    assert :ok = HarnessStream.append(issue_id, "only")
    assert_receive %{event: :harness_stream, issue_id: ^issue_id, last_seq: 1}, 50

    send(pid, {:flush, issue_id})
    sync_server()
    assert %{last_seq: 1, lines: [%{text: "only"}]} = HarnessStream.snapshot(issue_id)
    refute_receive %{event: :harness_stream, issue_id: ^issue_id}, 20

    assert :ok = HarnessStream.drop(issue_id)
    send(pid, {:flush, issue_id})
    sync_server()
    assert %{last_seq: 0, lines: []} = HarnessStream.snapshot(issue_id)
  end

  test "append, drop, and snapshot are no-ops when the server is down" do
    issue_id = unique_issue()

    on_exit(fn ->
      ensure_started()
    end)

    assert :ok = Supervisor.terminate_child(CymphonyElixir.Supervisor, HarnessStream)
    refute Process.whereis(HarnessStream)

    assert :ok = HarnessStream.append(issue_id, "line")
    assert :ok = HarnessStream.drop(issue_id)

    assert HarnessStream.snapshot(issue_id) == %{
             issue_id: issue_id,
             last_seq: 0,
             lines: [],
             dropped: 0
           }

    assert {:ok, _pid} = Supervisor.restart_child(CymphonyElixir.Supervisor, HarnessStream)
    assert is_pid(Process.whereis(HarnessStream))
  end

  defp unique_issue do
    "harness-#{System.unique_integer([:positive])}"
  end

  defp track_issue do
    issue_id = unique_issue()
    assert :ok = ObservabilityPubSub.subscribe_harness(issue_id)

    on_exit(fn ->
      if Process.whereis(HarnessStream), do: HarnessStream.drop(issue_id)
    end)

    issue_id
  end

  defp sync_server do
    assert :ok = HarnessStream.drop("sync-#{System.unique_integer([:positive])}")
  end

  defp ensure_started do
    case Process.whereis(HarnessStream) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case Supervisor.restart_child(CymphonyElixir.Supervisor, HarnessStream) do
          {:ok, _pid} ->
            :ok

          {:error, :running} ->
            :ok

          {:error, {:already_started, _pid}} ->
            :ok

          {:error, :not_found} ->
            {:ok, _pid} = HarnessStream.start_link([])
            :ok
        end
    end
  end
end
