defmodule CymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias CymphonyElixir.{Config, Orchestrator, ProjectSupervisor, StatusDashboard}

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    project_snapshots = aggregate_project_snapshots(snapshot_timeout_ms)

    case project_snapshots do
      [] ->
        # Legacy single-orchestrator fallback
        case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
          %{} = snapshot ->
            project_name = Map.get(snapshot, :project_name) || "default"
            polling = Map.get(snapshot, :polling) || %{}

            running =
              snapshot.running
              |> Enum.map(&Map.put(&1, :project_name, project_name))
              |> Enum.map(&running_entry_payload/1)

            retrying =
              snapshot.retrying
              |> Enum.map(&Map.put(&1, :project_name, project_name))
              |> Enum.map(&retry_entry_payload/1)

            project = %{
              name: project_name,
              running: running,
              retrying: retrying,
              running_count: length(running),
              retrying_count: length(retrying),
              providers: Map.get(snapshot, :providers, []),
              paused: Map.get(polling, :paused, false),
              max_concurrent_agents: Map.get(polling, :max_concurrent_agents)
            }

            %{
              generated_at: generated_at,
              counts: %{
                running: length(running),
                retrying: length(retrying)
              },
              running: running,
              retrying: retrying,
              recent_completed:
                snapshot
                |> Map.get(:recent_completed, [])
                |> Enum.map(&completed_entry_payload/1),
              claude_totals: normalize_claude_totals(snapshot.claude_totals),
              rate_limits: snapshot.rate_limits,
              polling: Map.get(snapshot, :polling),
              projects: [project]
            }

          :timeout ->
            %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

          :unavailable ->
            %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
        end

      snapshots ->
        merged = merge_project_snapshots(snapshots)

        projects =
          Enum.map(snapshots, fn %{project_name: name, snapshot: snap} ->
            polling = Map.get(snap, :polling) || %{}

            running =
              snap.running
              |> Enum.map(&Map.put(&1, :project_name, name))
              |> Enum.map(&running_entry_payload/1)

            retrying =
              snap.retrying
              |> Enum.map(&Map.put(&1, :project_name, name))
              |> Enum.map(&retry_entry_payload/1)

            %{
              name: name,
              running: running,
              retrying: retrying,
              running_count: length(running),
              retrying_count: length(retrying),
              providers: Map.get(snap, :providers, []),
              paused: Map.get(polling, :paused, false),
              max_concurrent_agents: Map.get(polling, :max_concurrent_agents)
            }
          end)

        flat_running = Enum.flat_map(projects, & &1.running)
        flat_retrying = Enum.flat_map(projects, & &1.retrying)

        %{
          generated_at: generated_at,
          counts: %{
            running: length(flat_running),
            retrying: length(flat_retrying)
          },
          running: flat_running,
          retrying: flat_retrying,
          recent_completed: Enum.map(merged.recent_completed, &completed_entry_payload/1),
          claude_totals: merged.claude_totals,
          rate_limits: merged.rate_limits,
          polling: merged.polling,
          projects: projects
        }
    end
  end

  @spec completed_entry_payload(map()) :: map()
  def completed_entry_payload(entry) do
    %{
      issue_id: Map.get(entry, :issue_id),
      issue_identifier: Map.get(entry, :identifier),
      project_name: Map.get(entry, :project_name),
      ended_at: iso8601(Map.get(entry, :ended_at)),
      started_at: iso8601(Map.get(entry, :started_at)),
      runtime_seconds: Map.get(entry, :runtime_seconds),
      claude_input_tokens: Map.get(entry, :claude_input_tokens, 0),
      claude_output_tokens: Map.get(entry, :claude_output_tokens, 0),
      claude_total_tokens: Map.get(entry, :claude_total_tokens, 0),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
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

  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms, project_name \\ nil)

  @spec issue_payload(String.t(), GenServer.name(), timeout(), String.t() | nil) ::
          {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, _orchestrator, snapshot_timeout_ms, project_name)
      when is_binary(issue_identifier) and is_binary(project_name) do
    case ProjectSupervisor.lookup(project_name, :orchestrator) do
      nil ->
        {:error, :issue_not_found}

      pid ->
        case Orchestrator.snapshot(pid, snapshot_timeout_ms) do
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
  end

  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms, nil)
      when is_binary(issue_identifier) do
    # Search primary orchestrator first (legacy single-project mode)
    primary_result =
      case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
        %{} = snapshot ->
          running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
          retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))

          if is_nil(running) and is_nil(retry) do
            nil
          else
            {:ok, issue_payload_body(issue_identifier, running, retry)}
          end

        _ ->
          nil
      end

    # If found in primary, return immediately
    if primary_result do
      primary_result
    else
      # Multi-project fallback: search across all project orchestrators
      find_issue_in_projects(issue_identifier, snapshot_timeout_ms)
    end
  end

  defp find_issue_in_projects(issue_identifier, snapshot_timeout_ms) do
    ProjectSupervisor.list_orchestrators()
    |> Enum.find_value(fn {_project_name, pid} ->
      try do
        case Orchestrator.snapshot(pid, snapshot_timeout_ms) do
          %{} = snapshot ->
            running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
            retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))

            if is_nil(running) and is_nil(retry) do
              nil
            else
              {:ok, issue_payload_body(issue_identifier, running, retry)}
            end

          _ ->
            nil
        end
      catch
        :exit, _ -> nil
      end
    end) ||
      {:error, :issue_not_found}
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

  @spec format_rate_limits_for_web(map() | nil) :: map()
  def format_rate_limits_for_web(nil), do: nil

  def format_rate_limits_for_web(rate_limits) when is_map(rate_limits) do
    limit_id =
      map_value(rate_limits, ["limit_id", :limit_id, "limit_name", :limit_name]) ||
        "unknown"

    %{
      limit_id: limit_id,
      primary: format_rate_limit_bucket_web(map_value(rate_limits, ["primary", :primary])),
      secondary: format_rate_limit_bucket_web(map_value(rate_limits, ["secondary", :secondary])),
      credits: format_rate_limit_credits_web(map_value(rate_limits, ["credits", :credits]))
    }
  end

  def format_rate_limits_for_web(_), do: nil

  defp format_rate_limit_bucket_web(nil), do: nil

  defp format_rate_limit_bucket_web(bucket) when is_map(bucket) do
    remaining = map_value(bucket, ["remaining", :remaining])
    limit = map_value(bucket, ["limit", :limit])

    reset_value =
      map_value(bucket, [
        "reset_in_seconds",
        :reset_in_seconds,
        "resetInSeconds",
        :resetInSeconds,
        "reset_at",
        :reset_at,
        "resetAt",
        :resetAt,
        "resets_at",
        :resets_at,
        "resetsAt",
        :resetsAt
      ])

    %{
      remaining: remaining,
      limit: limit,
      reset_in_seconds: reset_value,
      summary:
        cond do
          is_integer(remaining) and is_integer(limit) ->
            "#{remaining}/#{limit}"

          is_integer(remaining) ->
            "remaining #{remaining}"

          is_integer(limit) ->
            "limit #{limit}"

          true ->
            "n/a"
        end
    }
  end

  defp format_rate_limit_credits_web(nil), do: nil

  defp format_rate_limit_credits_web(credits) when is_map(credits) do
    unlimited = map_value(credits, ["unlimited", :unlimited]) == true
    has_credits = map_value(credits, ["has_credits", :has_credits]) == true
    balance = map_value(credits, ["balance", :balance])

    cond do
      unlimited -> %{status: "unlimited", summary: "unlimited"}
      has_credits and is_number(balance) -> %{status: "available", summary: "#{balance}"}
      has_credits -> %{status: "available", summary: "available"}
      true -> %{status: "none", summary: "none"}
    end
  end

  defp format_rate_limit_credits_web(_), do: nil

  defp map_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp map_value(_map, _keys), do: nil

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
        claude_session_logs: (running && Enum.map(Map.get(running, :log_events, []), &log_event_payload/1)) || []
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
      issue_title: issue_field(entry, :title),
      issue_url: issue_field(entry, :url),
      priority: issue_field(entry, :priority),
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      provider: Map.get(entry, :provider),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_claude_event,
      last_message: summarize_message(entry.last_claude_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_claude_timestamp),
      stalled: stalled?(entry.last_claude_timestamp),
      log_events: Enum.take(Map.get(entry, :log_events, []), 20),
      project_name: Map.get(entry, :project_name),
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
      issue_title: issue_field(entry, :title),
      issue_url: issue_field(entry, :url),
      priority: issue_field(entry, :priority),
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      tokens: %{input_tokens: 0, output_tokens: 0, total_tokens: 0},
      turn_count: 0,
      session_id: nil,
      started_at: nil,
      last_event: nil,
      last_message: nil,
      log_events: []
    }
  end

  defp issue_field(entry, key) do
    case Map.get(entry, :issue) do
      %{} = issue -> Map.get(issue, key)
      _ -> nil
    end
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
      log_events: Enum.map(Map.get(running, :log_events, []), &log_event_payload/1),
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

  defp log_event_payload(event) do
    %{
      at: iso8601(event.at),
      event: to_string(event.event),
      message: summarize_message(event.message)
    }
  end

  defp stalled?(%DateTime{} = last_event_at) do
    timeout_ms = Config.settings!().claude.stall_timeout_ms
    elapsed_ms = DateTime.diff(DateTime.utc_now(), last_event_at, :millisecond)
    elapsed_ms > timeout_ms
  rescue
    _ -> false
  end

  defp stalled?(_), do: false

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

    all_completed =
      snapshots
      |> Enum.flat_map(fn %{project_name: project_name, snapshot: snap} ->
        snap
        |> Map.get(:recent_completed, [])
        |> Enum.map(&Map.put(&1, :project_name, project_name))
      end)
      |> Enum.sort_by(fn entry -> entry[:ended_at] end, {:desc, DateTime})
      |> Enum.take(100)

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
      recent_completed: all_completed,
      claude_totals: merged_totals,
      rate_limits: Map.get(first_snap, :rate_limits),
      polling: Map.get(first_snap, :polling)
    }
  end

  defp normalize_claude_totals(nil) do
    %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
  end

  defp normalize_claude_totals(totals) when is_map(totals) do
    %{
      input_tokens: Map.get(totals, :input_tokens, 0),
      output_tokens: Map.get(totals, :output_tokens, 0),
      total_tokens: Map.get(totals, :total_tokens, 0),
      seconds_running: Map.get(totals, :seconds_running, 0)
    }
  end
end
