import Config

config :phoenix, :json_library, Jason

config :cymphony_elixir, CymphonyElixirWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: CymphonyElixirWeb.ErrorHTML, json: CymphonyElixirWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: CymphonyElixir.PubSub,
  live_view: [signing_salt: "cymphony-live-view"],
  secret_key_base: String.duplicate("s", 64),
  check_origin: false,
  server: false
