defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, ProjectSupervisor, StatusDashboard}

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    project_snapshots = aggregate_project_snapshots(snapshot_timeout_ms)

    case project_snapshots do
      [] ->
        # Legacy single-orchestrator fallback
        case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
          %{} = snapshot ->
            %{
              generated_at: generated_at,
              counts: %{
                running: length(snapshot.running),
                retrying: length(snapshot.retrying)
              },
              running: Enum.map(snapshot.running, &running_entry_payload/1),
              retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
              claude_totals: snapshot.claude_totals,
              rate_limits: snapshot.rate_limits
            }

          :timeout ->
            %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

          :unavailable ->
            %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
        end

      snapshots ->
        merged = merge_project_snapshots(snapshots)

        %{
          generated_at: generated_at,
          counts: %{
            running: length(merged.running),
            retrying: length(merged.retrying)
          },
          running: Enum.map(merged.running, &running_entry_payload/1),
          retrying: Enum.map(merged.retrying, &retry_entry_payload/1),
          claude_totals: merged.claude_totals,
          rate_limits: merged.rate_limits,
          projects:
            Enum.map(snapshots, fn %{project_name: name, snapshot: snap} ->
              %{name: name, running: length(snap.running), retrying: length(snap.retrying)}
            end)
        }
    end
  end

  @spec projects_payload() :: [map()]
  def projects_payload do
    ProjectSupervisor.list_orchestrators()
    |> Enum.map(fn {project_name, pid} ->
      case Orchestrator.snapshot(pid, 5_000) do
        %{} = snapshot ->
          %{
            name: project_name,
            running: length(snapshot.running),
            retrying: length(snapshot.retrying)
          }

        _ ->
          %{name: project_name, running: 0, retrying: 0}
      end
    end)
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry),
      status: issue_status(running, retry),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry),
        host: workspace_host(running, retry)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      logs: %{
        claude_session_logs: []
      },
      recent_events: (running && recent_events_payload(running)) || [],
      last_error: retry && retry.error,
      tracked: %{}
    }
  end

  defp issue_id_from_entries(running, retry),
    do: (running && running.issue_id) || (retry && retry.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(_running, nil), do: "running"
  defp issue_status(nil, _retry), do: "retrying"
  defp issue_status(_running, _retry), do: "running"

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_claude_event,
      last_message: summarize_message(entry.last_claude_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_claude_timestamp),
      tokens: %{
        input_tokens: entry.claude_input_tokens,
        output_tokens: entry.claude_output_tokens,
        total_tokens: entry.claude_total_tokens
      }
    }
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
  end

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_claude_event,
      last_message: summarize_message(running.last_claude_message),
      last_event_at: iso8601(running.last_claude_timestamp),
      tokens: %{
        input_tokens: running.claude_input_tokens,
        output_tokens: running.claude_output_tokens,
        total_tokens: running.claude_total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp workspace_path(issue_identifier, running, retry) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry) do
    (running && Map.get(running, :worker_host)) || (retry && Map.get(retry, :worker_host))
  end

  defp recent_events_payload(running) do
    [
      %{
        at: iso8601(running.last_claude_timestamp),
        event: running.last_claude_event,
        message: summarize_message(running.last_claude_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_claude_message(message)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil

  defp aggregate_project_snapshots(snapshot_timeout_ms) do
    ProjectSupervisor.list_orchestrators()
    |> Enum.flat_map(fn {project_name, pid} ->
      try do
        case Orchestrator.snapshot(pid, snapshot_timeout_ms) do
          %{} = snapshot ->
            [%{project_name: project_name, snapshot: snapshot}]

          _ ->
            []
        end
      catch
        :exit, _ -> []
      end
    end)
  end

  defp merge_project_snapshots(snapshots) do
    all_running =
      snapshots
      |> Enum.flat_map(fn %{project_name: project_name, snapshot: snap} ->
        Enum.map(snap.running, &Map.put(&1, :project_name, project_name))
      end)

    all_retrying =
      snapshots
      |> Enum.flat_map(fn %{project_name: project_name, snapshot: snap} ->
        Enum.map(snap.retrying, &Map.put(&1, :project_name, project_name))
      end)

    merged_totals =
      Enum.reduce(snapshots, %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}, fn %{snapshot: snap}, acc ->
        totals = Map.get(snap, :claude_totals, %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0})

        %{
          input_tokens: acc.input_tokens + Map.get(totals, :input_tokens, 0),
          output_tokens: acc.output_tokens + Map.get(totals, :output_tokens, 0),
          total_tokens: acc.total_tokens + Map.get(totals, :total_tokens, 0),
          seconds_running: acc.seconds_running + Map.get(totals, :seconds_running, 0)
        }
      end)

    first_snap = hd(snapshots).snapshot

    %{
      running: all_running,
      retrying: all_retrying,
      claude_totals: merged_totals,
      rate_limits: Map.get(first_snap, :rate_limits)
    }
  end
end
