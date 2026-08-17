defmodule CymphonyElixir.Agent do
  @moduledoc """
  Behaviour for coding-agent CLI adapters (Claude Code, Codex, Antigravity).

  An adapter turns a normalized `run_spec` into a shell command and parses the
  process output back into one normalized `turn_result`, so the shared
  `Agent.Runner` stays agnostic of which CLI is running.

  Kind vocabulary and per-kind config sections are the EP-KINDS / EP-SECTION
  extension points: callers must go through `known_kinds/0`, `known_kind?/1`,
  `module_for/1`, `section/2`, and `put_section/3` instead of hard-coding kinds.
  """

  @type run_spec :: %{
          kind: String.t(),
          command: String.t() | nil,
          model: String.t() | nil,
          effort: String.t() | nil,
          provider: String.t() | nil,
          session_id: String.t() | nil,
          prompt: String.t(),
          workspace: Path.t() | nil,
          mcp_descriptor: map() | nil,
          settings: map()
        }

  @type turn_result :: %{
          session_id: String.t() | nil,
          result: String.t() | nil,
          usage: map() | nil,
          raw: String.t()
        }

  @callback default_command() :: String.t()
  @callback build_command(run_spec()) :: {:ok, String.t()} | {:error, term()}
  @callback parse_output([String.t()], run_spec(), (map() -> any())) ::
              {:ok, turn_result()} | {:error, term()}
  @callback auth_env_prefixes() :: [String.t()]
  @callback auth_env_fallback() :: [String.t()]

  @known_kinds ["claude", "codex", "antigravity"]

  @spec known_kinds() :: [String.t()]
  def known_kinds, do: @known_kinds

  @spec known_kind?(term()) :: boolean()
  def known_kind?(kind), do: kind in @known_kinds

  @spec module_for(term()) :: {:ok, module()} | {:error, {:unknown_agent_kind, term()}}
  def module_for("claude"), do: {:ok, CymphonyElixir.Agent.Claude}
  def module_for("codex"), do: {:ok, CymphonyElixir.Agent.Codex}
  def module_for("antigravity"), do: {:ok, CymphonyElixir.Agent.Antigravity}
  def module_for(kind), do: {:error, {:unknown_agent_kind, kind}}

  @spec section(map(), String.t()) :: map()
  def section(settings, "codex"), do: settings.codex

  def section(settings, "antigravity") do
    Map.get(settings, :antigravity) || settings.claude
  end

  def section(settings, _kind), do: settings.claude

  @doc """
  Appends a section's `extra_args` to an argv list.

  Shared by every adapter so the two accepted shapes behave identically across
  kinds: a non-empty string is trusted operator input and is appended as a raw
  trailing fragment (it may contain several flags and its own quoting), while a
  list is escaped item by item. Non-binary list members and any other value are
  dropped — `extra_args` is the escape hatch for flags Cymphony does not model,
  not a place to fail a run.
  """
  @spec append_extra_args([String.t()], term()) :: [String.t()]
  def append_extra_args(args, extra) when is_binary(extra) and extra != "", do: args ++ [extra]

  def append_extra_args(args, extra) when is_list(extra) do
    args ++
      Enum.flat_map(extra, fn
        item when is_binary(item) -> [CymphonyElixir.Shell.escape(item)]
        _ -> []
      end)
  end

  def append_extra_args(args, _extra), do: args

  @spec put_section(map(), String.t(), map()) :: map()
  def put_section(settings, "codex", sec), do: %{settings | codex: sec}

  def put_section(settings, "antigravity", sec) when is_map_key(settings, :antigravity) do
    %{settings | antigravity: sec}
  end

  def put_section(settings, _kind, sec), do: %{settings | claude: sec}
end
