defmodule McpLogServer.Tools.SyncLogs do
  @moduledoc "Pull logs from cloud storage (S3, GCS, Azure Blob) into LOG_DIR."

  @behaviour McpLogServer.Tools.Tool

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

    case parse_scheme(source) do
      {:ok, :gcs, _bucket_path} ->
        run_sync("gsutil", build_gsutil_args(source, log_dir, prefix))

      {:ok, :s3, _bucket_path} ->
        run_sync("aws", build_s3_args(source, log_dir, prefix))

      {:ok, :azure, _container_path} ->
        run_sync("az", build_az_args(source, log_dir, prefix))

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_scheme("gs://" <> rest), do: {:ok, :gcs, rest}
  defp parse_scheme("s3://" <> rest), do: {:ok, :s3, rest}
  defp parse_scheme("az://" <> rest), do: {:ok, :azure, rest}

  defp parse_scheme(other) do
    {:error, "Unsupported URI scheme: #{other}. Use gs://, s3://, or az://"}
  end

  defp build_gsutil_args(source, log_dir, prefix) do
    source = if prefix, do: "#{source}#{prefix}*", else: source
    ["-m", "rsync", "-r", source, log_dir]
  end

  defp build_s3_args(source, log_dir, prefix) do
    args = ["s3", "sync", source, log_dir]
    if prefix, do: args ++ ["--exclude", "*", "--include", "#{prefix}*"], else: args
  end

  defp build_az_args(source, log_dir, prefix) do
    # az:// format: container/path
    args = ["storage", "blob", "download-batch", "--source", source, "--destination", log_dir]
    if prefix, do: args ++ ["--pattern", "#{prefix}*"], else: args
  end

  defp run_sync(cli, args) do
    case System.find_executable(cli) do
      nil ->
        {:error, "#{cli} not found. Install it to sync from cloud storage."}

      exe ->
        case System.cmd(exe, args, stderr_to_stdout: true) do
          {output, 0} ->
            lines = String.split(output, "\n", trim: true)
            {:ok, "Sync complete. #{length(lines)} lines of output from #{cli}."}

          {output, code} ->
            {:error, "#{cli} exited with code #{code}: #{String.slice(output, 0, 500)}"}
        end
    end
  end
end
