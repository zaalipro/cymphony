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

  @redaction "[REDACTED]"

  # A variable name is secret-shaped when one of its `_`/`-`/`.` separated
  # segments is exactly one of these words. Requiring a whole segment is what
  # keeps `MONKEY=banana` and `TOKENIZER_PATH=/x` out of the redactor while
  # still catching `ANTHROPIC_API_KEY`, `GH_TOKEN`, and `linear.api-key`.
  @secret_name_words "KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL"
  @secret_name "(?<![A-Za-z0-9_.\\-])(?:[A-Za-z0-9]+[_.\\-])*(?:#{@secret_name_words})(?:[_.\\-][A-Za-z0-9]+)*"

  # JSON first: its value may contain spaces, so the quoted form has to be
  # consumed before the bare `\\S+` forms get to it.
  @json_assignment_pattern ~s|"(#{@secret_name})"(\\s*:\\s*)"[^"]*"|
  @colon_assignment_pattern "(#{@secret_name})(\\s*:\\s*)\\S+"
  @equals_assignment_pattern "(#{@secret_name})(\\s*=\\s*)\\S+"
  @authorization_pattern "(authorization\\s*[:=]\\s*)(bearer\\s+)?\\S+"

  # Credentials with a recognizable prefix leak without any `NAME=` around them
  # (a bare `sk-…` in a CLI error message, a URL query string, a git remote).
  @bare_secret_patterns [
    "sk-[A-Za-z0-9_-]{8,}",
    "lin_api_[A-Za-z0-9_-]+",
    "ghp_[A-Za-z0-9]{20,}",
    "github_pat_[A-Za-z0-9_]{20,}",
    "xox[a-z]-[A-Za-z0-9-]+",
    "AIza[0-9A-Za-z_-]{35}"
  ]

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
  Replaces secret-shaped content in `value` with `[REDACTED]`.

  A failing agent CLI routinely prints its own environment: the retained
  failure tail is stored on the retry entry, served by `/api/v1/state`,
  rendered by the dashboard, and posted to the tracker as the abandonment
  comment, so a single crash published the live Linear API key to every one of
  those surfaces at once. Redaction covers three shapes:

  * assignments (`NAME=value`, `NAME: value`, `"NAME": "value"`) whose name has
    a `KEY`/`TOKEN`/`SECRET`/`PASSWORD`/`CREDENTIAL` segment — the name is kept
    so the diagnostic still says *which* variable was involved
  * `Authorization: Bearer <token>` and `Authorization: <token>`
  * bare credentials with a known vendor prefix (`sk-`, `lin_api_`, `ghp_`,
    `github_pat_`, `xox<a>-`, `AIza`)

  This is a redactor, not a secret scanner: an opaque high-entropy string with
  no name and no known prefix still passes through. Ordinary output — URLs,
  code, hex identifiers, words that merely contain "key" — is left alone.
  """
  @spec redact_secrets(String.t()) :: String.t()
  def redact_secrets(value) when is_binary(value) do
    value
    |> String.replace(Regex.compile!(@json_assignment_pattern, "i"), ~s|"\\1"\\2"#{@redaction}"|)
    |> String.replace(Regex.compile!(@colon_assignment_pattern, "i"), "\\1\\2#{@redaction}")
    |> String.replace(Regex.compile!(@equals_assignment_pattern, "i"), "\\1\\2#{@redaction}")
    |> String.replace(Regex.compile!(@authorization_pattern, "i"), "\\1\\2#{@redaction}")
    |> redact_bare_secrets()
  end

  defp redact_bare_secrets(value) do
    Enum.reduce(@bare_secret_patterns, value, fn pattern, acc ->
      String.replace(acc, Regex.compile!(pattern), @redaction)
    end)
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
