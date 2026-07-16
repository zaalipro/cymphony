defmodule CymphonyElixir.Agent.CodexAdapterTest do
  use ExUnit.Case, async: true

  alias CymphonyElixir.Agent.Codex

  defp spec(overrides \\ %{}) do
    Map.merge(
      %{
        kind: "codex",
        command: nil,
        model: nil,
        effort: nil,
        provider: nil,
        session_id: nil,
        prompt: "do the thing",
        workspace: "/tmp/ws",
        mcp_descriptor: nil,
        settings: %{
          command: "codex",
          sandbox: "workspace-write",
          network_access: true,
          provider: nil,
          providers: []
        }
      },
      overrides
    )
  end

  describe "build_command/1" do
    test "first turn uses exec --json with sandbox_mode and network access" do
      assert {:ok, cmd} = Codex.build_command(spec())
      assert cmd =~ "codex exec --json --skip-git-repo-check"
      assert cmd =~ ~s(sandbox_mode="workspace-write")
      assert cmd =~ "sandbox_workspace_write.network_access=true"
      assert String.ends_with?(cmd, "'do the thing'")
      refute cmd =~ " resume "
    end

    test "model and effort map to -m and -c model_reasoning_effort" do
      assert {:ok, cmd} = Codex.build_command(spec(%{model: "gpt-5.2-codex", effort: "high"}))
      assert cmd =~ "-m 'gpt-5.2-codex'"
      assert cmd =~ ~s(model_reasoning_effort="high")
    end

    test "resume inserts the subcommand with session id before flags" do
      assert {:ok, cmd} = Codex.build_command(spec(%{session_id: "0199-abc"}))
      assert cmd =~ "codex exec resume '0199-abc' --json --skip-git-repo-check"
    end

    test "read-only sandbox omits network access override" do
      settings = %{spec().settings | sandbox: "read-only"}
      assert {:ok, cmd} = Codex.build_command(spec(%{settings: settings}))
      assert cmd =~ ~s(sandbox_mode="read-only")
      refute cmd =~ "network_access"
    end

    test "mcp descriptor renders -c overrides with env_vars whitelist, never the key itself" do
      descriptor = %{api_key: "lin_api_SECRET", endpoint: "https://api.linear.app/graphql"}
      assert {:ok, cmd} = Codex.build_command(spec(%{mcp_descriptor: descriptor}))
      assert cmd =~ "mcp_servers.cymphony-linear.command"
      assert cmd =~ ~s(env_vars=["LINEAR_API_KEY"])
      assert cmd =~ "LINEAR_ENDPOINT"
      refute cmd =~ "lin_api_SECRET"
    end

    test "prompt is shell-escaped so metacharacters stay inside one argument" do
      assert {:ok, cmd} = Codex.build_command(spec(%{prompt: "it's; rm -rf /"}))
      assert cmd =~ ~s('it'"'"'s; rm -rf /')
    end
  end

  describe "parse_output/3" do
    test "collects thread id, last agent message, and turn.completed usage" do
      me = self()

      lines = [
        ~s({"type":"thread.started","thread_id":"t-1"}),
        ~s({"type":"turn.started"}),
        ~s({"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"pong"}}),
        ~s({"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":4,"output_tokens":5,"reasoning_output_tokens":0}})
      ]

      assert {:ok, result} = Codex.parse_output(lines, spec(), fn msg -> send(me, {:msg, msg}) end)
      assert result.session_id == "t-1"
      assert result.result == "pong"
      assert result.usage == %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15}

      assert_received {:msg, %{event: :stream_event, payload: %{"type" => "thread.started"}}}
    end

    test "turn.failed is an error carrying the failure payload" do
      lines = [
        ~s({"type":"thread.started","thread_id":"t-2"}),
        ~s({"type":"turn.failed","error":{"message":"boom"}})
      ]

      assert {:error, {:turn_failed, %{"message" => "boom"}}} =
               Codex.parse_output(lines, spec(), fn _ -> :ok end)
    end

    test "missing turn.completed is an error" do
      lines = [~s({"type":"thread.started","thread_id":"t-3"})]
      assert {:error, {:no_result_in_stream, _}} = Codex.parse_output(lines, spec(), fn _ -> :ok end)
    end
  end

  test "auth env callbacks" do
    assert Codex.default_command() == "codex"
    assert Codex.auth_env_prefixes() == ["OPENAI_", "CODEX_", "API_TIMEOUT"]
    assert Codex.auth_env_fallback() == ["OPENAI_API_KEY"]
  end
end
