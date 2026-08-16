defmodule CymphonyElixirWeb.Control do
  @moduledoc """
  Shared dispatch-control operations used by both the LiveView dashboard and the
  JSON API: Linear connect, add-project, pause/resume, concurrency / provider /
  agent / queue-order / queue-pin updates, and the daemon-wide dashboard payload
  refresh interval.
  Encapsulates the `ProjectSupervisor → Orchestrator → CymphonyConfig`
  orchestration so the two web surfaces don't each reimplement it.

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

  @doc """
  Persists the daemon-wide dashboard payload refresh interval (seconds).

  Reuses `parse_concurrency/1`. Writes only `config.json`; does not fan out to
  orchestrators, rewrite `WORKFLOW.md`, or change Linear poll timing.
  """
  @spec set_dashboard_refresh_seconds(term()) :: :ok | {:error, term()}
  def set_dashboard_refresh_seconds(value) do
    case parse_concurrency(value) do
      {:ok, n} -> persist_result(CymphonyConfig.update_dashboard_refresh_seconds(n))
      :error -> {:error, :invalid_refresh_interval}
    end
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
  Replaces the waiting-list order for one project, then persists `queue_order`.

  `:all` and a missing/blank project name are `{:error, :invalid_scope}`.
  """
  @spec set_queue_order(scope(), [String.t()]) ::
          :ok | {:error, :invalid_scope | :not_found | term()}
  def set_queue_order(scope, order) when is_list(order) do
    with :ok <- require_project_scope(scope) do
      apply_scope(
        scope,
        &Orchestrator.reorder_queue(&1, order),
        &persist_queue_order(&1, order)
      )
    end
  end

  @doc """
  Pins agent/model/effort for one waiting issue, then merges `queue_pins`.

  `:all` and a missing/blank project name are `{:error, :invalid_scope}`.
  Does not kill a session.
  """
  @spec set_queue_pin(scope(), String.t(), map()) ::
          :ok | {:error, :invalid_scope | :not_found | term()}
  def set_queue_pin(scope, issue, pin) when is_binary(issue) and is_map(pin) do
    with :ok <- require_project_scope(scope) do
      apply_scope(
        scope,
        &Orchestrator.set_queue_run_spec(&1, issue, pin),
        &persist_queue_pin(&1, issue, pin)
      )
    end
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

  @doc """
  Parses a waiting-list permutation. Trims items and drops blanks. Rejects a
  non-list or any non-binary item.
  """
  @spec parse_queue_order(term()) :: {:ok, [String.t()]} | :error
  def parse_queue_order(order) when is_list(order) do
    case Enum.reduce_while(order, {:ok, []}, &collect_queue_order_item/2) do
      {:ok, collected} -> {:ok, Enum.reverse(collected)}
      :error -> :error
    end
  end

  def parse_queue_order(_order), do: :error

  @doc """
  Parses a queue-pin payload (`issue` plus optional `kind`/`agent_kind` /
  `model` / `effort`). Empty/`keep` fields are omitted. Kind must be known or
  omitted. Requires a non-blank issue and at least one pin field.
  """
  @spec parse_queue_pin(term()) :: {:ok, {String.t(), map()}} | :error
  def parse_queue_pin(params) when is_map(params) do
    issue = trimmed_param(params, "issue")

    with issue when is_binary(issue) <- issue,
         {:ok, pin} <- parse_pin_fields(params),
         true <- pin != %{} do
      {:ok, {issue, pin}}
    else
      _ -> :error
    end
  end

  def parse_queue_pin(_params), do: :error

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
        Enum.reduce_while(orchestrators, :ok, &apply_scope_to_orchestrator(&1, &2, orch_fun, persist_fun))
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

  defp apply_scope_to_orchestrator({project, pid}, :ok, orch_fun, persist_fun) do
    orch_fun.(pid)

    case persist_result(persist_fun.(project)) do
      :ok -> {:cont, :ok}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp persist_agent_settings(project, settings) do
    case CymphonyConfig.update_agent_settings(project, settings) do
      :ok -> rewrite_after_persist(project)
      {:error, _} = error -> error
    end
  end

  defp require_project_scope({:project, name}) when is_binary(name) and name != "", do: :ok
  defp require_project_scope(_scope), do: {:error, :invalid_scope}

  defp persist_queue_order(project, order) do
    CymphonyConfig.update_project_queue(project, %{"queue_order" => order})
  end

  defp persist_queue_pin(project, issue, pin) do
    CymphonyConfig.update_project_queue(project, %{
      "queue_pins" => next_queue_pins(project, issue, pin)
    })
  end

  defp next_queue_pins(project, issue, pin) do
    project
    |> loaded_queue_pins()
    |> overlay_queue_pin(issue, pin)
  end

  defp loaded_queue_pins(project) do
    case CymphonyConfig.load() do
      {:ok, config} -> queue_pins_from_config(config, project)
      _ -> %{}
    end
  end

  defp queue_pins_from_config(config, nil) do
    case CymphonyConfig.projects(config) do
      [first | _] -> as_pin_map(Map.get(first, "queue_pins"))
      _ -> as_pin_map(Map.get(config, "queue_pins"))
    end
  end

  defp queue_pins_from_config(config, name) do
    case CymphonyConfig.find_project(config, name) do
      {:ok, project} -> as_pin_map(Map.get(project, "queue_pins"))
      _ -> %{}
    end
  end

  defp as_pin_map(pins) when is_map(pins), do: pins
  defp as_pin_map(_), do: %{}

  defp overlay_queue_pin(pins, issue, pin) when is_map(pin) do
    incoming = stringify_pin_map(pin)

    if incoming == %{} do
      Map.delete(pins, issue)
    else
      current =
        case Map.get(pins, issue) do
          map when is_map(map) -> stringify_pin_map(map)
          _ -> %{}
        end

      Map.put(pins, issue, Map.merge(current, incoming))
    end
  end

  # Both call sites are already guarded by `is_map/1`, so there is no fallback
  # clause — dialyzer proves one unreachable.
  defp stringify_pin_map(pin) do
    %{}
    |> put_string_pin_field(pin, [:agent_kind, "agent_kind", :kind, "kind"], "agent_kind")
    |> put_string_pin_field(pin, [:model, "model"], "model")
    |> put_string_pin_field(pin, [:effort, "effort"], "effort")
  end

  defp put_string_pin_field(acc, pin, keys, dest) do
    case first_binary_from(pin, keys) do
      nil ->
        acc

      value ->
        case String.trim(value) do
          "" -> acc
          "keep" -> acc
          trimmed -> maybe_put_string_pin_field(acc, dest, trimmed)
        end
    end
  end

  defp maybe_put_string_pin_field(acc, "agent_kind", kind) do
    if Agent.known_kind?(kind), do: Map.put(acc, "agent_kind", kind), else: acc
  end

  defp maybe_put_string_pin_field(acc, key, value), do: Map.put(acc, key, value)

  defp first_binary_from(pin, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(pin, key) do
        value when is_binary(value) -> value
        _ -> nil
      end
    end)
  end

  defp collect_queue_order_item(item, {:ok, acc}) when is_binary(item) do
    case String.trim(item) do
      "" -> {:cont, {:ok, acc}}
      trimmed -> {:cont, {:ok, [trimmed | acc]}}
    end
  end

  defp collect_queue_order_item(_item, _acc), do: {:halt, :error}

  defp trimmed_param(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp parse_pin_fields(params) do
    with {:ok, pin} <- put_pin_field(%{}, params, ["kind", "agent_kind"], "agent_kind"),
         {:ok, pin} <- put_pin_field(pin, params, ["model"], "model") do
      put_pin_field(pin, params, ["effort"], "effort")
    end
  end

  defp put_pin_field(pin, params, from_keys, to_key) do
    case first_binary_param(params, from_keys) do
      nil ->
        {:ok, pin}

      value ->
        case String.trim(value) do
          "" -> {:ok, pin}
          "keep" -> {:ok, pin}
          trimmed -> put_trimmed_pin_field(pin, to_key, trimmed)
        end
    end
  end

  defp put_trimmed_pin_field(pin, "agent_kind", kind) do
    if Agent.known_kind?(kind), do: {:ok, Map.put(pin, "agent_kind", kind)}, else: :error
  end

  defp put_trimmed_pin_field(pin, key, value), do: {:ok, Map.put(pin, key, value)}

  defp first_binary_param(params, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(params, key) do
        value when is_binary(value) -> value
        _ -> nil
      end
    end)
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
