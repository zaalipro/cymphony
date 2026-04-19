defmodule SymphonyElixir.CLI do
  @moduledoc """
  Escript entrypoint for running Symphony with an explicit WORKFLOW.md path.
  """

  alias SymphonyElixir.LogFile

  alias SymphonyElixir.Cymphony.Config, as: CymphonyConfig
  alias SymphonyElixir.Cymphony.Onboarding
  alias SymphonyElixir.Cymphony.WorkflowGenerator

  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails
  @switches [
    {@acknowledgement_switch, :boolean},
    help: :boolean,
    logs_root: :string,
    port: :integer,
    project: :string,
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

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @spec evaluate([String.t()], deps()) :: :ok | {:error, String.t()}
  def evaluate(args, deps \\ runtime_deps()) do
    args = expand_shorthands(args)

    cond do
      help_requested?(args) ->
        {:error, help_text()}

      version_requested?(args) ->
        show_version()

      list_requested?(args) ->
        list_projects()

      add_project_requested?(args) ->
        add_project()

      true ->
        if cymphony_mode?(args) do
          cymphony_evaluate(args, deps)
        else
          legacy_evaluate(args, deps)
        end
    end
  end

  defp expand_shorthands([]), do: []

  defp expand_shorthands(["h" | rest]), do: ["--help" | expand_shorthands(rest)]
  defp expand_shorthands(["s" | rest]), do: ["--setup" | expand_shorthands(rest)]
  defp expand_shorthands(["l" | rest]), do: ["list" | expand_shorthands(rest)]
  defp expand_shorthands(["a" | rest]), do: ["add-project" | expand_shorthands(rest)]
  defp expand_shorthands(["v" | rest]), do: ["--version" | expand_shorthands(rest)]
  defp expand_shorthands(["p", value | rest]), do: ["--project", value | expand_shorthands(rest)]
  defp expand_shorthands(["p" | _]), do: ["--help"]
  defp expand_shorthands([arg | rest]), do: [arg | expand_shorthands(rest)]

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

  defp help_text do
    """

    Usage:
      cymphony                       Run with saved config (all projects)
      cymphony p frontend            Run only the "frontend" project
      cymphony s                     Run setup / onboarding wizard
      cymphony a                     Add a project to existing config
      cymphony l                     List configured projects
      cymphony v                     Show version
      cymphony h                     Show this help

    Flags:
      --setup                  Force onboarding wizard
      --project <name>         Run a specific project
      --logs-root <path>       Override log directory
      --port <port>            Override HTTP server port
      --help, -h               Show this help
      --version                Show version

    Legacy mode (advanced):
      cymphony [WORKFLOW.md] --i-understand-that-this-will-be-running-without-the-usual-guardrails
    """
  end

  defp cymphony_mode?(args) do
    {opts, positional, _invalid} = OptionParser.parse(args, strict: @switches)

    positional == [] and
      not Keyword.has_key?(opts, @acknowledgement_switch) and
      not File.regular?(Path.expand("WORKFLOW.md"))
  end

  defp list_projects do
    case Onboarding.list_projects() do
      {:ok, projects} ->
        case projects do
          [] ->
            IO.puts("No projects configured. Run `cymphony s` to set up.")
            :ok

          projects ->
            IO.puts("Configured projects:\n")

            Enum.each(projects, fn project ->
              name = Map.get(project, "name", "unnamed")
              slug = Map.get(project, "linear_project_slug", "n/a")
              IO.puts("  #{name} (slug: #{slug})")
            end)

            :ok
        end

      {:error, reason} ->
        {:error, "Configuration error: #{inspect(reason)}"}
    end
  end

  defp add_project do
    case Onboarding.add_project() do
      {:ok, _config} -> :ok
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp show_version do
    version = Application.spec(:symphony_elixir, :vsn) || "unknown"
    IO.puts("cymphony #{version}")
    :ok
  end

  defp cymphony_evaluate(args, deps) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)
    project_filter = Keyword.get(opts, :project)

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
        {:error, "Failed to start Symphony: #{inspect(reason)}"}
    end
  end

  defp start_project(project_name, workflow_path) do
    spec = {
      SymphonyElixir.ProjectSupervisor,
      project_name: project_name, workflow_path: workflow_path
    }

    case DynamicSupervisor.start_child(SymphonyElixir.ProjectDynamicSupervisor, spec) do
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
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          run(Path.expand("WORKFLOW.md"), deps)
        end

      {opts, [workflow_path], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
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
          {:error, "Failed to start Symphony with workflow #{expanded_path}: #{inspect(reason)}"}
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
      set_workflow_file_path: &SymphonyElixir.Workflow.set_workflow_file_path/1,
      set_logs_root: &set_logs_root/1,
      set_server_port_override: &set_server_port_override/1,
      ensure_all_started: fn -> Application.ensure_all_started(:symphony_elixir) end
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

  defp require_guardrails_acknowledgement(opts) do
    if Keyword.get(opts, @acknowledgement_switch, false) do
      :ok
    else
      {:error, acknowledgement_banner()}
    end
  end

  @spec acknowledgement_banner() :: String.t()
  defp acknowledgement_banner do
    lines = [
      "This Symphony implementation is a low key engineering preview.",
      "Claude Code will run without any guardrails.",
      "SymphonyElixir is not a supported product and is presented as-is.",
      "To proceed, start with `--i-understand-that-this-will-be-running-without-the-usual-guardrails` CLI argument"
    ]

    width = Enum.max(Enum.map(lines, &String.length/1))
    border = String.duplicate("─", width + 2)
    top = "╭" <> border <> "╮"
    bottom = "╰" <> border <> "╯"
    spacer = "│ " <> String.duplicate(" ", width) <> " │"

    content =
      [
        top,
        spacer
        | Enum.map(lines, fn line ->
            "│ " <> String.pad_trailing(line, width) <> " │"
          end)
      ] ++ [spacer, bottom]

    [
      IO.ANSI.red(),
      IO.ANSI.bright(),
      Enum.join(content, "\n"),
      IO.ANSI.reset()
    ]
    |> IO.iodata_to_binary()
  end

  defp set_logs_root(logs_root) do
    Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
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
    Application.put_env(:symphony_elixir, :server_port_override, port)
    :ok
  end

  @spec wait_for_shutdown() :: no_return()
  defp wait_for_shutdown do
    case Process.whereis(SymphonyElixir.Supervisor) do
      nil ->
        IO.puts(:stderr, "Symphony supervisor is not running")
        System.halt(1)

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            case reason do
              :normal -> System.halt(0)
              _ -> System.halt(1)
            end
        end
    end
  end
end
