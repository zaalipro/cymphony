defmodule CymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Cymphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias CymphonyElixir.Cymphony.Config, as: CymphonyConfig
  alias CymphonyElixir.{Orchestrator, ProjectSupervisor}
  alias CymphonyElixirWeb.{Endpoint, Presenter}
  alias Plug.Conn

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec projects(Conn.t(), map()) :: Conn.t()
  def projects(conn, _params) do
    json(conn, %{projects: Presenter.projects_payload()})
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    project = conn.query_params["project"]

    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms(), project) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec completed(Conn.t(), map()) :: Conn.t()
  def completed(conn, params) do
    payload = Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
    entries = Map.get(payload, :recent_completed, [])

    entries =
      case params["project"] do
        nil -> entries
        "" -> entries
        project -> Enum.filter(entries, &(&1.project_name == project))
      end

    entries =
      case params["limit"] do
        nil ->
          entries

        value ->
          case Integer.parse(value) do
            {n, ""} when n > 0 -> Enum.take(entries, n)
            _ -> entries
          end
      end

    json(conn, %{recent_completed: entries})
  end

  @spec pause(Conn.t(), map()) :: Conn.t()
  def pause(conn, params) do
    apply_pause(:pause, params["project"])
    conn |> put_status(202) |> json(%{paused: true, project: params["project"]})
  end

  @spec resume(Conn.t(), map()) :: Conn.t()
  def resume(conn, params) do
    apply_pause(:resume, params["project"])
    conn |> put_status(202) |> json(%{paused: false, project: params["project"]})
  end

  @spec concurrency(Conn.t(), map()) :: Conn.t()
  def concurrency(conn, params) do
    project = params["project"]

    case parse_concurrency(params["value"]) do
      {:ok, n} ->
        apply_concurrency(n, project)

        conn
        |> put_status(202)
        |> json(%{max_concurrent_agents: n, project: project})

      :error ->
        error_response(
          conn,
          422,
          "invalid_concurrency",
          "concurrency 'value' must be a positive integer"
        )
    end
  end

  @spec providers(Conn.t(), map()) :: Conn.t()
  def providers(conn, params) do
    project = params["project"]

    case parse_providers(params["value"]) do
      {:ok, list} ->
        apply_providers(list, project)

        conn
        |> put_status(202)
        |> json(%{providers: list, project: project})

      :error ->
        error_response(
          conn,
          422,
          "invalid_providers",
          "providers 'value' must be a non-empty comma-separated list"
        )
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || CymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp apply_pause(action, nil), do: apply_pause_to_all(action)
  defp apply_pause(action, ""), do: apply_pause_to_all(action)

  defp apply_pause(action, project_name) when is_binary(project_name) do
    case ProjectSupervisor.lookup(project_name, :orchestrator) do
      pid when is_pid(pid) ->
        case action do
          :pause -> Orchestrator.pause(pid)
          :resume -> Orchestrator.resume(pid)
        end

      _ ->
        :unavailable
    end
  end

  defp apply_pause_to_all(action) do
    case ProjectSupervisor.list_orchestrators() do
      [] ->
        # Legacy single-orchestrator mode.
        case action do
          :pause -> Orchestrator.pause(orchestrator())
          :resume -> Orchestrator.resume(orchestrator())
        end

      orchestrators ->
        Enum.each(orchestrators, fn {_project, pid} ->
          case action do
            :pause -> Orchestrator.pause(pid)
            :resume -> Orchestrator.resume(pid)
          end
        end)
    end
  end

  defp apply_concurrency(n, nil), do: apply_concurrency_to_all(n)
  defp apply_concurrency(n, ""), do: apply_concurrency_to_all(n)

  defp apply_concurrency(n, project_name) when is_binary(project_name) do
    case ProjectSupervisor.lookup(project_name, :orchestrator) do
      pid when is_pid(pid) ->
        Orchestrator.set_concurrency(pid, n)
        _ = CymphonyConfig.update_concurrency(project_name, n)
        :ok

      _ ->
        :unavailable
    end
  end

  defp apply_concurrency_to_all(n) do
    case ProjectSupervisor.list_orchestrators() do
      [] ->
        Orchestrator.set_concurrency(orchestrator(), n)
        _ = CymphonyConfig.update_concurrency(nil, n)
        :ok

      orchestrators ->
        Enum.each(orchestrators, fn {project, pid} ->
          Orchestrator.set_concurrency(pid, n)
          _ = CymphonyConfig.update_concurrency(project, n)
        end)
    end
  end

  defp parse_concurrency(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_concurrency(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_concurrency(_), do: :error

  defp apply_providers(providers, nil), do: apply_providers_to_all(providers)
  defp apply_providers(providers, ""), do: apply_providers_to_all(providers)

  defp apply_providers(providers, project_name) when is_binary(project_name) do
    case ProjectSupervisor.lookup(project_name, :orchestrator) do
      pid when is_pid(pid) ->
        Orchestrator.set_providers(pid, providers)
        _ = CymphonyConfig.update_providers(project_name, providers)
        :ok

      _ ->
        :unavailable
    end
  end

  defp apply_providers_to_all(providers) do
    case ProjectSupervisor.list_orchestrators() do
      [] ->
        Orchestrator.set_providers(orchestrator(), providers)
        _ = CymphonyConfig.update_providers(nil, providers)
        :ok

      orchestrators ->
        Enum.each(orchestrators, fn {project, pid} ->
          Orchestrator.set_providers(pid, providers)
          _ = CymphonyConfig.update_providers(project, providers)
        end)
    end
  end

  defp parse_providers(value) when is_binary(value) do
    case CymphonyConfig.parse_providers_csv(value) do
      {:ok, list} -> {:ok, list}
      {:error, :empty} -> :error
    end
  end

  defp parse_providers(value) when is_list(value) do
    list = value |> Enum.map(&to_string/1) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    if list == [], do: :error, else: {:ok, list}
  end

  defp parse_providers(_), do: :error
end
