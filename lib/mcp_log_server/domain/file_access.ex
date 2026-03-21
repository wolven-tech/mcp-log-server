defmodule McpLogServer.Domain.FileAccess do
  @moduledoc """
  File-system access layer for log files: listing, resolving paths,
  reading file metadata, and loading file contents.
  """

  @type file_info :: %{
          name: String.t(),
          path: String.t(),
          size_bytes: non_neg_integer(),
          modified: String.t()
        }

  @doc "List all .log files in the given directory."
  @spec list_files(String.t()) :: {:ok, [file_info()]}
  def list_files(log_dir) do
    entries =
      log_dir
      |> Path.join("*.log")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.map(&file_info/1)

    {:ok, entries}
  end

  @doc "Resolve a file name to an absolute path inside `log_dir`, rejecting path traversal."
  @spec resolve(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
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

  @doc """
  Resolve and check file size against the configured MAX_LOG_FILE_MB limit.
  Returns `{:error, ...}` if the file exceeds the limit.
  Use this for tools that load file content. Streaming tools (log_stats) can use resolve/2 directly.
  """
  @spec resolve_with_size_check(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve_with_size_check(log_dir, file) do
    with {:ok, path} <- resolve(log_dir, file) do
      check_size(path)
    end
  end

  @doc "Check if a file exceeds the configured MAX_LOG_FILE_MB limit."
  @spec check_size(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def check_size(path) do
    max_mb = Application.get_env(:mcp_log_server, :max_log_file_mb, 100)
    max_bytes = max_mb * 1_048_576

    case File.stat(path) do
      {:ok, %{size: size}} when size > max_bytes ->
        actual_mb = Float.round(size / 1_048_576, 1)
        {:error, "File too large (#{actual_mb} MB). Max is #{max_mb} MB. Set MAX_LOG_FILE_MB to increase."}

      {:ok, _} ->
        {:ok, path}

      {:error, reason} ->
        {:error, "Cannot stat file: #{reason}"}
    end
  end

  @doc "Return metadata for a single file path, including size warning if applicable."
  @spec file_info(String.t()) :: file_info()
  def file_info(path) do
    stat = File.stat!(path)
    max_mb = Application.get_env(:mcp_log_server, :max_log_file_mb, 100)
    max_bytes = max_mb * 1_048_576

    info = %{
      name: Path.basename(path),
      path: path,
      size_bytes: stat.size,
      modified: NaiveDateTime.to_iso8601(stat.mtime |> NaiveDateTime.from_erl!())
    }

    if stat.size > max_bytes do
      actual_mb = Float.round(stat.size / 1_048_576, 1)
      Map.put(info, :warning, "exceeds max size (#{actual_mb} MB)")
    else
      info
    end
  end

  @doc """
  Delete .log files older than `retention_days` in `log_dir`.
  Skips symlinked files. Does nothing if retention_days is nil.
  """
  @spec cleanup_old_logs(String.t(), integer() | nil) :: :ok
  def cleanup_old_logs(_log_dir, nil), do: :ok

  def cleanup_old_logs(log_dir, retention_days) when is_integer(retention_days) do
    require Logger
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

  @doc "Read a file into a list of `{line, 1-based-index}` tuples."
  @spec read_indexed(String.t()) :: [{String.t(), pos_integer()}]
  def read_indexed(path) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim_trailing/1)
    |> Stream.with_index(1)
    |> Enum.to_list()
  end

  @doc "Read all lines of a file, trimming trailing whitespace."
  @spec read_all_lines(String.t()) :: [String.t()]
  def read_all_lines(path) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim_trailing/1)
    |> Enum.to_list()
  end
end
