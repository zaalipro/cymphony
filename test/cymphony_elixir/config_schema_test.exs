defmodule CymphonyElixir.ConfigSchemaTest do
  use ExUnit.Case, async: true

  alias CymphonyElixir.Config.Schema

  test "agent section carries kind/model/effort and moved timeouts with defaults" do
    assert {:ok, settings} = Schema.parse(%{})
    assert settings.agent.kind == "claude"
    assert settings.agent.model == nil
    assert settings.agent.effort == nil
    assert settings.agent.turn_timeout_ms == 3_600_000
    assert settings.agent.stall_timeout_ms == 300_000
  end

  test "agent.kind accepts codex and rejects unknown kinds" do
    assert {:ok, settings} = Schema.parse(%{"agent" => %{"kind" => "codex"}})
    assert settings.agent.kind == "codex"

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"agent" => %{"kind" => "gemini"}})

    assert message =~ "kind"
  end

  test "claude section is slim: providers live here, sandbox/approval vestiges are gone" do
    assert {:ok, settings} =
             Schema.parse(%{"claude" => %{"provider" => "cz", "providers" => ["cz", "cv"]}})

    assert settings.claude.command == "claude"
    assert settings.claude.output_format == "stream-json"
    assert settings.claude.provider == "cz"
    assert settings.claude.providers == ["cz", "cv"]
    refute Map.has_key?(settings.claude, :approval_policy)
    refute Map.has_key?(settings.claude, :thread_sandbox)
    refute Map.has_key?(settings.claude, :turn_sandbox_policy)
    refute Map.has_key?(settings.claude, :model)
  end

  test "codex section defaults and sandbox validation" do
    assert {:ok, settings} = Schema.parse(%{})
    assert settings.codex.command == "codex"
    assert settings.codex.sandbox == "workspace-write"
    assert settings.codex.network_access == true
    assert settings.codex.providers == []

    assert {:ok, settings} = Schema.parse(%{"codex" => %{"sandbox" => "read-only"}})
    assert settings.codex.sandbox == "read-only"

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"codex" => %{"sandbox" => "yolo"}})

    assert message =~ "sandbox"
  end
end
