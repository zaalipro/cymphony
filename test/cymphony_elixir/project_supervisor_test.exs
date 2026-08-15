defmodule CymphonyElixir.ProjectSupervisorTest do
  # async: false — registers keys on the global ProjectRegistry.
  use CymphonyElixir.TestSupport

  alias CymphonyElixir.ProjectSupervisor

  test "via_tuple/2 builds a ProjectRegistry via tuple" do
    assert ProjectSupervisor.via_tuple("Farm", :orchestrator) ==
             {:via, Registry, {CymphonyElixir.ProjectRegistry, {"Farm", :orchestrator}}}
  end

  test "lookup/2 returns the registered pid or nil" do
    name = "lookup-#{System.unique_integer([:positive])}"
    assert ProjectSupervisor.lookup(name, :orchestrator) == nil

    {:ok, _} = Registry.register(CymphonyElixir.ProjectRegistry, {name, :orchestrator}, :meta)
    assert ProjectSupervisor.lookup(name, :orchestrator) == self()
  end

  test "list_project_names/0 and list_orchestrators/0 filter registry entries" do
    name = "listed-#{System.unique_integer([:positive])}"

    {:ok, _} = Registry.register(CymphonyElixir.ProjectRegistry, {name, :supervisor}, nil)
    {:ok, _} = Registry.register(CymphonyElixir.ProjectRegistry, {name, :workflow_store}, nil)
    {:ok, _} = Registry.register(CymphonyElixir.ProjectRegistry, {name, :orchestrator}, nil)
    {:ok, _} = Registry.register(CymphonyElixir.ProjectRegistry, {:not_binary, :orchestrator}, nil)

    assert name in ProjectSupervisor.list_project_names()
    assert {name, self()} in ProjectSupervisor.list_orchestrators()
    refute Enum.any?(ProjectSupervisor.list_orchestrators(), fn {project, _} -> project == :not_binary end)
  end

  test "list_project_names/0 rescues when a registry key is not a {name, role} tuple" do
    {:ok, _} = Registry.register(CymphonyElixir.ProjectRegistry, :not_a_tuple, nil)
    assert ProjectSupervisor.list_project_names() == []
  end

  test "list_project_names/1 and list_orchestrators/1 return [] when the registry is missing" do
    missing = :"missing_registry_#{System.unique_integer([:positive])}"
    assert ProjectSupervisor.list_project_names(missing) == []
    assert ProjectSupervisor.list_orchestrators(missing) == []
  end

  test "init/1 builds a one_for_one supervisor with store and orchestrator children" do
    assert {:ok, {flags, children}} =
             ProjectSupervisor.init(project_name: "Farm", workflow_path: "/tmp/WORKFLOW.md")

    assert flags.strategy == :one_for_one
    assert length(children) == 2
  end

  test "start_link/1 fails when the workflow file is missing" do
    name = "missing-wf-#{System.unique_integer([:positive])}"
    missing = Path.join(System.tmp_dir!(), "cymphony-ps-missing-#{System.unique_integer([:positive])}.md")

    assert {:error, reason} =
             start_supervised({ProjectSupervisor, [project_name: name, workflow_path: missing]})

    assert inspect(reason) =~ "missing_workflow_file"
    assert inspect(reason) =~ missing
    assert ProjectSupervisor.lookup(name, :supervisor) == nil
  end

  test "start_link/1 starts the workflow store and orchestrator under the registry" do
    name = "started-#{System.unique_integer([:positive])}"
    path = Workflow.workflow_file_path()
    write_workflow_file!(path, tracker_kind: "memory", poll_interval_ms: 60_000)

    pid = start_supervised!({ProjectSupervisor, [project_name: name, workflow_path: path]})
    assert Process.alive?(pid)

    store = ProjectSupervisor.lookup(name, :workflow_store)
    orch = ProjectSupervisor.lookup(name, :orchestrator)

    assert is_pid(store)
    assert is_pid(orch)
    assert name in ProjectSupervisor.list_project_names()
    assert {name, orch} in ProjectSupervisor.list_orchestrators()
    assert {:ok, %{prompt: _}} = CymphonyElixir.WorkflowStore.current(store)
  end
end
