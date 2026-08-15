defmodule CymphonyElixir.Agent.AntigravityAdapterTest do
  use ExUnit.Case, async: true

  alias CymphonyElixir.Agent.Antigravity

  defp spec(overrides \\ %{}) do
    {settings_overrides, run_overrides} =
      case Map.pop(overrides, :settings) do
        {nil, rest} -> {%{}, rest}
        {settings, rest} -> {settings, rest}
      end

    Map.merge(
      %{
        kind: "antigravity",
        command: nil,
        model: nil,
        effort: nil,
        provider: nil,
        session_id: nil,
        prompt: "do the thing",
        workspace: "/tmp/ws",
        mcp_descriptor: nil,
        settings:
          Map.merge(
            %{
              command: "agy",
              output_format: "stream-json",
              extra_args: nil,
              skip_permissions: true,
              sandbox: false,
              print_timeout: nil,
              provider: nil,
              providers: []
            },
            settings_overrides
          )
      },
      run_overrides
    )
  end

  defp collect_messages(fun) do
    me = self()
    result = fun.(fn msg -> send(me, {:msg, msg}) end)
    messages = collect_inbox([])
    {result, messages}
  end

  defp collect_inbox(acc) do
    receive do
      {:msg, msg} -> collect_inbox(acc ++ [msg])
    after
      0 -> acc
    end
  end

  describe "build_command/1" do
    test "default is agy -p --output-format stream-json with skip-permissions" do
      assert {:ok, cmd} = Antigravity.build_command(spec())
      assert cmd == "agy -p 'do the thing' --output-format 'stream-json' --dangerously-skip-permissions"
      refute cmd =~ "--resume"
      refute cmd =~ "--continue"
      refute cmd =~ ~r/(^|\s)-c(\s|$)/
      refute cmd =~ "--sandbox"
      refute cmd =~ "--model"
      refute cmd =~ "--effort"
      refute cmd =~ "--conversation"
      refute cmd =~ "--print-timeout"
      refute cmd =~ "--mcp"
    end

    test "model and effort flags are escaped and appended" do
      assert {:ok, cmd} = Antigravity.build_command(spec(%{model: "gemini-3.5-flash-medium", effort: "high"}))
      assert cmd =~ "--model 'gemini-3.5-flash-medium'"
      assert cmd =~ "--effort 'high'"
    end

    test "session_id becomes --conversation and never --resume or -c" do
      assert {:ok, cmd} = Antigravity.build_command(spec(%{session_id: "conv-99"}))
      assert cmd =~ "--conversation 'conv-99'"
      refute cmd =~ "--resume"
      refute cmd =~ "--continue"
      refute cmd =~ ~r/(^|\s)-c(\s|$)/
    end

    test "empty session_id and empty model/effort add no flags" do
      assert {:ok, cmd} = Antigravity.build_command(spec(%{session_id: "", model: "", effort: ""}))
      refute cmd =~ "--conversation"
      refute cmd =~ "--model"
      refute cmd =~ "--effort"
    end

    test "skip_permissions false omits the flag; sandbox true adds --sandbox" do
      assert {:ok, cmd} = Antigravity.build_command(spec(%{settings: %{skip_permissions: false, sandbox: true}}))
      refute cmd =~ "--dangerously-skip-permissions"
      assert cmd =~ "--sandbox"
    end

    test "print_timeout is added only when it is a non-empty binary" do
      assert {:ok, cmd} = Antigravity.build_command(spec(%{settings: %{print_timeout: "30s"}}))
      assert cmd =~ "--print-timeout '30s'"

      assert {:ok, empty} = Antigravity.build_command(spec(%{settings: %{print_timeout: ""}}))
      refute empty =~ "--print-timeout"
    end

    test "extra_args string is appended raw as a trailing fragment" do
      assert {:ok, cmd} = Antigravity.build_command(spec(%{settings: %{extra_args: "--verbose --flag=1"}}))
      assert String.ends_with?(cmd, "--verbose --flag=1")
    end

    test "extra_args list of binaries is escaped and appended" do
      assert {:ok, cmd} = Antigravity.build_command(spec(%{settings: %{extra_args: ["--foo", "bar baz"]}}))
      assert String.ends_with?(cmd, "'--foo' 'bar baz'")
    end

    test "extra_args list skips non-binaries; empty string extra_args adds nothing" do
      assert {:ok, mixed} = Antigravity.build_command(spec(%{settings: %{extra_args: ["--ok", 12, :atom]}}))
      assert mixed =~ "'--ok'"
      refute mixed =~ "12"

      assert {:ok, empty} = Antigravity.build_command(spec(%{settings: %{extra_args: ""}}))
      refute empty =~ "--ok"
    end

    test "custom command from run_spec wins over settings" do
      assert {:ok, cmd} = Antigravity.build_command(spec(%{command: "/opt/agy"}))
      assert String.starts_with?(cmd, "/opt/agy ")
    end

    test "empty or nil command falls back to the default binary" do
      assert {:ok, from_nil} = Antigravity.build_command(spec(%{command: nil, settings: %{command: nil}}))
      assert String.starts_with?(from_nil, "agy ")

      assert {:ok, from_empty} = Antigravity.build_command(spec(%{command: "", settings: %{command: ""}}))
      assert String.starts_with?(from_empty, "agy ")
    end

    test "settings.command is used when run_spec.command is nil" do
      assert {:ok, cmd} = Antigravity.build_command(spec(%{settings: %{command: "agy-wrapper"}}))
      assert String.starts_with?(cmd, "agy-wrapper ")
    end

    test "prompt metacharacters are shell-escaped" do
      assert {:ok, cmd} = Antigravity.build_command(spec(%{prompt: "it's; rm -rf /"}))
      assert cmd =~ ~s(-p 'it'"'"'s; rm -rf /')
    end

    test "nil or empty output_format defaults to stream-json" do
      assert {:ok, from_nil} = Antigravity.build_command(spec(%{settings: %{output_format: nil}}))
      assert from_nil =~ "--output-format 'stream-json'"

      assert {:ok, from_empty} = Antigravity.build_command(spec(%{settings: %{output_format: ""}}))
      assert from_empty =~ "--output-format 'stream-json'"
    end

    test "explicit json output_format is passed through" do
      assert {:ok, cmd} = Antigravity.build_command(spec(%{settings: %{output_format: "json"}}))
      assert cmd =~ "--output-format 'json'"
    end
  end

  describe "parse_output/3 stream-json" do
    test "init + step_update text_delta + result SUCCESS with usage" do
      lines = [
        ~s({"event":"init","conversation_id":"c-1","init":{"cwd":"/tmp","tools":[]}}),
        ~s({"event":"step_update","step_update":{"conversation_id":"c-1","step_index":0,"state":"ACTIVE","step_type":"text","text_delta":"hel"}}),
        ~s({"event":"step_update","step_update":{"conversation_id":"c-1","step_index":0,"state":"DONE","step_type":"text","text_delta":"lo","usage":{"input_tokens":4,"output_tokens":2,"thinking_tokens":9,"cache_read_tokens":1}}}),
        ~s({"event":"result","result":{"conversation_id":"c-1","status":"SUCCESS","response":"hello world","usage":{"input_tokens":11,"output_tokens":7,"thinking_tokens":3,"cache_read_tokens":2,"total_tokens":99}}})
      ]

      {result, messages} = collect_messages(fn on_message -> Antigravity.parse_output(lines, spec(), on_message) end)

      assert {:ok, parsed} = result
      assert parsed.session_id == "c-1"
      assert parsed.result == "hello world"
      assert parsed.usage == %{"input_tokens" => 11, "output_tokens" => 7, "total_tokens" => 99}
      refute Map.has_key?(parsed.usage, "thinking_tokens")
      refute Map.has_key?(parsed.usage, "cache_read_tokens")
      assert {:ok, %{"status" => "SUCCESS"}} = Jason.decode(parsed.raw)

      assert length(messages) == 4

      Enum.each(messages, fn msg ->
        assert msg.event == :stream_event
        assert is_map(msg.payload)
        assert is_binary(msg.raw)
        assert %DateTime{} = msg.timestamp
      end)
    end

    test "result without response falls back to concatenated text_delta" do
      lines = [
        ~s({"event":"init","conversation_id":"c-delta"}),
        ~s({"event":"step_update","step_update":{"text_delta":"ab"}}),
        ~s({"event":"step_update","step_update":{"text_delta":"cd"}}),
        ~s({"event":"result","result":{"conversation_id":"c-delta","status":"SUCCESS"}})
      ]

      assert {:ok, parsed} = Antigravity.parse_output(lines, spec(), fn _ -> :ok end)
      assert parsed.result == "abcd"
      assert parsed.session_id == "c-delta"
      assert parsed.usage == nil
    end

    test "status ERROR is {:error, {:turn_failed, _}} using the error field" do
      lines = [
        ~s({"event":"init","conversation_id":"c-err"}),
        ~s({"event":"result","result":{"conversation_id":"c-err","status":"ERROR","error":"model exploded"}})
      ]

      assert {:error, {:turn_failed, "model exploded"}} = Antigravity.parse_output(lines, spec(), fn _ -> :ok end)
    end

    test "non-SUCCESS status without error field carries the completed envelope" do
      lines = [~s({"event":"result","result":{"conversation_id":"c-can","status":"CANCELED"}})]

      assert {:error, {:turn_failed, %{"status" => "CANCELED", "conversation_id" => "c-can"}}} =
               Antigravity.parse_output(lines, spec(), fn _ -> :ok end)
    end

    test "missing result event is {:error, {:no_result_in_stream, _}}" do
      lines = [~s({"event":"init","conversation_id":"c-none"})]
      assert {:error, {:no_result_in_stream, joined}} = Antigravity.parse_output(lines, spec(), fn _ -> :ok end)
      assert joined =~ "c-none"
    end

    test "non-JSON noise and non-binary lines are ignored" do
      lines = [
        "warning: stderr noise",
        123,
        :atom,
        "",
        "[]",
        "null",
        ~s({"event":"init","conversation_id":"c-noise"}),
        ~s({"event":"result","result":{"conversation_id":"c-noise","status":"SUCCESS","response":"ok"}})
      ]

      {result, messages} = collect_messages(fn on_message -> Antigravity.parse_output(lines, spec(), on_message) end)

      assert {:ok, %{session_id: "c-noise", result: "ok"}} = result
      assert length(messages) == 2
    end

    test "init conversation_id falls back to init.conversation_id" do
      lines = [
        ~s({"event":"init","init":{"conversation_id":"from-init","cwd":"/tmp"}}),
        ~s({"event":"result","result":{"status":"SUCCESS","response":"via-init"}})
      ]

      assert {:ok, %{session_id: "from-init", result: "via-init"}} = Antigravity.parse_output(lines, spec(), fn _ -> :ok end)
    end

    test "init without a map init payload and unknown events leave session_id unset until result" do
      lines = [
        ~s({"event":"init","init":"not-a-map"}),
        ~s({"event":"pong"}),
        ~s({"event":"result","conversation_id":"from-result","status":"SUCCESS","response":"flat"})
      ]

      assert {:ok, %{session_id: "from-result", result: "flat"}} = Antigravity.parse_output(lines, spec(), fn _ -> :ok end)
    end

    test "top-level conversation_id wins over init.conversation_id" do
      lines = [
        ~s({"event":"init","conversation_id":"top","init":{"conversation_id":"nested"}}),
        ~s({"event":"result","result":{"status":"SUCCESS","response":"x"}})
      ]

      assert {:ok, %{session_id: "top"}} = Antigravity.parse_output(lines, spec(), fn _ -> :ok end)
    end

    test "step_update without text_delta or usage is ignored; mid-turn usage is kept if result has none" do
      lines = [
        ~s({"event":"step_update"}),
        ~s({"event":"step_update","step_update":{"text_delta":12,"usage":"nope"}}),
        ~s({"event":"step_update","step_update":{"usage":{"input_tokens":3,"output_tokens":1}}}),
        ~s({"event":"result","result":{"conversation_id":"c-u","status":"SUCCESS"}})
      ]

      assert {:ok, parsed} = Antigravity.parse_output(lines, spec(), fn _ -> :ok end)
      assert parsed.result == nil
      assert parsed.usage == %{"input_tokens" => 3, "output_tokens" => 1, "total_tokens" => 4}
    end

    test "usage without total_tokens sums input and output; invalid counts clamp to zero" do
      lines = [
        ~s({"event":"result","result":{"status":"SUCCESS","response":"n","usage":{"input_tokens":-2,"output_tokens":"x","thinking_tokens":8}}})
      ]

      assert {:ok, %{usage: %{"input_tokens" => 0, "output_tokens" => 0, "total_tokens" => 0}}} =
               Antigravity.parse_output(lines, spec(), fn _ -> :ok end)
    end

    test "present total_tokens is kept even when it does not match input+output" do
      lines = [
        ~s({"event":"result","result":{"status":"SUCCESS","usage":{"input_tokens":1,"output_tokens":1,"total_tokens":50}}})
      ]

      assert {:ok, %{usage: %{"total_tokens" => 50}}} = Antigravity.parse_output(lines, spec(), fn _ -> :ok end)
    end

    test "result event with a non-map result field uses the event itself as the envelope" do
      lines = [~s({"event":"result","result":"oops","conversation_id":"c-flat","status":"SUCCESS","response":"fallback"})]

      assert {:ok, %{session_id: "c-flat", result: "fallback"}} = Antigravity.parse_output(lines, spec(), fn _ -> :ok end)
    end
  end

  describe "parse_output/3 json" do
    test "SUCCESS reads conversation_id, response, and normalized usage from the last object" do
      settings = %{output_format: "json"}

      lines = [
        "noise",
        ~s({"conversation_id":"old","status":"SUCCESS","response":"first"}),
        "  {\"conversation_id\":\"j-1\",\"status\":\"SUCCESS\",\"response\":\"done\",\"usage\":{\"input_tokens\":3,\"output_tokens\":2}}  "
      ]

      me = self()

      assert {:ok, parsed} =
               Antigravity.parse_output(lines, spec(%{settings: settings}), fn msg ->
                 send(me, {:msg, msg})
               end)

      assert parsed.session_id == "j-1"
      assert parsed.result == "done"
      assert parsed.usage == %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
      assert parsed.raw =~ "j-1"
      refute_received {:msg, _}
    end

    test "status ERROR is {:error, {:turn_failed, error}}" do
      settings = %{output_format: "json"}
      lines = [~s({"status":"ERROR","error":"bad model","conversation_id":"j-err"})]

      assert {:error, {:turn_failed, "bad model"}} =
               Antigravity.parse_output(lines, spec(%{settings: settings}), fn _ -> :ok end)
    end

    test "non-SUCCESS without error field carries the payload" do
      settings = %{output_format: "json"}
      lines = [~s({"status":"INTERRUPTED","conversation_id":"j-int"})]

      assert {:error, {:turn_failed, %{"status" => "INTERRUPTED"}}} =
               Antigravity.parse_output(lines, spec(%{settings: settings}), fn _ -> :ok end)
    end

    test "missing status is treated as success" do
      settings = %{output_format: "json"}
      lines = [~s({"conversation_id":"j-ns","response":"ok"})]

      assert {:ok, %{session_id: "j-ns", result: "ok", usage: nil}} =
               Antigravity.parse_output(lines, spec(%{settings: settings}), fn _ -> :ok end)
    end

    test "a braces line that is not valid JSON is a decode error" do
      settings = %{output_format: "json"}

      assert {:error, {:json_decode_failed, _, "{not json}"}} =
               Antigravity.parse_output(["{not json}"], spec(%{settings: settings}), fn _ -> :ok end)
    end

    test "no JSON object line is {:error, {:no_json_output, _}}" do
      settings = %{output_format: "json"}

      assert {:error, {:no_json_output, "nope"}} =
               Antigravity.parse_output(["nope"], spec(%{settings: settings}), fn _ -> :ok end)
    end

    test "non-binary lines are skipped by the json-line scan" do
      settings = %{output_format: "json"}
      lines = [123, :atom, ~s({"conversation_id":"j-bin","status":"SUCCESS","response":"ok"})]

      assert {:ok, %{session_id: "j-bin"}} = Antigravity.parse_output(lines, spec(%{settings: settings}), fn _ -> :ok end)

      assert {:error, {:no_json_output, _}} =
               Antigravity.parse_output([123, :atom], spec(%{settings: settings}), fn _ -> :ok end)
    end
  end

  describe "parse_output/3 text" do
    test "joins lines and returns nil session/usage" do
      settings = %{output_format: "text"}
      lines = ["hello", "world"]

      assert {:ok, %{session_id: nil, result: "hello\nworld", usage: nil, raw: "hello\nworld"}} =
               Antigravity.parse_output(lines, spec(%{settings: settings}), fn _ -> :ok end)
    end

    test "unknown or nil output_format uses the text fallback" do
      assert {:ok, %{result: "plain", session_id: nil}} =
               Antigravity.parse_output(["plain"], spec(%{settings: %{output_format: nil}}), fn _ -> :ok end)
    end
  end

  test "auth env callbacks" do
    assert Antigravity.default_command() == "agy"
    assert Antigravity.auth_env_prefixes() == ["ANTIGRAVITY_", "GOOGLE_", "GEMINI_", "API_TIMEOUT"]
    assert Antigravity.auth_env_fallback() == ["GOOGLE_API_KEY", "GEMINI_API_KEY"]
  end
end
