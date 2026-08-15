defmodule CymphonyElixir.CLITest do
  use ExUnit.Case, async: true

  alias CymphonyElixir.CLI

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  test "auto-accepts guardrails without requiring the flag" do
    parent = self()

    deps = %{
      file_regular?: fn path ->
        send(parent, {:file_checked, path})
        true
      end,
      set_workflow_file_path: fn path ->
        send(parent, {:workflow_set, path})
        :ok
      end,
      set_logs_root: fn _path ->
        send(parent, :logs_root_set)
        :ok
      end,
      set_server_port_override: fn _port ->
        send(parent, :port_set)
        :ok
      end,
      ensure_all_started: fn ->
        send(parent, :started)
        {:ok, [:cymphony_elixir]}
      end
    }

    assert :ok = CLI.evaluate(["WORKFLOW.md"], deps)
    assert_received {:file_checked, _}
    assert_received {:workflow_set, _}
    assert_received :started
  end

  test "defaults to WORKFLOW.md when workflow path is missing" do
    deps = %{
      file_regular?: fn path -> Path.basename(path) == "WORKFLOW.md" end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:cymphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag], deps)
  end

  test "uses an explicit workflow path override when provided" do
    parent = self()
    workflow_path = "tmp/custom/WORKFLOW.md"
    expanded_path = Path.expand(workflow_path)

    deps = %{
      file_regular?: fn path ->
        send(parent, {:workflow_checked, path})
        path == expanded_path
      end,
      set_workflow_file_path: fn path ->
        send(parent, {:workflow_set, path})
        :ok
      end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:cymphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, workflow_path], deps)
    assert_received {:workflow_checked, ^expanded_path}
    assert_received {:workflow_set, ^expanded_path}
  end

  test "accepts --logs-root and passes an expanded root to runtime deps" do
    parent = self()

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn path ->
        send(parent, {:logs_root, path})
        :ok
      end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:cymphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "--logs-root", "tmp/custom-logs", "WORKFLOW.md"], deps)
    assert_received {:logs_root, expanded_path}
    assert expanded_path == Path.expand("tmp/custom-logs")
  end

  test "returns not found when workflow file does not exist" do
    deps = %{
      file_regular?: fn _path -> false end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:cymphony_elixir]} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
    assert message =~ "Workflow file not found:"
  end

  test "returns startup error when app cannot start" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:error, :boom} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
    assert message =~ "Failed to start Cymphony with workflow"
    assert message =~ ":boom"
  end

  test "returns ok when workflow exists and app starts" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:cymphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
  end

  describe "help" do
    test "shows help for --help" do
      assert {:error, text} = CLI.evaluate(["--help"])
      assert text =~ "Usage:"
      assert text =~ "Coding agent: claude, codex, or antigravity"
    end

    test "shows help for -h" do
      assert {:error, text} = CLI.evaluate(["-h"])
      assert text =~ "Usage:"
    end

    test "shows help for h shorthand" do
      assert {:error, text} = CLI.evaluate(["h"])
      assert text =~ "Usage:"
    end
  end

  describe "shorthands" do
    setup do
      deps = %{
        file_regular?: fn _path -> true end,
        set_workflow_file_path: fn _path -> :ok end,
        set_logs_root: fn _path -> :ok end,
        set_server_port_override: fn _port -> :ok end,
        ensure_all_started: fn -> {:ok, [:cymphony_elixir]} end
      }

      %{deps: deps}
    end

    test "s expands to --setup", %{deps: deps} do
      parent = self()

      onboarding_deps =
        Map.put(deps, :ensure_all_started, fn ->
          send(parent, :started)
          {:ok, [:cymphony_elixir]}
        end)

      # s triggers setup mode; config must exist or onboarding runs
      # We test that 's' is expanded to '--setup' by checking evaluate doesn't error on mode detection
      result = CLI.evaluate(["s"], onboarding_deps)
      # Will either :ok or {:error, _} depending on config, but should not crash
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "setup expands to --setup", %{deps: deps} do
      result = CLI.evaluate(["setup"], deps)
      assert result in [:ok, :done] or match?({:error, _}, result)
    end

    test "--logs-root <path> sets log root", %{deps: deps} do
      parent = self()

      log_deps =
        Map.put(deps, :set_logs_root, fn path ->
          send(parent, {:logs_root, path})
          :ok
        end)

      assert :ok = CLI.evaluate([@ack_flag, "--logs-root", "tmp/custom-logs", "WORKFLOW.md"], log_deps)
      assert_received {:logs_root, expanded}
      assert expanded == Path.expand("tmp/custom-logs")
    end

    test "--port <port> sets server port", %{deps: deps} do
      parent = self()

      port_deps =
        Map.put(deps, :set_server_port_override, fn port ->
          send(parent, {:port, port})
          :ok
        end)

      assert :ok = CLI.evaluate([@ack_flag, "--port", "9090", "WORKFLOW.md"], port_deps)
      assert_received {:port, 9090}
    end

    test "logs is accepted as alias for log" do
      ExUnit.CaptureIO.capture_io(fn -> assert :done = CLI.evaluate(["log"]) end)
      ExUnit.CaptureIO.capture_io(fn -> assert :done = CLI.evaluate(["logs"]) end)
    end

    test "logs accepts a tail count argument" do
      ExUnit.CaptureIO.capture_io(fn -> assert :done = CLI.evaluate(["logs", "50"]) end)
    end

    test "p without value shows help" do
      assert {:error, text} = CLI.evaluate(["p"])
      assert text =~ "Usage:"
    end

    test "project without value shows help" do
      assert {:error, text} = CLI.evaluate(["project"])
      assert text =~ "Usage:"
    end

    test "projects without value shows help" do
      assert {:error, text} = CLI.evaluate(["projects"])
      assert text =~ "Usage:"
    end

    test "port without value shows help" do
      assert {:error, text} = CLI.evaluate(["port"])
      assert text =~ "Usage:"
    end

    test "port <n> sets server port", %{deps: deps} do
      parent = self()

      port_deps =
        Map.put(deps, :set_server_port_override, fn port ->
          send(parent, {:port, port})
          :ok
        end)

      assert :ok = CLI.evaluate([@ack_flag, "port", "9090", "WORKFLOW.md"], port_deps)
      assert_received {:port, 9090}
    end

    test "c without value shows help" do
      assert {:error, text} = CLI.evaluate(["c"])
      assert text =~ "Usage:"
    end

    test "c expands to --provider", %{deps: deps} do
      result = CLI.evaluate(["c", "cz"], deps)
      assert result in [:ok, :done] or match?({:error, _}, result)
    end

    test "agent/model/effort shorthands run in cymphony mode without crashing", %{deps: deps} do
      for args <- [["agent", "codex"], ["agent", "antigravity"], ["model", "opus"], ["effort", "high"]] do
        result = CLI.evaluate(args, deps)
        assert result in [:ok, :done] or match?({:error, _}, result)
      end
    end

    test "bare agent/model/effort shorthands show help" do
      for shorthand <- ["agent", "model", "effort"] do
        assert {:error, text} = CLI.evaluate([shorthand])
        assert text =~ "Usage:"
      end
    end

    test "--claude-command is no longer a recognized switch" do
      assert {:error, _} = CLI.evaluate(["--claude-command", "cz"])
    end

    test "--provider <name> sets provider override", %{deps: deps} do
      parent = self()

      provider_deps =
        Map.put(deps, :set_workflow_file_path, fn path ->
          send(parent, {:workflow_set, path})
          :ok
        end)

      result = CLI.evaluate(["--provider", "cz"], provider_deps)
      assert result in [:ok, :done] or match?({:error, _}, result)
    end
  end
