defmodule CymphonyElixir.LogFile do
  @moduledoc """
  Configures the on-disk log sinks.

  Two handlers are installed, both under the Cymphony config directory:

  * `:cymphony_disk_log` — the full `debug`-and-up transcript, written by OTP's
    rotating `:logger_disk_log_h` to `<config_dir>/log/cymphony.log.N` and read
    back by `cymphony logs`.
  * `:cymphony_daemon_log` — a plain, size-capped `<config_dir>/daemon.log`
    written by `:logger_std_h` at `warning` and above. The background daemon's
    stdout capture (`<config_dir>/daemon.out`) is a terminal repaint stream, so
    warnings and errors need a sink an operator can `tail` directly.

  Console behaviour is unchanged: the default console handler is removed once a
  disk sink is in place, exactly as before.
  """

  require Logger

  alias CymphonyElixir.Cymphony.Config, as: CymphonyConfig

  @handler_id :cymphony_disk_log
  @daemon_handler_id :cymphony_daemon_log
  @log_subdir "log"
  @default_log_filename "cymphony.log"
  @daemon_log_filename "daemon.log"
  @daemon_output_filename "daemon.out"
  @default_max_bytes 10 * 1024 * 1024
  @default_max_files 5
  @daemon_max_bytes 2 * 1024 * 1024
  @daemon_max_files 2

  @spec default_log_file() :: Path.t()
  def default_log_file do
    default_log_file(Path.join(CymphonyConfig.config_dir(), @log_subdir))
  end

  @spec default_log_file(Path.t()) :: Path.t()
  def default_log_file(logs_root) when is_binary(logs_root) do
    Path.join(logs_root, @default_log_filename)
  end

  @doc """
  Path of the warning-and-above log sink an operator can tail directly.
  """
  @spec daemon_log_file() :: Path.t()
  def daemon_log_file do
    Path.join(CymphonyConfig.config_dir(), @daemon_log_filename)
  end

  @doc """
  Path the background daemon's raw stdout/stderr is redirected to.

  This is a terminal capture (status TUI repaints), not a log: it exists so a
  startup crash that never reaches Logger is still recoverable.
  """
  @spec daemon_output_file() :: Path.t()
  def daemon_output_file do
    Path.join(CymphonyConfig.config_dir(), @daemon_output_filename)
  end

  @spec configure() :: :ok
  def configure do
    log_file = Application.get_env(:cymphony_elixir, :log_file, default_log_file())
    max_bytes = Application.get_env(:cymphony_elixir, :log_file_max_bytes, @default_max_bytes)
    max_files = Application.get_env(:cymphony_elixir, :log_file_max_files, @default_max_files)

    setup_disk_handler(log_file, max_bytes, max_files)
    setup_daemon_handler(Application.get_env(:cymphony_elixir, :daemon_log_file, daemon_log_file()))
  end

  defp setup_disk_handler(log_file, max_bytes, max_files) do
    expanded_path = Path.expand(log_file)
    :ok = File.mkdir_p(Path.dirname(expanded_path))
    :ok = remove_handler(@handler_id)

    case :logger.add_handler(
           @handler_id,
           :logger_disk_log_h,
           disk_log_handler_config(expanded_path, max_bytes, max_files)
         ) do
      :ok ->
        remove_default_console_handler()
        :ok

      {:error, reason} ->
        Logger.warning("Failed to configure rotating log file handler: #{inspect(reason)}")
        :ok
    end
  end

  defp setup_daemon_handler(log_file) do
    expanded_path = Path.expand(log_file)
    :ok = File.mkdir_p(Path.dirname(expanded_path))
    :ok = remove_handler(@daemon_handler_id)

    case :logger.add_handler(@daemon_handler_id, :logger_std_h, daemon_handler_config(expanded_path)) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to configure daemon log file handler: #{inspect(reason)}")
        :ok
    end
  end

  defp remove_handler(handler_id) do
    case :logger.remove_handler(handler_id) do
      :ok -> :ok
      {:error, {:not_found, ^handler_id}} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp remove_default_console_handler, do: remove_handler(:default)

  defp disk_log_handler_config(path, max_bytes, max_files) do
    %{
      level: :all,
      formatter: {:logger_formatter, %{single_line: true}},
      config: %{
        file: String.to_charlist(path),
        type: :wrap,
        max_no_bytes: max_bytes,
        max_no_files: max_files
      }
    }
  end

  defp daemon_handler_config(path) do
    %{
      level: :warning,
      formatter: {:logger_formatter, %{single_line: true}},
      config: %{
        file: String.to_charlist(path),
        type: :file,
        max_no_bytes: @daemon_max_bytes,
        max_no_files: @daemon_max_files
      }
    }
  end
end
