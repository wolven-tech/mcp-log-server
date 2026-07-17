defmodule McpLogServer.Infrastructure.CloudSync do
  @moduledoc """
  `McpLogServer.Ports.LogSync` adapter that pulls logs from cloud object
  storage into LOG_DIR by shelling out to the vendor CLI:

    * `gs://` — gsutil
    * `s3://` — aws
    * `az://` — az

  This is infrastructure: it owns URI-scheme dispatch, CLI argument
  construction, and process execution. Nothing above this layer knows which
  CLI ran.
  """

  @behaviour McpLogServer.Ports.LogSync

  @impl true
  def sync(source, log_dir, prefix) do
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
