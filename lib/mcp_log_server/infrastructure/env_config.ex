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

  # -- Streamed source (LOG_SOURCES) settings --
  # Not part of the Ports.Config behaviour: only the infrastructure-level
  # source workers consume them, so widening the port would leak an
  # ingest-only concern into every config fake.

  @doc """
  Rotation threshold for streamed source files, in MB
  (`LOG_SOURCE_ROTATE_MB`). Defaults to `max_log_file_mb/0` so a live file
  is rotated before it could ever trip the oversized-file skip.
  """
  @spec source_rotate_mb() :: pos_integer()
  def source_rotate_mb,
    do: Application.get_env(:mcp_log_server, :source_rotate_mb) || max_log_file_mb()

  @doc "Number of rotated files kept per source (`LOG_SOURCE_ROTATIONS`, default 3, min 1)."
  @spec source_rotations() :: pos_integer()
  def source_rotations,
    do: max(Application.get_env(:mcp_log_server, :source_rotations, 3), 1)
end
