defmodule CymphonyElixir.AgentTest do
  use ExUnit.Case, async: true

  alias CymphonyElixir.Agent

  @claude_section %{command: "claude"}
  @codex_section %{command: "codex"}
  @antigravity_section %{command: "agy"}

  @settings_with_antigravity %{
    claude: @claude_section,
    codex: @codex_section,
    antigravity: @antigravity_section
  }

  @settings_without_antigravity %{
    claude: @claude_section,
    codex: @codex_section
  }

  test "module_for resolves known kinds" do
    assert {:ok, CymphonyElixir.Agent.Claude} = Agent.module_for("claude")
    assert {:ok, CymphonyElixir.Agent.Codex} = Agent.module_for("codex")
    assert {:ok, CymphonyElixir.Agent.Antigravity} = Agent.module_for("antigravity")
  end

  test "module_for rejects unknown kinds" do
    assert {:error, {:unknown_agent_kind, "gemini"}} = Agent.module_for("gemini")
    assert {:error, {:unknown_agent_kind, nil}} = Agent.module_for(nil)
  end

  test "known_kinds lists the supported vocabulary" do
    assert Agent.known_kinds() == ["claude", "codex", "antigravity"]
  end

  test "known_kind? accepts the closed vocabulary and rejects everything else" do
    assert Agent.known_kind?("claude")
    assert Agent.known_kind?("codex")
    assert Agent.known_kind?("antigravity")
    refute Agent.known_kind?("gemini")
    refute Agent.known_kind?("")
    refute Agent.known_kind?(nil)
    refute Agent.known_kind?(:claude)
  end

  test "section reads the matching kind section and falls back to claude" do
    assert Agent.section(@settings_with_antigravity, "claude") == @claude_section
    assert Agent.section(@settings_with_antigravity, "codex") == @codex_section
    assert Agent.section(@settings_with_antigravity, "antigravity") == @antigravity_section
    assert Agent.section(@settings_without_antigravity, "antigravity") == @claude_section
    assert Agent.section(@settings_with_antigravity, "unknown") == @claude_section
  end

  test "section falls back to claude when antigravity is present but nil" do
    settings = Map.put(@settings_with_antigravity, :antigravity, nil)
    assert Agent.section(settings, "antigravity") == @claude_section
  end

  test "put_section writes the matching kind section" do
    new_claude = %{command: "claude-next"}
    new_codex = %{command: "codex-next"}
    new_agy = %{command: "agy-next"}

    assert Agent.put_section(@settings_with_antigravity, "claude", new_claude).claude == new_claude
    assert Agent.put_section(@settings_with_antigravity, "codex", new_codex).codex == new_codex

    updated = Agent.put_section(@settings_with_antigravity, "antigravity", new_agy)
    assert updated.antigravity == new_agy
    assert updated.claude == @claude_section
  end

  describe "append_extra_args/2" do
    test "a non-empty string is appended raw as one trailing fragment" do
      assert Agent.append_extra_args(["-p"], "--verbose --flag=1") == ["-p", "--verbose --flag=1"]
    end

    test "a list is escaped item by item" do
      assert Agent.append_extra_args([], ["--foo", "bar baz"]) == ["'--foo'", "'bar baz'"]
    end

    test "non-binary list members are dropped rather than failing the run" do
      assert Agent.append_extra_args([], ["--ok", 12, :atom, nil]) == ["'--ok'"]
    end

    test "empty, nil, and unsupported shapes append nothing" do
      for extra <- ["", nil, 12, %{"antigravity" => ["--x"]}, :atom] do
        assert Agent.append_extra_args(["-p"], extra) == ["-p"]
      end

      assert Agent.append_extra_args(["-p"], []) == ["-p"]
    end
  end

  test "put_section writes claude when antigravity is absent or the kind is unknown" do
    new_sec = %{command: "fallback"}

    without = Agent.put_section(@settings_without_antigravity, "antigravity", new_sec)
    assert without.claude == new_sec
    refute Map.has_key?(without, :antigravity)

    unknown = Agent.put_section(@settings_with_antigravity, "unknown", new_sec)
    assert unknown.claude == new_sec
    assert unknown.antigravity == @antigravity_section
  end
end
