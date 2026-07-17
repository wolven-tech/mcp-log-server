defmodule McpLogServer.Tools.SyncLogs do
  @moduledoc "Pull logs from cloud storage (S3, GCS, Azure Blob) into LOG_DIR."

  @behaviour McpLogServer.Tools.Tool

  alias McpLogServer.UseCases

  @impl true
  def name, do: "sync_logs"

  @impl true
  def description,
    do: "Pull logs from cloud storage into the log directory. Supports gs://, s3://, and az:// URIs. Requires the respective CLI tool (gsutil, aws, az) to be installed."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        source: %{type: "string", description: "Cloud storage URI (e.g. \"gs://bucket/logs/\", \"s3://bucket/logs/\", \"az://container/logs/\")"},
        prefix: %{type: "string", description: "Only sync files matching this name prefix"},
        since: %{type: "string", description: "Only sync files modified after this time. ISO 8601 or relative shorthand (e.g. \"1h\", \"1d\")"}
      },
      required: ["source"]
    }
  end

  @impl true
  def execute(args, log_dir) do
    source = Map.get(args, "source", "")
    prefix = Map.get(args, "prefix")
    _since = Map.get(args, "since")

    UseCases.SyncLogs.run(source, log_dir, prefix)
  end
end
