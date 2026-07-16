defmodule CymphonyElixir.Claude.AppServer do
  @moduledoc """
  Client for Claude Code CLI in headless mode (`claude -p`).

  Spawns `claude` non-interactively per turn, parses JSON output,
  and supports session resumption via `--resume` for multi-turn continuity.
  """

  require Logger
  alias CymphonyElixir.{Config, PathSafety, SSH}

  alias CymphonyElixir.Cymphony.ShellProvider

  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000
  @shell_env_name_pattern ~r/^[A-Za-z_][A-Za-z0-9_]*$/

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
    with {:ok, command} <- build_claude_command(prompt, issue, session_id, config, workspace, worker_host) do
      start_port_for_command(command, workspace, worker_host, config)
    end
  end

  @doc false
  @spec build_claude_command(String.t(), map(), String.t() | nil, term(), Path.t() | nil, String.t() | nil) ::
          {:ok, String.t()}
  def build_claude_command(prompt, _issue, session_id, config, workspace \\ nil, worker_host \\ nil) do
    settings = if config, do: config.claude, else: Config.settings!().claude
    agent = if config, do: config.agent, else: Config.settings!().agent

    args =
      []
      |> maybe_add_flag(settings.bare_mode, "--bare")
      |> maybe_add_flag(true, "-p")
      |> then(fn args -> args ++ [shell_escape(prompt)] end)
      |> maybe_add_flag(settings.output_format, "--output-format", settings.output_format)
      |> maybe_add_flag(settings.output_format == "stream-json", "--verbose")
      |> maybe_add_flag(settings.permission_mode, "--permission-mode", settings.permission_mode)
      |> maybe_add_flag(settings.allowed_tools, "--allowedTools", settings.allowed_tools)
      |> maybe_add_flag(agent.model, "--model", agent.model)
      |> maybe_add_flag(settings.fallback_model, "--fallback-model", settings.fallback_model)
      |> maybe_add_flag(settings.max_turns, "--max-turns", settings.max_turns)
      |> maybe_add_flag(settings.max_budget_usd, "--max-budget-usd", settings.max_budget_usd)
      |> maybe_add_mcp_config(workspace, worker_host, config)
      |> maybe_add_resume_flag(session_id)

    command =
      case settings.command do
        cmd when is_binary(cmd) and cmd != "" -> cmd
        _ -> "claude"
      end

    full_command = Enum.join([command | args], " ")
    {:ok, full_command}
  end

  defp maybe_add_mcp_config(args, workspace, nil, %{tracker: %{kind: "linear", api_key: key} = tracker})
       when is_binary(workspace) and is_binary(key) and key != "" do
    descriptor = %{api_key: key, endpoint: Map.get(tracker, :endpoint)}

    case CymphonyElixir.Mcp.ConfigWriter.write(workspace, descriptor) do
      {:ok, path} -> args ++ ["--mcp-config", shell_escape(path)]
      {:error, _reason} -> args
    end
  end

  defp maybe_add_mcp_config(args, _workspace, _worker_host, _config), do: args

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

  defp start_port_for_command(command, workspace, worker_host, config)

  defp start_port_for_command(command, workspace, nil, config) do
    case pick_local_shell() do
      {:ok, shell} ->
        port =
          Port.open(
            {:spawn_executable, String.to_charlist(shell)},
            [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              args: [~c"-c", String.to_charlist(local_launch_script(command))],
              cd: String.to_charlist(workspace),
              line: @port_line_bytes,
              env: claude_env(config)
            ]
          )

        {:ok, port}

      {:error, _} = err ->
        err
    end
  end

  defp start_port_for_command(command, workspace, worker_host, config) when is_binary(worker_host) do
    remote_command = remote_launch_command(workspace, command, config)
    SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

  # Wrap the user's command so shell-function aliases (e.g. `cz`, `cm`, `cv1`
  # defined in ~/.cld) resolve when used as claude_command. Sourcing only
  # happens when the first word of the command isn't already on $PATH, so
  # plain binary commands (`claude`, `bash`, etc.) don't trigger rc-file
  # sourcing — that would otherwise override env vars (LINEAR_API_KEY,
  # ANTHROPIC_*, etc.) that we explicitly pass via Port.open's :env option.
  defp local_launch_script(command) do
    cmd_name = command |> String.split(" ", parts: 2) |> List.first() || ""

    """
    if ! command -v #{shell_escape(cmd_name)} >/dev/null 2>&1; then
      for __cymphony_rc in "$HOME/.cld" "$HOME/.zshrc" "$HOME/.bashrc"; do
        [ -f "$__cymphony_rc" ] && . "$__cymphony_rc" 2>/dev/null || true
      done
      unset __cymphony_rc
    fi
    exec #{command}
    """
  end

  defp pick_local_shell do
    case System.find_executable("zsh") || System.find_executable("bash") do
      nil -> {:error, :shell_not_found}
      path -> {:ok, path}
    end
  end

  defp remote_launch_command(workspace, command, config) when is_binary(workspace) do
    (["cd #{shell_escape(workspace)}"] ++ remote_env_exports(config) ++ ["exec #{command}"])
    |> Enum.join(" && ")
  end

  defp claude_env(nil) do
    claude_env(Config.settings!())
  end

  defp claude_env(config) do
    config
    |> claude_process_env(include_base?: true)
    |> Enum.map(fn {key, value} ->
      {String.to_charlist(key), String.to_charlist(value)}
    end)
  end

  defp remote_env_exports(config) do
    config
    |> claude_process_env(include_base?: false)
    |> Enum.map(fn {key, value} ->
      "export #{key}=#{shell_escape(value)}"
    end)
  end

  defp claude_process_env(config, opts) do
    config = config || Config.settings!()

    base_env =
      if Keyword.get(opts, :include_base?, false) do
        %{
          "PATH" => System.get_env("PATH") || "",
          "HOME" => System.get_env("HOME") || ""
        }
      else
        %{}
      end

    base_env
    |> Map.merge(claude_auth_env(config))
    |> Map.merge(integration_auth_env(config))
    |> valid_env_map()
  end

  defp claude_auth_env(config) do
    config
    |> provider_env()
    |> case do
      provider_env when map_size(provider_env) > 0 ->
        provider_env

      _ ->
        inherited_env(["ANTHROPIC_API_KEY"])
    end
  end

  defp provider_env(%{claude: %{provider: provider_name}})
       when is_binary(provider_name) and provider_name != "" do
    case ShellProvider.load_env(provider_name) do
      {:ok, env_map} when is_map(env_map) ->
        normalize_env_map(env_map)

      {:error, :not_found} ->
        %{}
    end
  end

  defp provider_env(_config), do: %{}

  defp integration_auth_env(config) do
    %{}
    |> maybe_put_env("LINEAR_API_KEY", linear_api_key(config))
    |> Map.merge(inherited_env(["GH_TOKEN", "GITHUB_TOKEN"]))
  end

  defp linear_api_key(%{tracker: %{kind: "linear", api_key: api_key}})
       when is_binary(api_key) and api_key != "",
       do: api_key

  defp linear_api_key(_config), do: nil

  defp inherited_env(names) when is_list(names) do
    Enum.reduce(names, %{}, fn name, env ->
      maybe_put_env(env, name, System.get_env(name))
    end)
  end

  defp normalize_env_map(env_map) when is_map(env_map) do
    Enum.reduce(env_map, %{}, fn {key, value}, env ->
      maybe_put_env(env, to_string(key), value)
    end)
  end

  defp maybe_put_env(env, name, value)
       when is_map(env) and is_binary(name) and is_binary(value) and value != "" do
    Map.put(env, name, value)
  end

  defp maybe_put_env(env, _name, _value), do: env

  defp valid_env_map(env) when is_map(env) do
    env
    |> Enum.filter(fn {key, value} ->
      is_binary(key) and is_binary(value) and Regex.match?(@shell_env_name_pattern, key)
    end)
    |> Map.new()
  end

  defp await_process_completion(port, on_message, metadata) do
    config = Map.get(metadata, :config)
    output = collect_output(port, config)

    case output do
      {:ok, lines} ->
        parse_claude_output(lines, on_message, metadata, config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_output(port, config) do
    collect_output(port, "", [], config)
  end

  # Tail-recursive: accumulates completed lines in reverse and reverses once at
  # the end, so a long stream-json turn (thousands of events) does not grow the
  # call stack proportionally to the number of output lines.
  defp collect_output(port, buffer, acc, config) do
    timeout_ms = if config, do: config.agent.turn_timeout_ms, else: Config.settings!().agent.turn_timeout_ms

    receive do
      {^port, {:data, {:eol, chunk}}} ->
        line = buffer <> to_string(chunk)
        log_stream_line(line)
        collect_output(port, "", [line | acc], config)

      {^port, {:data, {:noeol, chunk}}} ->
        collect_output(port, buffer <> to_string(chunk), acc, config)

      {^port, {:exit_status, 0}} ->
        remaining = buffer |> to_string() |> String.trim()
        if remaining != "", do: log_stream_line(remaining)
        lines = if remaining != "", do: [remaining | acc], else: acc
        {:ok, Enum.reverse(lines)}

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

  defp shell_escape(value) when is_binary(value), do: CymphonyElixir.Shell.escape(value)
end
