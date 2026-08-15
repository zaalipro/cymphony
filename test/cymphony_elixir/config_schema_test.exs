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

  test "agent.kind accepts known kinds including antigravity and rejects unknown kinds" do
    kinds = CymphonyElixir.Agent.known_kinds()

    assert kinds == Schema.Agent.changeset(%Schema.Agent{}, %{}) |> kind_inclusion()
    assert "antigravity" in kinds

    for kind <- kinds do
      assert {:ok, settings} = Schema.parse(%{"agent" => %{"kind" => kind}})
      assert settings.agent.kind == kind
    end

    assert {:ok, settings} = Schema.parse(%{"agent" => %{"kind" => "antigravity"}})
    assert settings.agent.kind == "antigravity"

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

  test "antigravity section defaults to agy/stream-json/skip_permissions" do
    assert {:ok, settings} = Schema.parse(%{})
    assert settings.antigravity.command == "agy"
    assert settings.antigravity.output_format == "stream-json"
    assert settings.antigravity.skip_permissions == true
    assert settings.antigravity.sandbox == false
    assert settings.antigravity.providers == []
    assert settings.antigravity.extra_args == nil
    assert settings.antigravity.print_timeout == nil
    assert settings.antigravity.provider == nil
  end

  test "antigravity accepts extra_args/print_timeout/provider/providers" do
    assert {:ok, settings} =
             Schema.parse(%{
               "antigravity" => %{
                 "extra_args" => "--foo bar",
                 "print_timeout" => "30s",
                 "provider" => "cz",
                 "providers" => ["cz", "cv"]
               }
             })

    assert settings.antigravity.extra_args == "--foo bar"
    assert settings.antigravity.print_timeout == "30s"
    assert settings.antigravity.provider == "cz"
    assert settings.antigravity.providers == ["cz", "cv"]
  end

  test "antigravity rejects unknown output_format" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"antigravity" => %{"output_format" => "yaml"}})

    assert message =~ "output_format"
  end

  defp kind_inclusion(changeset) do
    changeset
    |> Ecto.Changeset.validations()
    |> Keyword.get_values(:kind)
    |> Enum.find_value(fn
      {:inclusion, kinds} when is_list(kinds) -> kinds
      _other -> nil
    end)
  end
end
