defmodule CymphonyElixir.LogFileTest do
  # async: false — configure/0 installs global :logger handlers and the path
  # helpers read the global :config_dir_override.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CymphonyElixir.LogFile

  test "default_log_file/0 uses ~/.cymphony/log" do
    assert LogFile.default_log_file() == Path.join(Path.expand("~/.cymphony/log"), "cymphony.log")
  end

  test "default_log_file/1 builds the log path under a custom root" do
    assert LogFile.default_log_file("/tmp/cymphony-logs") == "/tmp/cymphony-logs/cymphony.log"
  end

  # `Application.start/2` installs both sinks unconditionally, so an
  # unconfigured suite run appends its warning noise — raw agent stdout
  # included — to the `daemon.log` an operator tails and rotates their real one.
  test "the test environment keeps both disk sinks out of the operator's config dir" do
    real_config_dir = Path.expand("~/.cymphony")

    refute String.starts_with?(Application.fetch_env!(:cymphony_elixir, :log_file), real_config_dir)
    refute String.starts_with?(Application.fetch_env!(:cymphony_elixir, :daemon_log_file), real_config_dir)

    assert {:ok, daemon_handler} = :logger.get_handler_config(:cymphony_daemon_log)
    refute String.starts_with?(List.to_string(daemon_handler.config.file), real_config_dir)
  end

  describe "with a temporary config dir" do
    setup do
      config_dir = Path.join(System.tmp_dir!(), "cymphony-log-file-#{System.unique_integer([:positive])}")
      File.mkdir_p!(config_dir)

      # The test environment pins both sinks to `tmp/test-logs` so the suite
      # never writes into the operator's real `~/.cymphony`. Drop the pins for
      # the duration of this describe block (the point is to exercise the
      # config-dir-derived defaults) and put them back afterwards — deleting
      # them outright would send every later test's log line back to the real
      # `~/.cymphony/daemon.log`.
      previous = %{
        log_file: Application.fetch_env(:cymphony_elixir, :log_file),
        daemon_log_file: Application.fetch_env(:cymphony_elixir, :daemon_log_file)
      }

      Application.delete_env(:cymphony_elixir, :log_file)
      Application.delete_env(:cymphony_elixir, :daemon_log_file)
      Application.put_env(:cymphony_elixir, :config_dir_override, config_dir)

      on_exit(fn ->
        Application.delete_env(:cymphony_elixir, :config_dir_override)
        restore_env(:log_file, previous.log_file)
        restore_env(:daemon_log_file, previous.daemon_log_file)
        :ok = LogFile.configure()
        File.rm_rf(config_dir)
      end)

      {:ok, config_dir: config_dir}
    end

    test "log paths derive from the config dir", %{config_dir: config_dir} do
      assert LogFile.default_log_file() == Path.join([config_dir, "log", "cymphony.log"])
      assert LogFile.daemon_log_file() == Path.join(config_dir, "daemon.log")
      assert LogFile.daemon_output_file() == Path.join(config_dir, "daemon.out")
    end

    test "configure/0 persists warnings to daemon.log without touching console behaviour", %{config_dir: config_dir} do
      assert :ok = LogFile.configure()

      assert {:ok, disk_handler} = :logger.get_handler_config(:cymphony_disk_log)
      assert disk_handler.module == :logger_disk_log_h
      assert disk_handler.config.type == :wrap
      assert disk_handler.config.file == String.to_charlist(Path.join([config_dir, "log", "cymphony.log"]))

      assert {:ok, daemon_handler} = :logger.get_handler_config(:cymphony_daemon_log)
      assert daemon_handler.module == :logger_std_h
      assert daemon_handler.level == :warning
      assert daemon_handler.config.type == :file
      assert daemon_handler.config.file == String.to_charlist(LogFile.daemon_log_file())
      assert daemon_handler.config.max_no_bytes > 0
      assert daemon_handler.config.max_no_files > 0

      assert {:error, {:not_found, :default}} = :logger.get_handler_config(:default)

      capture_log(fn ->
        require Logger
        Logger.warning("daemon sink warning marker")
        Logger.debug("daemon sink debug marker")
        Logger.flush()
      end)

      :ok = :logger_std_h.filesync(:cymphony_daemon_log)

      assert {:ok, contents} = File.read(LogFile.daemon_log_file())
      assert contents =~ "daemon sink warning marker"
      refute contents =~ "daemon sink debug marker"
    end
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:cymphony_elixir, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:cymphony_elixir, key)
end
