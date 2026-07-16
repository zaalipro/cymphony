defmodule CymphonyElixir.AgentTest do
  use ExUnit.Case, async: true

  alias CymphonyElixir.Agent

  test "module_for resolves known kinds" do
    assert {:ok, CymphonyElixir.Agent.Claude} = Agent.module_for("claude")
    assert {:ok, CymphonyElixir.Agent.Codex} = Agent.module_for("codex")
  end

  test "module_for rejects unknown kinds" do
    assert {:error, {:unknown_agent_kind, "gemini"}} = Agent.module_for("gemini")
    assert {:error, {:unknown_agent_kind, nil}} = Agent.module_for(nil)
  end

  test "known_kinds lists the supported vocabulary" do
    assert Agent.known_kinds() == ["claude", "codex"]
  end
end
