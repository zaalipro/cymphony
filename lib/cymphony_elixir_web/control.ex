defmodule CymphonyElixirWeb.Control do
  @moduledoc """
  Shared dispatch-control operations used by both the LiveView dashboard and the
  JSON API: Linear connect, add-project, pause/resume, and concurrency /
  provider / agent updates. Encapsulates the
  `ProjectSupervisor → Orchestrator → CymphonyConfig` orchestration so the two
  web surfaces don't each reimplement it.

  A `scope` is either `:all` (every registered project, or the single legacy
  orchestrator when none are registered) or `{:project, name}` (one named
  project, falling back to the legacy orchestrator when no per-project
  supervisors are registered).
  """

  alias CymphonyElixir.{Agent, Orchestrator, ProjectSupervisor}
  alias CymphonyElixir.Cymphony.Config, as: CymphonyConfig
  alias CymphonyElixir.Cymphony.WorkflowGenerator
  alias CymphonyElixir.Linear.Client, as: LinearClient
  alias CymphonyElixirWeb.Endpoint

  @type scope :: :all | {:project, String.t()}
  @type linear_status :: %{
          connected: boolean(),
          masked_key: String.t() | nil,
          source: String.t() | nil
        }

  @doc "Maps an optional project param (nil/\"\" → `:all`) to a `scope`."
  @spec scope(String.t() | nil) :: scope()
  def scope(nil), do: :all
  def scope(""), do: :all
  def scope(name) when is_binary(name), do: {:project, name}

  @spec pause(scope()) :: :ok | {:error, :not_found}
  def pause(scope), do: apply_scope(scope, &Orchestrator.pause/1, &noop_persist/1)

  @spec resume(scope()) :: :ok | {:error, :not_found}
  def resume(scope), do: apply_scope(scope, &Orchestrator.resume/1, &noop_persist/1)

  @spec set_concurrency(scope(), pos_integer()) :: :ok | {:error, :not_found}
  def set_concurrency(scope, n) when is_integer(n) and n > 0 do
    apply_scope(
      scope,
      &Orchestrator.set_concurrency(&1, n),
      fn project -> CymphonyConfig.update_concurrency(project, n) end
    )
  end

  @spec set_providers(scope(), [String.t()]) :: :ok | {:error, :not_found}
  def set_providers(scope, providers) when is_list(providers) do
    apply_scope(
      scope,
      &Orchestrator.set_providers(&1, providers),
      fn project -> CymphonyConfig.update_providers(project, providers) end
    )
  end

  @spec set_agent_settings(scope(), map()) :: :ok | {:error, :not_found | term()}
  def set_agent_settings(scope, settings) when is_map(settings) do
    apply_scope(
      scope,
      &Orchestrator.set_agent_settings(&1, settings),
      fn project -> persist_agent_settings(project, settings) end
    )
  end

  @doc """
  Linear connect status for the dashboard and `GET /api/v1/linear`.

  Never includes the raw API key — `masked_key` is `mask_linear_api_key/1`.
  """
  @spec linear_status() :: linear_status()
  def linear_status do
    config = loaded_config()
    key = CymphonyConfig.resolve_linear_api_key(config)
    source = source_name(CymphonyConfig.linear_key_source(config))

    %{
      connected: is_binary(key),
      masked_key: if(is_binary(key), do: CymphonyConfig.mask_linear_api_key(key), else: nil),
      source: source
    }
  end

  @doc """
  Validates `api_key` against Linear, persists it to `config.json`, and
  rewrites each registered project's generated `WORKFLOW.md`.
  """
  @spec connect_linear(String.t()) ::
          {:ok, linear_status()} | {:error, :empty | :unauthorized | :invalid | term()}
  def connect_linear(api_key) when is_binary(api_key) do
    with {:ok, _viewer} <- LinearClient.validate_api_key(api_key),
         {:ok, _config} <- CymphonyConfig.put_linear_api_key(api_key) do
      rewrite_registered_workflows()
      {:ok, linear_status()}
    end
  end

  @doc """
  Lists Linear projects accessible with the resolved API key.
  """
  @spec list_linear_projects() :: {:ok, [map()]} | {:error, :not_connected | term()}
  def list_linear_projects do
    case CymphonyConfig.resolve_linear_api_key(loaded_config()) do
      key when is_binary(key) -> LinearClient.list_accessible_projects(key)
      _ -> {:error, :not_connected}
    end
  end

  @doc """
  Persists a project to `config.json`, writes a temp `WORKFLOW.md`, and starts
  the project supervisor. The returned map never includes `linear_api_key`.
  """
  @spec add_project(map()) ::
          {:ok, map()}
          | {:error,
             :duplicate_name
             | :duplicate_slug
             | :not_connected
             | :invalid_project
             | {:project_start_failed, term()}
             | term()}
  def add_project(attrs) when is_map(attrs) do
    case CymphonyConfig.add_project(attrs) do
      {:ok, project} -> start_added_project(project)
      {:error, _} = error -> error
    end
  end

  @doc """
  Parses API/LiveView agent-settings params (`kind`/`model`/`effort`, all
  optional but at least one required) into the settings map
  `update_agent_settings/2` accepts (`"agent"`/`"model"`/`"effort"` keys,
  whitespace trimmed — an all-whitespace value becomes `""`, which clears the
  key). Returns `:error` on an unknown kind or when no recognized key is
  present.
  """
  @spec parse_agent_settings(map()) :: {:ok, map()} | :error
  def parse_agent_settings(params) when is_map(params) do
    settings =
      %{}
      |> put_param(params, "kind", "agent")
      |> put_param(params, "model", "model")
      |> put_param(params, "effort", "effort")

    cond do
      map_size(settings) == 0 -> :error
      Map.get(settings, "agent") not in [nil | Agent.known_kinds()] -> :error
      true -> {:ok, settings}
    end
  end

  defp put_param(settings, params, from_key, to_key) do
    case Map.get(params, from_key) do
      value when is_binary(value) -> Map.put(settings, to_key, String.trim(value))
      _ -> settings
    end
  end

  @doc """
  Parses a concurrency value (integer or string) into `{:ok, pos_integer}` or
  `:error`.
  """
  @spec parse_concurrency(term()) :: {:ok, pos_integer()} | :error
  def parse_concurrency(value) when is_integer(value) and value > 0, do: {:ok, value}

  def parse_concurrency(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

  def parse_concurrency(_), do: :error

  # Runs `orch_fun.(pid)` and `persist_fun.(project_name | nil)` for every
  # orchestrator in scope. `persist_fun` receives the project name (or `nil` for
  # the legacy single orchestrator) so config writes are keyed correctly.
  # Persist errors (`{:error, reason}`) are returned; `:ok` / `{:ok, _}` succeed.
  defp apply_scope(:all, orch_fun, persist_fun) do
    case ProjectSupervisor.list_orchestrators() do
      [] ->
        maybe_call_legacy_orchestrator(orch_fun)
        persist_result(persist_fun.(nil))

      orchestrators ->
        Enum.reduce_while(orchestrators, :ok, fn {project, pid}, :ok ->
          orch_fun.(pid)

          case persist_result(persist_fun.(project)) do
            :ok -> {:cont, :ok}
            {:error, _} = error -> {:halt, error}
          end
        end)
    end
  end

  defp apply_scope({:project, name}, orch_fun, persist_fun) when is_binary(name) do
    case ProjectSupervisor.lookup(name, :orchestrator) do
      pid when is_pid(pid) ->
        orch_fun.(pid)
        persist_result(persist_fun.(name))

      _ ->
        case ProjectSupervisor.list_orchestrators() do
          [] ->
            maybe_call_legacy_orchestrator(orch_fun)
            persist_result(persist_fun.(nil))

          _ ->
            {:error, :not_found}
        end
    end
  end

  defp persist_agent_settings(project, settings) do
    case CymphonyConfig.update_agent_settings(project, settings) do
      :ok -> rewrite_after_persist(project)
      {:error, _} = error -> error
    end
  end

  defp rewrite_after_persist(nil), do: :ok

  defp rewrite_after_persist(project) when is_binary(project) do
    case ProjectSupervisor.rewrite_workflow(project) do
      {:error, :not_found} -> :ok
      other -> other
    end
  end

  defp start_added_project(project) do
    {:ok, path} = WorkflowGenerator.write_temp(project)

    # Tests may pin {name, path} so start uses a memory-tracker workflow.
    {start_name, start_path} =
      Application.get_env(:cymphony_elixir, :start_project_args, {project["name"], path})

    case ProjectSupervisor.start_project(start_name, start_path) do
      :ok -> {:ok, strip_linear_api_key(project)}
      {:error, reason} -> {:error, {:project_start_failed, reason}}
    end
  end

  defp strip_linear_api_key(project) when is_map(project) do
    project
    |> Map.delete("linear_api_key")
    |> Map.put("started", true)
  end

  defp rewrite_registered_workflows do
    Enum.each(ProjectSupervisor.list_orchestrators(), fn {name, _pid} ->
      _ = ProjectSupervisor.rewrite_workflow(name)
    end)
  end

  defp loaded_config do
    case CymphonyConfig.load() do
      {:ok, config} -> config
      _ -> nil
    end
  end

  defp source_name(:config), do: "config"
  defp source_name(:env), do: "env"
  defp source_name(_), do: nil

  defp persist_result(:ok), do: :ok
  defp persist_result({:ok, _}), do: :ok
  defp persist_result({:error, _} = error), do: error

  defp noop_persist(_project), do: :ok

  defp maybe_call_legacy_orchestrator(orch_fun) do
    case live_legacy_orchestrator() do
      nil -> :ok
      server -> orch_fun.(server)
    end
  end

  defp live_legacy_orchestrator do
    server = endpoint_orchestrator() || Orchestrator
    if orchestrator_alive?(server), do: server
  end

  # Endpoint.config/1 reads an ETS table that only exists while the Phoenix
  # endpoint is started (dashboard/API tests). Persist must still succeed
  # when no orchestrator is running.
  defp endpoint_orchestrator do
    if Process.whereis(Endpoint), do: Endpoint.config(:orchestrator)
  rescue
    ArgumentError -> nil
  end

  defp orchestrator_alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp orchestrator_alive?(name) when is_atom(name), do: is_pid(Process.whereis(name))
  defp orchestrator_alive?(_server), do: false
end
