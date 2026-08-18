defmodule CymphonyElixirWeb.StaticAssetController do
  @moduledoc """
  Serves the dashboard's embedded CSS and JavaScript assets.
  """

  use Phoenix.Controller, formats: []

  alias CymphonyElixirWeb.StaticAssets
  alias Plug.Conn

  @spec dashboard_css(Conn.t(), map()) :: Conn.t()
  def dashboard_css(conn, _params), do: serve(conn, "/dashboard.css")

  @spec phoenix_html_js(Conn.t(), map()) :: Conn.t()
  def phoenix_html_js(conn, _params), do: serve(conn, "/vendor/phoenix_html/phoenix_html.js")

  @spec phoenix_js(Conn.t(), map()) :: Conn.t()
  def phoenix_js(conn, _params), do: serve(conn, "/vendor/phoenix/phoenix.js")

  @spec phoenix_live_view_js(Conn.t(), map()) :: Conn.t()
  def phoenix_live_view_js(conn, _params), do: serve(conn, "/vendor/phoenix_live_view/phoenix_live_view.js")

  @spec icon(Conn.t(), map()) :: Conn.t()
  def icon(conn, %{"name" => name}) when name in ["claude.png", "codex.png", "agy.png"] do
    serve(conn, "/icons/" <> name)
  end

  def icon(conn, _params), do: send_resp(conn, 404, "Not Found")

  defp serve(conn, path) do
    case StaticAssets.fetch(path) do
      {:ok, content_type, body} ->
        conn
        |> put_resp_content_type(content_type, content_type_charset(content_type))
        |> put_resp_header("cache-control", "public, max-age=3600")
        |> send_resp(200, body)

      :error ->
        send_resp(conn, 404, "Not Found")
    end
  end

  defp content_type_charset("image/" <> _rest), do: nil
  defp content_type_charset(_content_type), do: "utf-8"
end
