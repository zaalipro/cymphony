defmodule CymphonyElixir.ShellProviderPrefixTest do
  use ExUnit.Case, async: true

  alias CymphonyElixir.Cymphony.ShellProvider

  test "parse_env_output keeps only lines matching the given prefixes" do
    lines = """
    ANTHROPIC_API_KEY=a
    OPENAI_API_KEY=o
    CODEX_HOME=/x
    PATH=/usr/bin
    API_TIMEOUT=30
    """

    claude = ShellProvider.parse_env_output(lines, ["ANTHROPIC_", "API_TIMEOUT", "CLAUDE_CODE_"])
    assert claude == %{"ANTHROPIC_API_KEY" => "a", "API_TIMEOUT" => "30"}

    codex = ShellProvider.parse_env_output(lines, ["OPENAI_", "CODEX_", "API_TIMEOUT"])
    assert codex == %{"OPENAI_API_KEY" => "o", "CODEX_HOME" => "/x", "API_TIMEOUT" => "30"}
  end

  test "values containing = are preserved whole" do
    assert ShellProvider.parse_env_output("OPENAI_BASE_URL=https://x?a=b", ["OPENAI_"]) ==
             %{"OPENAI_BASE_URL" => "https://x?a=b"}
  end
end
