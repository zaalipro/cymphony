defmodule CymphonyElixir.Claude.DynamicTool do
  @moduledoc """
  Backward-compatibility placeholder for dynamic tool support.

  In Cymphony's first revision, custom tools like `linear_graphql` were
  expected to be served as orchestrator-side callbacks. That mechanism was
  superseded once Claude Code's MCP integration matured: the canonical path
  for `linear_graphql` is now a per-session stdio MCP server (see
  `CymphonyElixir.Mcp.LinearGraphqlServer` and the descriptor produced by
  `CymphonyElixir.Mcp.ConfigWriter`).

  This module is retained so the legacy `execute/3` and `tool_specs/0`
  contract remains callable. Both are no-ops — the real tool lives in the
  MCP server.

  Reference: openai/symphony SPEC §10.5 (`linear_graphql` tool contract).
  """

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(_tool, _arguments, _opts \\ []) do
    %{
      "success" => false,
      "output" => "Dynamic tools are not supported with Claude Code. Use built-in Bash/Read/Edit tools.",
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => "Dynamic tools are not supported with Claude Code."
        }
      ]
    }
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    []
  end
end
