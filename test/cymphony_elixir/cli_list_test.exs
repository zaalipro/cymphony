defmodule CymphonyElixir.CLIListTest do
  # async: false — mutates the global :config_dir_override.
  use ExUnit.Case, async: false

  alias CymphonyElixir.CLI

  setup do
    tmp = Path.join(System.tmp_dir!(), "cymphony-cli-list-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:cymphony_elixir, :config_dir_override, tmp)
    File.write!(Path.join(tmp, "config.json"), Jason.encode!(%{"projects" => []}))

    on_exit(fn ->
      Application.delete_env(:cymphony_elixir, :config_dir_override)
      File.rm_rf!(tmp)
    end)
  end

  test "l lists projects" do
    ExUnit.CaptureIO.capture_io(fn -> assert :done = CLI.evaluate(["l"]) end)
  end

  test "list lists projects" do
    ExUnit.CaptureIO.capture_io(fn -> assert :done = CLI.evaluate(["list"]) end)
  end
end
