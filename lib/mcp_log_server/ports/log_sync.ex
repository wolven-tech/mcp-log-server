defmodule McpLogServer.Ports.LogSync do
  @moduledoc """
  Port (behaviour) for pulling logs from an external store into the local
  log directory.

  Why this port exists: `sync_logs` shells out to cloud CLIs today
  (`McpLogServer.Infrastructure.CloudSync` — gsutil/aws/az). Future adapters
  can sync from arbitrary remote sources (HTTP, SSH, object-store SDKs)
  without the use-case or the tool module changing.

  ## Options

    * `:prefix` — only sync files whose name starts with this prefix
      (`String.t()` or nil)
    * `:since` — only sync files modified strictly after this instant
      (`DateTime.t()` or nil). Parsing the user-supplied since string is the
      use-case's job; adapters receive an absolute instant or nothing.
  """

  @callback sync(source_uri :: String.t(), log_dir :: String.t(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, String.t()}
end
