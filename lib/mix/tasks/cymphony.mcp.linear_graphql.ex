defmodule Mix.Tasks.Cymphony.Mcp.LinearGraphql do
  @moduledoc """
  Run the Cymphony `linear_graphql` MCP server over stdio.

  Invoked by Claude Code via the MCP descriptor written by
  `CymphonyElixir.Mcp.ConfigWriter`. Reads newline-delimited JSON-RPC 2.0
  frames from stdin, dispatches them through
  `CymphonyElixir.Mcp.LinearGraphqlServer.handle_message/2`, and writes
  responses to stdout.

  Not a developer-facing task. Reaches Linear via `LINEAR_API_KEY` and
  `LINEAR_ENDPOINT` in the environment.
  """

  use Mix.Task

  alias CymphonyElixir.Mcp.LinearGraphqlServer

  @shortdoc false

  @impl Mix.Task
  def run(_args) do
    Application.ensure_all_started(:cymphony_elixir)

    LinearGraphqlServer.log_started(%{workspace_path: File.cwd!()})

    env = LinearGraphqlServer.env_from_system()
    loop(env)
  end

  defp loop(env) do
    case IO.read(:stdio, :line) do
      :eof ->
        :ok

      {:error, _reason} ->
        :ok

      data when is_binary(data) ->
        line = String.trim_trailing(data)

        if line != "" do
          handle_line(line, env)
        end

        loop(env)
    end
  end

  defp handle_line(line, env) do
    case LinearGraphqlServer.handle_message(line, env) do
      :no_reply -> :ok
      response when is_binary(response) -> IO.puts(response)
    end
  end
end
