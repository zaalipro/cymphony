defmodule CymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Cymphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias CymphonyElixir.{Orchestrator, ProjectSupervisor}
  alias CymphonyElixirWeb.{Endpoint, Presenter}

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
  def pause(conn, _params) do
    apply_pause_to_all(:pause)
    conn |> put_status(202) |> json(%{paused: true})
  end

  @spec resume(Conn.t(), map()) :: Conn.t()
  def resume(conn, _params) do
    apply_pause_to_all(:resume)
    conn |> put_status(202) |> json(%{paused: false})
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
end
