defmodule CymphonyElixirWeb.Layouts do
  @moduledoc """
  Shared layouts for the observability dashboard.
  """

  use Phoenix.Component

  @version Mix.Project.config()[:version]

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    assigns =
      assigns
      |> assign(:csrf_token, Plug.CSRFProtection.get_csrf_token())
      |> assign(:version, @version)

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <title>Cymphony Observability</title>
        <script src={"/vendor/phoenix_html/phoenix_html.js?v=#{@version}"}></script>
        <script src={"/vendor/phoenix/phoenix.js?v=#{@version}"}></script>
        <script src={"/vendor/phoenix_live_view/phoenix_live_view.js?v=#{@version}"}></script>
        <link rel="stylesheet" href={"/dashboard.css?v=#{@version}"} />
      </head>
      <body>
        {@inner_content}

        <script>
          (function() {
            var meta = document.querySelector("meta[name='csrf-token']");
            var csrfToken = meta ? meta.getAttribute("content") : null;

            if (!window.Phoenix || !window.LiveView) {
              console.error("Phoenix or LiveView not loaded");
              return;
            }

            var liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              params: {_csrf_token: csrfToken}
            });

            liveSocket.connect();
            window.liveSocket = liveSocket;
          })();
        </script>
      </body>
    </html>
    """
  end

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    ~H"""
    <main class="app-shell">
      {@inner_content}
    </main>
    """
  end
end
