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

  ## `:since` (list-then-copy)

  None of the three CLIs supports a modification-time filter on its bulk
  sync command, so a sync with `:since` runs in two phases instead of the
  bulk path: LIST remote objects with their timestamps, filter locally for
  modified strictly after `:since` (and matching `:prefix`), then COPY only
  the survivors:

    * `gs://` — `gsutil ls -l ...`, then chunked `gsutil -m cp <url>... <dir>`
    * `s3://` — `aws s3 ls <source> --recursive`, then `aws s3 cp` per key
    * `az://` — `az storage blob list ... -o tsv`, then
      `az storage blob download-batch --pattern <name>` per blob

  Listing output is parsed by `McpLogServer.Infrastructure.CloudListing`.
  The success message reports listed/matched/copied counts so a filter that
  matched nothing is visible, not silent.

  CAVEAT (s3): `aws s3 ls` prints modification times in the local timezone
  of the host running the CLI, with no offset in the output. They are
  treated as UTC, so on hosts not running in UTC the since cut-off can be
  off by the host's UTC offset.

  Without `:since` the original single-command bulk paths run unchanged
  (`gsutil -m rsync -r` / `aws s3 sync` / `az storage blob download-batch`).
  """

  @behaviour McpLogServer.Ports.LogSync

  alias McpLogServer.Infrastructure.CloudListing

  # Max remote URLs passed to a single `gsutil -m cp` invocation.
  @copy_chunk_size 500

  @impl true
  def sync(source, log_dir, opts \\ []) do
    prefix = Keyword.get(opts, :prefix)
    since = Keyword.get(opts, :since)

    case parse_scheme(source) do
      {:ok, scheme, bucket_path} when is_struct(since, DateTime) ->
        sync_since(scheme, source, bucket_path, log_dir, prefix, since)

      {:ok, :gcs, _bucket_path} ->
        run_bulk("gsutil", build_gsutil_args(source, log_dir, prefix))

      {:ok, :s3, _bucket_path} ->
        run_bulk("aws", build_s3_args(source, log_dir, prefix))

      {:ok, :azure, _container_path} ->
        run_bulk("az", build_az_args(source, log_dir, prefix))

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

  # -- bulk paths (no :since) --

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

  defp run_bulk(cli, args) do
    with {:ok, output} <- run_cli(cli, args) do
      lines = String.split(output, "\n", trim: true)
      {:ok, "Sync complete. #{length(lines)} lines of output from #{cli}."}
    end
  end

  # -- list-then-copy paths (:since) --

  defp sync_since(:gcs, source, _bucket_path, log_dir, prefix, since) do
    listing_target = if prefix, do: "#{source}#{prefix}*", else: source

    with {:ok, output} <- run_cli("gsutil", ["ls", "-l", listing_target]) do
      entries = CloudListing.parse_gsutil(output)
      urls = for {url, ts} <- entries, DateTime.compare(ts, since) == :gt, do: url

      copy_result =
        urls
        |> Enum.chunk_every(@copy_chunk_size)
        |> each_ok(fn chunk -> run_cli("gsutil", ["-m", "cp"] ++ chunk ++ [log_dir]) end)

      with :ok <- copy_result, do: {:ok, report(length(entries), length(urls), since)}
    end
  end

  defp sync_since(:s3, source, bucket_path, log_dir, prefix, since) do
    [bucket | path_parts] = String.split(bucket_path, "/", parts: 2)
    key_prefix = Enum.join(path_parts) <> (prefix || "")

    with {:ok, output} <- run_cli("aws", ["s3", "ls", source, "--recursive"]) do
      entries = CloudListing.parse_aws_s3(output)

      keys =
        for {key, ts} <- entries,
            String.starts_with?(key, key_prefix),
            DateTime.compare(ts, since) == :gt,
            do: key

      dest = String.trim_trailing(log_dir, "/") <> "/"

      copy_result =
        each_ok(keys, fn key -> run_cli("aws", ["s3", "cp", "s3://#{bucket}/#{key}", dest]) end)

      with :ok <- copy_result, do: {:ok, report(length(entries), length(keys), since)}
    end
  end

  defp sync_since(:azure, _source, container_path, log_dir, prefix, since) do
    [container | path_parts] = String.split(container_path, "/", parts: 2)
    blob_prefix = Enum.join(path_parts) <> (prefix || "")

    list_args =
      ["storage", "blob", "list", "--container-name", container] ++
        ["--query", "[].[name,properties.lastModified]", "--output", "tsv"] ++
        if(blob_prefix == "", do: [], else: ["--prefix", blob_prefix])

    with {:ok, output} <- run_cli("az", list_args) do
      entries = CloudListing.parse_az_tsv(output)
      names = for {name, ts} <- entries, DateTime.compare(ts, since) == :gt, do: name

      copy_result =
        each_ok(names, fn name ->
          run_cli(
            "az",
            ["storage", "blob", "download-batch", "--source", container] ++
              ["--destination", log_dir, "--pattern", name]
          )
        end)

      with :ok <- copy_result, do: {:ok, report(length(entries), length(names), since)}
    end
  end

  defp report(_listed, 0, _since), do: "Sync complete. 0 files matched since filter."

  defp report(listed, matched, since) do
    "Sync complete. #{matched} of #{listed} files modified after " <>
      "#{DateTime.to_iso8601(since)} copied."
  end

  # Runs fun for each element, halting on the first {:error, _}.
  defp each_ok(enumerable, fun) do
    Enum.reduce_while(enumerable, :ok, fn item, :ok ->
      case fun.(item) do
        {:ok, _output} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp run_cli(cli, args) do
    case System.find_executable(cli) do
      nil ->
        {:error, "#{cli} not found. Install it to sync from cloud storage."}

      exe ->
        case System.cmd(exe, args, stderr_to_stdout: true) do
          {output, 0} ->
            {:ok, output}

          {output, code} ->
            {:error, "#{cli} exited with code #{code}: #{String.slice(output, 0, 500)}"}
        end
    end
  end
end
