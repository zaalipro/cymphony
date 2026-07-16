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

  # from_description/1 and resolve/2 are exercised in later tasks; the issue/1
  # helper stays here for them.
  test "issue helper builds a valid struct" do
    assert %Issue{labels: ["a"]} = issue(labels: ["a"])
  end
end
