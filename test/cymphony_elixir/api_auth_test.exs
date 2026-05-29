defmodule CymphonyElixirWeb.Plugs.ApiAuthTest do
  # async: false — reads/writes the OS env and the :api_token application env.
  use ExUnit.Case, async: false

  alias CymphonyElixirWeb.Plugs.ApiAuth

  setup do
    orig_env = System.get_env("CYMPHONY_API_TOKEN")
    orig_app = Application.get_env(:cymphony_elixir, :api_token)

    on_exit(fn ->
      if orig_env, do: System.put_env("CYMPHONY_API_TOKEN", orig_env), else: System.delete_env("CYMPHONY_API_TOKEN")

      if orig_app,
        do: Application.put_env(:cymphony_elixir, :api_token, orig_app),
        else: Application.delete_env(:cymphony_elixir, :api_token)
    end)

    :ok
  end

  test "configured_token/0 is nil when neither cache nor env is set" do
    Application.delete_env(:cymphony_elixir, :api_token)
    System.delete_env("CYMPHONY_API_TOKEN")
    assert ApiAuth.configured_token() == nil
  end

  test "configured_token/0 reads the OS env when nothing is cached" do
    Application.delete_env(:cymphony_elixir, :api_token)
    System.put_env("CYMPHONY_API_TOKEN", "from-env")
    assert ApiAuth.configured_token() == "from-env"
  end

  test "cache_from_env/0 caches the OS env token so requests don't re-read the environment" do
    Application.delete_env(:cymphony_elixir, :api_token)
    System.put_env("CYMPHONY_API_TOKEN", "cached-secret")

    assert ApiAuth.cache_from_env() == :ok
    assert Application.get_env(:cymphony_elixir, :api_token) == "cached-secret"

    # The cached value wins even if the OS env later changes/clears.
    System.delete_env("CYMPHONY_API_TOKEN")
    assert ApiAuth.configured_token() == "cached-secret"
  end

  test "cache_from_env/0 is a no-op when the OS env is unset (auth stays disabled)" do
    Application.delete_env(:cymphony_elixir, :api_token)
    System.delete_env("CYMPHONY_API_TOKEN")

    assert ApiAuth.cache_from_env() == :ok
    assert Application.get_env(:cymphony_elixir, :api_token) == nil
  end
end
