defmodule CymphonyElixir.WorkflowStoreTest do
  # async: false — starts named stores and mutates the global workflow path.
  use CymphonyElixir.TestSupport

  alias CymphonyElixir.WorkflowStore.State

  setup do
    stop_named_workflow_store()
    :ok
  end

  test "current/0 and force_reload/0 fall back to Workflow.load when the store is down" do
    stop_named_workflow_store()
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Fallback prompt")

    assert {:ok, %{prompt: "Fallback prompt"}} = WorkflowStore.current()
    assert :ok = WorkflowStore.force_reload()

    File.rm!(Workflow.workflow_file_path())
    assert {:error, {:missing_workflow_file, _, :enoent}} = WorkflowStore.force_reload()
    assert {:error, {:missing_workflow_file, _, :enoent}} = WorkflowStore.current()
  end

  test "start_link/1 with a fixed workflow_path ignores global path changes" do
    {store, path} = start_named_store!(prompt: "Pinned prompt")
    other = Path.join(Path.dirname(path), "OTHER_WORKFLOW.md")
    write_workflow_file!(other, prompt: "Global other prompt")
    Workflow.set_workflow_file_path(other)

    assert {:ok, %{prompt: "Pinned prompt"}} = WorkflowStore.current(store)
    assert :ok = WorkflowStore.force_reload(store)
    assert {:ok, %{prompt: "Pinned prompt"}} = WorkflowStore.current(store)

    write_workflow_file!(path, prompt: "Pinned updated")
    assert :ok = WorkflowStore.force_reload(store)
    assert {:ok, %{prompt: "Pinned updated"}} = WorkflowStore.current(store)
  end

  test "fixed-path store keeps the last good workflow when its file is broken or gone" do
    {store, path} = start_named_store!(prompt: "Keep me")

    File.write!(path, "---\ntracker: [\n---\nBroken\n")
    assert {:error, _} = WorkflowStore.force_reload(store)
    assert {:ok, %{prompt: "Keep me"}} = WorkflowStore.current(store)

    File.rm!(path)
    assert {:error, _} = WorkflowStore.force_reload(store)
    assert {:ok, %{prompt: "Keep me"}} = WorkflowStore.current(store)
  end

  test "current/1 and poll keep last good workflow when the file becomes a directory" do
    {store, path} = start_named_store!(prompt: "Before dir")
    state = :sys.get_state(store)

    File.rm!(path)
    File.mkdir!(path)

    assert {:ok, %{prompt: "Before dir"}} = WorkflowStore.current(store)
    assert {:noreply, polled} = WorkflowStore.handle_info(:poll, state)
    assert polled.workflow.prompt == "Before dir"
  end

  test "handle_info :poll reloads an unchanged stamp and a changed file on a fixed path" do
    {_store, path} = start_named_store!(prompt: "Original")

    {:ok, workflow} = Workflow.load(path)
    {:ok, stamp} = file_stamp(path)
    state = %State{path: path, stamp: stamp, workflow: workflow, fixed_path?: true}

    assert {:noreply, ^state} = WorkflowStore.handle_info(:poll, state)

    write_workflow_file!(path, prompt: "After poll")
    assert {:noreply, reloaded} = WorkflowStore.handle_info(:poll, state)
    assert reloaded.workflow.prompt == "After poll"
    refute reloaded.stamp == stamp
  end

  test "handle_call :current and :force_reload cover success and last-good error paths" do
    path = Path.join(Path.dirname(Workflow.workflow_file_path()), "CALL_WORKFLOW.md")
    write_workflow_file!(path, prompt: "Call original")
    {:ok, workflow} = Workflow.load(path)
    {:ok, stamp} = file_stamp(path)
    state = %State{path: path, stamp: stamp, workflow: workflow, fixed_path?: true}

    assert {:reply, {:ok, %{prompt: "Call original"}}, ^state} =
             WorkflowStore.handle_call(:current, {self(), make_ref()}, state)

    assert {:reply, :ok, ^state} = WorkflowStore.handle_call(:force_reload, {self(), make_ref()}, state)

    File.write!(path, "---\ntracker: [\n---\nBroken\n")

    assert {:reply, {:ok, %{prompt: "Call original"}}, error_state} =
             WorkflowStore.handle_call(:current, {self(), make_ref()}, state)

    assert error_state.workflow.prompt == "Call original"

    assert {:reply, {:error, _reason}, _} =
             WorkflowStore.handle_call(:force_reload, {self(), make_ref()}, state)
  end

  test "global store follows workflow_file_path changes and keeps last good on a bad new path" do
    first = Path.join(Path.dirname(Workflow.workflow_file_path()), "GLOBAL_FIRST.md")
    second = Path.join(Path.dirname(Workflow.workflow_file_path()), "GLOBAL_SECOND.md")
    missing = Path.join(Path.dirname(Workflow.workflow_file_path()), "GLOBAL_MISSING.md")

    write_workflow_file!(first, prompt: "First global")
    write_workflow_file!(second, prompt: "Second global")
    Workflow.set_workflow_file_path(first)

    {:ok, workflow} = Workflow.load(first)
    {:ok, stamp} = file_stamp(first)
    state = %State{path: first, stamp: stamp, workflow: workflow, fixed_path?: false}

    Workflow.set_workflow_file_path(second)
    assert {:noreply, moved} = WorkflowStore.handle_info(:poll, state)
    assert moved.path == second
    assert moved.workflow.prompt == "Second global"

    Workflow.set_workflow_file_path(missing)
    assert {:noreply, kept} = WorkflowStore.handle_info(:poll, moved)
    assert kept.path == missing
    assert kept.workflow.prompt == "Second global"
  end

  test "init/1 starts a poll timer on success and stops when the file is missing" do
    path = Path.join(Path.dirname(Workflow.workflow_file_path()), "INIT_WORKFLOW.md")
    write_workflow_file!(path, prompt: "Init ok")

    assert {:ok, %State{path: ^path, fixed_path?: true}} =
             WorkflowStore.init(workflow_path: path, name: :unused)

    assert_receive :poll, 1_100

    missing = Path.join(Path.dirname(path), "INIT_MISSING.md")

    assert {:stop, {:missing_workflow_file, ^missing, :enoent}} =
             WorkflowStore.init(workflow_path: missing)
  end

  test "start_link/0 uses the global workflow path" do
    stop_named_workflow_store()
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Default name")

    assert {:ok, pid} = WorkflowStore.start_link()
    assert Process.whereis(WorkflowStore) == pid
    assert {:ok, %{prompt: "Default name"}} = WorkflowStore.current()
    assert :ok = WorkflowStore.force_reload()
    GenServer.stop(pid)
  end

  defp start_named_store!(overrides) do
    path = Path.join(Path.dirname(Workflow.workflow_file_path()), "FIXED_#{System.unique_integer([:positive])}.md")
    write_workflow_file!(path, overrides)
    name = :"workflow_store_#{System.unique_integer([:positive])}"
    {:ok, pid} = start_supervised({WorkflowStore, [name: name, workflow_path: path]})
    {pid, path}
  end

  defp stop_named_workflow_store do
    case Process.whereis(WorkflowStore) do
      pid when is_pid(pid) ->
        GenServer.stop(pid)

      _ ->
        :ok
    end
  catch
    :exit, _ -> :ok
  end

  defp file_stamp(path) do
    with {:ok, stat} <- File.stat(path, time: :posix),
         {:ok, content} <- File.read(path) do
      {:ok, {stat.mtime, stat.size, :erlang.phash2(content)}}
    end
  end
end
