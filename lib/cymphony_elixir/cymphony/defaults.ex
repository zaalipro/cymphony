defmodule CymphonyElixir.Cymphony.Defaults do
  @moduledoc """
  Canonical defaults applied when deriving a project's runtime config from
  `~/.cymphony/config.json`.

  Centralized here so the values live in exactly one place instead of being
  buried in string interpolation. These are the *generation* defaults for
  config.json-driven projects; `CymphonyElixir.Config.Schema` keeps its own
  field defaults for hand-authored `WORKFLOW.md` files that omit keys.
  """

  @active_states ["Todo", "In Progress", "Merging", "Rework"]
  @terminal_states ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
  @max_turns 20
  @output_format "stream-json"
  @polling_interval_ms 5000
  @workspace_root "~/.cymphony/workspaces"
  @max_concurrent_agents 10
  @agent_kind "claude"
  @claude_command "claude"
  @codex_command "codex"
  @codex_sandbox "workspace-write"

  @spec active_states() :: [String.t()]
  def active_states, do: @active_states

  @spec terminal_states() :: [String.t()]
  def terminal_states, do: @terminal_states

  @spec max_turns() :: pos_integer()
  def max_turns, do: @max_turns

  @spec output_format() :: String.t()
  def output_format, do: @output_format

  @spec polling_interval_ms() :: pos_integer()
  def polling_interval_ms, do: @polling_interval_ms

  @spec workspace_root() :: String.t()
  def workspace_root, do: @workspace_root

  @spec max_concurrent_agents() :: pos_integer()
  def max_concurrent_agents, do: @max_concurrent_agents

  @spec agent_kind() :: String.t()
  def agent_kind, do: @agent_kind

  @spec claude_command() :: String.t()
  def claude_command, do: @claude_command

  @spec codex_command() :: String.t()
  def codex_command, do: @codex_command

  @spec codex_sandbox() :: String.t()
  def codex_sandbox, do: @codex_sandbox
end
