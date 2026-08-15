defmodule CymphonyElixirWeb.Plugs.ApiAuthTest do
  # async: false — reads/writes the OS env.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

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

  test "init/1 returns the given options unchanged" do
    assert ApiAuth.init([]) == []
    assert ApiAuth.init(foo: :bar) == [foo: :bar]
  end

  test "call/2 is a passthrough when auth is disabled" do
    System.delete_env("CYMPHONY_API_TOKEN")
    conn = build_conn(:get, "/api/v1/state") |> ApiAuth.call([])

    refute conn.halted
    refute conn.status
  end

  test "call/2 is a passthrough when the configured token is blank" do
    System.put_env("CYMPHONY_API_TOKEN", "")
    conn = build_conn(:get, "/api/v1/state") |> ApiAuth.call([])

    refute conn.halted
  end

  test "Bearer token matching the configured secret is accepted" do
    System.put_env("CYMPHONY_API_TOKEN", "secret123")

    conn =
      build_conn(:get, "/api/v1/state")
      |> put_req_header("authorization", "Bearer secret123")
      |> ApiAuth.call([])

    refute conn.halted
    refute conn.status == 401
  end

  test "wrong Bearer token is rejected with a JSON 401" do
    System.put_env("CYMPHONY_API_TOKEN", "secret123")

    conn =
      build_conn(:get, "/api/v1/state")
      |> put_req_header("authorization", "Bearer wrong")
      |> ApiAuth.call([])

    assert conn.halted
    assert conn.status == 401
    assert conn.resp_body =~ "unauthorized"
    assert get_resp_header(conn, "content-type") |> List.first() =~ "application/json"
  end

  test "non-Bearer Authorization header is treated as missing" do
    System.put_env("CYMPHONY_API_TOKEN", "secret123")

    conn =
      build_conn(:get, "/api/v1/state")
      |> put_req_header("authorization", "Basic secret123")
      |> ApiAuth.call([])

    assert conn.halted
    assert conn.status == 401
  end

  test "missing token is rejected with a JSON 401" do
    System.put_env("CYMPHONY_API_TOKEN", "secret123")
    conn = build_conn(:get, "/api/v1/state") |> ApiAuth.call([])

    assert conn.halted
    assert conn.status == 401
    assert conn.resp_body =~ "Missing or invalid token"
  end

  test "valid session token is accepted without a header or query param" do
    System.put_env("CYMPHONY_API_TOKEN", "secret123")

    conn =
      build_conn(:get, "/api/v1/state")
      |> Plug.Test.init_test_session(%{"api_token" => "secret123"})
      |> ApiAuth.call([])

    refute conn.halted
    refute conn.status == 401
  end

  test "wrong session token is rejected" do
    System.put_env("CYMPHONY_API_TOKEN", "secret123")

    conn =
      build_conn(:get, "/api/v1/state")
      |> Plug.Test.init_test_session(%{"api_token" => "nope"})
      |> ApiAuth.call([])

    assert conn.halted
    assert conn.status == 401
  end

  test "?token= matching the secret stores the session and redirects to the clean path" do
    System.put_env("CYMPHONY_API_TOKEN", "secret123")

    conn =
      build_conn(:get, "/dashboard?token=secret123&keep=1")
      |> Plug.Test.init_test_session(%{})
      |> ApiAuth.call([])

    assert conn.halted
    assert conn.status == 302
    assert get_resp_header(conn, "location") == ["/dashboard"]
    assert get_session(conn, :api_token) == "secret123"
  end

  test "wrong ?token= is rejected" do
    System.put_env("CYMPHONY_API_TOKEN", "secret123")

    conn =
      build_conn(:get, "/?token=wrong")
      |> Plug.Test.init_test_session(%{})
      |> ApiAuth.call([])

    assert conn.halted
    assert conn.status == 401
  end

  test "session lookup returns nil when plug_session is not a map" do
    System.put_env("CYMPHONY_API_TOKEN", "secret123")

    conn =
      build_conn(:get, "/api/v1/state")
      |> Map.update!(:private, &Map.put(&1, :plug_session, :not_a_map))
      |> ApiAuth.call([])

    assert conn.halted
    assert conn.status == 401
  end
end
