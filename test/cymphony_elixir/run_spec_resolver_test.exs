defmodule CymphonyElixir.RunSpecResolverTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CymphonyElixir.Config.Schema
  alias CymphonyElixir.Linear.Issue
  alias CymphonyElixir.RunSpecResolver

  defp issue(attrs) do
    struct!(
      %Issue{id: "i-1", identifier: "MT-1", title: "t", state: "Todo"},
      attrs
    )
  end

  describe "from_labels/1" do
    test "extracts agent/model/effort/provider prefixed labels" do
      overrides =
        RunSpecResolver.from_labels([
          "agent:codex",
          "model:gpt-5.2-codex",
          "effort:high",
          "provider:cz1",
          "backend"
        ])

      assert overrides == %{
               agent_kind: "codex",
               model: "gpt-5.2-codex",
               effort: "high",
               provider: "cz1"
             }
    end

    test "ignores unrelated labels and empty values" do
      log =
        capture_log(fn ->
          assert RunSpecResolver.from_labels(["backend", "model:", "urgent"]) == %{}
        end)

      assert log =~ "empty value"
    end

    test "duplicate prefixes pick the sorted-first value and warn" do
      log =
        capture_log(fn ->
          assert %{model: "aaa"} = RunSpecResolver.from_labels(["model:zzz", "model:aaa"])
        end)

      assert log =~ "duplicate"
    end

    test "agent:antigravity is accepted as a known kind" do
      assert RunSpecResolver.from_labels(["agent:antigravity"]) == %{agent_kind: "antigravity"}
    end

    test "unknown agent kind falls through with a warning" do
      log =
        capture_log(fn ->
          assert RunSpecResolver.from_labels(["agent:gemini"]) == %{}
        end)

      assert log =~ "unknown agent"
    end

    test "non-binary entries are ignored" do
      assert RunSpecResolver.from_labels([nil, 42, "model:m1"]) == %{model: "m1"}
    end
  end

  describe "from_description/1" do
    test "parses the first cymphony: directive line" do
      description = """
      Some intro text.

      cymphony: agent=codex model=gpt-5.2-codex effort=high provider=oa1

      More text. cymphony: model=ignored-not-line-start
      """

      assert RunSpecResolver.from_description(description) == %{
               agent_kind: "codex",
               model: "gpt-5.2-codex",
               effort: "high",
               provider: "oa1"
             }
    end

    test "only the first directive line wins" do
      description = """
      cymphony: model=first
      cymphony: model=second
      """

      assert %{model: "first"} = RunSpecResolver.from_description(description)
    end

    test "agent and effort values are lowercased; model/provider preserved" do
      assert %{agent_kind: "codex", effort: "high", model: "GPT-5.2-Codex"} =
               RunSpecResolver.from_description("cymphony: agent=CODEX effort=HIGH model=GPT-5.2-Codex")
    end

    test "unknown keys are ignored, malformed lines yield nothing" do
      assert %{model: "m1"} = RunSpecResolver.from_description("cymphony: model=m1 fuel=diesel")
      assert RunSpecResolver.from_description("cymphony: not_kv_pairs at all!") == %{}
      assert RunSpecResolver.from_description(nil) == %{}
      assert RunSpecResolver.from_description("no directive here") == %{}
    end

    test "cymphony: agent=antigravity is accepted as a known kind" do
      assert RunSpecResolver.from_description("cymphony: agent=antigravity") == %{agent_kind: "antigravity"}
    end

    test "unknown agent kind in directive falls through with a warning" do
      log =
        capture_log(fn ->
          assert RunSpecResolver.from_description("cymphony: agent=gemini") == %{}
        end)

      assert log =~ "unknown agent"
    end

    test "case-insensitive directive prefix" do
      assert %{model: "m2"} = RunSpecResolver.from_description("Cymphony: model=m2")
      assert %{model: "m3"} = RunSpecResolver.from_description("CYMPHONY: model=m3")
    end
  end

  describe "resolve/2" do
    defp config_with(agent_overrides) do
      {:ok, settings} = Schema.parse(%{"agent" => agent_overrides})
      settings
    end

    test "per-field precedence: labels > directive > config" do
      issue =
        issue(
          labels: ["effort:xhigh"],
          description: "cymphony: model=directive-model effort=low"
        )

      config = config_with(%{"kind" => "claude", "model" => "config-model", "effort" => "medium"})

      resolved = RunSpecResolver.resolve(issue, config)

      assert resolved.agent_kind == "claude"
      assert resolved.model == "directive-model"
      assert resolved.effort == "xhigh"
      assert resolved.source == :labels
    end

    test "config-only issue resolves to project defaults with source :config" do
      resolved = RunSpecResolver.resolve(issue(labels: [], description: "plain"), config_with(%{"kind" => "codex"}))

      assert resolved.agent_kind == "codex"
      assert resolved.model == nil
      assert resolved.effort == nil
      assert resolved.provider == nil
      assert resolved.source == :config
    end

    test "label agent switch does not implicitly pin that kind's provider" do
      {:ok, settings} =
        Schema.parse(%{
          "agent" => %{"kind" => "claude"},
          "claude" => %{"provider" => "cz"},
          "codex" => %{"provider" => "oa"}
        })

      resolved = RunSpecResolver.resolve(issue(labels: ["agent:codex"]), settings)
      assert resolved.agent_kind == "codex"
      # provider stays nil here: rotation/config provider selection is the
      # orchestrator's job; the resolver only pins EXPLICIT provider overrides.
      assert resolved.provider == nil
      assert resolved.source == :labels
    end

    test "explicit provider label pins the provider; directive source reported when only directive contributes" do
      resolved = RunSpecResolver.resolve(issue(labels: ["provider:cz1"]), config_with(%{}))
      assert resolved.provider == "cz1"
      assert resolved.source == :labels

      directive_only = RunSpecResolver.resolve(issue(labels: [], description: "cymphony: model=m1"), config_with(%{}))
      assert directive_only.model == "m1"
      assert directive_only.source == :directive
    end

    test "agent:antigravity label wins over config kind" do
      resolved = RunSpecResolver.resolve(issue(labels: ["agent:antigravity"]), config_with(%{"kind" => "claude"}))

      assert resolved.agent_kind == "antigravity"
      assert resolved.source == :labels
    end

    test "cymphony: agent=antigravity directive wins over config kind" do
      resolved =
        RunSpecResolver.resolve(
          issue(labels: [], description: "cymphony: agent=antigravity"),
          config_with(%{"kind" => "claude"})
        )

      assert resolved.agent_kind == "antigravity"
      assert resolved.source == :directive
    end

    test "unknown agent label is dropped so config kind remains" do
      log =
        capture_log(fn ->
          resolved = RunSpecResolver.resolve(issue(labels: ["agent:gemini"]), config_with(%{"kind" => "claude"}))
          assert resolved.agent_kind == "claude"
          assert resolved.source == :config
        end)

      assert log =~ "unknown agent"
    end
  end

  test "issue helper builds a valid struct" do
    assert %Issue{labels: ["a"]} = issue(labels: ["a"])
  end
end
