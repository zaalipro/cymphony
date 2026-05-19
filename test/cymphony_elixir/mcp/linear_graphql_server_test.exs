defmodule CymphonyElixir.Mcp.LinearGraphqlServerTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias CymphonyElixir.Mcp.LinearGraphqlServer, as: Server

  defp call_tool(args, graphql_fun) do
    env =
      %{api_key: "key", endpoint: "https://lin.example/graphql"}
      |> maybe_put(:graphql_fun, graphql_fun)

    frame =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 7,
        "method" => "tools/call",
        "params" => %{"name" => "linear_graphql", "arguments" => args}
      })

    {:ok, response} = Jason.decode(Server.handle_message(frame, env))
    response
  end

  defp tool_payload(response) do
    %{"result" => %{"content" => [%{"text" => text}]}} = response
    Jason.decode!(text)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  describe "protocol dispatch" do
    test "initialize returns protocolVersion + serverInfo" do
      frame = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"})
      assert {:ok, decoded} = Jason.decode(Server.handle_message(frame, %{}))
      assert decoded["id"] == 1
      assert decoded["result"]["protocolVersion"]
      assert decoded["result"]["serverInfo"]["name"] == "cymphony-linear"
      assert decoded["result"]["capabilities"]["tools"]
    end

    test "tools/list advertises a single linear_graphql tool" do
      frame = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"})
      {:ok, decoded} = Jason.decode(Server.handle_message(frame, %{}))
      [tool] = decoded["result"]["tools"]
      assert tool["name"] == "linear_graphql"
      assert tool["inputSchema"]["required"] == ["query"]
    end

    test "unknown method returns -32601" do
      frame = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 3, "method" => "totally/unknown"})
      {:ok, decoded} = Jason.decode(Server.handle_message(frame, %{}))
      assert decoded["error"]["code"] == -32601
    end

    test "notification (no id) returns :no_reply" do
      frame = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
      assert Server.handle_message(frame, %{}) == :no_reply
    end

    test "invalid JSON returns -32700" do
      {:ok, decoded} = Jason.decode(Server.handle_message("{not json", %{}))
      assert decoded["error"]["code"] == -32700
    end

    test "non-2.0 jsonrpc returns -32600" do
      frame = Jason.encode!(%{"id" => 1, "method" => "initialize"})
      {:ok, decoded} = Jason.decode(Server.handle_message(frame, %{}))
      assert decoded["error"]["code"] == -32600
    end

    test "tools/call with unknown tool name returns -32602" do
      frame =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 9,
          "method" => "tools/call",
          "params" => %{"name" => "nope", "arguments" => %{}}
        })

      {:ok, decoded} = Jason.decode(Server.handle_message(frame, %{}))
      assert decoded["error"]["code"] == -32602
    end
  end

  describe "linear_graphql tool" do
    test "success envelope when GraphQL returns no errors" do
      fun = fn _q, _v, _opts -> {:ok, %{"data" => %{"issue" => %{"id" => "i1"}}}} end

      payload =
        capture_log(fn ->
          response = call_tool(%{"query" => "query Q { issue(id:\"i1\") { id } }"}, fun)
          send(self(), {:payload, tool_payload(response)})
        end)

      assert payload =~ "mcp.linear_graphql.call"
      assert_received {:payload, %{"success" => true, "data" => %{"issue" => %{"id" => "i1"}}}}
    end

    test "error envelope when GraphQL returns top-level errors" do
      fun = fn _q, _v, _opts ->
        {:ok, %{"errors" => [%{"message" => "bad"}], "data" => nil}}
      end

      response = call_tool(%{"query" => "query Q { foo }"}, fun)
      tool = tool_payload(response)
      assert tool["success"] == false
      assert [%{"message" => "bad"}] = tool["errors"]
    end

    test "error envelope when transport fails" do
      fun = fn _q, _v, _opts -> {:error, {:linear_api_status, 401}} end

      response = call_tool(%{"query" => "query Q { foo }"}, fun)
      tool = tool_payload(response)
      assert tool["success"] == false
      assert is_binary(tool["error"])
    end

    test "rejects empty query without calling graphql_fun" do
      fun = fn _q, _v, _opts -> flunk("graphql_fun should not run") end
      response = call_tool(%{"query" => ""}, fun)
      tool = tool_payload(response)
      assert tool["success"] == false
      assert tool["error"] =~ "non-empty"
    end

    test "rejects non-string query without calling graphql_fun" do
      fun = fn _q, _v, _opts -> flunk("graphql_fun should not run") end
      response = call_tool(%{"query" => 42}, fun)
      tool = tool_payload(response)
      assert tool["success"] == false
    end

    test "rejects multi-operation document without calling graphql_fun" do
      fun = fn _q, _v, _opts -> flunk("graphql_fun should not run") end

      multi = """
      query A { issue { id } }
      mutation B { issueUpdate(input: {id: \"x\"}) { success } }
      """

      response = call_tool(%{"query" => multi}, fun)
      tool = tool_payload(response)
      assert tool["success"] == false
      assert tool["error"] =~ "exactly one"
    end

    test "rejects non-map variables" do
      fun = fn _q, _v, _opts -> flunk("graphql_fun should not run") end

      response = call_tool(%{"query" => "query Q { ok }", "variables" => "not a map"}, fun)

      tool = tool_payload(response)
      assert tool["success"] == false
      assert tool["error"] =~ "variables"
    end

    test "accepts missing variables and defaults to empty map" do
      fun = fn _q, vars, _opts ->
        assert vars == %{}
        {:ok, %{"data" => %{"ok" => true}}}
      end

      response = call_tool(%{"query" => "query Q { ok }"}, fun)
      assert tool_payload(response)["success"] == true
    end

    test "isError flag reflects success in result content envelope" do
      ok_fun = fn _q, _v, _o -> {:ok, %{"data" => %{}}} end
      ok_response = call_tool(%{"query" => "query Q { x }"}, ok_fun)
      %{"result" => result_ok} = ok_response
      assert result_ok["isError"] == false

      err_fun = fn _q, _v, _o -> {:error, :network} end
      err_response = call_tool(%{"query" => "query Q { x }"}, err_fun)
      %{"result" => result_err} = err_response
      assert result_err["isError"] == true
    end
  end

  describe "env helpers" do
    test "env_from_system reads from env vars" do
      System.put_env("LINEAR_API_KEY", "test-key")
      System.put_env("LINEAR_ENDPOINT", "https://test.example")

      try do
        env = Server.env_from_system()
        assert env.api_key == "test-key"
        assert env.endpoint == "https://test.example"
      after
        System.delete_env("LINEAR_API_KEY")
        System.delete_env("LINEAR_ENDPOINT")
      end
    end

    test "log_started emits a structured event" do
      log = capture_log(fn -> :ok = Server.log_started(%{workspace_path: "/tmp/x"}) end)
      assert log =~ "mcp.linear_graphql.started"
      assert log =~ "/tmp/x"
    end
  end
end
