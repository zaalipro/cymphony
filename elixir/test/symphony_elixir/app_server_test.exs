defmodule SymphonyElixir.AppServerTest do
  use SymphonyElixir.TestSupport

  test "app server rejects the workspace root and paths outside workspace root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-cwd-guard-#{System.unique_integer([:positive])}"
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
               AppServer.run(workspace_root, "guard", issue)

      assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _path, _root}} =
               AppServer.run(outside_workspace, "guard", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server rejects symlink escape cwd paths under the workspace root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-symlink-cwd-guard-#{System.unique_integer([:positive])}"
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
               AppServer.run(symlink_workspace, "guard", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server runs claude -p and parses json output" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-json-output-#{System.unique_integer([:positive])}"
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
               AppServer.run(workspace, "do the thing", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server handles non-zero exit as error" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-exit-error-#{System.unique_integer([:positive])}"
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

      assert {:error, {:claude_exit, 1, _}} =
               AppServer.run(workspace, "do the thing", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server passes bare mode and permission flags" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-flags-#{System.unique_integer([:positive])}"
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
        claude_model: "claude-sonnet-4-6",
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
               AppServer.run(workspace, "do the thing", issue)

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

  test "app server resumes session with --resume flag" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-resume-#{System.unique_integer([:positive])}"
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

      {:ok, session} = AppServer.start_session(workspace)

      # First turn
      assert {:ok, %{session_id: first_session_id}} =
               AppServer.run_turn(session, "first turn", issue)

      # Second turn should resume
      session = %{session | session_id: first_session_id}

      assert {:ok, %{session_id: ^first_session_id}} =
               AppServer.run_turn(session, "second turn", issue)

      flags = File.read!(trace_file)
      assert flags =~ "--resume #{first_session_id}"
    after
      File.rm_rf(test_root)
    end
  end
end
