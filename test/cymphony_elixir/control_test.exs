defmodule CymphonyElixirWeb.ControlTest do
  # async: false — mutates the global ProjectRegistry and :config_dir_override.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CymphonyElixir.Cymphony.Config, as: CymphonyConfig
  alias CymphonyElixir.Cymphony.WorkflowGenerator
  alias CymphonyElixir.ProjectSupervisor
  alias CymphonyElixir.WorkflowStore
  alias CymphonyElixirWeb.Control

  @fake_key "lin_api_fake"
  @test_key "lin_test"

  setup do
    previous_key = System.get_env("LINEAR_API_KEY")
    previous_opts = Application.get_env(:cymphony_elixir, :linear_graphql_opts)
    previous_start_args = Application.get_env(:cymphony_elixir, :start_project_args)

    System.delete_env("LINEAR_API_KEY")
    Application.delete_env(:cymphony_elixir, :linear_graphql_opts)
    Application.delete_env(:cymphony_elixir, :start_project_args)

    on_exit(fn ->
      restore_env("LINEAR_API_KEY", previous_key)
      restore_app_env(:linear_graphql_opts, previous_opts)
      restore_app_env(:start_project_args, previous_start_args)
    end)

    :ok
  end

  # Stand-in orchestrator: registers under the project via-tuple and forwards
  # every GenServer call Control makes back to the test process.
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

  describe "pure helpers" do
    test "scope/1 maps an optional project param" do
      assert Control.scope(nil) == :all
      assert Control.scope("") == :all
      assert Control.scope("Farm") == {:project, "Farm"}
    end

    test "parse_agent_settings validates kind and normalizes params" do
      assert {:ok, %{"agent" => "codex", "model" => "m", "effort" => "high"}} =
               Control.parse_agent_settings(%{"kind" => "codex", "model" => "m", "effort" => "high"})

      assert {:ok, %{"agent" => "antigravity"}} = Control.parse_agent_settings(%{"kind" => "antigravity"})

      for kind <- CymphonyElixir.Agent.known_kinds() do
        assert {:ok, %{"agent" => ^kind}} = Control.parse_agent_settings(%{"kind" => kind})
      end

      assert {:ok, %{"model" => "m"}} = Control.parse_agent_settings(%{"model" => "m"})
      assert {:ok, %{"model" => ""}} = Control.parse_agent_settings(%{"model" => "  "})
      assert :error = Control.parse_agent_settings(%{"kind" => "gemini"})
      assert :error = Control.parse_agent_settings(%{})
      assert :error = Control.parse_agent_settings(%{"other" => "x"})
    end

    test "parse_concurrency/1 accepts positive integers/strings and rejects the rest" do
      assert Control.parse_concurrency(3) == {:ok, 3}
      assert Control.parse_concurrency("5") == {:ok, 5}
      assert Control.parse_concurrency(" 7 ") == {:ok, 7}
      assert Control.parse_concurrency(0) == :error
      assert Control.parse_concurrency("nope") == :error
      assert Control.parse_concurrency(nil) == :error
    end

    test "parse_queue_order/1 trims, drops blanks, and rejects non-lists" do
      assert Control.parse_queue_order(["LLM-51", " LLM-12 ", ""]) == {:ok, ["LLM-51", "LLM-12"]}
      assert Control.parse_queue_order([]) == {:ok, []}
      assert Control.parse_queue_order("LLM-51") == :error
      assert Control.parse_queue_order(nil) == :error
      assert Control.parse_queue_order([1, "LLM-51"]) == :error
    end

    test "parse_queue_pin/1 requires issue plus at least one real field" do
      assert {:ok, {"LLM-51", %{"agent_kind" => "codex", "model" => "m", "effort" => "high"}}} =
               Control.parse_queue_pin(%{
                 "issue" => " LLM-51 ",
                 "kind" => "codex",
                 "model" => " m ",
                 "effort" => "high"
               })

      assert {:ok, {"LLM-51", %{"agent_kind" => "antigravity"}}} =
               Control.parse_queue_pin(%{"issue" => "LLM-51", "agent_kind" => "antigravity"})

      assert {:ok, {"LLM-51", %{"model" => "opus"}}} =
               Control.parse_queue_pin(%{"issue" => "LLM-51", "kind" => "keep", "model" => "opus", "effort" => ""})

      assert {:ok, {"LLM-51", %{"agent_kind" => "codex", "model" => "m"}}} =
               Control.parse_queue_pin(%{
                 "issue" => "LLM-51",
                 "kind" => 1,
                 "agent_kind" => "codex",
                 "model" => "m",
                 "effort" => 3
               })

      assert :error = Control.parse_queue_pin(%{"issue" => "LLM-51"})
      assert :error = Control.parse_queue_pin(%{"issue" => "", "kind" => "codex"})
      assert :error = Control.parse_queue_pin(%{"kind" => "codex"})
      assert :error = Control.parse_queue_pin(%{"issue" => "LLM-51", "kind" => "gemini"})
      assert :error = Control.parse_queue_pin(%{"issue" => "LLM-51", "kind" => "keep", "model" => "  "})
      assert :error = Control.parse_queue_pin("LLM-51")
    end
  end

  describe "dispatch across registered project orchestrators" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "cymphony-control-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "config.json"), ~s({"projects": [{"name": "alpha"}, {"name": "beta"}]}))
      Application.put_env(:cymphony_elixir, :config_dir_override, tmp)

      on_exit(fn ->
        Application.delete_env(:cymphony_elixir, :config_dir_override)
        File.rm_rf!(tmp)
      end)

      {:ok, tmp: tmp}
    end

    test "set_concurrency(:all, n) fans out to every orchestrator and persists per project", %{tmp: tmp} do
      start_orch!("alpha")
      start_orch!("beta")

      assert Control.set_concurrency(:all, 4) == :ok
      assert_receive {:orch, _, {:set_concurrency, 4}}
      assert_receive {:orch, _, {:set_concurrency, 4}}

      {:ok, cfg} = Jason.decode(File.read!(Path.join(tmp, "config.json")))
      assert Enum.all?(cfg["projects"], &(&1["max_concurrent_agents"] == 4))
    end

    test "set_dashboard_refresh_seconds persists only and does not message orchestrators", %{tmp: tmp} do
      start_orch!("alpha")
      start_orch!("beta")

      assert Control.set_dashboard_refresh_seconds(8) == :ok
      assert Control.set_dashboard_refresh_seconds(" 6 ") == :ok
      refute_receive {:orch, _, _}, 100

      {:ok, cfg} = Jason.decode(File.read!(Path.join(tmp, "config.json")))
      assert cfg["dashboard_refresh_seconds"] == 6
      refute Enum.any?(cfg["projects"], &Map.has_key?(&1, "dashboard_refresh_seconds"))
      refute Map.has_key?(cfg, "polling_interval_ms")
    end

    test "set_dashboard_refresh_seconds rejects invalid values without touching orchestrators" do
      start_orch!("alpha")

      assert Control.set_dashboard_refresh_seconds(0) == {:error, :invalid_refresh_interval}
      assert Control.set_dashboard_refresh_seconds("nope") == {:error, :invalid_refresh_interval}
      refute_receive {:orch, _, _}, 100
    end

    test "set_dashboard_refresh_seconds surfaces persist errors", %{tmp: tmp} do
      File.rm!(Path.join(tmp, "config.json"))

      assert {:error, msg} = Control.set_dashboard_refresh_seconds(5)
      assert is_binary(msg)
      assert msg =~ "Failed to read"
    end

    test "set_agent_settings fans out to orchestrators and persists", %{tmp: tmp} do
      start_orch!("alpha")
      start_orch!("beta")

      assert :ok = Control.set_agent_settings(:all, %{"agent" => "codex", "effort" => "high"})

      assert_receive {:orch, _, {:set_agent_settings, %{"agent" => "codex", "effort" => "high"}}}
      assert_receive {:orch, _, {:set_agent_settings, %{"agent" => "codex", "effort" => "high"}}}

      {:ok, cfg} = Jason.decode(File.read!(Path.join(tmp, "config.json")))
      assert Enum.all?(cfg["projects"], &(&1["agent"] == "codex" and &1["effort"] == "high"))
    end

    test "set_providers({:project, name}, list) targets only the named orchestrator", %{tmp: tmp} do
      start_orch!("alpha")
      start_orch!("beta")

      assert Control.set_providers({:project, "alpha"}, ["cv1", "cz2"]) == :ok
      assert_receive {:orch, _, {:set_providers, ["cv1", "cz2"]}}
      refute_receive {:orch, _, {:set_providers, _}}, 100

      {:ok, cfg} = Jason.decode(File.read!(Path.join(tmp, "config.json")))
      alpha = Enum.find(cfg["projects"], &(&1["name"] == "alpha"))
      assert alpha["providers"] == ["cv1", "cz2"]
    end

    test "returns {:error, :not_found} for an unknown project when others are registered" do
      start_orch!("alpha")

      assert Control.set_concurrency({:project, "ghost"}, 2) == {:error, :not_found}
      refute_receive {:orch, _, _}, 100
    end

    test "pause(:all) fans out without writing config", %{tmp: tmp} do
      start_orch!("alpha")

      before = File.read!(Path.join(tmp, "config.json"))
      assert Control.pause(:all) == :ok
      assert_receive {:orch, _, :pause}
      assert File.read!(Path.join(tmp, "config.json")) == before
    end

    test "set_agent_settings on :all with no orchestrators persists globally", %{tmp: tmp} do
      assert :ok = Control.set_agent_settings(:all, %{"agent" => "codex"})

      {:ok, cfg} = Jason.decode(File.read!(Path.join(tmp, "config.json")))
      assert Enum.all?(cfg["projects"], &(&1["agent"] == "codex"))
    end

    test "set_agent_settings surfaces persist errors", %{tmp: tmp} do
      start_orch!("alpha")
      File.rm!(Path.join(tmp, "config.json"))

      assert {:error, msg} = Control.set_agent_settings({:project, "alpha"}, %{"agent" => "codex"})
      assert is_binary(msg)
      assert msg =~ "Failed to read"
    end

    test "set_agent_settings surfaces invalid agent kind persist errors" do
      start_orch!("alpha")

      assert {:error, :invalid_agent_kind} =
               Control.set_agent_settings({:project, "alpha"}, %{"agent" => "gemini"})
    end

    test "set_queue_order(:all) is invalid_scope and does not message orchestrators" do
      start_orch!("alpha")

      assert Control.set_queue_order(:all, ["LLM-51"]) == {:error, :invalid_scope}
      assert Control.set_queue_order({:project, ""}, ["LLM-51"]) == {:error, :invalid_scope}
      refute_receive {:orch, _, _}, 100
    end

    test "set_queue_order calls orchestrator then persists queue_order", %{tmp: tmp} do
      start_orch!("alpha")
      start_orch!("beta")

      assert Control.set_queue_order({:project, "alpha"}, ["LLM-51", "LLM-12"]) == :ok
      assert_receive {:orch, _, {:reorder_queue, ["LLM-51", "LLM-12"]}}
      refute_receive {:orch, _, {:reorder_queue, _}}, 100

      {:ok, cfg} = Jason.decode(File.read!(Path.join(tmp, "config.json")))
      alpha = Enum.find(cfg["projects"], &(&1["name"] == "alpha"))
      beta = Enum.find(cfg["projects"], &(&1["name"] == "beta"))
      assert alpha["queue_order"] == ["LLM-51", "LLM-12"]
      refute Map.has_key?(beta, "queue_order")
    end

    test "set_queue_pin calls orchestrator then persists queue_pins", %{tmp: tmp} do
      start_orch!("alpha")
      start_orch!("beta")

      pin = %{"agent_kind" => "codex", "model" => "gpt-5.2-codex", "effort" => "high"}
      assert Control.set_queue_pin({:project, "alpha"}, "LLM-51", pin) == :ok
      assert_receive {:orch, _, {:set_queue_run_spec, "LLM-51", ^pin}}
      refute_receive {:orch, _, {:set_queue_run_spec, _, _}}, 100

      {:ok, cfg} = Jason.decode(File.read!(Path.join(tmp, "config.json")))
      alpha = Enum.find(cfg["projects"], &(&1["name"] == "alpha"))
      beta = Enum.find(cfg["projects"], &(&1["name"] == "beta"))
      assert alpha["queue_pins"]["LLM-51"] == pin
      refute Map.has_key?(beta, "queue_pins")

      assert Control.set_queue_pin({:project, "alpha"}, "LLM-51", %{"model" => "opus"}) == :ok
      {:ok, cfg} = Jason.decode(File.read!(Path.join(tmp, "config.json")))
      alpha = Enum.find(cfg["projects"], &(&1["name"] == "alpha"))
      assert alpha["queue_pins"]["LLM-51"]["agent_kind"] == "codex"
      assert alpha["queue_pins"]["LLM-51"]["model"] == "opus"
    end

    test "set_queue_pin stringifies atom LiveView keys and does not clobber siblings", %{tmp: tmp} do
      File.write!(
        Path.join(tmp, "config.json"),
        Jason.encode!(%{
          "projects" => [
            %{
              "name" => "alpha",
              "queue_pins" => %{
                "LLM-51" => %{"agent_kind" => "claude", "model" => "sonnet"},
                "LLM-12" => %{"effort" => "low"}
              }
            }
          ]
        })
      )

      start_orch!("alpha")

      assert Control.set_queue_pin({:project, "alpha"}, "LLM-51", %{model: "opus"}) == :ok
      {:ok, cfg} = Jason.decode(File.read!(Path.join(tmp, "config.json")))
      alpha = Enum.find(cfg["projects"], &(&1["name"] == "alpha"))
      assert alpha["queue_pins"]["LLM-51"] == %{"agent_kind" => "claude", "model" => "opus"}
      assert alpha["queue_pins"]["LLM-12"] == %{"effort" => "low"}
    end

    test "set_queue_pin(:all) is invalid_scope" do
      start_orch!("alpha")

      assert Control.set_queue_pin(:all, "LLM-51", %{"agent_kind" => "codex"}) == {:error, :invalid_scope}
      refute_receive {:orch, _, _}, 100
    end

    test "set_queue_order returns :not_found for an unknown project when others are registered" do
      start_orch!("alpha")

      assert Control.set_queue_order({:project, "ghost"}, ["LLM-51"]) == {:error, :not_found}

      assert Control.set_queue_pin({:project, "ghost"}, "LLM-51", %{"effort" => "high"}) ==
               {:error, :not_found}

      refute_receive {:orch, _, _}, 100
    end

    test "set_queue_order persists via nil name when no orchestrators are registered", %{tmp: tmp} do
      assert Control.set_queue_order({:project, "alpha"}, ["LLM-51"]) == :ok
      refute_receive {:orch, _, _}, 100

      {:ok, cfg} = Jason.decode(File.read!(Path.join(tmp, "config.json")))
      assert Enum.all?(cfg["projects"], &(&1["queue_order"] == ["LLM-51"]))
    end

    test "set_queue_pin persists via nil name when no orchestrators are registered", %{tmp: tmp} do
      assert Control.set_queue_pin({:project, "alpha"}, "LLM-51", %{"effort" => "high"}) == :ok
      refute_receive {:orch, _, _}, 100

      {:ok, cfg} = Jason.decode(File.read!(Path.join(tmp, "config.json")))
      assert Enum.all?(cfg["projects"], &(&1["queue_pins"]["LLM-51"]["effort"] == "high"))
    end

    test "set_queue_pin overlays a non-map existing pin and can delete an empty pin", %{tmp: tmp} do
      File.write!(
        Path.join(tmp, "config.json"),
        Jason.encode!(%{
          "projects" => [
            %{"name" => "alpha", "queue_pins" => %{"LLM-51" => "bad", "LLM-12" => %{"model" => "m"}}}
          ]
        })
      )

      start_orch!("alpha")

      assert Control.set_queue_pin({:project, "alpha"}, "LLM-51", %{"effort" => "high"}) == :ok
      assert_receive {:orch, _, {:set_queue_run_spec, "LLM-51", %{"effort" => "high"}}}
      {:ok, cfg} = Jason.decode(File.read!(Path.join(tmp, "config.json")))
      alpha = Enum.find(cfg["projects"], &(&1["name"] == "alpha"))
      assert alpha["queue_pins"]["LLM-51"] == %{"effort" => "high"}
      assert alpha["queue_pins"]["LLM-12"] == %{"model" => "m"}

      assert Control.set_queue_pin({:project, "alpha"}, "LLM-12", %{}) == :ok
      assert_receive {:orch, _, {:set_queue_run_spec, "LLM-12", %{}}}
      {:ok, cfg} = Jason.decode(File.read!(Path.join(tmp, "config.json")))
      alpha = Enum.find(cfg["projects"], &(&1["name"] == "alpha"))
      refute Map.has_key?(alpha["queue_pins"], "LLM-12")
    end

    test "set_queue_pin with no orchestrators reads top-level pins when projects is empty", %{tmp: tmp} do
      File.write!(
        Path.join(tmp, "config.json"),
        Jason.encode!(%{"projects" => [], "queue_pins" => %{"LLM-1" => %{"model" => "opus"}}})
      )

      assert Control.set_queue_pin({:project, "alpha"}, "LLM-1", %{"effort" => "high"}) == :ok

      {:ok, cfg} = Jason.decode(File.read!(Path.join(tmp, "config.json")))
      assert cfg["projects"] == []
      assert cfg["queue_pins"] == %{"LLM-1" => %{"model" => "opus"}}
    end

    test "set_queue_pin treats a non-map pins value as empty", %{tmp: tmp} do
      File.write!(
        Path.join(tmp, "config.json"),
        Jason.encode!(%{
          "projects" => [
            %{"name" => "alpha", "queue_pins" => "legacy"},
            %{"name" => "beta"}
          ]
        })
      )

      start_orch!("alpha")

      assert Control.set_queue_pin({:project, "alpha"}, "LLM-51", %{"effort" => "high"}) == :ok
      assert_receive {:orch, _, {:set_queue_run_spec, "LLM-51", %{"effort" => "high"}}}
      {:ok, cfg} = Jason.decode(File.read!(Path.join(tmp, "config.json")))
      alpha = Enum.find(cfg["projects"], &(&1["name"] == "alpha"))
      assert alpha["queue_pins"] == %{"LLM-51" => %{"effort" => "high"}}

      assert Control.set_queue_pin({:project, "alpha"}, "LLM-51", %{"model" => "opus"}) == :ok
      assert_receive {:orch, _, {:set_queue_run_spec, "LLM-51", %{"model" => "opus"}}}
      {:ok, cfg} = Jason.decode(File.read!(Path.join(tmp, "config.json")))
      alpha = Enum.find(cfg["projects"], &(&1["name"] == "alpha"))
      assert alpha["queue_pins"]["LLM-51"]["effort"] == "high"
      assert alpha["queue_pins"]["LLM-51"]["model"] == "opus"
    end

    test "set_queue_pin with a registered name missing from config does not invent a project", %{
      tmp: tmp
    } do
      File.write!(Path.join(tmp, "config.json"), Jason.encode!(%{"projects" => [%{"name" => "beta"}]}))
      start_orch!("alpha")

      assert Control.set_queue_pin({:project, "alpha"}, "LLM-51", %{"effort" => "high"}) == :ok
      assert_receive {:orch, _, {:set_queue_run_spec, "LLM-51", %{"effort" => "high"}}}
      {:ok, cfg} = Jason.decode(File.read!(Path.join(tmp, "config.json")))
      assert cfg["projects"] == [%{"name" => "beta"}]
    end

    test "set_queue_order surfaces persist errors after the orchestrator call", %{tmp: tmp} do
      start_orch!("alpha")
      File.rm!(Path.join(tmp, "config.json"))

      assert {:error, msg} = Control.set_queue_order({:project, "alpha"}, ["LLM-51"])
      assert_receive {:orch, _, {:reorder_queue, ["LLM-51"]}}
      assert is_binary(msg)
      assert msg =~ "Failed to read"
    end

    test "set_queue_pin surfaces persist errors after the orchestrator call", %{tmp: tmp} do
      start_orch!("alpha")
      File.rm!(Path.join(tmp, "config.json"))

      assert {:error, msg} = Control.set_queue_pin({:project, "alpha"}, "LLM-51", %{"effort" => "high"})
      assert_receive {:orch, _, {:set_queue_run_spec, "LLM-51", %{"effort" => "high"}}}
      assert is_binary(msg)
      assert msg =~ "Failed to read"
    end

    test "set_agent_settings rewrites WORKFLOW.md after a successful persist", %{tmp: tmp} do
      project = %{
        "name" => "alpha",
        "linear_api_key" => @test_key,
        "linear_project_slug" => "alpha-slug",
        "agent" => "claude",
        "workspace_root" => Path.join(tmp, "ws")
      }

      File.write!(Path.join(tmp, "config.json"), Jason.encode!(%{"projects" => [project]}))
      workflow_path = Path.join(tmp, "WORKFLOW.md")
      File.write!(workflow_path, WorkflowGenerator.generate(project))

      start_supervised!(%{
        id: {:fake_store, "alpha"},
        start: {WorkflowStore, :start_link, [[name: ProjectSupervisor.via_tuple("alpha", :workflow_store), workflow_path: workflow_path]]}
      })

      start_orch!("alpha")

      assert :ok = Control.set_agent_settings({:project, "alpha"}, %{"agent" => "codex"})
      assert File.read!(workflow_path) =~ "\"kind\": \"codex\""
    end
  end

  describe "linear_status/0" do
    setup do
      override_config_dir()
    end

    test "is disconnected when no file key and no env" do
      assert Control.linear_status() == %{connected: false, masked_key: nil, source: nil}
    end

    test "reports env source and last-4 mask when only LINEAR_API_KEY is set" do
      System.put_env("LINEAR_API_KEY", @fake_key)

      assert Control.linear_status() == %{
               connected: true,
               masked_key: "••••fake",
               source: "env"
             }
    end

    test "reports config source when the file has a top-level key", %{path: path} do
      System.put_env("LINEAR_API_KEY", "lin_must_not_win")
      File.write!(path, Jason.encode!(%{"linear_api_key" => @fake_key, "projects" => []}))

      assert Control.linear_status() == %{
               connected: true,
               masked_key: "••••fake",
               source: "config"
             }
    end

    test "treats a project-stamped key as config source", %{path: path} do
      File.write!(
        path,
        Jason.encode!(%{"projects" => [%{"name" => "alpha", "linear_api_key" => @test_key}]})
      )

      assert Control.linear_status() == %{
               connected: true,
               masked_key: "••••test",
               source: "config"
             }
    end

    test "masks keys shorter than 4 characters without revealing length", %{path: path} do
      File.write!(path, Jason.encode!(%{"linear_api_key" => "ab", "projects" => []}))
      assert Control.linear_status().masked_key == "••••"
    end
  end

  describe "connect_linear/1" do
    setup do
      override_config_dir()
    end

    test "returns :empty for a blank key and does not persist" do
      assert {:error, :empty} = Control.connect_linear("")
      assert {:error, :empty} = Control.connect_linear("   \n")
      refute CymphonyConfig.exists?()
    end

    test "returns :unauthorized when Linear rejects the key" do
      stub_linear_request(fn _payload, _headers ->
        {:ok, %{status: 401, body: %{"errors" => [%{"message" => "Unauthorized"}]}}}
      end)

      log =
        capture_log(fn ->
          assert {:error, :unauthorized} = Control.connect_linear(@fake_key)
        end)

      assert log =~ "status=401"
      refute inspect(Control.linear_status()) =~ @fake_key
    end

    test "returns :invalid when Linear returns 200 without a viewer id" do
      stub_linear_request(fn _payload, _headers ->
        {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{}}}}}
      end)

      assert {:error, :invalid} = Control.connect_linear(@fake_key)
    end

    test "returns transport errors from Linear" do
      stub_linear_request(fn _payload, _headers -> {:error, :nxdomain} end)

      capture_log(fn ->
        assert {:error, {:linear_api_request, :nxdomain}} = Control.connect_linear(@fake_key)
      end)
    end

    test "returns persist errors after a successful Linear validation" do
      stub_linear_viewer()
      file = Path.join(System.tmp_dir!(), "cymphony-control-notdir-#{System.unique_integer([:positive])}")
      File.write!(file, "not-a-directory")
      Application.put_env(:cymphony_elixir, :config_dir_override, file)

      on_exit(fn -> File.rm_rf!(file) end)

      assert {:error, _reason} = Control.connect_linear(@fake_key)
    end

    test "succeeds when no project orchestrators are registered" do
      stub_linear_viewer()

      assert {:ok, %{connected: true, masked_key: "••••fake", source: "config"}} =
               Control.connect_linear(@fake_key)
    end

    test "persists the key, rewrites registered workflows, and returns masked status", %{tmp: tmp} do
      project = %{
        "name" => "alpha",
        "linear_api_key" => @test_key,
        "linear_project_slug" => "alpha-slug",
        "workspace_root" => Path.join(tmp, "ws")
      }

      File.write!(Path.join(tmp, "config.json"), Jason.encode!(%{"projects" => [project]}))
      workflow_path = Path.join(tmp, "WORKFLOW.md")
      File.write!(workflow_path, WorkflowGenerator.generate(project))

      start_supervised!(%{
        id: {:connect_store, "alpha"},
        start: {WorkflowStore, :start_link, [[name: ProjectSupervisor.via_tuple("alpha", :workflow_store), workflow_path: workflow_path]]}
      })

      start_orch!("alpha")
      stub_linear_viewer()

      assert {:ok, status} = Control.connect_linear(@fake_key)
      assert status == %{connected: true, masked_key: "••••fake", source: "config"}
      refute inspect(status) =~ @fake_key

      {:ok, cfg} = CymphonyConfig.load()
      assert cfg["linear_api_key"] == @fake_key
      assert File.read!(workflow_path) =~ @fake_key
    end
  end

  describe "list_linear_projects/0" do
    setup do
      override_config_dir()
    end

    test "returns :not_connected when no key is resolved" do
      assert {:error, :not_connected} = Control.list_linear_projects()
    end

    test "uses LINEAR_API_KEY when config.json is missing" do
      System.put_env("LINEAR_API_KEY", @fake_key)

      stub_linear_request(fn payload, _headers ->
        assert payload["query"] =~ "CymphonyLinearProjects"

        {:ok,
         %{
           status: 200,
           body: %{
             "data" => %{
               "projects" => %{
                 "nodes" => [%{"id" => "p1", "name" => "Env", "slugId" => "env-1"}],
                 "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
               }
             }
           }
         }}
      end)

      assert {:ok, [%{id: "p1", name: "Env", slug_id: "env-1"}]} = Control.list_linear_projects()
    end

    test "lists accessible projects for a stored key", %{path: path} do
      File.write!(path, Jason.encode!(%{"linear_api_key" => @fake_key, "projects" => []}))

      stub_linear_request(fn payload, headers ->
        assert payload["query"] =~ "CymphonyLinearProjects"
        assert {"Authorization", @fake_key} in headers

        {:ok,
         %{
           status: 200,
           body: %{
             "data" => %{
               "projects" => %{
                 "nodes" => [
                   %{"id" => "p1", "name" => "AI Logic", "slugId" => "ailogic-ced4159f70c4"}
                 ],
                 "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
               }
             }
           }
         }}
      end)

      assert {:ok, [%{id: "p1", name: "AI Logic", slug_id: "ailogic-ced4159f70c4"}]} =
               Control.list_linear_projects()
    end

    test "returns Linear client errors", %{path: path} do
      File.write!(path, Jason.encode!(%{"linear_api_key" => @fake_key, "projects" => []}))

      stub_linear_request(fn _payload, _headers ->
        {:ok, %{status: 401, body: "nope"}}
      end)

      capture_log(fn ->
        assert {:error, :unauthorized} = Control.list_linear_projects()
      end)
    end
  end

  describe "add_project/1" do
    setup do
      ctx = override_config_dir()
      File.write!(ctx.path, Jason.encode!(%{"linear_api_key" => @test_key, "projects" => []}))
      ctx
    end

    test "rejects missing name or slug" do
      assert {:error, :invalid_project} = Control.add_project(%{})
      assert {:error, :invalid_project} = Control.add_project(%{"name" => "Farm"})
      assert {:error, :invalid_project} = Control.add_project(%{"linear_project_slug" => "farm-abc"})
    end

    test "returns :not_connected when no Linear key is stored", %{path: path} do
      File.write!(path, Jason.encode!(%{"projects" => []}))
      System.delete_env("LINEAR_API_KEY")

      assert {:error, :not_connected} =
               Control.add_project(%{"name" => "Farm", "linear_project_slug" => "farm-abc"})
    end

    test "rejects a duplicate name after a successful add", %{tmp: tmp} do
      name = "farm-#{System.unique_integer([:positive])}"
      memory_path = write_memory_workflow!(tmp)
      Application.put_env(:cymphony_elixir, :start_project_args, {name, memory_path})

      assert {:ok, project} =
               Control.add_project(%{"name" => name, "linear_project_slug" => "farm-abc"})

      assert project["started"] == true
      assert project["name"] == name
      assert project["linear_project_slug"] == "farm-abc"
      refute Map.has_key?(project, "linear_api_key")

      on_exit(fn -> _ = ProjectSupervisor.stop_project(name) end)

      assert {:error, :duplicate_name} =
               Control.add_project(%{"name" => name, "linear_project_slug" => "farm-other"})
    end

    test "rejects a duplicate Linear slug", %{tmp: tmp} do
      name = "slug-#{System.unique_integer([:positive])}"
      memory_path = write_memory_workflow!(tmp)
      Application.put_env(:cymphony_elixir, :start_project_args, {name, memory_path})

      on_exit(fn -> _ = ProjectSupervisor.stop_project(name) end)

      assert {:ok, _project} =
               Control.add_project(%{"name" => name, "linear_project_slug" => "farm-abc"})

      assert {:error, :duplicate_slug} =
               Control.add_project(%{"name" => "Other#{System.unique_integer([:positive])}", "linear_project_slug" => "farm-abc"})
    end

    test "starts the project supervisor after persisting", %{tmp: tmp} do
      name = "started-#{System.unique_integer([:positive])}"
      memory_path = write_memory_workflow!(tmp)
      Application.put_env(:cymphony_elixir, :start_project_args, {name, memory_path})

      on_exit(fn -> _ = ProjectSupervisor.stop_project(name) end)

      assert {:ok, project} =
               Control.add_project(%{
                 "name" => name,
                 "linear_project_slug" => "slug-#{System.unique_integer([:positive])}",
                 "workspace_root" => Path.join(tmp, "ws")
               })

      assert project["started"] == true
      refute Map.has_key?(project, "linear_api_key")
      assert is_pid(ProjectSupervisor.lookup(name, :supervisor))
      assert is_pid(ProjectSupervisor.lookup(name, :orchestrator))
    end

    test "returns project_start_failed when the supervisor cannot start" do
      Application.put_env(
        :cymphony_elixir,
        :start_project_args,
        {"boom-#{System.unique_integer([:positive])}", "/missing-cymphony-workflow.md"}
      )

      assert {:error, {:project_start_failed, _reason}} =
               Control.add_project(%{"name" => "Boom", "linear_project_slug" => "boom-slug"})
    end
  end

  defp start_orch!(project) do
    spec = %{
      id: {:fake_orch, project},
      start: {FakeOrch, :start_link, [[name: ProjectSupervisor.via_tuple(project, :orchestrator), recipient: self()]]}
    }

    start_supervised!(spec)
  end

  defp override_config_dir do
    tmp = Path.join(System.tmp_dir!(), "cymphony-control-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:cymphony_elixir, :config_dir_override, tmp)

    on_exit(fn ->
      Application.delete_env(:cymphony_elixir, :config_dir_override)
      File.rm_rf!(tmp)
    end)

    %{tmp: tmp, path: Path.join(tmp, "config.json")}
  end

  defp stub_linear_viewer do
    stub_linear_request(fn _payload, _headers ->
      {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"id" => "user-1"}}}}}
    end)
  end

  defp stub_linear_request(fun) when is_function(fun, 2) do
    Application.put_env(:cymphony_elixir, :linear_graphql_opts, request_fun: fun)
  end

  defp write_memory_workflow!(dir) do
    path = Path.join(dir, "memory_workflow.md")

    File.write!(path, """
    ---
    tracker:
      kind: "memory"
    polling:
      interval_ms: 60000
    workspace:
      root: "#{Path.join(dir, "ws")}"
    agent:
      kind: "claude"
      max_concurrent_agents: 1
      max_turns: 1
    ---
    Test prompt
    """)

    path
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:cymphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:cymphony_elixir, key, value)

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
