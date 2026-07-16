defmodule CymphonyElixir.Cymphony.ConfigAgentSettingsTest do
  # async: false — mutates the global :config_dir_override.
  use ExUnit.Case, async: false

  alias CymphonyElixir.Cymphony.Config, as: CymphonyConfig

  describe "update_agent_settings/2" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "cymphony-agentcfg-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      File.write!(
        Path.join(tmp, "config.json"),
        ~s({"projects": [{"name": "alpha"}, {"name": "beta"}]})
      )

      Application.put_env(:cymphony_elixir, :config_dir_override, tmp)

      on_exit(fn ->
        Application.delete_env(:cymphony_elixir, :config_dir_override)
        File.rm_rf!(tmp)
      end)

      :ok
    end

    test "writes agent/model/effort keys onto the named project only" do
      assert :ok =
               CymphonyConfig.update_agent_settings("alpha", %{
                 "agent" => "codex",
                 "model" => "gpt-5.2-codex",
                 "effort" => "high"
               })

      {:ok, config} = CymphonyConfig.load()
      {:ok, alpha} = CymphonyConfig.find_project(config, "alpha")
      assert alpha["agent"] == "codex"
      assert alpha["model"] == "gpt-5.2-codex"
      assert alpha["effort"] == "high"

      {:ok, beta} = CymphonyConfig.find_project(config, "beta")
      refute Map.has_key?(beta, "agent")
    end

    test "nil project applies to all projects" do
      assert :ok = CymphonyConfig.update_agent_settings(nil, %{"effort" => "low"})

      {:ok, config} = CymphonyConfig.load()

      for name <- ["alpha", "beta"] do
        {:ok, project} = CymphonyConfig.find_project(config, name)
        assert project["effort"] == "low"
      end
    end

    test "omitted keys are left untouched; empty string clears" do
      assert :ok = CymphonyConfig.update_agent_settings("alpha", %{"model" => "opus"})
      assert :ok = CymphonyConfig.update_agent_settings("alpha", %{"effort" => "high"})

      {:ok, config} = CymphonyConfig.load()
      {:ok, alpha} = CymphonyConfig.find_project(config, "alpha")
      assert alpha["model"] == "opus"
      assert alpha["effort"] == "high"

      assert :ok = CymphonyConfig.update_agent_settings("alpha", %{"model" => ""})

      {:ok, config} = CymphonyConfig.load()
      {:ok, alpha} = CymphonyConfig.find_project(config, "alpha")
      refute Map.has_key?(alpha, "model")
      assert alpha["effort"] == "high"
    end

    test "rejects unknown agent kinds" do
      assert {:error, :invalid_agent_kind} =
               CymphonyConfig.update_agent_settings("alpha", %{"agent" => "gemini"})
    end
  end
end
