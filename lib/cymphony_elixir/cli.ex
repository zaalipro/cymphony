defmodule CymphonyElixir.CLI do
  @moduledoc """
  Escript entrypoint for running Cymphony with an explicit WORKFLOW.md path.
  """

  alias CymphonyElixir.LogFile
  alias CymphonyElixir.Shell

  alias CymphonyElixir.Cymphony.Config, as: CymphonyConfig
  alias CymphonyElixir.Cymphony.Onboarding
  alias CymphonyElixir.Cymphony.ShellProvider
  alias CymphonyElixir.Cymphony.WorkflowGenerator

  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails
  @switches [
    {@acknowledgement_switch, :boolean},
    background: :boolean,
    background_stop: :boolean,
    claude_command: :string,
    concurrency: :integer,
    daemon_internal: :boolean,
    help: :boolean,
    logs_root: :string,
    port: :integer,
    project: :string,
    provider: :string,
    restart: :boolean,
    setup: :boolean,
    version: :boolean
  ]

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type deps :: %{
          file_regular?: (String.t() -> boolean()),
          set_workflow_file_path: (String.t() -> :ok | {:error, term()}),
          set_logs_root: (String.t() -> :ok | {:error, term()}),
          set_server_port_override: (non_neg_integer() | nil -> :ok | {:error, term()}),
          ensure_all_started: (-> ensure_started_result())
        }

  @spec main([String.t()]) :: no_return()
  def main(args) do
    case evaluate(args) do
      :ok ->
        wait_for_shutdown()

      :done ->
        :ok

      {:error, message} ->
        cleanup_pidfile()
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @spec evaluate([String.t()], deps()) :: :ok | :done | {:error, String.t()}
  def evaluate(args, deps \\ runtime_deps()) do
    args = expand_shorthands(args)

    cond do
      help_requested?(args) ->
        {:error, help_text()}

      version_requested?(args) ->
        show_version()

      log_requested?(args) ->
        show_log(args)

      list_requested?(args) ->
        list_projects()

      add_project_requested?(args) ->
        add_project()

      stop_background_requested?(args) ->
        stop_background()

      restart_requested?(args) ->
        restart_background(args, deps)

      webui_requested?(args) ->
        open_webui()

      background_requested?(args) ->
        run_background(args, deps)

      true ->
        if cymphony_mode?(args) do
          cymphony_evaluate(args, deps)
        else
          legacy_evaluate(args, deps)
        end
    end
  end

  defp expand_shorthands([]), do: []

  defp expand_shorthands(["b" | rest]), do: ["--background" | expand_shorthands(rest)]
  defp expand_shorthands(["start" | rest]), do: ["--background" | expand_shorthands(rest)]
  defp expand_shorthands(["bs" | rest]), do: ["--background-stop" | expand_shorthands(rest)]
  defp expand_shorthands(["stop" | rest]), do: ["--background-stop" | expand_shorthands(rest)]
  defp expand_shorthands(["h" | rest]), do: ["--help" | expand_shorthands(rest)]
  defp expand_shorthands(["r" | rest]), do: ["--restart" | expand_shorthands(rest)]
  defp expand_shorthands(["restart" | rest]), do: ["--restart" | expand_shorthands(rest)]
  defp expand_shorthands(["s" | rest]), do: ["--setup" | expand_shorthands(rest)]
  defp expand_shorthands(["setup" | rest]), do: ["--setup" | expand_shorthands(rest)]
  defp expand_shorthands(["l" | rest]), do: ["list" | expand_shorthands(rest)]
  defp expand_shorthands(["a" | rest]), do: ["add-project" | expand_shorthands(rest)]
  defp expand_shorthands(["add" | rest]), do: ["add-project" | expand_shorthands(rest)]
  defp expand_shorthands(["v" | rest]), do: ["--version" | expand_shorthands(rest)]
  defp expand_shorthands(["log" | rest]), do: ["log" | expand_shorthands(rest)]
  defp expand_shorthands(["logs" | rest]), do: ["log" | expand_shorthands(rest)]
  defp expand_shorthands(["p", value | rest]), do: ["--project", value | expand_shorthands(rest)]
  defp expand_shorthands(["p" | _]), do: ["--help"]
  defp expand_shorthands(["project", value | rest]), do: ["--project", value | expand_shorthands(rest)]
  defp expand_shorthands(["project" | _]), do: ["--help"]
  defp expand_shorthands(["projects", value | rest]), do: ["--project", value | expand_shorthands(rest)]
  defp expand_shorthands(["projects" | _]), do: ["--help"]
  defp expand_shorthands(["c", value | rest]), do: ["--claude-command", value | expand_shorthands(rest)]
  defp expand_shorthands(["c" | _]), do: ["--help"]
  defp expand_shorthands(["cr", value | rest]), do: ["--concurrency", value | expand_shorthands(rest)]
  defp expand_shorthands(["cr" | _]), do: ["--help"]
  defp expand_shorthands(["port", value | rest]), do: ["--port", value | expand_shorthands(rest)]
  defp expand_shorthands(["port" | _]), do: ["--help"]
  defp expand_shorthands([arg | rest]), do: [arg | expand_shorthands(rest)]

  defp background_requested?(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)
    Keyword.get(opts, :background, false)
  end

  defp stop_background_requested?(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)
    Keyword.get(opts, :background_stop, false)
  end

  defp restart_requested?(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)
    Keyword.get(opts, :restart, false)
  end

  defp help_requested?(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)
    Keyword.get(opts, :help, false)
  end

  defp version_requested?(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)
    Keyword.get(opts, :version, false)
  end

  defp list_requested?(args) do
    args == ["list"] or args == ["ls"]
  end

  defp add_project_requested?(args) do
    args == ["add-project"]
  end

  defp log_requested?(["log" | _]), do: true
  defp log_requested?(_), do: false

  defp webui_requested?(args), do: args == ["webui"]

  defp show_log(args) do
    tail_count =
      case args do
        ["log"] ->
          nil

        ["log", count | _] ->
          case Integer.parse(count) do
            {n, ""} when n > 0 -> n
            _ -> nil
          end

        _ ->
          nil
      end

    log_path = CymphonyElixir.LogFile.default_log_file()

    if File.exists?(log_path) or has_rotated_logs?(log_path) do
      output =
        case tail_count do
          nil ->
            read_all_logs(log_path)

          n ->
            read_all_logs(log_path) |> tail_lines(n)
        end

      IO.binwrite(output)
    else
      IO.puts(:stderr, "No log file found at #{log_path}")
    end

    :done
  end

  defp has_rotated_logs?(log_path) do
    log_dir = Path.dirname(log_path)
    base = Path.basename(log_path)

    case File.ls(log_dir) do
      {:ok, files} ->
        Enum.any?(files, &String.starts_with?(&1, base <> "."))

      {:error, _} ->
        false
    end
  end

  defp read_all_logs(log_path) do
    log_dir = Path.dirname(log_path)
    base = Path.basename(log_path)

    rotated =
      case File.ls(log_dir) do
        {:ok, files} ->
          files
          |> Enum.filter(&String.starts_with?(&1, base <> "."))
          |> Enum.sort_by(
            fn f ->
              case String.trim_leading(f, base <> ".") |> Integer.parse() do
                {n, ""} -> n
                _ -> 0
              end
            end,
            :desc
          )
          |> Enum.map(&Path.join(log_dir, &1))

        {:error, _} ->
          []
      end

    # Read rotated logs (oldest rotation index first, then newer), then current
    all_paths = Enum.reverse(rotated) ++ [log_path]

    all_paths
    |> Enum.map(fn path ->
      case File.read(path) do
        {:ok, content} -> content
        {:error, _} -> ""
      end
    end)
    |> Enum.join()
  end

  defp tail_lines(content, n) do
    content
    |> String.split("\n")
    |> Enum.take(-n)
    |> Enum.join("\n")
  end

  defp help_text do
    """

    Usage:
      cymphony                       Run with saved config (all projects)
      cymphony project frontend      Run only the "frontend" project
      cymphony c cz                  Run with a different Claude provider (e.g. cz, ck, cm)
      cymphony c cv1,cz2,cz1         Run with provider rotation (random per session)
      cymphony cr 3                  Set max concurrent agents to 3
      cymphony cr 3 c cv1,cz2        Set concurrency and provider rotation together
      cymphony port 4089             Set HTTP server / dashboard port
      cymphony start                 Run in background
      cymphony stop                  Stop background process
      cymphony restart               Restart background process
      cymphony webui                 Open the dashboard in your browser
      cymphony setup                 Run setup / onboarding wizard
      cymphony add                   Add a project to existing config
      cymphony list                  List configured projects
      cymphony v                     Show version
      cymphony logs                  Show full log
      cymphony logs 50               Show last 50 lines of log
      cymphony h                     Show this help

    Flags:
      --setup                  Force onboarding wizard
      --project <name>         Run a specific project
      --provider <name>        Override the Claude provider for this run
      --claude-command <cmd>   Override the Claude command for this run
      --concurrency <n>        Set max concurrent agents
      --logs-root <path>       Override log directory
      --port <port>            Override HTTP server port
      --help, -h               Show this help
      --version                Show version

    Legacy mode (advanced):
      cymphony [WORKFLOW.md] --i-understand-that-this-will-be-running-without-the-usual-guardrails
    """
  end

  defp cymphony_mode?(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    # Daemon-internal processes are always spawned by cymphony itself
    # and should always use config-based cymphony mode.
    Keyword.get(opts, :daemon_internal, false) or
      Keyword.has_key?(opts, :project) or
      Keyword.has_key?(opts, :setup) or
      Keyword.has_key?(opts, :claude_command) or
      Keyword.has_key?(opts, :provider) or
      Keyword.has_key?(opts, :concurrency) or
      (positional == [] and invalid == [] and
         not Keyword.has_key?(opts, @acknowledgement_switch) and
         (CymphonyConfig.exists?() or
            not File.regular?(Path.expand("WORKFLOW.md"))))
  end

  defp list_projects do
    case Onboarding.list_projects() do
      {:ok, projects} ->
        case projects do
          [] ->
            IO.puts("No projects configured. Run `cymphony s` to set up.")
            :done

          projects ->
            IO.puts("Configured projects:\n")

            Enum.each(projects, fn project ->
              name = Map.get(project, "name", "unnamed")
              slug = Map.get(project, "linear_project_slug", "n/a")
              IO.puts("  #{name} (slug: #{slug})")
            end)

            :done
        end

      {:error, reason} ->
        {:error, "Configuration error: #{inspect(reason)}"}
    end
  end

  defp add_project do
    case Onboarding.add_project() do
      {:ok, _config} -> :done
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @version Mix.Project.config()[:version]

  defp show_version do
    IO.puts("cymphony #{@version}")
    :done
  end

  defp cymphony_evaluate(args, deps) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)
    project_filter = Keyword.get(opts, :project)

    if Keyword.get(opts, :daemon_internal, false) do
      :ok = write_pidfile(System.pid())
    end

    config =
      if Keyword.get(opts, :setup, false) or not CymphonyConfig.exists?() do
        Onboarding.run()
      else
        CymphonyConfig.load()
      end

    case config do
      {:ok, cfg} ->
        projects = CymphonyConfig.projects(cfg)
        filtered_projects = filter_projects(projects, project_filter)

        filtered_projects =
          case Keyword.get(opts, :claude_command) do
            nil -> filtered_projects
            cmd -> Enum.map(filtered_projects, &resolve_command_override(&1, cmd))
          end

        filtered_projects =
          case Keyword.get(opts, :provider) do
            nil -> filtered_projects
            provider -> Enum.map(filtered_projects, &Map.put(&1, "provider", provider))
          end

        filtered_projects =
          case Keyword.get(opts, :concurrency) do
            n when is_integer(n) and n > 0 ->
              Enum.map(filtered_projects, &Map.put(&1, "max_concurrent_agents", n))

            _ ->
              filtered_projects
          end

        case filtered_projects do
          [] ->
            {:error,
             if project_filter do
               "Project '#{project_filter}' not found in config"
             else
               "No projects configured. Run `cymphony s` to set up."
             end}

          projects ->
            case generate_workflow_files(projects) do
              {:ok, project_workflow_pairs} ->
                with :ok <- maybe_set_logs_root(opts, deps),
                     :ok <- maybe_set_server_port(opts, deps) do
                  run_multi_project(project_workflow_pairs, deps)
                end

              {:error, reason} ->
                {:error, "Failed to generate workflow: #{inspect(reason)}"}
            end
        end

      {:error, reason} ->
        {:error, "Configuration error: #{inspect(reason)}"}
    end
  end

  defp resolve_command_override(project, cmd) do
    providers = parse_provider_list(cmd)

    case providers do
      [single] ->
        case ShellProvider.load_env(single) do
          {:ok, _env} -> Map.put(project, "provider", single)
          {:error, :not_found} -> Map.put(project, "claude_command", cmd)
        end

      multiple ->
        case ShellProvider.load_env(hd(multiple)) do
          {:ok, _env} ->
            project
            |> Map.put("provider", hd(multiple))
            |> Map.put("providers", multiple)

          {:error, :not_found} ->
            Map.put(project, "claude_command", cmd)
        end
    end
  end

  defp parse_provider_list(value) when is_binary(value) do
    case String.split(value, ",", trim: true) do
      [] -> [value]
      list -> Enum.map(list, &String.trim/1)
    end
  end

  defp filter_projects(projects, nil), do: projects

  defp filter_projects(projects, project_name) when is_binary(project_name) do
    Enum.filter(projects, fn project ->
      Map.get(project, "name") == project_name
    end)
  end

  defp generate_workflow_files(projects) do
    results =
      Enum.map(projects, fn project ->
        case WorkflowGenerator.write_temp(project) do
          {:ok, path} -> {:ok, {project, path}}
          {:error, reason} -> {:error, reason}
        end
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      {:error, reason} -> {:error, reason}
      nil -> {:ok, Enum.map(results, fn {:ok, pair} -> pair end)}
    end
  end

  defp run_multi_project(project_workflow_pairs, deps) do
    # Set the first project's workflow as the global default for backward compat
    {_first_project, first_workflow_path} = hd(project_workflow_pairs)
    :ok = deps.set_workflow_file_path.(first_workflow_path)

    case deps.ensure_all_started.() do
      {:ok, _started_apps} ->
        # Start each project under the DynamicSupervisor
        Enum.each(project_workflow_pairs, fn {project, workflow_path} ->
          project_name = Map.get(project, "name", "default")
          start_project(project_name, workflow_path)
        end)

        :ok

      {:error, reason} ->
        {:error, "Failed to start Cymphony: #{inspect(reason)}"}
    end
  end

  defp start_project(project_name, workflow_path) do
    spec = {
      CymphonyElixir.ProjectSupervisor,
      project_name: project_name, workflow_path: workflow_path
    }

    case DynamicSupervisor.start_child(CymphonyElixir.ProjectDynamicSupervisor, spec) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "Failed to start project '#{project_name}': #{inspect(reason)}")
        :ok
    end
  end

  defp legacy_evaluate(args, deps) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        if Keyword.get(opts, :daemon_internal, false) do
          :ok = write_pidfile(System.pid())
        end

        with :ok <- maybe_require_guardrails(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          run(Path.expand("WORKFLOW.md"), deps)
        end

      {opts, [workflow_path], []} ->
        if Keyword.get(opts, :daemon_internal, false) do
          :ok = write_pidfile(System.pid())
        end

        with :ok <- maybe_require_guardrails(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          run(workflow_path, deps)
        end

      _ ->
        {:error, usage_message()}
    end
  end

  @spec run(String.t(), deps()) :: :ok | {:error, String.t()}
  def run(workflow_path, deps) do
    expanded_path = Path.expand(workflow_path)

    if deps.file_regular?.(expanded_path) do
      :ok = deps.set_workflow_file_path.(expanded_path)

      case deps.ensure_all_started.() do
        {:ok, _started_apps} ->
          :ok

        {:error, reason} ->
          {:error, "Failed to start Cymphony with workflow #{expanded_path}: #{inspect(reason)}"}
      end
    else
      {:error, "Workflow file not found: #{expanded_path}"}
    end
  end

  @spec usage_message() :: String.t()
  defp usage_message do
    "Usage: cymphony [--setup] [--project <name>] [--logs-root <path>] [--port <port>]\n" <>
      "       cymphony [--logs-root <path>] [--port <port>] [path-to-WORKFLOW.md] --i-understand-that-this-will-be-running-without-the-usual-guardrails"
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      file_regular?: &File.regular?/1,
      set_workflow_file_path: &CymphonyElixir.Workflow.set_workflow_file_path/1,
      set_logs_root: &set_logs_root/1,
      set_server_port_override: &set_server_port_override/1,
      ensure_all_started: fn -> Application.ensure_all_started(:cymphony_elixir) end
    }
  end

  defp maybe_set_logs_root(opts, deps) do
    case Keyword.get_values(opts, :logs_root) do
      [] ->
        :ok

      values ->
        logs_root = values |> List.last() |> String.trim()

        if logs_root == "" do
          {:error, usage_message()}
        else
          :ok = deps.set_logs_root.(Path.expand(logs_root))
        end
    end
  end

  defp maybe_require_guardrails(_opts) do
    :ok
  end

  defp set_logs_root(logs_root) do
    Application.put_env(:cymphony_elixir, :log_file, LogFile.default_log_file(logs_root))
    :ok
  end

  defp maybe_set_server_port(opts, deps) do
    case Keyword.get_values(opts, :port) do
      [] ->
        :ok

      values ->
        port = List.last(values)

        if is_integer(port) and port >= 0 do
          :ok = deps.set_server_port_override.(port)
        else
          {:error, usage_message()}
        end
    end
  end

  defp set_server_port_override(port) when is_integer(port) and port >= 0 do
    Application.put_env(:cymphony_elixir, :server_port_override, port)
    :ok
  end

  @spec wait_for_shutdown() :: no_return()
  defp wait_for_shutdown do
    case Process.whereis(CymphonyElixir.Supervisor) do
      nil ->
        cleanup_pidfile()
        IO.puts(:stderr, "Cymphony supervisor is not running")
        System.halt(1)

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            cleanup_pidfile()

            case reason do
              :normal -> System.halt(0)
              _ -> System.halt(1)
            end
        end
    end
  end

  # ─── Background process management ───

  defp run_background(args, deps) do
    case read_pidfile() do
      {:ok, pid} ->
        if process_alive?(pid) do
          {:error, "Cymphony is already running in background (PID: #{pid})"}
        else
          remove_pidfile()
          do_run_background(args, deps)
        end

      :error ->
        do_run_background(args, deps)
    end
  end

  defp do_run_background(args, _deps) do
    filtered_args =
      args
      |> Enum.reject(&(&1 == "--background"))
      |> Kernel.++(["--daemon-internal"])

    escript = escript_path()
    log_file = Path.join(CymphonyConfig.config_dir(), "cymphony.log")

    # Use nohup to detach from terminal; the inner & backgrounds the process
    # so the outer sh exits immediately. Each token is shell-escaped so paths
    # or args containing spaces/metacharacters are treated literally.
    escaped_command = Enum.map_join([escript | filtered_args], " ", &Shell.escape/1)

    cmd = "nohup #{escaped_command} > #{Shell.escape(log_file)} 2>&1 </dev/null &"

    _ = System.cmd("sh", ["-c", cmd], stderr_to_stdout: true)

    # Give the child process a moment to write its pidfile
    case wait_for_pidfile(5_000) do
      {:ok, pid} ->
        IO.puts("Cymphony started in background (PID: #{pid})")
        :done

      :timeout ->
        IO.puts("Cymphony started in background (PID unknown)")
        :done
    end
  end

  defp stop_background do
    case read_pidfile() do
      :error ->
        {:error, "Cymphony is not running in background"}

      {:ok, pid} ->
        if not process_alive?(pid) do
          remove_pidfile()
          {:error, "Cymphony is not running in background (stale pidfile removed)"}
        else
          System.cmd("kill", ["-TERM", pid])

          case wait_for_process_death(pid, 10_000) do
            :ok ->
              remove_pidfile()
              IO.puts("Cymphony stopped (PID: #{pid})")
              :done

            :timeout ->
              {:error, "Timed out waiting for Cymphony (PID: #{pid}) to stop"}
          end
        end
    end
  end

  defp restart_background(args, deps) do
    _ = stop_background()
    run_background(args, deps)
  end

  defp open_webui do
    alias CymphonyElixir.Cymphony.UrlFile

    with {:ok, url} <- UrlFile.read(),
         :ok <- launch_browser(url) do
      IO.puts("Opening #{url}")
      :done
    else
      {:error, :not_running} ->
        {:error, "No dashboard URL recorded. Is cymphony running with a port? Try `cymphony port 4089 start`."}

      {:error, reason} ->
        {:error, "Failed to open browser: #{inspect(reason)}"}
    end
  end

  defp launch_browser(url) do
    opener =
      case :os.type() do
        {:unix, :darwin} -> {"open", [url]}
        {:unix, _} -> {"xdg-open", [url]}
        {:win32, _} -> {"cmd", ["/c", "start", "", url]}
      end

    {cmd, args} = opener

    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {output, status} -> {:error, "#{cmd} exited #{status}: #{String.trim(output)}"}
    end
  rescue
    error in [ErlangError] -> {:error, Exception.message(error)}
  end

  # ─── Pidfile helpers ───

  defp pidfile_path do
    Path.join(CymphonyConfig.config_dir(), "cymphony.pid")
  end

  defp read_pidfile do
    case File.read(pidfile_path()) do
      {:ok, content} ->
        pid = String.trim(content)
        if pid != "", do: {:ok, pid}, else: :error

      {:error, _} ->
        :error
    end
  end

  defp write_pidfile(pid) when is_binary(pid) do
    :ok = File.mkdir_p(CymphonyConfig.config_dir())
    File.write(pidfile_path(), pid)
  end

  defp write_pidfile(pid) when is_integer(pid) do
    write_pidfile(Integer.to_string(pid))
  end

  defp remove_pidfile do
    case File.rm(pidfile_path()) do
      :ok -> :ok
      {:error, _} -> :ok
    end
  end

  defp cleanup_pidfile do
    case read_pidfile() do
      {:ok, pid} ->
        if pid == System.pid() do
          remove_pidfile()
          CymphonyElixir.Cymphony.UrlFile.delete()
        end

      :error ->
        :ok
    end
  end

  defp process_alive?(pid) when is_binary(pid) do
    case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp escript_path do
    script = :escript.script_name()

    cond do
      is_binary(script) and script != "" ->
        script

      is_list(script) and script != [] ->
        List.to_string(script)

      true ->
        case :init.get_argument(:progname) do
          {:ok, [[path]]} when path != ~c"erl" and path != ~c"erlexec" ->
            List.to_string(path)

          _ ->
            System.find_executable("cymphony") || "cymphony"
        end
    end
  end

  defp wait_for_pidfile(timeout_ms) when timeout_ms > 0 do
    case read_pidfile() do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        Process.sleep(200)
        wait_for_pidfile(max(0, timeout_ms - 200))
    end
  end

  defp wait_for_pidfile(_timeout_ms), do: :timeout

  defp wait_for_process_death(pid, timeout_ms) when timeout_ms > 0 do
    if process_alive?(pid) do
      Process.sleep(200)
      wait_for_process_death(pid, max(0, timeout_ms - 200))
    else
      :ok
    end
  end

  defp wait_for_process_death(_pid, _timeout_ms), do: :timeout
end
