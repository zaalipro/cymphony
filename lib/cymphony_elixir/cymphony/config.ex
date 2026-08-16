defmodule CymphonyElixir.Cymphony.Config do
  @moduledoc false

  alias CymphonyElixir.Agent
  alias CymphonyElixir.Cymphony.Defaults

  @config_dir "~/.cymphony"
  @config_file "config.json"
  @default_dashboard_refresh_seconds 3

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
  Resolves the shared Linear API key.

  Prefers a non-empty `config["linear_api_key"]`, then the first non-empty
  project `linear_api_key`, then `LINEAR_API_KEY`.
  """
  @spec resolve_linear_api_key(map() | nil) :: String.t() | nil
  def resolve_linear_api_key(nil), do: env_linear_api_key()

  def resolve_linear_api_key(config) when is_map(config) do
    file_linear_api_key(config) || env_linear_api_key()
  end

  @doc """
  Masks a Linear API key as `••••` plus the last 4 characters.

  Keys shorter than 4 characters (after trim) are entirely `••••` so the
  mask never encodes the key length.
  """
  @spec mask_linear_api_key(String.t()) :: String.t()
  def mask_linear_api_key(key) when is_binary(key) do
    trimmed = String.trim(key)

    if String.length(trimmed) < 4 do
      "••••"
    else
      "••••" <> String.slice(trimmed, -4, 4)
    end
  end

  @doc """
  Where `resolve_linear_api_key/1` would get a key from: the config file,
  the process environment, or nowhere.
  """
  @spec linear_key_source(map() | nil) :: :config | :env | nil
  def linear_key_source(nil) do
    if is_binary(env_linear_api_key()), do: :env, else: nil
  end

  def linear_key_source(config) when is_map(config) do
    cond do
      is_binary(file_linear_api_key(config)) -> :config
      is_binary(env_linear_api_key()) -> :env
      true -> nil
    end
  end

  @doc """
  Persists a shared Linear API key to `config.json` (created if missing).

  Sets the top-level `linear_api_key` and stamps the same value onto every
  `projects[]` entry. `save/1` keeps the file mode at `0o600`.
  """
  @spec put_linear_api_key(String.t()) :: {:ok, map()} | {:error, :empty | term()}
  def put_linear_api_key(key) when is_binary(key) do
    case String.trim(key) do
      "" -> {:error, :empty}
      trimmed -> persist_linear_api_key(trimmed)
    end
  end

  @doc """
  Appends a project to `config.json`, inheriting the shared Linear API key.
  """
  @spec add_project(map()) ::
          {:ok, map()}
          | {:error, :duplicate_name | :duplicate_slug | :not_connected | :invalid_project | term()}
  def add_project(attrs) when is_map(attrs) do
    with {:ok, name} <- required_project_string(attrs, "name"),
         {:ok, slug} <- required_project_string(attrs, "linear_project_slug"),
         {:ok, config} <- load_or_empty_config(),
         {:ok, api_key} <- connected_linear_api_key(config),
         :ok <- reject_duplicate_project(config, name, slug) do
      project = build_added_project(attrs, name, slug, api_key)
      persist_added_project(config, project)
    end
  end

  defp persist_linear_api_key(key) do
    with {:ok, config} <- load_or_empty_config() do
      updated = stamp_linear_api_key(config, key)

      case save(updated) do
        :ok -> {:ok, updated}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp persist_added_project(config, project) do
    updated = Map.put(config, "projects", projects(config) ++ [project])

    case save(updated) do
      :ok -> {:ok, project}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_or_empty_config do
    case load() do
      {:ok, config} ->
        {:ok, config}

      {:error, reason} ->
        if exists?() do
          {:error, reason}
        else
          {:ok, %{"projects" => []}}
        end
    end
  end

  defp stamp_linear_api_key(config, key) do
    config
    |> Map.put("linear_api_key", key)
    |> stamp_projects_linear_key(key)
  end

  defp stamp_projects_linear_key(%{"projects" => projects} = config, key) when is_list(projects) do
    Map.put(config, "projects", Enum.map(projects, &Map.put(&1, "linear_api_key", key)))
  end

  defp stamp_projects_linear_key(config, _key), do: config

  defp file_linear_api_key(config) when is_map(config) do
    case present_string(Map.get(config, "linear_api_key")) do
      nil -> first_project_linear_api_key(projects(config))
      key -> key
    end
  end

  defp first_project_linear_api_key(project_list) do
    Enum.find_value(project_list, fn project ->
      present_string(Map.get(project, "linear_api_key"))
    end)
  end

  defp env_linear_api_key, do: present_string(System.get_env("LINEAR_API_KEY"))

  defp connected_linear_api_key(config) do
    case resolve_linear_api_key(config) do
      key when is_binary(key) -> {:ok, key}
      _ -> {:error, :not_connected}
    end
  end

  defp required_project_string(attrs, key) do
    case present_string(Map.get(attrs, key)) do
      nil -> {:error, :invalid_project}
      value -> {:ok, value}
    end
  end

  defp reject_duplicate_project(config, name, slug) do
    existing = projects(config)

    cond do
      Enum.any?(existing, &(present_string(&1["name"]) == name)) ->
        {:error, :duplicate_name}

      Enum.any?(existing, &(present_string(&1["linear_project_slug"]) == slug)) ->
        {:error, :duplicate_slug}

      true ->
        :ok
    end
  end

  defp build_added_project(attrs, name, slug, api_key) do
    %{
      "name" => name,
      "linear_project_slug" => slug,
      "linear_api_key" => api_key,
      "workspace_root" => added_workspace_root(attrs, name),
      "polling_interval_ms" => added_polling_interval_ms(attrs)
    }
    |> maybe_put_copied(attrs, "github_repo_url")
    |> maybe_put_agent(attrs)
    |> maybe_put_copied(attrs, "model")
    |> maybe_put_copied(attrs, "effort")
    |> maybe_put_copied(attrs, "provider")
  end

  defp added_workspace_root(attrs, name) do
    case present_string(Map.get(attrs, "workspace_root")) do
      nil -> Path.join(Defaults.workspace_root(), name)
      root -> root
    end
  end

  defp added_polling_interval_ms(attrs) do
    case Map.get(attrs, "polling_interval_ms") do
      n when is_integer(n) and n > 0 -> n
      _ -> Defaults.polling_interval_ms()
    end
  end

  defp maybe_put_copied(map, attrs, key) do
    case present_string(Map.get(attrs, key)) do
      nil -> map
      value -> Map.put(map, key, value)
    end
  end

  defp maybe_put_agent(map, attrs) do
    case present_string(Map.get(attrs, "agent")) do
      nil ->
        map

      kind ->
        if Agent.known_kind?(kind), do: Map.put(map, "agent", kind), else: map
    end
  end

  defp present_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present_string(_value), do: nil

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
  Dashboard payload refresh interval in seconds.

  Loads `config.json` and returns a positive integer. Missing or unreadable
  files, and any non-positive stored value, fall back to `3`.
  """
  @spec dashboard_refresh_seconds() :: pos_integer()
  def dashboard_refresh_seconds do
    case load() do
      {:ok, config} -> dashboard_refresh_seconds(config)
      _ -> @default_dashboard_refresh_seconds
    end
  end

  @doc """
  Normalizes a stored or in-memory refresh interval.

  A positive integer is returned as-is. A config map uses its top-level
  `dashboard_refresh_seconds` key. Anything else (including `0`, negatives,
  strings, and a missing key) is `3`.
  """
  @spec dashboard_refresh_seconds(term()) :: pos_integer()
  def dashboard_refresh_seconds(n) when is_integer(n) and n > 0, do: n

  def dashboard_refresh_seconds(config) when is_map(config) do
    dashboard_refresh_seconds(Map.get(config, "dashboard_refresh_seconds"))
  end

  def dashboard_refresh_seconds(_value), do: @default_dashboard_refresh_seconds

  @doc """
  Persists the daemon-wide dashboard payload refresh interval as a top-level
  `config.json` key (beside `projects`, never inside a project map).

  Requires an existing readable file, same as the other `update_*` helpers.
  Rejects non-positive values. Does not write `polling_interval_ms` or
  rewrite `WORKFLOW.md`.
  """
  @spec update_dashboard_refresh_seconds(term()) :: {:ok, map()} | {:error, term()}
  def update_dashboard_refresh_seconds(n) when is_integer(n) and n > 0 do
    with {:ok, config} <- load() do
      updated = Map.put(config, "dashboard_refresh_seconds", n)

      case save(updated) do
        :ok -> {:ok, updated}
        {:error, _} = error -> error
      end
    end
  end

  def update_dashboard_refresh_seconds(_n), do: {:error, :invalid_refresh_interval}

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

  @agent_setting_keys ["agent", "model", "effort"]

  @doc """
  Merges agent settings (`"agent"`, `"model"`, `"effort"`) onto the named
  project (or all projects when `project_name` is nil) and saves. Keys absent
  from `settings` are untouched; empty-string values delete the key.
  """
  @spec update_agent_settings(String.t() | nil, map()) ::
          :ok | {:error, :invalid_agent_kind | term()}
  def update_agent_settings(project_name, settings) when is_map(settings) do
    with :ok <- validate_agent_kind(Map.get(settings, "agent")),
         {:ok, config} <- load(),
         {:ok, updated} <- apply_agent_settings(config, project_name, settings) do
      save(updated)
    end
  end

  defp validate_agent_kind(nil), do: :ok

  defp validate_agent_kind(kind) do
    if kind in Agent.known_kinds(), do: :ok, else: {:error, :invalid_agent_kind}
  end

  defp apply_agent_settings(%{"projects" => projects} = config, project_name, settings)
       when is_list(projects) do
    updated_projects =
      Enum.map(projects, fn project ->
        if project_name == nil or Map.get(project, "name") == project_name do
          merge_agent_settings(project, settings)
        else
          project
        end
      end)

    {:ok, Map.put(config, "projects", updated_projects)}
  end

  defp apply_agent_settings(config, _project_name, settings) when is_map(config) do
    {:ok, merge_agent_settings(config, settings)}
  end

  defp merge_agent_settings(map, settings) do
    Enum.reduce(@agent_setting_keys, map, fn key, acc ->
      case Map.fetch(settings, key) do
        {:ok, ""} -> Map.delete(acc, key)
        {:ok, value} when is_binary(value) -> Map.put(acc, key, value)
        _ -> acc
      end
    end)
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
      "codex" => agent_section_map(config, "codex"),
      "antigravity" => agent_section_map(config, "antigravity")
    }

    maybe_put_hooks(base, config)
  end

  defp agent_kind(config) do
    kind = Map.get(config, "agent")
    if kind in Agent.known_kinds(), do: kind, else: Defaults.agent_kind()
  end

  defp agent_section_map(config, "claude") do
    %{"command" => Defaults.claude_command(), "output_format" => Defaults.output_format()}
    |> maybe_put_provider_keys(config, "claude")
  end

  defp agent_section_map(config, "codex") do
    %{"command" => Defaults.codex_command(), "sandbox" => Defaults.codex_sandbox()}
    |> maybe_put_provider_keys(config, "codex")
  end

  defp agent_section_map(config, "antigravity") do
    %{
      "command" => Defaults.antigravity_command(),
      "output_format" => "stream-json",
      "skip_permissions" => true
    }
    |> maybe_put_provider_keys(config, "antigravity")
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
