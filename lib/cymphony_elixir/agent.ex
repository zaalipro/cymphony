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

  alias CymphonyElixir.Text

  @known_kinds ["claude", "codex", "antigravity"]

  @failure_excerpt_lines 20
  @failure_excerpt_bytes 2048
  # Redaction cost is superlinear in line length on segmented input and a port
  # line can be a megabyte, so each retained line is capped before the regexes
  # see it. 8 KB is four times the whole excerpt budget — nothing that survives
  # the byte cap below can be lost to this one.
  @failure_excerpt_line_bytes 8192

  @doc """
  Builds the bounded, sanitized, redacted excerpt every failure surface shows.

  Input is **newest line first**, because every surface that renders the result
  truncates from the front (the dashboard retry row at 120 characters) after a
  fixed `agent exited: Agent run failed: {:agent_exit, 1, "` prefix: in
  chronological order the CLI's own error line — the last thing it printed, and
  the entire point of keeping an excerpt — lands past every cut.

  Lazy on purpose (`Stream`, then `Enum.take/2`): the caller's list holds every
  line of a stream-json transcript, routinely tens of megabytes, and only the
  ~20 retained lines are worth sanitizing.
  """
  @spec failure_excerpt(Enumerable.t()) :: String.t()
  def failure_excerpt(lines) do
    lines
    |> Stream.map(&excerpt_line/1)
    |> Stream.reject(&(&1 == ""))
    |> Enum.take(@failure_excerpt_lines)
    |> Enum.join("\n")
    |> Text.truncate_trailing_bytes(@failure_excerpt_bytes)
  end

  @doc """
  `failure_excerpt/1` for a chronological transcript.

  Adapters build their error payloads from the whole collected output — an exit
  status of 0 with an unparseable stream still reaches the tracker abandonment
  comment and `/api/v1/state` — so `Enum.join(lines, "\\n")` there shipped an
  unbounded, unredacted transcript through a path the runner's own tail guard
  never touches.
  """
  @spec transcript_excerpt([term()]) :: String.t()
  def transcript_excerpt(lines) when is_list(lines) do
    lines |> Enum.reverse() |> failure_excerpt()
  end

  @doc """
  Redacts every binary inside a decoded error payload, preserving its shape.

  A `{:turn_failed, error}` payload is whatever the CLI put in its error event:
  usually a message, sometimes the whole envelope including echoed request
  headers. Map keys are field names and are left alone.
  """
  @spec redact_payload(term()) :: term()
  def redact_payload(value) when is_binary(value), do: Text.redact_secrets(value)
  def redact_payload(%{} = value), do: Map.new(value, fn {key, nested} -> {key, redact_payload(nested)} end)
  def redact_payload(value) when is_list(value), do: Enum.map(value, &redact_payload/1)
  def redact_payload(value), do: value

  defp excerpt_line(line) do
    line
    |> to_string()
    |> Text.truncate_trailing_bytes(@failure_excerpt_line_bytes)
    |> Text.strip_ansi_and_control()
    |> Text.redact_secrets()
    |> String.trim()
  end

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
