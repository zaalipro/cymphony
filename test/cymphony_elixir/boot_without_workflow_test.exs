defmodule CymphonyElixir.BootWithoutWorkflowTest do
  @moduledoc """
  Regression coverage for the release boot crash: the Burrito binary starts
  the full supervision tree BEFORE CLI.main parses args, so every child that
  runs at boot must tolerate a missing/unset WORKFLOW.md (the config only
  becomes available after the CLI generates it from ~/.cymphony/config.json).
  """

  # async: false — points the global workflow path at a nonexistent file.
  use ExUnit.Case, async: false

  alias CymphonyElixir.{Config, HttpServer, StatusDashboard, Workflow}

  setup do
    previous = Application.get_env(:cymphony_elixir, :workflow_file_path)
    missing = Path.join(System.tmp_dir!(), "cymphony-boot-missing-#{System.unique_integer([:positive])}/WORKFLOW.md")
    Application.put_env(:cymphony_elixir, :workflow_file_path, missing)

    on_exit(fn ->
      if previous do
        Application.put_env(:cymphony_elixir, :workflow_file_path, previous)
      else
        Application.delete_env(:cymphony_elixir, :workflow_file_path)
      end
    end)

    :ok
  end

  test "Config.server_port/0 returns nil instead of raising when workflow config is unavailable" do
    Application.delete_env(:cymphony_elixir, :server_port_override)
    assert Config.server_port() == nil
  end

  test "HttpServer.start_link/1 ignores (does not crash) when no port is configured" do
    Application.delete_env(:cymphony_elixir, :server_port_override)
    assert HttpServer.start_link([]) == :ignore
  end

  test "HttpServer.start_link/1 with an explicit port boots without workflow config" do
    assert {:ok, pid} = HttpServer.start_link(port: 0)
    Supervisor.stop(pid)
  end

  test "StatusDashboard.init/1 falls back to defaults when workflow config is unavailable" do
    assert {:ok, state} = StatusDashboard.init(enabled: false)
    assert state.refresh_ms == 1_000
    assert state.render_interval_ms == 16

    assert Workflow.current() |> elem(0) == :error
  end

  test "HttpServer.ensure_started/0 starts the ignored boot child once a port override exists" do
    # Simulate the Burrito sequence: tree boots with no port (HttpServer
    # :ignore), then the CLI sets the override and calls ensure_started.
    Application.delete_env(:cymphony_elixir, :server_port_override)

    {:ok, sup} =
      Supervisor.start_link([CymphonyElixir.HttpServer], strategy: :one_for_one, name: :boot_test_sup)

    assert [{HttpServer, :undefined, _, _}] = Supervisor.which_children(:boot_test_sup)

    Application.put_env(:cymphony_elixir, :server_port_override, 0)
    on_exit(fn -> Application.delete_env(:cymphony_elixir, :server_port_override) end)

    assert {:ok, _child} = Supervisor.restart_child(:boot_test_sup, HttpServer)
    assert is_integer(HttpServer.bound_port())

    Supervisor.stop(sup)
  end

  test "StatusDashboard.suspend/resume gates terminal rendering (interactive prompts own the tty)" do
    parent = self()
    name = Module.concat(__MODULE__, :SuspendDashboard)

    {:ok, pid} =
      StatusDashboard.start_link(
        name: name,
        enabled: true,
        refresh_ms: 60_000,
        render_interval_ms: 0,
        render_fun: fn _content -> send(parent, :rendered) end
      )

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    StatusDashboard.notify_update(name)
    assert_receive :rendered, 500

    :ok = StatusDashboard.suspend(name)
    StatusDashboard.notify_update(name)
    send(pid, :tick)
    refute_receive :rendered, 200

    :ok = StatusDashboard.resume(name)
    StatusDashboard.notify_update(name)
    assert_receive :rendered, 500
  end
end
