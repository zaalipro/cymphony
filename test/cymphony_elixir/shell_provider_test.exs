defmodule CymphonyElixir.Cymphony.ShellProviderTest do
  use ExUnit.Case, async: true

  alias CymphonyElixir.Cymphony.ShellProvider

  test "load_env rejects provider names with unsafe characters before shelling out" do
    # Names are interpolated into a zsh script, so anything outside the safe
    # character class must be rejected rather than executed.
    assert {:error, :invalid_provider_name} = ShellProvider.load_env("c; rm -rf /")
    assert {:error, :invalid_provider_name} = ShellProvider.load_env("a b")
    assert {:error, :invalid_provider_name} = ShellProvider.load_env("$(whoami)")
    assert {:error, :invalid_provider_name} = ShellProvider.load_env("`id`")
    assert {:error, :invalid_provider_name} = ShellProvider.load_env("")
  end
end
