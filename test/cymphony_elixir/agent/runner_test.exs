defmodule CymphonyElixir.Agent.RunnerTest do
  use CymphonyElixir.TestSupport

  test "app server rejects the workspace root and paths outside workspace root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-app-server-cwd-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-workspace-guard",
        identifier: "MT-999",
        title: "Validate workspace guard",
        description: "Ensure app-server refuses invalid cwd targets",
        state: "In Progress",
        url: "https://example.org/issues/MT-999",
        labels: ["backend"]
      }

      assert {:error, {:invalid_workspace_cwd, :workspace_root, _path}} =
               Runner.run(workspace_root, "guard", issue)

      assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _path, _root}} =
               Runner.run(outside_workspace, "guard", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server rejects symlink escape cwd paths under the workspace root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-app-server-symlink-cwd-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")
      symlink_workspace = Path.join(workspace_root, "MT-1000")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)
      File.ln_s!(outside_workspace, symlink_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-workspace-symlink-guard",
        identifier: "MT-1000",
        title: "Validate symlink workspace guard",
        description: "Ensure app-server refuses symlink escape cwd targets",
        state: "In Progress",
        url: "https://example.org/issues/MT-1000",
        labels: ["backend"]
      }

      assert {:error, {:invalid_workspace_cwd, :symlink_escape, ^symlink_workspace, _root}} =
               Runner.run(symlink_workspace, "guard", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server runs claude -p and parses json output" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-app-server-json-output-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-2000")
      claude_binary = Path.join(test_root, "fake-claude")
      trace_file = Path.join(test_root, "claude-output.trace")

      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      echo '{"result":"done","session_id":"sess-abc123","usage":{"input_tokens":100,"output_tokens":50}}' >> "#{trace_file}"
      echo '{"result":"done","session_id":"sess-abc123","usage":{"input_tokens":100,"output_tokens":50}}'
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary
      )

      issue = %Issue{
        id: "issue-json-output",
        identifier: "MT-2000",
        title: "JSON output parsing",
        description: "Ensure app server parses claude json output",
        state: "In Progress",
        url: "https://example.org/issues/MT-2000",
        labels: ["backend"]
      }

      assert {:ok, %{session_id: "sess-abc123", result: %{result: "done"}}} =
               Runner.run(workspace, "do the thing", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server handles non-zero exit as error" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-app-server-exit-error-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-2001")
      claude_binary = Path.join(test_root, "fake-claude")

      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      echo '{"result":null}'
      exit 1
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary
      )

      issue = %Issue{
        id: "issue-exit-error",
        identifier: "MT-2001",
        title: "Exit error handling",
        description: "Ensure app server handles claude exit errors",
        state: "In Progress",
        url: "https://example.org/issues/MT-2001",
        labels: ["backend"]
      }

      assert {:error, {:agent_exit, 1, _}} =
               Runner.run(workspace, "do the thing", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server passes bare mode and permission flags" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-app-server-flags-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-2002")
      claude_binary = Path.join(test_root, "fake-claude")
      trace_file = Path.join(test_root, "claude-flags.trace")

      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      echo "$@" >> "#{trace_file}"
      echo '{"result":"done","session_id":"sess-flags"}'
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary,
        claude_permission_mode: "plan",
        claude_allowed_tools: "Bash,Read",
        agent_model: "claude-sonnet-4-6",
        claude_bare_mode: true,
        claude_output_format: "json"
      )

      issue = %Issue{
        id: "issue-flags",
        identifier: "MT-2002",
        title: "Flag passing",
        description: "Ensure app server passes claude flags correctly",
        state: "In Progress",
        url: "https://example.org/issues/MT-2002",
        labels: ["backend"]
      }

      assert {:ok, %{session_id: "sess-flags"}} =
               Runner.run(workspace, "do the thing", issue)

      flags = File.read!(trace_file)
      assert flags =~ "--bare"
      assert flags =~ "--output-format"
      assert flags =~ "--permission-mode"
      assert flags =~ "plan"
      assert flags =~ "--allowedTools"
      assert flags =~ "Bash,Read"
      assert flags =~ "--model"
      assert flags =~ "claude-sonnet-4-6"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server exposes Linear and GitHub auth env to local Claude process" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-app-server-local-env-#{System.unique_integer([:positive])}"
      )

    previous_gh_token = System.get_env("GH_TOKEN")
    previous_github_token = System.get_env("GITHUB_TOKEN")

    on_exit(fn ->
      restore_env("GH_TOKEN", previous_gh_token)
      restore_env("GITHUB_TOKEN", previous_github_token)
    end)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-2004")
      claude_binary = Path.join(test_root, "fake-claude")
      trace_file = Path.join(test_root, "claude-env.trace")

      File.mkdir_p!(workspace)
      System.put_env("GH_TOKEN", "gh-test-token")
      System.put_env("GITHUB_TOKEN", "github-test-token")

      File.write!(claude_binary, """
      #!/bin/sh
      {
        printf 'LINEAR_API_KEY=%s\\n' "$LINEAR_API_KEY"
        printf 'GH_TOKEN=%s\\n' "$GH_TOKEN"
        printf 'GITHUB_TOKEN=%s\\n' "$GITHUB_TOKEN"
      } > "#{trace_file}"
      echo '{"result":"done","session_id":"sess-env"}'
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        tracker_api_token: "linear-config-token",
        claude_command: claude_binary
      )

      issue = %Issue{
        id: "issue-env",
        identifier: "MT-2004",
        title: "Environment passing",
        description: "Ensure app server passes auth env",
        state: "In Progress",
        url: "https://example.org/issues/MT-2004",
        labels: ["backend"]
      }

      assert {:ok, %{session_id: "sess-env"}} =
               Runner.run(workspace, "do the thing", issue)

      trace = File.read!(trace_file)
      assert trace =~ "LINEAR_API_KEY=linear-config-token"
      assert trace =~ "GH_TOKEN=gh-test-token"
      assert trace =~ "GITHUB_TOKEN=github-test-token"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server exports Linear and GitHub auth env to ssh Claude process" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-app-server-remote-env-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_anthropic_api_key = System.get_env("ANTHROPIC_API_KEY")
    previous_gh_token = System.get_env("GH_TOKEN")
    previous_github_token = System.get_env("GITHUB_TOKEN")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("ANTHROPIC_API_KEY", previous_anthropic_api_key)
      restore_env("GH_TOKEN", previous_gh_token)
      restore_env("GITHUB_TOKEN", previous_github_token)
    end)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = "/remote/workspaces/MT-2005"
      fake_ssh = Path.join(test_root, "ssh")
      claude_binary = Path.join(test_root, "fake-claude")
      trace_file = Path.join(test_root, "ssh-env.trace")

      File.mkdir_p!(test_root)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))
      System.delete_env("ANTHROPIC_API_KEY")
      System.put_env("GH_TOKEN", "gh-test-token")
      System.put_env("GITHUB_TOKEN", "github-test-token")

      File.write!(fake_ssh, """
      #!/bin/sh
      printf '%s\\n' "$@" > "#{trace_file}"
      echo '{"result":"done","session_id":"sess-remote-env"}'
      """)

      File.write!(claude_binary, """
      #!/bin/sh
      echo '{"result":"done","session_id":"unused"}'
      """)

      File.chmod!(fake_ssh, 0o755)
      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        tracker_api_token: "linear-config-token",
        claude_command: claude_binary
      )

      issue = %Issue{
        id: "issue-remote-env",
        identifier: "MT-2005",
        title: "Remote environment passing",
        description: "Ensure app server exports auth env for SSH workers",
        state: "In Progress",
        url: "https://example.org/issues/MT-2005",
        labels: ["backend"]
      }

      assert {:ok, %{session_id: "sess-remote-env"}} =
               Runner.run(workspace, "do the thing", issue, worker_host: "worker.example")

      trace = File.read!(trace_file)
      assert trace =~ "export LINEAR_API_KEY="
      assert trace =~ "linear-config-token"
      assert trace =~ "export GH_TOKEN="
      assert trace =~ "gh-test-token"
      assert trace =~ "export GITHUB_TOKEN="
      assert trace =~ "github-test-token"
      refute trace =~ "export PATH="
      refute trace =~ "export HOME="
    after
      File.rm_rf(test_root)
    end
  end

  test "app server resumes session with --resume flag" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-app-server-resume-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-2003")
      claude_binary = Path.join(test_root, "fake-claude")
      trace_file = Path.join(test_root, "claude-resume.trace")

      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      echo "$@" >> "#{trace_file}"
      echo '{"result":"done","session_id":"sess-resume-123"}'
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary
      )

      issue = %Issue{
        id: "issue-resume",
        identifier: "MT-2003",
        title: "Session resume",
        description: "Ensure app server passes --resume for continuation",
        state: "In Progress",
        url: "https://example.org/issues/MT-2003",
        labels: ["backend"]
      }

      {:ok, session} = Runner.start_session(workspace)

      # First turn
      assert {:ok, %{session_id: first_session_id}} =
               Runner.run_turn(session, "first turn", issue)

      # Second turn should resume
      session = %{session | session_id: first_session_id}

      assert {:ok, %{session_id: ^first_session_id}} =
               Runner.run_turn(session, "second turn", issue)

      flags = File.read!(trace_file)
      assert flags =~ "--resume #{first_session_id}"
    after
      File.rm_rf(test_root)
    end
  end

  test "runner drives a codex-kind session through the codex adapter" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-runner-codex-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-3001")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-args.trace")

      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      echo "$@" > "#{trace_file}"
      echo '{"type":"thread.started","thread_id":"t-e2e"}'
      echo '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"done"}}'
      echo '{"type":"turn.completed","usage":{"input_tokens":8,"output_tokens":2}}'
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_kind: "codex",
        agent_model: "gpt-5.2-codex",
        agent_effort: "high",
        codex_command: codex_binary
      )

      issue = %Issue{
        id: "issue-codex-e2e",
        identifier: "MT-3001",
        title: "Codex path",
        description: "drive codex adapter",
        state: "In Progress",
        url: "https://example.org/issues/MT-3001"
      }

      assert {:ok, %{session_id: "t-e2e", result: %{result: "done", usage: usage}}} =
               Runner.run(workspace, "do it", issue)

      assert usage["total_tokens"] == 10

      args = File.read!(trace_file)
      assert args =~ "exec"
      assert args =~ "--json"
      assert args =~ "-m gpt-5.2-codex"
      assert args =~ "model_reasoning_effort"
    after
      File.rm_rf(test_root)
    end
  end
end
