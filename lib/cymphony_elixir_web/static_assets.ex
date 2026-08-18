defmodule CymphonyElixirWeb.StaticAssets do
  @moduledoc false

  @dashboard_css_path Path.expand("../../priv/static/dashboard.css", __DIR__)
  @phoenix_html_js_path Application.app_dir(:phoenix_html, "priv/static/phoenix_html.js")
  @phoenix_js_path Application.app_dir(:phoenix, "priv/static/phoenix.js")
  @phoenix_live_view_js_path Application.app_dir(:phoenix_live_view, "priv/static/phoenix_live_view.js")
  @claude_icon_path Path.expand("../../priv/static/icons/claude.png", __DIR__)
  @codex_icon_path Path.expand("../../priv/static/icons/codex.png", __DIR__)
  @agy_icon_path Path.expand("../../priv/static/icons/agy.png", __DIR__)

  @external_resource @dashboard_css_path
  @external_resource @phoenix_html_js_path
  @external_resource @phoenix_js_path
  @external_resource @phoenix_live_view_js_path
  @external_resource @claude_icon_path
  @external_resource @codex_icon_path
  @external_resource @agy_icon_path

  @dashboard_css File.read!(@dashboard_css_path)
  @phoenix_html_js File.read!(@phoenix_html_js_path)
  @phoenix_js File.read!(@phoenix_js_path)
  @phoenix_live_view_js File.read!(@phoenix_live_view_js_path)
  @claude_icon File.read!(@claude_icon_path)
  @codex_icon File.read!(@codex_icon_path)
  @agy_icon File.read!(@agy_icon_path)

  @assets %{
    "/dashboard.css" => {"text/css", @dashboard_css},
    "/vendor/phoenix_html/phoenix_html.js" => {"application/javascript", @phoenix_html_js},
    "/vendor/phoenix/phoenix.js" => {"application/javascript", @phoenix_js},
    "/vendor/phoenix_live_view/phoenix_live_view.js" => {"application/javascript", @phoenix_live_view_js},
    "/icons/claude.png" => {"image/png", @claude_icon},
    "/icons/codex.png" => {"image/png", @codex_icon},
    "/icons/agy.png" => {"image/png", @agy_icon}
  }

  @spec fetch(String.t()) :: {:ok, String.t(), binary()} | :error
  def fetch(path) when is_binary(path) do
    case Map.fetch(@assets, path) do
      {:ok, {content_type, body}} -> {:ok, content_type, body}
      :error -> :error
    end
  end
end
