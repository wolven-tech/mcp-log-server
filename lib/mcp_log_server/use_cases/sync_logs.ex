defmodule McpLogServer.UseCases.SyncLogs do
  @moduledoc """
  Use-case: pull logs from an external store into the local log directory
  through the `McpLogServer.Ports.LogSync` port.
  """

  alias McpLogServer.UseCases.Deps

  @spec run(String.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def run(source_uri, log_dir, prefix, opts \\ []) do
    Deps.log_sync(opts).sync(source_uri, log_dir, prefix)
  end
end
