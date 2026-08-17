defmodule CymphonyElixir.Daemon do
  @moduledoc """
  Helpers for launching and diagnosing the detached background daemon.

  `cymphony start` re-executes this binary under `nohup`, so the running
  process has to be able to name its own executable. That is not the same
  lookup for every build:

  * Burrito-wrapped releases boot the BEAM directly (`erlexec ... -s elixir
    start_cli`), so `:escript.script_name/0` is empty and `-progname` is the
    Erlang launcher rather than the wrapper. The wrapper exports its own
    absolute path instead, which `Burrito.Util.Args.get_bin_path/0` reads.
  * Escript builds are started through `escript:start/0`, so
    `:escript.script_name/0` is authoritative.
  * Anything else falls back to the launcher `progname` and finally to
    `cymphony` on `PATH`.

  Every candidate is validated before use: an unqualified or non-executable
  argv[0] produced a `nohup` command that failed silently in the background,
  after the CLI had already reported success.
  """

  alias Burrito.Util.Args
  alias CymphonyElixir.Shell
  alias CymphonyElixir.Text

  @fallback_executable "cymphony"
  @log_tail_bytes 8_192
  @log_tail_lines 8
  @pid_marker "cymphony-daemon-pid="

  @typedoc """
  Overridable system lookups, injected by tests. Missing keys use the real
  system functions.
  """
  @type lookups :: %{optional(atom()) => (... -> term())}

  @doc """
  Resolves the absolute path of the executable that should be re-launched in
  the background.

  Returns `{:error, message}` rather than a blank or unqualified command when
  no candidate resolves to an executable file, so the caller can abort instead
  of emitting a broken `nohup` command.
  """
  @spec executable_path(lookups()) :: {:ok, String.t()} | {:error, String.t()}
  def executable_path(lookups \\ %{}) do
    resolved = Map.merge(default_lookups(), lookups)

    case Enum.find_value(candidates(resolved), &usable_path(&1, resolved)) do
      nil -> {:error, unresolved_message()}
      path -> {:ok, path}
    end
  end

  @doc """
  Builds the `sh -c` command that detaches `executable` from the terminal and
  captures its stdout/stderr in `log_path`.

  The command also prints the detached child's OS pid on a marked line. The
  pidfile is written by the daemon itself, late in its own boot, so without a
  pid to probe the caller cannot tell a slow start (a Burrito binary
  decompresses its payload and deletes the previous version's install tree
  before the BEAM starts) from a dead one, and has to guess with a timeout.
  """
  @spec background_command(String.t(), [String.t()], Path.t()) :: String.t()
  def background_command(executable, args, log_path) do
    escaped_command = Enum.map_join([executable | args], " ", &Shell.escape/1)

    "nohup #{escaped_command} > #{Shell.escape(log_path)} 2>&1 </dev/null & " <>
      "printf '#{@pid_marker}%s\\n' \"$!\""
  end

  @doc """
  Splits launcher output into the detached child's pid and the rest of the text.

  The pid line is emitted by `background_command/3`; `nil` when it is missing
  (a shell that does not support `$!`, or a launcher that failed before the
  `printf`). The remaining text is what the operator should see, so the marker
  line never reaches a diagnostic.
  """
  @spec split_launcher_pid(String.t()) :: {String.t() | nil, String.t()}
  def split_launcher_pid(output) when is_binary(output) do
    {pid_lines, rest} =
      output
      |> String.split("\n")
      |> Enum.split_with(&String.starts_with?(&1, @pid_marker))

    {launcher_pid(pid_lines), Enum.join(rest, "\n")}
  end

  @doc """
  Explains why a background start never produced a pidfile.

  `cause` is the elapsed wait in milliseconds, or `:exited` when the detached
  process was gone before it wrote its pidfile. Includes whatever the launcher
  printed plus a bounded, sanitized tail of the daemon output file, because the
  daemon's own stdout is the only place a startup crash is recorded.
  """
  @spec startup_failure_message(Path.t(), String.t(), non_neg_integer() | :exited) :: String.t()
  def startup_failure_message(log_path, launcher_output, cause) do
    [headline(cause), launcher_section(launcher_output), log_section(log_path)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp headline(:exited) do
    "Cymphony failed to start in background: the daemon exited before writing its pidfile."
  end

  defp headline(timeout_ms) do
    "Cymphony failed to start in background: no pidfile appeared within #{timeout_ms}ms."
  end

  defp launcher_pid([line | _rest]) do
    case line |> String.replace_prefix(@pid_marker, "") |> String.trim() do
      "" -> nil
      pid -> pid
    end
  end

  defp launcher_pid(_lines), do: nil

  defp default_lookups do
    %{
      burrito_bin_path: &burrito_bin_path/0,
      escript_name: &:escript.script_name/0,
      progname: fn -> :init.get_argument(:progname) end,
      find_executable: &System.find_executable/1,
      executable?: &executable_file?/1
    }
  end

  defp burrito_bin_path, do: Args.get_bin_path()

  defp candidates(lookups) do
    [
      burrito_candidate(lookups.burrito_bin_path.()),
      escript_candidate(lookups.escript_name.()),
      progname_candidate(lookups.progname.()),
      @fallback_executable
    ]
  end

  defp burrito_candidate(path) when is_binary(path), do: path
  defp burrito_candidate(_path), do: nil

  defp escript_candidate(name) when is_list(name), do: List.to_string(name)
  defp escript_candidate(_name), do: nil

  defp progname_candidate({:ok, [[name] | _rest]}) when name != ~c"erl" and name != ~c"erlexec" do
    List.to_string(name)
  end

  defp progname_candidate(_argument), do: nil

  defp usable_path(nil, _lookups), do: nil

  defp usable_path(candidate, lookups) do
    case String.trim(candidate) do
      "" -> nil
      trimmed -> qualify(trimmed, lookups)
    end
  end

  # A bare name is only usable if PATH resolves it; anything path-like has to
  # point at a real executable file.
  defp qualify(candidate, lookups) do
    if String.contains?(candidate, "/") do
      expanded = Path.expand(candidate)
      if lookups.executable?.(expanded), do: expanded, else: nil
    else
      lookups.find_executable.(candidate)
    end
  end

  defp executable_file?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _other -> false
    end
  end

  defp unresolved_message do
    "Cannot determine the Cymphony executable to launch in background " <>
      "(no Burrito wrapper path, escript path, launcher progname, or `#{@fallback_executable}` on PATH). " <>
      "Run Cymphony in the foreground, or put the `#{@fallback_executable}` binary on PATH."
  end

  defp launcher_section(launcher_output) do
    case format_output(launcher_output) do
      "" -> ""
      text -> "Launcher output:\n" <> text
    end
  end

  defp log_section(log_path) do
    case log_path |> read_tail() |> format_output() do
      "" ->
        "No daemon output was captured in #{log_path}. Run `cymphony --daemon-internal` in the foreground to see the failure."

      text ->
        "Last daemon output from #{log_path}:\n" <> text
    end
  end

  # `daemon.out` is a raw terminal capture read from an arbitrary byte offset,
  # so its first line is routinely a split multi-byte codepoint (the status TUI
  # draws box-drawing characters) and a killed process can leave a partial
  # write anywhere. The message this builds is printed with
  # `IO.puts(:stderr, …)`, which raises `ArgumentError` on invalid character
  # data — the startup diagnostic would be replaced by a crash — so scrub
  # before anything else touches it.
  defp format_output(output) do
    output
    |> to_string()
    |> Text.scrub_invalid_utf8()
    |> String.split("\n")
    |> Enum.map(&(&1 |> Text.strip_ansi_and_control() |> String.trim()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(-@log_tail_lines)
    |> Enum.map_join("\n", &("  " <> &1))
  end

  # The daemon log is a terminal capture and can be large; only the tail is
  # read into memory.
  defp read_tail(log_path) do
    case File.stat(log_path) do
      {:ok, %File.Stat{size: size}} -> read_tail_bytes(log_path, max(size - @log_tail_bytes, 0))
      {:error, _reason} -> ""
    end
  end

  defp read_tail_bytes(log_path, offset) do
    read =
      File.open(log_path, [:read, :binary], fn device ->
        _ = :file.position(device, offset)
        IO.binread(device, :eof)
      end)

    case read do
      {:ok, data} when is_binary(data) -> data
      _other -> ""
    end
  end
end
