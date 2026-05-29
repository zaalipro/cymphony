defmodule CymphonyElixirWeb.Plugs.ApiAuth do
  @moduledoc """
  Bearer-token auth gate for the dashboard and observability API.

  The expected token comes from `CYMPHONY_API_TOKEN`. It is read once at boot
  (see `cache_from_env/0`, called from `CymphonyElixir.Application.start/2`) and
  cached in application env, so the common request path does not re-read the OS
  environment on every request. When the variable is unset the plug is a
  passthrough — preserving the original no-auth behavior.

  When set:
  - `Authorization: Bearer <token>` matches → ok (preferred for API clients)
  - Browser only: `?token=<token>` query param → store in session, redirect to clean URL
  - Browser only: existing valid session token → ok
  - Otherwise → 401 (logged)

  Note: the `?token=` query-param path is a deliberate convenience for opening
  the dashboard in a browser once; the token can leak via browser history or a
  `Referer` header, so API clients should prefer the `Authorization` header.
  """

  import Plug.Conn
  require Logger

  @behaviour Plug

  @app :cymphony_elixir
  @cache_key :api_token

  @doc """
  Reads `CYMPHONY_API_TOKEN` once and caches it in application env. Called at
  application boot so requests don't re-read the OS environment. A no-op when
  the variable is unset (auth stays disabled / read-through).
  """
  @spec cache_from_env() :: :ok
  def cache_from_env do
    case os_env_token() do
      nil -> :ok
      token -> Application.put_env(@app, @cache_key, token)
    end
  end

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case configured_token() do
      nil -> conn
      token -> authenticate(conn, token)
    end
  end

  defp authenticate(conn, expected) do
    cond do
      header_token(conn) == expected ->
        conn

      session_token(conn) == expected ->
        conn

      query_token(conn) == expected ->
        conn
        |> put_session(:api_token, expected)
        |> Phoenix.Controller.redirect(to: conn.request_path)
        |> halt()

      true ->
        Logger.warning("Rejected unauthenticated request to #{conn.method} #{conn.request_path}")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, ~s({"error":{"code":"unauthorized","message":"Missing or invalid token"}}))
        |> halt()
    end
  end

  defp header_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> nil
    end
  end

  defp session_token(conn) do
    case conn.private[:plug_session] do
      %{} = session -> Map.get(session, "api_token")
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp query_token(conn) do
    conn = fetch_query_params(conn)
    Map.get(conn.query_params, "token")
  end

  @doc """
  Returns the configured API token, or `nil` if auth is disabled.

  Prefers the value cached in application env at boot (`cache_from_env/0`); falls
  back to reading the OS environment when no value is cached (the no-auth default
  and tests that set the variable at runtime).
  """
  @spec configured_token() :: String.t() | nil
  def configured_token do
    case Application.get_env(@app, @cache_key) do
      token when is_binary(token) and token != "" -> token
      _ -> os_env_token()
    end
  end

  defp os_env_token do
    case System.get_env("CYMPHONY_API_TOKEN") do
      token when is_binary(token) and token != "" -> token
      _ -> nil
    end
  end
end
