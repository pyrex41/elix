import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :backend, Backend.Repo,
  database: Path.expand("../backend_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :backend, BackendWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "4UhImrOHEeEvwhoEdtxdzXCQIPyN0OForvYCMT/lWu07B9rdSHaQeYFsFxHDV4om",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

config :backend,
  public_base_url: "http://localhost:4002",
  asset_base_url: "http://localhost:4002",
  video_generation_model: "veo3",
  replicate_webhook_url: nil