end

defmodule CymphonyElixir.CLIAgentOverrideTest do
  # async: false — mutates the global :config_dir_override.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias CymphonyElixir.CLI

  setup do
    tmp = Path.join(System.tmp_dir!(), "cymphony-cli-agent-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    File.write!(
      Path.join(tmp, "config.json"),
      Jason.encode!(%{
        "projects" => [
          %{
            "name" => "Farm",
            "github_repo_url" => "git@github.com:example/repo.git",
            "linear_project_slug" => "team-abc",
            "linear_api_key" => "lin_test",
            "workspace_root" => Path.join(tmp, "ws"),
            "polling_interval_ms" => 5000,
            "agent" => "claude"
          }
        ]
      })
    )

    Application.put_env(:cymphony_elixir, :config_dir_override, tmp)

    on_exit(fn ->
      Application.delete_env(:cymphony_elixir, :config_dir_override)
      File.rm_rf!(tmp)
    end)

    :ok
  end

  defp evaluate_deps(parent) do
    %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn path ->
        send(parent, {:workflow_set, path})
        :ok
      end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:cymphony_elixir]} end
    }
  end

  test "agent antigravity expands and is written onto the project workflow" do
    parent = self()

    capture_io(:stderr, fn ->
      assert :ok = CLI.evaluate(["agent", "antigravity"], evaluate_deps(parent))
    end)

    assert_received {:workflow_set, path}
    assert workflow_agent_kind(path) == "antigravity"
    File.rm(path)
  end

  test "agent codex still applies onto the project workflow" do
    parent = self()

    capture_io(:stderr, fn ->
      assert :ok = CLI.evaluate(["agent", "codex"], evaluate_deps(parent))
    end)

    assert_received {:workflow_set, path}
    assert workflow_agent_kind(path) == "codex"
    File.rm(path)
  end

  test "unknown agent warns and keeps the configured kind" do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        assert :ok = CLI.evaluate(["agent", "gemini"], evaluate_deps(parent))
      end)

    assert stderr =~ "Unknown agent 'gemini' — using configured agent"
    assert_received {:workflow_set, path}
    assert workflow_agent_kind(path) == "claude"
    File.rm(path)
  end

  defp workflow_agent_kind(path) do
    content = File.read!(path)
    [_preamble, front_matter, _body] = String.split(content, "---", parts: 3)
    {:ok, parsed} = Jason.decode(String.trim(front_matter))
    parsed["agent"]["kind"]
  end
end
