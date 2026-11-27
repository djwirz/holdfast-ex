import Config

# Not read by tests: they set everything themselves, and an inherited variable must
# not change what they run against.
if config_env() != :test do
  if port = System.get_env("PORT") do
    config :holdfast_ex,
      http_port: String.to_integer(port),
      app_origin: "http://localhost:#{port}"
  end

  if origin = System.get_env("APP_ORIGIN"), do: config(:holdfast_ex, app_origin: origin)
  if dir = System.get_env("WEB_DIST"), do: config(:holdfast_ex, web_dist: dir)

  if max = System.get_env("BID_RATE_LIMIT") do
    config :holdfast_ex, bid_rate_limit: {String.to_integer(max), 10_000}
  end

  if max = System.get_env("AUTH_RATE_LIMIT") do
    config :holdfast_ex, auth_rate_limit: {String.to_integer(max), 60_000}
  end

  if config_env() == :prod do
    config :holdfast_ex,
      alias_key: System.fetch_env!("ALIAS_KEY"),
      app_origin: System.fetch_env!("APP_ORIGIN")
  end
end
