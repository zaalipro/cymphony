defmodule CymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Claude Code.
  """

  require Logger
  alias CymphonyElixir.Claude.AppServer
  alias CymphonyElixir.{Config, Linear.Issue, PromptBuilder, Tracker, Workspace}

  @type worker_host :: String.t() | nil

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, claude_update_recipient \\ nil, opts \\ []) do
    config = Keyword.get(opts, :config)
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_hosts = if config, do: config.worker.ssh_hosts, else: Config.settings!().worker.ssh_hosts
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), worker_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, claude_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, claude_update_recipient, opts, worker_host) do
    config = Keyword.get(opts, :config)
    provider_override = Keyword.get(opts, :provider_override)

    config =
      if provider_override && config do
        %{config | claude: %{config.claude | provider: provider_override}}
      else
        config
      end

    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)} provider=#{provider_override || "default"}")

    case Workspace.create_for_issue(issue, worker_host, config: config) do
      {:ok, workspace} ->
        send_worker_runtime_info(claude_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host, config: config) do
            run_claude_turns(workspace, issue, claude_update_recipient, Keyword.put(opts, :config, config), worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host, config: config)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp claude_message_handler(recipient, issue) do
    fn message ->
      send_claude_update(recipient, issue, message)
    end
  end

  defp send_claude_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:claude_worker_update, issue_id, message})
    :ok
  end

  defp send_claude_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_claude_turns(workspace, issue, claude_update_recipient, opts, worker_host) do
    config = Keyword.get(opts, :config)
    max_turns = Keyword.get(opts, :max_turns) || if config, do: config.agent.max_turns, else: Config.settings!().agent.max_turns
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher) || if config, do: &Tracker.fetch_issue_states_by_ids(&1, config), else: &Tracker.fetch_issue_states_by_ids/1

    with {:ok, session} <- AppServer.start_session(workspace, worker_host: worker_host, config: config) do
      try do
        do_run_claude_turns(session, workspace, issue, claude_update_recipient, opts, issue_state_fetcher, 1, max_turns, config)
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp do_run_claude_turns(app_session, workspace, issue, claude_update_recipient, opts, issue_state_fetcher, turn_number, max_turns, config) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns, config)

    with {:ok, turn_result} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: claude_message_handler(claude_update_recipient, issue),
             config: config
           ) do
      session_id = turn_result[:session_id]

      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{session_id} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continue_with_issue?(issue, issue_state_fetcher, config) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          # Resume the Claude session for the next turn
          app_session = %{app_session | session_id: session_id}

          do_run_claude_turns(
            app_session,
            workspace,
            refreshed_issue,
            claude_update_recipient,
            opts,
            issue_state_fetcher,
            turn_number + 1,
            max_turns,
            config
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns, config) do
    opts =
      if config do
        Keyword.put(opts, :config, config)
      else
        opts
      end

    PromptBuilder.build_prompt(issue, opts)
  end

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns, _config) do
    """
    Continuation guidance:

    - The previous Claude turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher, config) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state, config) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher, _config), do: {:done, issue}

  defp active_issue_state?(state_name, config) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)
    active_states = if config, do: config.tracker.active_states, else: Config.settings!().tracker.active_states

    active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name, _config), do: false

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
