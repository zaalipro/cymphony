defmodule CymphonyElixirWeb.Router do
  @moduledoc """
  Router for Cymphony's observability dashboard and API.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {CymphonyElixirWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(CymphonyElixirWeb.Plugs.ApiAuth)
  end

  pipeline :api do
    plug(CymphonyElixirWeb.Plugs.ApiAuth)
  end

  scope "/", CymphonyElixirWeb do
    get("/dashboard.css", StaticAssetController, :dashboard_css)
    get("/vendor/phoenix_html/phoenix_html.js", StaticAssetController, :phoenix_html_js)
    get("/vendor/phoenix/phoenix.js", StaticAssetController, :phoenix_js)
    get("/vendor/phoenix_live_view/phoenix_live_view.js", StaticAssetController, :phoenix_live_view_js)
  end

  scope "/", CymphonyElixirWeb do
    pipe_through(:browser)

    live("/", DashboardLive, :index)
  end

  scope "/", CymphonyElixirWeb do
    pipe_through(:api)

    get("/api/v1/projects", ObservabilityApiController, :projects)
    get("/api/v1/state", ObservabilityApiController, :state)

    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/completed", ObservabilityApiController, :completed)
    match(:*, "/api/v1/completed", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/pause", ObservabilityApiController, :pause)
    match(:*, "/api/v1/pause", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/resume", ObservabilityApiController, :resume)
    match(:*, "/api/v1/resume", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/concurrency", ObservabilityApiController, :concurrency)
    match(:*, "/api/v1/concurrency", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/providers", ObservabilityApiController, :providers)
    match(:*, "/api/v1/providers", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/agent", ObservabilityApiController, :agent)
    match(:*, "/api/v1/agent", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier/harness", ObservabilityApiController, :harness)
    match(:*, "/api/v1/:issue_identifier/harness", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end
end
