defmodule CymphonyElixir.Agent.RunnerMcpTest do
  @moduledoc """
  Verifies MCP descriptor injection: the Claude adapter appends `--mcp-config`
  pointing at a freshly-written descriptor when the run_spec carries one, and
  the descriptor is only derived from configs whose tracker is Linear with a
  non-empty API key (local runs only — remote workers get no descriptor).
  """

  use CymphonyElixir.TestSupport

  alias CymphonyElixir.Agent.Claude
  alias CymphonyElixir.Mcp.ConfigWriter

  setup do
    workspace = Path.join(System.tmp_dir!(), "cymphony-mcp-cmd-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)
    {:ok, workspace: workspace}
  end

  defp settings_for(tracker_kind) do
    {:ok, settings} =
      CymphonyElixir.Config.Schema.parse(%{
        "tracker" => %{"kind" => tracker_kind, "api_key" => "secret-abc", "project_slug" => "p"},
        "claude" => %{"command" => "claude"}
      })

    settings
  end

  defp run_spec(workspace, descriptor) do
    settings = settings_for("linear")

    %{
      kind: "claude",
      command: nil,
      model: nil,
      effort: nil,
      provider: nil,
      session_id: nil,
      prompt: "hello",
      workspace: workspace,
      mcp_descriptor: descriptor,
      settings: Map.from_struct(settings.claude)
    }
  end

  test "descriptor_from_config yields data only for linear trackers with an api key" do
    assert %{api_key: "secret-abc"} = ConfigWriter.descriptor_from_config(settings_for("linear"))
    assert ConfigWriter.descriptor_from_config(settings_for("memory")) == nil
  end

  test "claude adapter appends --mcp-config and writes descriptor when run_spec carries one", %{workspace: ws} do
    descriptor = ConfigWriter.descriptor_from_config(settings_for("linear"))
    {:ok, command} = Claude.build_command(run_spec(ws, descriptor))

    descriptor_path = Path.join(ws, ConfigWriter.descriptor_subpath())
    assert File.exists?(descriptor_path)
    assert command =~ "--mcp-config"
    assert command =~ descriptor_path
  end

  test "claude adapter omits --mcp-config when run_spec has no descriptor", %{workspace: ws} do
    {:ok, command} = Claude.build_command(run_spec(ws, nil))
    refute command =~ "--mcp-config"
    refute File.exists?(Path.join(ws, ConfigWriter.descriptor_subpath()))
  end

  test "claude adapter omits --mcp-config when workspace is nil" do
    descriptor = ConfigWriter.descriptor_from_config(settings_for("linear"))
    {:ok, command} = Claude.build_command(run_spec(nil, descriptor))
    refute command =~ "--mcp-config"
  end
end
