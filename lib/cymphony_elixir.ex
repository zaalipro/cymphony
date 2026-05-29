defmodule CymphonyElixir do
  @moduledoc """
  Entry point for the Cymphony orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    CymphonyElixir.Orchestrator.start_link(opts)
  end
end

defmodule CymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  @impl true
  def start(_type, _args) do
    :ok = CymphonyElixir.LogFile.configure()
    Supervisor.start_link(children(), strategy: :one_for_one, name: CymphonyElixir.Supervisor)
  end

  @doc false
  @spec children() :: [Supervisor.child_spec() | module() | {module(), term()}]
  def children do
    [
      {Phoenix.PubSub, name: CymphonyElixir.PubSub},
      {Registry, keys: :unique, name: CymphonyElixir.ProjectRegistry},
      CymphonyElixir.CompletionStore,
      {Task.Supervisor, name: CymphonyElixir.TaskSupervisor},
      {DynamicSupervisor, name: CymphonyElixir.ProjectDynamicSupervisor, strategy: :one_for_one},
      CymphonyElixir.HttpServer,
      CymphonyElixir.StatusDashboard
    ]
  end

  @impl true
  def stop(_state) do
    CymphonyElixir.StatusDashboard.render_offline_status()
    :ok
  end
end
