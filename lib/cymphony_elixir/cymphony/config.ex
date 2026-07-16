defmodule CymphonyElixir.Cymphony.Config do
  @moduledoc false

  alias CymphonyElixir.Cymphony.Defaults

  @config_dir "~/.cymphony"
  @config_file "config.json"

  @spec config_dir() :: String.t()
  def config_dir do
    case Application.get_env(:cymphony_elixir, :config_dir_override) do
      override when is_binary(override) -> override
      _ -> Path.expand(@config_dir)
    end
  end

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

  @doc """
  Updates `max_concurrent_agents` for the named project (or for the entire
  legacy single-project config if `project_name` is `nil`) and persists to
  disk. Returns `{:ok, updated_config}` or an error tuple.
  """
  @spec update_concurrency(String.t() | nil, pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def update_concurrency(project_name, n) when is_integer(n) and n > 0 do
    with {:ok, config} <- load(),
         {:ok, updated} <- apply_concurrency(config, project_name, n),
         :ok <- save(updated) do
      {:ok, updated}
    end
  end

  defp apply_concurrency(%{"projects" => projects} = config, project_name, n)
       when is_list(projects) do
    updated_projects =
      Enum.map(projects, fn project ->
        cond do
          is_nil(project_name) ->
            Map.put(project, "max_concurrent_agents", n)

          project["name"] == project_name ->
            Map.put(project, "max_concurrent_agents", n)

          true ->
            project
        end
      end)

    {:ok, Map.put(config, "projects", updated_projects)}
  end

  defp apply_concurrency(config, _project_name, n) when is_map(config) do
    {:ok, Map.put(config, "max_concurrent_agents", n)}
  end

  @doc """
  Updates `provider` (head) and `providers` (full list) for the named project
  (or for all projects if `project_name` is `nil`) and persists to disk.
  Returns `{:ok, updated_config}` or an error tuple.
  """
  @spec update_providers(String.t() | nil, [String.t()]) ::
          {:ok, map()} | {:error, term()}
  def update_providers(project_name, providers)
      when is_list(providers) and providers != [] do
    with {:ok, config} <- load(),
         {:ok, updated} <- apply_providers(config, project_name, providers),
         :ok <- save(updated) do
      {:ok, updated}
    end
  end

  def update_providers(_project_name, _providers), do: {:error, :invalid_providers}

  defp apply_providers(%{"projects" => projects} = config, project_name, providers)
       when is_list(projects) do
    updated_projects =
      Enum.map(projects, fn project ->
        cond do
          is_nil(project_name) ->
            put_providers(project, providers)

          project["name"] == project_name ->
            put_providers(project, providers)

          true ->
            project
        end
      end)

    {:ok, Map.put(config, "projects", updated_projects)}
  end

  defp apply_providers(config, _project_name, providers) when is_map(config) do
    {:ok, put_providers(config, providers)}
  end

  defp put_providers(map, providers) do
    map
    |> Map.put("provider", hd(providers))
    |> Map.put("providers", providers)
  end

  @doc """
  Parses a comma-separated provider list into a normalized list of names.
  Trims whitespace and drops empty segments. Returns `{:error, :empty}` if no
  non-empty segments remain.
  """
  @spec parse_providers_csv(String.t()) :: {:ok, [String.t()]} | {:error, :empty}
  def parse_providers_csv(value) when is_binary(value) do
    list =
      value
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if list == [], do: {:error, :empty}, else: {:ok, list}
  end

  def parse_providers_csv(_), do: {:error, :empty}

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

  @doc """
  Builds the Schema-shaped (nested, string-keyed) runtime config map for a
  project from its flat `config.json` representation, applying `Defaults`.

  This is the structured replacement for the old hand-built YAML string: the
  generator serializes this map (as JSON, which is valid YAML) into the
  `WORKFLOW.md` front matter, so values containing YAML metacharacters (`:`,
  `#`, quotes, newlines) round-trip safely and missing keys get explicit
  defaults rather than silently becoming Schema fallbacks.
  """
  @spec to_schema_map(map()) :: map()
  def to_schema_map(config) when is_map(config) do
    base = %{
      "tracker" => %{
        "kind" => "linear",
        "api_key" => Map.get(config, "linear_api_key", ""),
        "project_slug" => Map.get(config, "linear_project_slug", ""),
        "active_states" => Defaults.active_states(),
        "terminal_states" => Defaults.terminal_states()
      },
      "polling" => %{
        "interval_ms" => Map.get(config, "polling_interval_ms", Defaults.polling_interval_ms())
      },
      "workspace" => %{
        "root" => Map.get(config, "workspace_root", Defaults.workspace_root())
      },
      "agent" => %{
        "kind" => agent_kind(config),
        "model" => Map.get(config, "model"),
        "effort" => Map.get(config, "effort"),
        "max_concurrent_agents" => Map.get(config, "max_concurrent_agents", Defaults.max_concurrent_agents()),
        "max_turns" => Defaults.max_turns()
      },
      "claude" => agent_section_map(config, "claude"),
      "codex" => agent_section_map(config, "codex")
    }

    maybe_put_hooks(base, config)
  end

  defp agent_kind(config) do
    case Map.get(config, "agent") do
      kind when kind in ["claude", "codex"] -> kind
      _ -> Defaults.agent_kind()
    end
  end

  defp agent_section_map(config, "claude") do
    %{"command" => Defaults.claude_command(), "output_format" => Defaults.output_format()}
    |> maybe_put_provider_keys(config, "claude")
  end

  defp agent_section_map(config, "codex") do
    %{"command" => Defaults.codex_command(), "sandbox" => Defaults.codex_sandbox()}
    |> maybe_put_provider_keys(config, "codex")
  end

  # Providers are auth aliases for a specific backend: they belong to the
  # active kind's section only.
  defp maybe_put_provider_keys(section, config, kind) do
    if agent_kind(config) == kind do
      providers = Map.get(config, "providers", [])
      provider = Map.get(config, "provider")

      cond do
        is_list(providers) and providers != [] ->
          section
          |> Map.put("providers", providers)
          |> Map.put("provider", hd(providers))

        is_binary(provider) and provider != "" ->
          Map.put(section, "provider", provider)

        true ->
          section
      end
    else
      section
    end
  end

  defp maybe_put_hooks(base, config) do
    case Map.get(config, "github_repo_url", "") do
      repo when is_binary(repo) and repo != "" ->
        Map.put(base, "hooks", %{"after_create" => "git clone --depth 1 #{repo} .\n"})

      _ ->
        base
    end
  end
end
