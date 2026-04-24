defmodule CymphonyElixir.Claude.DynamicTool do
  @moduledoc """
  Placeholder for dynamic tool support with Claude Code.

  Claude Code has built-in Read, Edit, and Bash tools. Custom tools like
  `linear_graphql` are no longer needed as callbacks because Claude can
  execute `curl` commands directly via Bash when `LINEAR_API_KEY` is available
  in the environment.
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
