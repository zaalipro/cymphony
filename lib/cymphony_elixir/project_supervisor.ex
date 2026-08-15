defmodule CymphonyElixir.ProjectSupervisor do
  @moduledoc """
  Supervisor for a single project's WorkflowStore and Orchestrator.

  Each project gets its own `ProjectSupervisor` under the
  `ProjectDynamicSupervisor`, with children registered via
  `ProjectRegistry` for lookup by project name.
  """

  use Supervisor

  alias CymphonyElixir.{Orchestrator, WorkflowStore}

  @type project_spec :: [
          {:name, String.t()}
          | {:workflow_path, String.t()}
          | {:project_name, String.t()}
        ]

  @spec start_link(project_spec()) :: Supervisor.on_start()
  def start_link(opts) do
    project_name = Keyword.fetch!(opts, :project_name)
    Supervisor.start_link(__MODULE__, opts, name: via_tuple(project_name, :supervisor))
  end

  @impl true
  def init(opts) do
    project_name = Keyword.fetch!(opts, :project_name)
    workflow_path = Keyword.fetch!(opts, :workflow_path)

    children = [
      {WorkflowStore, name: via_tuple(project_name, :workflow_store), workflow_path: workflow_path},
      {Orchestrator, name: via_tuple(project_name, :orchestrator), project_name: project_name}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Builds a via tuple for registry lookup.
  """
  @spec via_tuple(String.t(), atom()) ::
          {:via, Registry, {CymphonyElixir.ProjectRegistry, {String.t(), atom()}}}
  def via_tuple(project_name, role) do
    {:via, Registry, {CymphonyElixir.ProjectRegistry, {project_name, role}}}
  end

  @doc """
  Looks up a project process by name and role.
  Returns the pid or nil.
  """
  @spec lookup(String.t(), atom()) :: pid() | nil
  def lookup(project_name, role) do
    case Registry.lookup(CymphonyElixir.ProjectRegistry, {project_name, role}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Lists all registered project names.
  """
  @spec list_project_names() :: [String.t()]
  @spec list_project_names(atom()) :: [String.t()]
  def list_project_names(registry \\ CymphonyElixir.ProjectRegistry) do
    Registry.select(registry, [{{:"$1", :"$2", :_}, [], [:"$1"]}])
    |> Enum.map(fn {project_name, _role} -> project_name end)
    |> Enum.uniq()
  rescue
    _ -> []
  end

  @doc """
  Lists all registered orchestrator pids with their project names.
  Returns a list of `{project_name, pid}` tuples.
  """
  @spec list_orchestrators() :: [{String.t(), pid()}]
  @spec list_orchestrators(atom()) :: [{String.t(), pid()}]
  def list_orchestrators(registry \\ CymphonyElixir.ProjectRegistry) do
    Registry.select(registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.flat_map(fn
      {{project_name, :orchestrator}, pid} when is_binary(project_name) and is_pid(pid) ->
        [{project_name, pid}]

      _ ->
        []
    end)
  rescue
    _ -> []
  end
end
