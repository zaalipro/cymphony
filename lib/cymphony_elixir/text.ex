defmodule CymphonyElixir.Text do
  @moduledoc """
  Text helpers shared by the log, diagnostic, and status surfaces.

  Agent CLIs and the background daemon both emit terminal-oriented output
  (ANSI colours, cursor moves, carriage returns). Anything that is stored,
  rendered in the dashboard, or posted back to the tracker goes through these
  helpers first so operators read the message instead of the escape codes.
  """

  @ansi_csi_pattern "\\x1B\\[[0-9;]*[A-Za-z]"
  @ansi_escape_pattern "\\x1B."
  @control_byte_pattern "[\\x00-\\x1F\\x7F]"

  @doc """
  Removes ANSI escape sequences and control bytes from `value`.

  Control bytes include newlines and carriage returns, so callers that need to
  keep line structure must split first and sanitize each line.
  """
  @spec strip_ansi_and_control(String.t()) :: String.t()
  def strip_ansi_and_control(value) when is_binary(value) do
    value
    |> String.replace(Regex.compile!(@ansi_csi_pattern), "")
    |> String.replace(Regex.compile!(@ansi_escape_pattern), "")
    |> String.replace(Regex.compile!(@control_byte_pattern), "")
  end

  @doc """
  Caps `value` at `max_bytes`, keeping the head.

  Diagnostics are truncated from the back because every status surface that
  renders them truncates from the front as well (the dashboard retry row cuts
  at 120 characters), so the caller puts the failure first and the oldest
  context last. Cutting on a byte boundary can split a multi-byte codepoint, so
  a truncated result is scrubbed back to valid UTF-8.
  """
  @spec truncate_trailing_bytes(String.t(), non_neg_integer()) :: String.t()
  def truncate_trailing_bytes(value, max_bytes) when is_binary(value) and is_integer(max_bytes) and max_bytes >= 0 do
    if byte_size(value) <= max_bytes do
      value
    else
      value
      |> binary_part(0, max_bytes)
      |> scrub_invalid_utf8()
    end
  end

  @doc """
  Drops byte runs that are not valid UTF-8 from `value`.

  Terminal captures and agent CLI stdout are raw bytes: a partial write, a
  byte-boundary cut, or a non-UTF-8 locale leaves sequences that `IO.puts/2`
  rejects with `ArgumentError` ("not valid character data"). Anything that
  reaches stderr, a flash, or the tracker is scrubbed first so a diagnostic is
  never replaced by a crash.
  """
  @spec scrub_invalid_utf8(String.t()) :: String.t()
  def scrub_invalid_utf8(value) when is_binary(value) do
    if String.valid?(value) do
      value
    else
      value
      |> String.chunk(:valid)
      |> Enum.filter(&String.valid?/1)
      |> Enum.join()
    end
  end
end
