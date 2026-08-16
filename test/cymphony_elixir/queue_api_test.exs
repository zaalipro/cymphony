defmodule CymphonyElixir.QueueApiTest do
  # async: false — mutates :config_dir_override, Endpoint, and ProjectRegistry.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias CymphonyElixir.ProjectSupervisor

  @endpoint CymphonyElixirWeb.Endpoint

  defmodule FakeOrch do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :recipient), name: Keyword.fetch!(opts, :name))
    end

    @impl true
    def init(recipient), do: {:ok, recipient}

    @impl true
    def handle_call(msg, _from, recipient) do
      send(recipient, {:orch, self(), msg})
      {:reply, :ok, recipient}
    end
  end

  setup do
    endpoint_config = Application.get_env(:cymphony_elixir, CymphonyElixirWeb.Endpoint, [])

    tmp = Path.join(System.tmp_dir!(), "cymphony-queue-api-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    path = Path.join(tmp, "config.json")

    File.write!(
      path,
      Jason.encode!(%{"projects" => [%{"name" => "queue"}, %{"name" => "Farm"}]})
    )

    Application.put_env(:cymphony_elixir, :config_dir_override, tmp)

    Application.put_env(
      :cymphony_elixir,
      CymphonyElixirWeb.Endpoint,
      endpoint_config
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
    )

    start_supervised!({CymphonyElixirWeb.Endpoint, []})

    start_supervised!(%{
      id: {:fake_orch, "queue"},
      start: {FakeOrch, :start_link, [[name: ProjectSupervisor.via_tuple("queue", :orchestrator), recipient: self()]]}
    })

    on_exit(fn ->
      Application.delete_env(:cymphony_elixir, :config_dir_override)
      Application.put_env(:cymphony_elixir, CymphonyElixirWeb.Endpoint, endpoint_config)
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp, path: path}
  end

  test "POST /api/v1/queue?project= returns 202 and persists order", %{path: path} do
    conn = post(build_conn(), "/api/v1/queue?project=queue", %{"order" => ["LLM-51", " LLM-12 ", ""]})

    assert json_response(conn, 202) == %{
             "order" => ["LLM-51", "LLM-12"],
             "project" => "queue"
           }

    assert_receive {:orch, _, {:reorder_queue, ["LLM-51", "LLM-12"]}}

    {:ok, cfg} = Jason.decode(File.read!(path))
    project = Enum.find(cfg["projects"], &(&1["name"] == "queue"))
    other = Enum.find(cfg["projects"], &(&1["name"] == "Farm"))
    assert project["queue_order"] == ["LLM-51", "LLM-12"]
    refute Map.has_key?(other, "queue_order")
    refute inspect(Jason.decode!(conn.resp_body)) =~ "api_key"
  end

  test "POST /api/v1/queue-pin?project= returns 202 and persists the pin", %{path: path} do
    conn =
      post(build_conn(), "/api/v1/queue-pin?project=queue", %{
        "issue" => "LLM-51",
        "kind" => "codex",
        "model" => "gpt-5.2-codex",
        "effort" => "high"
      })

    assert json_response(conn, 202) == %{
             "issue" => "LLM-51",
             "agent_kind" => "codex",
             "model" => "gpt-5.2-codex",
             "effort" => "high",
             "project" => "queue"
           }

    assert_receive {:orch, _, {:set_queue_run_spec, "LLM-51", %{"agent_kind" => "codex", "model" => "gpt-5.2-codex", "effort" => "high"}}}

    {:ok, cfg} = Jason.decode(File.read!(path))
    project = Enum.find(cfg["projects"], &(&1["name"] == "queue"))
    assert project["queue_pins"]["LLM-51"]["agent_kind"] == "codex"
  end

  test "POST /api/v1/queue-pin skips empty/keep fields" do
    conn =
      post(build_conn(), "/api/v1/queue-pin?project=queue", %{
        "issue" => "LLM-51",
        "kind" => "keep",
        "model" => "opus",
        "effort" => ""
      })

    assert json_response(conn, 202) == %{
             "issue" => "LLM-51",
             "agent_kind" => nil,
             "model" => "opus",
             "effort" => nil,
             "project" => "queue"
           }
  end

  test "POST /api/v1/queue without project is 422 invalid_scope" do
    assert json_response(post(build_conn(), "/api/v1/queue", %{"order" => ["LLM-51"]}), 422) ==
             %{
               "error" => %{
                 "code" => "invalid_scope",
                 "message" => "query param 'project' is required"
               }
             }

    assert json_response(post(build_conn(), "/api/v1/queue?project=", %{"order" => ["LLM-51"]}), 422) ==
             %{
               "error" => %{
                 "code" => "invalid_scope",
                 "message" => "query param 'project' is required"
               }
             }

    refute_receive {:orch, _, _}, 100
  end

  test "POST /api/v1/queue-pin without project is 422 invalid_scope" do
    assert json_response(
             post(build_conn(), "/api/v1/queue-pin", %{"issue" => "LLM-51", "kind" => "codex"}),
             422
           ) ==
             %{
               "error" => %{
                 "code" => "invalid_scope",
                 "message" => "query param 'project' is required"
               }
             }
  end

  test "POST /api/v1/queue rejects a non-list order with 422" do
    assert json_response(post(build_conn(), "/api/v1/queue?project=queue", %{"order" => "LLM-51"}), 422) ==
             %{
               "error" => %{
                 "code" => "invalid_queue_order",
                 "message" => "body 'order' must be a list of issue identifiers"
               }
             }
  end

  test "POST /api/v1/queue-pin rejects a missing issue with 422" do
    assert json_response(
             post(build_conn(), "/api/v1/queue-pin?project=queue", %{"kind" => "codex"}),
             422
           )["error"]["code"] == "invalid_queue_pin"
  end

  test "POST /api/v1/queue-pin rejects an unknown kind with 422" do
    assert json_response(
             post(build_conn(), "/api/v1/queue-pin?project=queue", %{
               "issue" => "LLM-51",
               "kind" => "gemini"
             }),
             422
           ) ==
             %{
               "error" => %{
                 "code" => "invalid_queue_pin",
                 "message" => "body must include issue and at least one of kind/model/effort; kind must be one of: claude, codex, antigravity"
               }
             }
  end

  test "POST /api/v1/queue for an unknown project is 422 invalid_scope" do
    assert json_response(post(build_conn(), "/api/v1/queue?project=ghost", %{"order" => ["LLM-51"]}), 422) ==
             %{
               "error" => %{
                 "code" => "invalid_scope",
                 "message" => "query param 'project' is required"
               }
             }
  end

  test "GET and PUT on queue routes are 405, not issue_not_found" do
    method_not_allowed = %{
      "error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}
    }

    assert json_response(get(build_conn(), "/api/v1/queue"), 405) == method_not_allowed
    assert json_response(put(build_conn(), "/api/v1/queue", %{"order" => []}), 405) == method_not_allowed
    assert json_response(get(build_conn(), "/api/v1/queue-pin"), 405) == method_not_allowed

    assert json_response(put(build_conn(), "/api/v1/queue-pin", %{"issue" => "LLM-51"}), 405) ==
             method_not_allowed
  end

  test "POST /api/v1/queue is not stolen by :issue_identifier for a project named queue" do
    conn = post(build_conn(), "/api/v1/queue?project=queue", %{"order" => ["LLM-9"]})
    body = json_response(conn, 202)
    assert body["project"] == "queue"
    refute Map.has_key?(body, "error")
  end

  test "POST /api/v1/queue surfaces persist errors as 422", %{path: path} do
    File.rm!(path)

    assert json_response(post(build_conn(), "/api/v1/queue?project=queue", %{"order" => ["LLM-51"]}), 422) ==
             %{
               "error" => %{
                 "code" => "invalid_queue_order",
                 "message" => "Could not persist queue order"
               }
             }
  end

  test "POST /api/v1/queue-pin surfaces persist errors as 422", %{path: path} do
    File.rm!(path)

    assert json_response(
             post(build_conn(), "/api/v1/queue-pin?project=queue", %{
               "issue" => "LLM-51",
               "kind" => "codex"
             }),
             422
           ) ==
             %{
               "error" => %{
                 "code" => "invalid_queue_pin",
                 "message" => "Could not persist queue pin"
               }
             }
  end
end
