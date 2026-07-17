defmodule McpLogServer.Infrastructure.SourceStatus do
  @moduledoc """
  Public ETS registry of streamed-source worker statuses.

  Written by `McpLogServer.Infrastructure.SourceWorker` processes and read
  by `McpLogServer.Infrastructure.FileLogSource.file_info/1` to mark
  `<name>.log` entries as live in `list_logs` output.

  Statuses:

    * `:running`     — the command is spawned and streaming
    * `:backing_off` — the command exited; a supervised respawn is scheduled
    * `:dead`        — the command cannot be started at all (executable not
      found); retried at the backoff cap

  The table is created by `McpLogServer.Infrastructure.SourceSupervisor.init/1`
  so its owner is the long-lived supervisor process, surviving worker
  restarts. Reads degrade to `nil` when the table does not exist (e.g. no
  sources declared), so listing logs never depends on the ingest tree.
  """

  @table :mcp_log_server_source_status

  @type status :: :running | :backing_off | :dead

  @doc """
  Create the registry table if it does not exist. The table is owned by the
  CALLING process — call this from a long-lived process (the source
  supervisor) before any worker writes.
  """
  @spec ensure_table() :: :ok
  def ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
        :ok

      _ref ->
        :ok
    end
  end

  @spec put(String.t(), status()) :: :ok
  def put(name, status) when status in [:running, :backing_off, :dead] do
    ensure_table()
    :ets.insert(@table, {name, status})
    :ok
  end

  @doc "Return the status for a source name, or nil when unknown / no table."
  @spec get(String.t()) :: status() | nil
  def get(name) do
    case :ets.whereis(@table) do
      :undefined ->
        nil

      _ref ->
        case :ets.lookup(@table, name) do
          [{^name, status}] -> status
          [] -> nil
        end
    end
  end

  @spec delete(String.t()) :: :ok
  def delete(name) do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _ref -> :ets.delete(@table, name)
    end

    :ok
  end
end
