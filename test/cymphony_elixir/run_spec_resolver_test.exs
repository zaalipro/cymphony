defmodule CymphonyElixir.RunSpecResolverTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

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

    test "unknown agent kind in directive falls through" do
      assert RunSpecResolver.from_description("cymphony: agent=gemini") == %{}
    end

    test "case-insensitive directive prefix" do
      assert %{model: "m2"} = RunSpecResolver.from_description("Cymphony: model=m2")
      assert %{model: "m3"} = RunSpecResolver.from_description("CYMPHONY: model=m3")
    end
  end

  # resolve/2 is exercised in a later task; the issue/1 helper stays for it.
  test "issue helper builds a valid struct" do
    assert %Issue{labels: ["a"]} = issue(labels: ["a"])
  end
end
