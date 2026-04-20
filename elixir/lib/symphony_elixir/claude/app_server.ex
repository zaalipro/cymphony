defmodule SymphonyElixir.Claude.AppServer do
  @moduledoc """
  Client for Claude Code CLI in headless mode (`claude -p`).

  Spawns `claude` non-interactively per turn, parses JSON output,
  and supports session resumption via `--resume` for multi-turn continuity.
  """

  require Logger
  alias SymphonyElixir.{Config, PathSafety, SSH}

  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000

  @type session :: %{
          port: port() | nil,
          metadata: map(),
          session_id: String.t() | nil,
          workspace: Path.t(),
          worker_host: String.t() | nil
        }

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    config = Keyword.get(opts, :config)

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host, config) do
      {:ok,
       %{
         port: nil,
         metadata: %{},
         session_id: nil,
         workspace: expanded_workspace,
         worker_host: worker_host,
         config: config
       }}
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          workspace: workspace,
          worker_host: worker_host,
          session_id: session_id,
          config: session_config
        } = _session,
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    config = Keyword.get(opts, :config, session_config)

    case spawn_claude_turn(workspace, worker_host, prompt, issue, session_id, config) do
      {:ok, port} ->
        metadata = port_metadata(port, worker_host)
        session_id = "#{session_id || "new"}"

        emit_message(
          on_message,
          :session_started,
          %{
            session_id: session_id,
            thread_id: session_id,
            turn_id: 1
          },
          metadata
        )

        case await_process_completion(port, on_message, metadata) do
          {:ok, result} ->
            new_session_id = result[:session_id] || session_id

            Logger.info("Claude session completed for #{issue_context(issue)} session_id=#{new_session_id}")

            emit_message(
              on_message,
              :turn_completed,
              %{
                session_id: new_session_id,
                result: result[:result],
                usage: result[:usage],
                raw: result[:raw]
              },
              metadata
            )

            {:ok,
             %{
               result: result,
               session_id: new_session_id,
               thread_id: new_session_id,
               turn_id: 1
             }}

          {:error, reason} ->
            Logger.warning("Claude session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

            emit_message(
              on_message,
              :turn_ended_with_error,
              %{
                session_id: session_id,
                reason: reason
              },
              metadata
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Claude session failed for #{issue_context(issue)}: #{inspect(reason)}")
        emit_message(on_message, :startup_failed, %{reason: reason}, %{})
        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{port: nil}), do: :ok

  def stop_session(%{port: port}) when is_port(port) do
    stop_port(port)
  end

  defp spawn_claude_turn(workspace, worker_host, prompt, issue, session_id, config) do
    with {:ok, command} <- build_claude_command(prompt, issue, session_id, config) do
      start_port_for_command(command, workspace, worker_host)
    end
  end

  defp build_claude_command(prompt, _issue, session_id, config) do
    settings = if config, do: config.claude, else: Config.settings!().claude

    args =
      []
      |> maybe_add_flag(settings.bare_mode, "--bare")
      |> maybe_add_flag(true, "-p")
      |> then(fn args -> args ++ [shell_escape(prompt)] end)
      |> maybe_add_flag(settings.output_format, "--output-format", settings.output_format)
      |> maybe_add_flag(settings.output_format == "stream-json", "--verbose")
      |> maybe_add_flag(settings.permission_mode, "--permission-mode", settings.permission_mode)
      |> maybe_add_flag(settings.allowed_tools, "--allowedTools", settings.allowed_tools)
      |> maybe_add_flag(settings.model, "--model", settings.model)
      |> maybe_add_flag(settings.fallback_model, "--fallback-model", settings.fallback_model)
      |> maybe_add_flag(settings.max_turns, "--max-turns", settings.max_turns)
      |> maybe_add_flag(settings.max_budget_usd, "--max-budget-usd", settings.max_budget_usd)
      |> maybe_add_resume_flag(session_id)

    command =
      case settings.command do
        cmd when is_binary(cmd) and cmd != "" -> cmd
        _ -> "claude"
      end

    full_command = Enum.join([command | args], " ")
    {:ok, full_command}
  end

  defp maybe_add_flag(args, nil, _flag), do: args
  defp maybe_add_flag(args, false, _flag), do: args
  defp maybe_add_flag(args, true, flag), do: args ++ [flag]
  defp maybe_add_flag(args, value, flag, value) when is_binary(value), do: args ++ [flag, shell_escape(value)]
  defp maybe_add_flag(args, value, flag, value) when is_integer(value), do: args ++ [flag, to_string(value)]
  defp maybe_add_flag(args, value, flag, _display) when is_binary(value) and value != "", do: args ++ [flag, shell_escape(value)]
  defp maybe_add_flag(args, %Decimal{} = value, flag, _display), do: args ++ [flag, to_string(Decimal.to_string(value))]
  defp maybe_add_flag(args, _value, _flag, _display), do: args

  defp maybe_add_resume_flag(args, nil), do: args
  defp maybe_add_resume_flag(args, ""), do: args
  defp maybe_add_resume_flag(args, session_id) when is_binary(session_id), do: args ++ ["--resume", shell_escape(session_id)]

  defp start_port_for_command(command, workspace, nil) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(command)],
            cd: String.to_charlist(workspace),
            line: @port_line_bytes,
            env: claude_env()
          ]
        )

      {:ok, port}
    end
  end

  defp start_port_for_command(command, workspace, worker_host) when is_binary(worker_host) do
    remote_command = remote_launch_command(workspace, command)
    SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

  defp remote_launch_command(workspace, command) when is_binary(workspace) do
    [
      "cd #{shell_escape(workspace)}",
      "export ANTHROPIC_API_KEY=#{shell_escape(System.get_env("ANTHROPIC_API_KEY") || "")}",
      "exec #{command}"
    ]
    |> Enum.join(" && ")
  end

  defp claude_env do
    case System.get_env("ANTHROPIC_API_KEY") do
      key when is_binary(key) and key != "" ->
        [{~c"ANTHROPIC_API_KEY", String.to_charlist(key)}]

      _ ->
        []
    end
  end

  defp await_process_completion(port, on_message, metadata) do
    config = Map.get(metadata, :config)
    output = collect_output(port, "", config)

    case output do
      {:ok, lines} ->
        parse_claude_output(lines, on_message, metadata, config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_output(port, buffer, config) do
    timeout_ms = if config, do: config.claude.turn_timeout_ms, else: Config.settings!().claude.turn_timeout_ms

    receive do
      {^port, {:data, {:eol, chunk}}} ->
        line = buffer <> to_string(chunk)
        log_stream_line(line)

        with {:ok, lines} <- collect_output(port, "", config),
             do: {:ok, [line | lines]}

      {^port, {:data, {:noeol, chunk}}} ->
        collect_output(port, buffer <> to_string(chunk), config)

      {^port, {:exit_status, 0}} ->
        remaining = buffer |> to_string() |> String.trim()
        if remaining != "", do: log_stream_line(remaining)
        {:ok, if(remaining != "", do: [remaining], else: [])}

      {^port, {:exit_status, status}} ->
        remaining = buffer |> to_string() |> String.trim()
        if remaining != "", do: log_stream_line(remaining)
        {:error, {:claude_exit, status, remaining}}
    after
      timeout_ms ->
        stop_port(port)
        {:error, :turn_timeout}
    end
  end

  defp parse_claude_output(lines, on_message, metadata, config) do
    settings = if config, do: config.claude, else: Config.settings!().claude

    case settings.output_format do
      "json" ->
        parse_json_output(lines, on_message, metadata)

      "stream-json" ->
        parse_stream_json_output(lines, on_message, metadata)

      _ ->
        parse_json_output(lines, on_message, metadata)
    end
  end

  defp parse_json_output(lines, _on_message, _metadata) do
    case find_last_json_line(lines) do
      nil ->
        {:error, {:no_json_output, Enum.join(lines, "\n")}}

      line ->
        case Jason.decode(line) do
          {:ok, %{} = payload} ->
            {:ok,
             %{
               session_id: payload["session_id"],
               result: payload["result"],
               usage: payload["usage"],
               raw: line
             }}

          {:error, decode_error} ->
            {:error, {:json_decode_failed, decode_error, line}}
        end
    end
  end

  defp parse_stream_json_output(lines, on_message, metadata) do
    result =
      Enum.reduce(lines, %{events: [], last_result: nil}, fn line, acc ->
        case Jason.decode(line) do
          {:ok, %{} = event} ->
            emit_message(on_message, :stream_event, %{event: event, raw: line}, metadata)

            last_result =
              if event["type"] == "result" do
                event
              else
                acc.last_result
              end

            %{acc | events: [event | acc.events], last_result: last_result}

          {:error, _} ->
            log_non_json_stream_line(line, "claude stream")
            acc
        end
      end)

    case result.last_result do
      nil ->
        {:error, {:no_result_in_stream, Enum.join(lines, "\n")}}

      last_result ->
        {:ok,
         %{
           session_id: last_result["session_id"],
           result: last_result["result"],
           usage: last_result["usage"],
           raw: Jason.encode!(last_result)
         }}
    end
  end

  defp find_last_json_line(lines) when is_list(lines) do
    lines
    |> Enum.reverse()
    |> Enum.find(&json_line?/1)
  end

  defp json_line?(line) when is_binary(line) do
    trimmed = String.trim(line)
    String.starts_with?(trimmed, "{") and String.ends_with?(trimmed, "}")
  end

  defp json_line?(_), do: false

  defp validate_workspace_cwd(workspace, nil, config) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(if config, do: config.workspace.root, else: Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host, _config)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} ->
          %{claude_app_server_pid: to_string(os_pid)}

        _ ->
          %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp port_metadata(_port, worker_host) do
    case worker_host do
      host when is_binary(host) -> %{worker_host: host}
      _ -> %{}
    end
  end

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError ->
            :ok
        end
    end
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp log_stream_line(data) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, Regex.compile!("\\b(error|warn|warning|failed|fatal|panic|exception)\\b", "i")) do
        Logger.warning("Claude output: #{text}")
      else
        Logger.debug("Claude output: #{text}")
      end
    end
  end

  defp log_non_json_stream_line(data, stream_label) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, Regex.compile!("\\b(error|warn|warning|failed|fatal|panic|exception)\\b", "i")) do
        Logger.warning("#{stream_label} output: #{text}")
      else
        Logger.debug("#{stream_label} output: #{text}")
      end
    end
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp default_on_message(_message), do: :ok

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
