defmodule SymphonyElixir.LogFileTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.LogFile

  test "default_log_file/0 uses ~/.cymphony/log" do
    assert LogFile.default_log_file() == Path.join(Path.expand("~/.cymphony/log"), "symphony.log")
  end

  test "default_log_file/1 builds the log path under a custom root" do
    assert LogFile.default_log_file("/tmp/symphony-logs") == "/tmp/symphony-logs/symphony.log"
  end
end
