defmodule McpLogServer.Ports.Config do
  @moduledoc """
  Port (behaviour) for runtime configuration.

  Why this port exists: all env-derived settings (LOG_DIR, MAX_LOG_FILE_MB,
  LOG_RETENTION_DAYS) are resolved behind this single boundary and handed to
  the rest of the system as plain data — domain and application code never
  read `System.get_env/1` or `Application.get_env/3` for these settings
  directly. Today the only adapter is
  `McpLogServer.Infrastructure.EnvConfig` (OS environment via
  `config/runtime.exs`). Future adapters can source configuration from a
  file, flags, or a control plane without touching callers.

  Log-level patterns follow the same philosophy via
  `McpLogServer.Config.Patterns`: env-provided pattern strings are compiled
  once at startup and exposed to pure domain code as data.
  """

  @callback log_dir() :: String.t()
  @callback max_log_file_mb() :: pos_integer()
  @callback log_retention_days() :: integer() | nil
end
