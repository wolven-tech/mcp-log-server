import Config

# Send logger output to stderr (stdout is reserved for MCP JSON-RPC)
config :logger, :default_handler,
  config: [type: :standard_error]

# Only log warnings+ to minimize stderr noise (MCP clients may interpret stderr as errors)
config :logger,
  level: :warning

# -- Port wiring (clean architecture) --
# Default adapter for each port. Use-cases resolve these at call time, so
# tests can swap in fakes via `Application.put_env/3` or the `opts` argument.
config :mcp_log_server, :log_source, McpLogServer.Infrastructure.FileLogSource
config :mcp_log_server, :config_impl, McpLogServer.Infrastructure.EnvConfig
config :mcp_log_server, :log_sync, McpLogServer.Infrastructure.CloudSync
