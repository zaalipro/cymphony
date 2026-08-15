defmodule CymphonyElixir.Cymphony.ConfigPersistenceTest do
  # async: false — mutates the global :config_dir_override.
  use ExUnit.Case, async: false

  alias CymphonyElixir.Cymphony.Config, as: CymphonyConfig

  setup do
    tmp = Path.join(System.tmp_dir!(), "cymphony-cfg-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:cymphony_elixir, :config_dir_override, tmp)

    on_exit(fn ->
      Application.delete_env(:cymphony_elixir, :config_dir_override)
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp, path: Path.join(tmp, "config.json")}
  end

  defp write_config!(path, data) when is_map(data) do
    File.write!(path, Jason.encode!(data))
  end

  describe "exists?/0 and load/0" do
    test "reports a missing file and returns a read error", %{path: path} do
      refute File.exists?(path)
      refute CymphonyConfig.exists?()
      assert {:error, msg} = CymphonyConfig.load()
      assert msg =~ "Failed to read"
      assert msg =~ path
    end

    test "loads and normalizes a valid multi-project file", %{path: path} do
      write_config!(path, %{"projects" => [%{"name" => "alpha"}]})

      assert CymphonyConfig.exists?()
      assert {:ok, %{"projects" => [%{"name" => "alpha"}]}} = CymphonyConfig.load()
    end

    test "normalizes a legacy flat file on load", %{path: path} do
      write_config!(path, %{"linear_project_slug" => "farm", "linear_api_key" => "k"})

      assert {:ok, %{"projects" => [project]}} = CymphonyConfig.load()
      assert project["name"] == "farm"
      assert project["linear_api_key"] == "k"
    end

    test "returns an invalid JSON error for a corrupt file", %{path: path} do
      File.write!(path, "{not json")

      assert {:error, msg} = CymphonyConfig.load()
      assert msg =~ "Invalid JSON in #{path}"
    end
  end

  describe "save/1" do
    test "writes pretty JSON and sets 0o600 permissions", %{path: path} do
      config = %{"projects" => [%{"name" => "alpha"}]}
      assert :ok = CymphonyConfig.save(config)

      assert File.read!(path) == Jason.encode!(config, pretty: true)
      assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    end

    test "returns a mkdir error when the config dir is a file" do
      file = Path.join(System.tmp_dir!(), "cymphony-cfg-file-#{System.unique_integer([:positive])}")
      File.write!(file, "not a directory")
      Application.put_env(:cymphony_elixir, :config_dir_override, file)

      on_exit(fn -> File.rm_rf!(file) end)

      assert {:error, reason} = CymphonyConfig.save(%{"projects" => []})
      assert reason in [:eexist, :enotdir]
    end

    test "returns a write error when config.json is a directory", %{path: path} do
      File.mkdir_p!(path)

      assert {:error, msg} = CymphonyConfig.save(%{"projects" => []})
      assert msg =~ "Failed to write #{path}"
    end

    test "returns an encode error for values Jason cannot serialize", %{tmp: _tmp} do
      assert {:error, %Protocol.UndefinedError{protocol: Jason.Encoder}} =
               CymphonyConfig.save(%{"pid" => self()})
    end
  end

  describe "update_concurrency/2" do
    test "updates only the named project", %{path: path} do
      write_config!(path, %{"projects" => [%{"name" => "alpha"}, %{"name" => "beta"}]})

      assert {:ok, updated} = CymphonyConfig.update_concurrency("alpha", 4)

      assert updated["projects"] == [
               %{"name" => "alpha", "max_concurrent_agents" => 4},
               %{"name" => "beta"}
             ]

      {:ok, reloaded} = CymphonyConfig.load()
      assert reloaded == updated
    end

    test "nil project name updates every project", %{path: path} do
      write_config!(path, %{"projects" => [%{"name" => "alpha"}, %{"name" => "beta"}]})

      assert {:ok, updated} = CymphonyConfig.update_concurrency(nil, 2)
      assert Enum.all?(updated["projects"], &(&1["max_concurrent_agents"] == 2))
    end

    test "returns the load error when the file is missing" do
      assert {:error, msg} = CymphonyConfig.update_concurrency("alpha", 3)
      assert msg =~ "Failed to read"
    end

    test "applies at the top level when projects is not a list", %{path: path} do
      write_config!(path, %{"projects" => "legacy", "name" => "flat"})

      assert {:ok, updated} = CymphonyConfig.update_concurrency("ignored", 9)
      assert updated["max_concurrent_agents"] == 9
      assert updated["projects"] == "legacy"
    end
  end

  describe "update_providers/2" do
    test "updates only the named project", %{path: path} do
      write_config!(path, %{"projects" => [%{"name" => "alpha"}, %{"name" => "beta"}]})

      assert {:ok, updated} = CymphonyConfig.update_providers("alpha", ["cv1", "cz2"])
      alpha = Enum.find(updated["projects"], &(&1["name"] == "alpha"))
      beta = Enum.find(updated["projects"], &(&1["name"] == "beta"))
      assert alpha["provider"] == "cv1"
      assert alpha["providers"] == ["cv1", "cz2"]
      refute Map.has_key?(beta, "provider")
    end

    test "nil project name updates every project", %{path: path} do
      write_config!(path, %{"projects" => [%{"name" => "alpha"}, %{"name" => "beta"}]})

      assert {:ok, updated} = CymphonyConfig.update_providers(nil, ["ck1"])
      assert Enum.all?(updated["projects"], &(&1["provider"] == "ck1" and &1["providers"] == ["ck1"]))
    end

    test "rejects an empty or non-list provider list" do
      assert CymphonyConfig.update_providers("alpha", []) == {:error, :invalid_providers}
      assert CymphonyConfig.update_providers("alpha", nil) == {:error, :invalid_providers}
      assert CymphonyConfig.update_providers(nil, "cv1") == {:error, :invalid_providers}
    end

    test "returns the load error when the file is missing" do
      assert {:error, msg} = CymphonyConfig.update_providers("alpha", ["cv1"])
      assert msg =~ "Failed to read"
    end

    test "applies at the top level when projects is not a list", %{path: path} do
      write_config!(path, %{"projects" => %{"name" => "flat"}})

      assert {:ok, updated} = CymphonyConfig.update_providers("ignored", ["cz1", "cz2"])
      assert updated["provider"] == "cz1"
      assert updated["providers"] == ["cz1", "cz2"]
      assert updated["projects"] == %{"name" => "flat"}
    end
  end

  describe "update_agent_settings/2" do
    test "returns the load error when the file is missing" do
      assert {:error, msg} = CymphonyConfig.update_agent_settings("alpha", %{"model" => "opus"})
      assert msg =~ "Failed to read"
    end

    test "applies at the top level when projects is not a list", %{path: path} do
      write_config!(path, %{"projects" => nil, "effort" => "low"})

      assert :ok = CymphonyConfig.update_agent_settings("ignored", %{"model" => "opus", "effort" => ""})

      {:ok, updated} = CymphonyConfig.load()
      assert updated["model"] == "opus"
      refute Map.has_key?(updated, "effort")
      assert updated["projects"] == nil
    end
  end
end
