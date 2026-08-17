defmodule CymphonyElixir.DaemonTest do
  use ExUnit.Case, async: true

  alias CymphonyElixir.Daemon

  setup do
    root = Path.join(System.tmp_dir!(), "cymphony-daemon-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, root: root}
  end

  describe "executable_path/1" do
    test "prefers the Burrito wrapper path over escript and progname", %{root: root} do
      wrapper = executable!(root, "cymphony-wrapper")
      escript = executable!(root, "cymphony-escript")

      lookups =
        lookups(%{
          burrito_bin_path: fn -> wrapper end,
          escript_name: fn -> String.to_charlist(escript) end,
          progname: fn -> {:ok, [[~c"cymphony"]]} end
        })

      assert {:ok, ^wrapper} = Daemon.executable_path(lookups)
    end

    test "falls back to the escript path when not running under Burrito", %{root: root} do
      escript = executable!(root, "cymphony-escript")

      assert {:ok, ^escript} = Daemon.executable_path(lookups(%{escript_name: fn -> String.to_charlist(escript) end}))
    end

    test "falls back to the launcher progname when there is no escript name", %{root: root} do
      binary = executable!(root, "cymphony-progname")

      lookups =
        lookups(%{
          escript_name: fn -> :undefined end,
          progname: fn -> {:ok, [[String.to_charlist(binary)], [~c"ignored"]]} end
        })

      assert {:ok, ^binary} = Daemon.executable_path(lookups)
    end

    test "ignores the Erlang launcher progname and resolves cymphony on PATH", %{root: root} do
      binary = executable!(root, "cymphony")

      lookups =
        lookups(%{
          progname: fn -> {:ok, [[~c"erlexec"]]} end,
          find_executable: fn "cymphony" -> binary end
        })

      assert {:ok, ^binary} = Daemon.executable_path(lookups)
    end

    test "skips candidates that are not executable files", %{root: root} do
      not_executable = Path.join(root, "cymphony-data")
      File.write!(not_executable, "not a program")
      wrapper = executable!(root, "cymphony-wrapper")

      lookups =
        lookups(%{
          burrito_bin_path: fn -> root end,
          escript_name: fn -> String.to_charlist(not_executable) end,
          progname: fn -> {:ok, [[String.to_charlist(wrapper)]]} end
        })

      assert {:ok, ^wrapper} = Daemon.executable_path(lookups)
    end

    test "aborts with an operator-readable error when nothing resolves" do
      assert {:error, message} = Daemon.executable_path(lookups(%{escript_name: fn -> ~c"   " end}))

      assert message =~ "Cannot determine the Cymphony executable"
      assert message =~ "PATH"
      refute message =~ "nohup"
    end

    test "resolves an existing file with the real system lookups" do
      case Daemon.executable_path() do
        {:ok, path} -> assert File.exists?(path)
        {:error, message} -> assert message =~ "cymphony"
      end
    end
  end

  describe "background_command/3" do
    test "detaches from the terminal, escapes every token, and reports the child pid" do
      command = Daemon.background_command("/opt/my apps/cymphony", ["project", "A B"], "/logs/da emon.out")

      assert command ==
               "nohup '/opt/my apps/cymphony' 'project' 'A B' > '/logs/da emon.out' 2>&1 </dev/null & " <>
                 "printf 'cymphony-daemon-pid=%s\\n' \"$!\""
    end

    test "the emitted pid is the detached process, and it outlives the launcher shell" do
      {output, 0} =
        System.cmd("sh", ["-c", Daemon.background_command("/bin/sleep", ["5"], "/dev/null")], stderr_to_stdout: true)

      assert {pid, ""} = Daemon.split_launcher_pid(output)
      assert {_, 0} = System.cmd("kill", ["-0", pid], stderr_to_stdout: true)
      System.cmd("kill", ["-TERM", pid], stderr_to_stdout: true)
    end
  end

  describe "split_launcher_pid/1" do
    test "separates the marked pid line from the operator-facing output" do
      assert Daemon.split_launcher_pid("nohup: redirecting\ncymphony-daemon-pid=4242\n") ==
               {"4242", "nohup: redirecting\n"}
    end

    test "returns nil when no pid line was emitted" do
      assert Daemon.split_launcher_pid("sh: cymphony: not found\n") == {nil, "sh: cymphony: not found\n"}
    end

    test "returns nil when the shell produced an empty pid" do
      assert Daemon.split_launcher_pid("cymphony-daemon-pid=\n") == {nil, ""}
    end
  end

  describe "startup_failure_message/3" do
    test "surfaces a sanitized, bounded tail of the daemon output", %{root: root} do
      log = Path.join(root, "daemon.out")
      frames = Enum.map_join(1..12, "", fn n -> "\e[2J\e[Hline-#{n}\n" end)
      File.write!(log, frames <> "** (RuntimeError) boom\n")

      message = Daemon.startup_failure_message(log, "", 5_000)

      assert message =~ "no pidfile appeared within 5000ms"
      assert message =~ "Last daemon output from #{log}"
      assert message =~ "  ** (RuntimeError) boom"
      assert message =~ "line-12"
      assert message =~ "line-6"
      refute message =~ "line-4"
      refute message =~ "\e["
    end

    test "reports launcher output and a missing daemon log", %{root: root} do
      log = Path.join(root, "absent.out")

      message = Daemon.startup_failure_message(log, "sh: cymphony: command not found\n", 5_000)

      assert message =~ "Launcher output:\n  sh: cymphony: command not found"
      assert message =~ "No daemon output was captured in #{log}"
      assert message =~ "--daemon-internal"
    end

    test "treats an empty daemon log as no output", %{root: root} do
      log = Path.join(root, "empty.out")
      File.write!(log, "")

      assert Daemon.startup_failure_message(log, "", 250) =~ "No daemon output was captured"
    end

    test "names a daemon that died before writing its pidfile", %{root: root} do
      log = Path.join(root, "died.out")
      File.write!(log, "** (MatchError) no match of right hand side value: []\n")

      message = Daemon.startup_failure_message(log, "", :exited)

      assert message =~ "the daemon exited before writing its pidfile"
      refute message =~ "no pidfile appeared within"
      assert message =~ "MatchError"
    end

    test "survives a daemon log whose tail cut splits a multi-byte character", %{root: root} do
      log = Path.join(root, "boxdrawing.out")
      # `read_tail/1` seeks to a byte offset, so the first retained bytes are
      # routinely the middle of one of the status TUI's box-drawing glyphs.
      # `IO.puts(:stderr, …)` raises ArgumentError on that, which would replace
      # the diagnostic with a crash.
      File.write!(log, String.duplicate("╭─────╮\n", 4_000) <> "** (RuntimeError) boom\n")

      message = Daemon.startup_failure_message(log, "", 5_000)

      assert String.valid?(message)
      assert message =~ "** (RuntimeError) boom"
      assert ExUnit.CaptureIO.capture_io(fn -> IO.puts(message) end) =~ "boom"
    end

    test "reads only the tail of a large daemon log", %{root: root} do
      log = Path.join(root, "big.out")
      File.write!(log, "EARLY-MARKER\n" <> String.duplicate("filler line padding\n", 1_000) <> "LATE-ERROR\n")

      message = Daemon.startup_failure_message(log, "", 5_000)

      assert message =~ "LATE-ERROR"
      refute message =~ "EARLY-MARKER"
    end
  end

  defp lookups(overrides) do
    Map.merge(
      %{
        burrito_bin_path: fn -> :not_in_burrito end,
        escript_name: fn -> ~c"" end,
        progname: fn -> :error end,
        find_executable: fn _name -> nil end
      },
      overrides
    )
  end

  defp executable!(root, name) do
    path = Path.join(root, name)
    File.write!(path, "#!/bin/sh\nexit 0\n")
    File.chmod!(path, 0o755)
    path
  end
end
