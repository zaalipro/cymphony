defmodule CymphonyElixir.AppServerMcpTest do
  @moduledoc """
  Verifies that `Claude.AppServer.build_claude_command/6` appends an
  `--mcp-config` flag pointing at a freshly-written descriptor when, and only
  when, the active tracker is Linear with a non-empty API key.
  """

  use CymphonyElixir.TestSupport

  alias CymphonyElixir.Mcp.ConfigWriter

  setup do
    workspace = Path.join(System.tmp_dir!(), "cymphony-mcp-cmd-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)
    {:ok, workspace: workspace}
  end

  defp linear_config do
    {:ok, settings} =
      CymphonyElixir.Config.Schema.parse(%{
        "tracker" => %{"kind" => "linear", "api_key" => "secret-abc", "project_slug" => "p"},
        "claude" => %{"command" => "claude"}
      })

    settings
  end

  defp memory_config do
    {:ok, settings} =
      CymphonyElixir.Config.Schema.parse(%{
        "tracker" => %{"kind" => "memory", "api_key" => "secret-abc", "project_slug" => "p"},
        "claude" => %{"command" => "claude"}
      })

    settings
  end

  test "appends --mcp-config and writes descriptor when tracker.kind is linear", %{workspace: ws} do
    {:ok, command} = AppServer.build_claude_command("hello", %{}, nil, linear_config(), ws, nil)

    descriptor_path = Path.join(ws, ConfigWriter.descriptor_subpath())
    assert File.exists?(descriptor_path)
    assert command =~ "--mcp-config"
    assert command =~ descriptor_path
  end

  test "omits --mcp-config when tracker.kind is not linear", %{workspace: ws} do
    {:ok, command} = AppServer.build_claude_command("hello", %{}, nil, memory_config(), ws, nil)
    refute command =~ "--mcp-config"
    refute File.exists?(Path.join(ws, ConfigWriter.descriptor_subpath()))
  end

  test "omits --mcp-config for remote (SSH) workers", %{workspace: ws} do
    {:ok, command} =
      AppServer.build_claude_command("hello", %{}, nil, linear_config(), ws, "remote-host-1")

    refute command =~ "--mcp-config"
  end

  test "omits --mcp-config when workspace is nil", _ctx do
    {:ok, command} = AppServer.build_claude_command("hello", %{}, nil, linear_config(), nil, nil)
    refute command =~ "--mcp-config"
  end
end
