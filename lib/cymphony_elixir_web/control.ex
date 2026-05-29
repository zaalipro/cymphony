defmodule CymphonyElixirWeb.Control do
  @moduledoc """
  Shared dispatch-control operations used by both the LiveView dashboard and the
  JSON API: pause/resume and concurrency/provider updates. Encapsulates the
  `ProjectSupervisor → Orchestrator → CymphonyConfig` orchestration so the two
  web surfaces don't each reimplement it.

  A `scope` is either `:all` (every registered project, or the single legacy
  orchestrator when none are registered) or `{:project, name}` (one named
  project, falling back to the legacy orchestrator when no per-project
  supervisors are registered).
  """

  alias CymphonyElixir.Cymphony.Config, as: CymphonyConfig
  alias CymphonyElixir.{Orchestrator, ProjectSupervisor}
  alias CymphonyElixirWeb.Endpoint

  @type scope :: :all | {:project, String.t()}

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
  defp apply_scope(:all, orch_fun, persist_fun) do
    case ProjectSupervisor.list_orchestrators() do
      [] ->
        orch_fun.(legacy_orchestrator())
        persist_fun.(nil)
        :ok

      orchestrators ->
        Enum.each(orchestrators, fn {project, pid} ->
          orch_fun.(pid)
          persist_fun.(project)
        end)

        :ok
    end
  end

  defp apply_scope({:project, name}, orch_fun, persist_fun) when is_binary(name) do
    case ProjectSupervisor.lookup(name, :orchestrator) do
      pid when is_pid(pid) ->
        orch_fun.(pid)
        persist_fun.(name)
        :ok

      _ ->
        case ProjectSupervisor.list_orchestrators() do
          [] ->
            orch_fun.(legacy_orchestrator())
            persist_fun.(nil)
            :ok

          _ ->
            {:error, :not_found}
        end
    end
  end

  defp noop_persist(_project), do: :ok

  defp legacy_orchestrator do
    Endpoint.config(:orchestrator) || Orchestrator
  end
end
