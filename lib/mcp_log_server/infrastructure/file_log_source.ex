defmodule McpLogServer.Infrastructure.FileLogSource do
  @moduledoc """
  `McpLogServer.Ports.LogSource` adapter for local `.log` files under
  `LOG_DIR`.

  Owns every file-system concern for log access: listing, name resolution
  with path-traversal protection, the `MAX_LOG_FILE_MB` size guardrail
  (via `McpLogServer.Infrastructure.EnvConfig`), lazy line streaming, format
  detection (via `McpLogServer.Infrastructure.FormatCache`), and retention
  cleanup. The `handle` this adapter produces is the absolute file path.

  Local files are reported with `live?: false` — a file on disk is a static
  snapshot — EXCEPT ingest files of declared `LOG_SOURCES` streams
  (`<name>.log` with a registered worker in
  `McpLogServer.Infrastructure.SourceStatus`), which are reported with
  `live?: true` plus the source name and worker status. Rotated files
  (`<name>.1.log` ...) stay static: only the actively-appended file is live.
  """

  @behaviour McpLogServer.Ports.LogSource

  require Logger

  alias McpLogServer.Domain.JsonLogParser
  alias McpLogServer.Infrastructure.EnvConfig
  alias McpLogServer.Infrastructure.FormatCache
  alias McpLogServer.Infrastructure.SourceStatus

  @impl true
  def list(log_dir) do
    entries =
      log_dir
      |> Path.join("*.log")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.map(&file_info/1)

    {:ok, entries}
  end

  @impl true
  def resolve(log_dir, file) do
    basename = Path.basename(file)

    if basename != file do
      {:error, "Invalid file name: path separators not allowed"}
    else
      path = Path.join(log_dir, basename)

      if File.exists?(path),
        do: {:ok, path},
        else: {:error, "File not found: #{file}"}
    end
  end

  @impl true
  def resolve_readable(log_dir, file) do
    with {:ok, path} <- resolve(log_dir, file) do
      check_size(path)
    end
  end

  @impl true
  def stream_lines(path) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim_trailing/1)
  end

  @impl true
  def read(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Failed to read file: #{reason}"}
    end
  end

  @impl true
  def stat(path) do
    case File.stat(path) do
      {:ok, stat} ->
        {:ok,
         %{
           size_bytes: stat.size,
           modified: NaiveDateTime.to_iso8601(stat.mtime |> NaiveDateTime.from_erl!())
         }}

      {:error, reason} ->
        {:error, "Cannot stat file: #{reason}"}
    end
  end

  @impl true
  def format(path), do: FormatCache.detect(path)

  @doc """
  Check a file against the configured MAX_LOG_FILE_MB limit.
  Returns `{:error, ...}` when the file exceeds the limit.
  """
  @spec check_size(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def check_size(path) do
    max_mb = EnvConfig.max_log_file_mb()
    max_bytes = max_mb * 1_048_576

    case File.stat(path) do
      {:ok, %{size: size}} when size > max_bytes ->
        actual_mb = Float.round(size / 1_048_576, 1)

        {:error,
         "File too large (#{actual_mb} MB). Max is #{max_mb} MB. Set MAX_LOG_FILE_MB to increase."}

      {:ok, _} ->
        {:ok, path}

      {:error, reason} ->
        {:error, "Cannot stat file: #{reason}"}
    end
  end

  @doc "Return the descriptor for a single file path, including size warning if applicable."
  @spec file_info(String.t()) :: McpLogServer.Ports.LogSource.descriptor()
  def file_info(path) do
    stat = File.stat!(path)
    max_bytes = EnvConfig.max_log_file_mb() * 1_048_576
    basename = Path.basename(path)

    info =
      %{
        name: basename,
        path: path,
        size_bytes: stat.size,
        modified: NaiveDateTime.to_iso8601(stat.mtime |> NaiveDateTime.from_erl!()),
        live?: false
      }
      |> with_live_source(basename)

    if stat.size > max_bytes do
      actual_mb = Float.round(stat.size / 1_048_576, 1)
      Map.put(info, :warning, "exceeds max size (#{actual_mb} MB)")
    else
      info
    end
  end

  # `demo.log` is live iff a source worker named "demo" is registered.
  # `demo.1.log` roots to "demo.1" — never a valid source name — so rotated
  # files stay static snapshots.
  defp with_live_source(info, basename) do
    source = Path.rootname(basename, ".log")

    case SourceStatus.get(source) do
      nil -> info
      status -> Map.merge(info, %{live?: true, source: source, status: status})
    end
  end

  @doc """
  Read a file and return a list of parsed JSON maps with extracted fields.

  Convenience composition of `read/1` and
  `McpLogServer.Domain.JsonLogParser.parse_string/2` for `:json_lines` /
  `:json_array` files. Prefer `McpLogServer.Ports.LogSource.stream_entries/3`
  for memory-efficient processing of NDJSON.
  """
  @spec parse_entries(String.t(), :json_lines | :json_array) ::
          {:ok, [map()]} | {:error, String.t()}
  def parse_entries(path, format) do
    with {:ok, content} <- read(path) do
      JsonLogParser.parse_string(content, format)
    end
  end

  @doc """
  Delete `.log` files older than `retention_days` in `log_dir`.
  Skips symlinked files. Does nothing if retention_days is nil.
  """
  @spec cleanup_old_logs(String.t(), integer() | nil) :: :ok
  def cleanup_old_logs(_log_dir, nil), do: :ok

  def cleanup_old_logs(log_dir, retention_days) when is_integer(retention_days) do
    cutoff = NaiveDateTime.add(NaiveDateTime.utc_now(), -retention_days * 86400, :second)

    files =
      log_dir
      |> Path.join("*.log")
      |> Path.wildcard()

    deleted =
      Enum.filter(files, fn path ->
        with {:ok, lstat} <- File.lstat(path),
             false <- lstat.type == :symlink,
             {:ok, stat} <- File.stat(path),
             mtime <- NaiveDateTime.from_erl!(stat.mtime),
             true <- NaiveDateTime.compare(mtime, cutoff) == :lt do
          File.rm(path)
          Logger.info("Cleaned up old log: #{Path.basename(path)}")
          true
        else
          _ -> false
        end
      end)

    if deleted == [] do
      Logger.info("Log cleanup: no files older than #{retention_days} days")
    else
      Logger.info("Cleaned up #{length(deleted)} log files older than #{retention_days} days")
    end

    :ok
  end
end
