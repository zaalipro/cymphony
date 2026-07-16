defmodule CymphonyElixirWeb.ControlTest do
  # async: false — mutates the global ProjectRegistry and :config_dir_override.
  use ExUnit.Case, async: false

  alias CymphonyElixir.ProjectSupervisor
  alias CymphonyElixirWeb.Control

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
  end

  defp start_orch!(project) do
    spec = %{
      id: {:fake_orch, project},
      start: {FakeOrch, :start_link, [[name: ProjectSupervisor.via_tuple(project, :orchestrator), recipient: self()]]}
    }

    start_supervised!(spec)
  end
end
