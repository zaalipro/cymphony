defmodule CymphonyElixir.Shell do
  @moduledoc """
  Helpers for safely constructing shell command strings.
  """

  @doc """
  POSIX single-quote escaping: wraps `value` in single quotes, escaping any
  embedded single quotes. Safe for interpolation into `sh -c`/`zsh -c` command
  strings so that spaces and shell metacharacters are treated literally.
  """
  @spec escape(String.t()) :: String.t()
  def escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
