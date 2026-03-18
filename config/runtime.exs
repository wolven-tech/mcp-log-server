import Config

config :logger, :default_handler,
  config: [type: :standard_error]

config :logger,
  level: :warning
