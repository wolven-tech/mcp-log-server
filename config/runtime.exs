import Config

config :logger, :default_handler,
  config: [type: :standard_error]

config :logger,
  level: :warning

# -- MCP Log Server runtime config --

config :mcp_log_server, :log_dir, System.get_env("LOG_DIR", "/tmp/mcp-logs")

max_log_file_mb =
  case System.get_env("MAX_LOG_FILE_MB") do
    nil -> 100
    val -> String.to_integer(val)
  end

config :mcp_log_server, :max_log_file_mb, max_log_file_mb

log_retention_days =
  case System.get_env("LOG_RETENTION_DAYS") do
    nil -> nil
    val -> String.to_integer(val)
  end

config :mcp_log_server, :log_retention_days, log_retention_days

# Streamed log sources: 'name:cmd=command' entries separated by ';'
# e.g. LOG_SOURCES='fly:cmd=flyctl logs -a my-app; k8s:cmd=kubectl logs -f deploy/api'
# Validated at boot by McpLogServer.Config.LogSources.init!/0.
config :mcp_log_server, :log_sources, System.get_env("LOG_SOURCES")

# Rotation threshold for streamed source files, in MB.
# Defaults to MAX_LOG_FILE_MB so an unattended stream never grows into the
# oversized-file skip that would make it unreadable by the tools.
source_rotate_mb =
  case System.get_env("LOG_SOURCE_ROTATE_MB") do
    nil -> nil
    val -> String.to_integer(val)
  end

config :mcp_log_server, :source_rotate_mb, source_rotate_mb

# How many rotated files (<name>.1.log .. <name>.N.log) to keep. Default 3.
source_rotations =
  case System.get_env("LOG_SOURCE_ROTATIONS") do
    nil -> 3
    val -> String.to_integer(val)
  end

config :mcp_log_server, :source_rotations, source_rotations

# Declared timestamp formats: glob=format pairs separated by ';'
# e.g. LOG_TS_FORMATS='fly-*.log=%FT%T%.fZ; app*.log=epoch_ms; dev-*.log=%H:%M:%S'
# Validated at boot by McpLogServer.Config.TsFormats.init!/0.
config :mcp_log_server, :ts_formats, System.get_env("LOG_TS_FORMATS")

config :mcp_log_server, :patterns,
  fatal: System.get_env("LOG_FATAL_PATTERNS"),
  error: System.get_env("LOG_ERROR_PATTERNS"),
  warn: System.get_env("LOG_WARN_PATTERNS"),
  extra: System.get_env("LOG_EXTRA_PATTERNS")
