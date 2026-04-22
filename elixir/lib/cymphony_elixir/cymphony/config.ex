defmodule CymphonyElixir.Cymphony.Config do
  @moduledoc false

  @config_dir "~/.cymphony"
  @config_file "config.json"

  @spec config_dir() :: String.t()
  def config_dir, do: Path.expand(@config_dir)

  @spec config_path() :: String.t()
  def config_path, do: Path.join(config_dir(), @config_file)

  @spec exists?() :: boolean()
  def exists?, do: File.regular?(config_path())

  @spec load() :: {:ok, map()} | {:error, term()}
  def load do
    case File.read(config_path()) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, parsed} -> {:ok, normalize(parsed)}
          {:error, reason} -> {:error, "Invalid JSON in #{config_path()}: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "Failed to read #{config_path()}: #{inspect(reason)}"}
    end
  end

  @doc """
  Normalizes a config map into the multi-project format.

  Old flat format (no "projects" key) is converted to a single-element
  projects array with name derived from the linear_project_slug.
  """
  @spec normalize(map()) :: map()
  def normalize(%{"projects" => [_ | _]} = config), do: config

  def normalize(config) when is_map(config) do
    if Map.has_key?(config, "projects") do
      config
    else
      name = Map.get(config, "linear_project_slug", "default")
      project = Map.put(config, "name", name)
      Map.put(%{}, "projects", [project])
    end
  end

  @doc """
  Extracts the list of project configs from a normalized config map.
  """
  @spec projects(map()) :: [map()]
  def projects(%{"projects" => projects}) when is_list(projects), do: projects
  def projects(_config), do: []

  @doc """
  Finds a single project by name from a normalized config map.
  """
  @spec find_project(map(), String.t()) :: {:ok, map()} | {:error, :project_not_found}
  def find_project(config, project_name) when is_binary(project_name) do
    case Enum.find(projects(config), &(&1["name"] == project_name)) do
      nil -> {:error, :project_not_found}
      project -> {:ok, project}
    end
  end

  @spec save(map()) :: :ok | {:error, term()}
  def save(config) do
    dir = config_dir()

    with :ok <- File.mkdir_p(dir),
         {:ok, json} <- Jason.encode(config, pretty: true) do
      path = config_path()

      case File.write(path, json) do
        :ok ->
          File.chmod(path, 0o600)
          :ok

        {:error, reason} ->
          {:error, "Failed to write #{path}: #{inspect(reason)}"}
      end
    end
  end

  @spec to_workflow_yaml(map()) :: String.t()
  def to_workflow_yaml(config) do
    github_repo = Map.get(config, "github_repo_url", "")
    workspace_root = Map.get(config, "workspace_root", "~/.cymphony/workspaces")
    polling_ms = Map.get(config, "polling_interval_ms", 5000)
    claude_command = Map.get(config, "claude_command", "claude")

    hooks_section =
      if github_repo != "" do
        "\nhooks:\n" <>
          "  after_create: |\n" <>
          "    git clone --depth 1 #{github_repo} .\n" <>
          "    if command -v mise >/dev/null 2>&1; then\n" <>
          "      cd elixir && mise trust && mise exec -- mix deps.get\n" <>
          "    fi\n"
      else
        ""
      end

    "tracker:\n" <>
      "  kind: linear\n" <>
      "  api_key: #{Map.get(config, "linear_api_key", "")}\n" <>
      "  project_slug: #{Map.get(config, "linear_project_slug", "")}\n" <>
      "  active_states:\n" <>
      "    - Todo\n" <>
      "    - In Progress\n" <>
      "    - Merging\n" <>
      "    - Rework\n" <>
      "  terminal_states:\n" <>
      "    - Closed\n" <>
      "    - Cancelled\n" <>
      "    - Canceled\n" <>
      "    - Duplicate\n" <>
      "    - Done\n" <>
      "polling:\n" <>
      "  interval_ms: #{polling_ms}\n" <>
      "workspace:\n" <>
      "  root: #{workspace_root}\n" <>
      "#{hooks_section}" <>
      "agent:\n" <>
      "  max_concurrent_agents: 10\n" <>
      "  max_turns: 20\n" <>
      "claude:\n" <>
      "  command: #{claude_command}\n" <>
      "  output_format: stream-json\n" <>
      "  approval_policy: \"never\"\n" <>
      "  thread_sandbox: workspace-write\n" <>
      "  turn_sandbox_policy:\n" <>
      "    type: workspaceWrite\n"
  end
end
