defmodule McpLogServer.Ports.LogSync do
  @moduledoc """
  Port (behaviour) for pulling logs from an external store into the local
  log directory.

  Why this port exists: `sync_logs` shells out to cloud CLIs today
  (`McpLogServer.Infrastructure.CloudSync` — gsutil/aws/az). Future adapters
  can sync from arbitrary remote sources (HTTP, SSH, object-store SDKs)
  without the use-case or the tool module changing.
  """

  @callback sync(source_uri :: String.t(), log_dir :: String.t(), prefix :: String.t() | nil) ::
              {:ok, String.t()} | {:error, String.t()}
end
