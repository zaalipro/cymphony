defmodule CymphonyElixirWeb.Plugs.ApiAuthTest do
  # async: false — reads/writes the OS env.
  use ExUnit.Case, async: false

  alias CymphonyElixirWeb.Plugs.ApiAuth

  setup do
    orig_env = System.get_env("CYMPHONY_API_TOKEN")

    on_exit(fn ->
      if orig_env,
        do: System.put_env("CYMPHONY_API_TOKEN", orig_env),
        else: System.delete_env("CYMPHONY_API_TOKEN")
    end)

    :ok
  end

  test "configured_token/0 is nil when the env var is unset (auth disabled)" do
    System.delete_env("CYMPHONY_API_TOKEN")
    assert ApiAuth.configured_token() == nil
  end

  test "configured_token/0 is nil when the env var is blank" do
    System.put_env("CYMPHONY_API_TOKEN", "")
    assert ApiAuth.configured_token() == nil
  end

  test "configured_token/0 returns the OS env token when set" do
    System.put_env("CYMPHONY_API_TOKEN", "from-env")
    assert ApiAuth.configured_token() == "from-env"
  end
end
