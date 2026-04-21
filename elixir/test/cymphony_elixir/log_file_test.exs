defmodule CymphonyElixir.LogFileTest do
  use ExUnit.Case, async: true

  alias CymphonyElixir.LogFile

  test "default_log_file/0 uses ~/.cymphony/log" do
    assert LogFile.default_log_file() == Path.join(Path.expand("~/.cymphony/log"), "cymphony.log")
  end

  test "default_log_file/1 builds the log path under a custom root" do
    assert LogFile.default_log_file("/tmp/cymphony-logs") == "/tmp/cymphony-logs/cymphony.log"
  end
end
