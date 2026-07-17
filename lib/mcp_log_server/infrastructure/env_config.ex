defmodule McpLogServer.Infrastructure.EnvConfig do
  @moduledoc """
  `McpLogServer.Ports.Config` adapter backed by the application environment,
  which `config/runtime.exs` populates from OS environment variables
  (`LOG_DIR`, `MAX_LOG_FILE_MB`, `LOG_RETENTION_DAYS`).

  Values are read at call time so tests (and operators) can adjust them via
  `Application.put_env/3` without restarting the VM.
  """

  @behaviour McpLogServer.Ports.Config

  @impl true
  def log_dir, do: Application.fetch_env!(:mcp_log_server, :log_dir)

  @impl true
  def max_log_file_mb, do: Application.get_env(:mcp_log_server, :max_log_file_mb, 100)

  @impl true
  def log_retention_days, do: Application.get_env(:mcp_log_server, :log_retention_days)
end
