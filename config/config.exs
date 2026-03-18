import Config

# Send logger output to stderr (stdout is reserved for MCP JSON-RPC)
config :logger, :default_handler,
  config: [type: :standard_error]

# Only log warnings+ to minimize stderr noise (MCP clients may interpret stderr as errors)
config :logger,
  level: :warning
