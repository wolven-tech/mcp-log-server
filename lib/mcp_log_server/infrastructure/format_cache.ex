defmodule McpLogServer.Infrastructure.FormatCache do
  @moduledoc """
  File-backed format detection with an ETS cache.

  Samples the first few lines (and, for array candidates, the first chunk) of
  a local file and delegates classification to the pure
  `McpLogServer.Domain.FormatDetector`. Results are cached per
  `{path, mtime}` so repeated tool calls do not re-read files.

  This module is infrastructure: it owns the file I/O and the cache. The
  decision logic ("do these lines look like NDJSON?") lives in the domain.
  """

  alias McpLogServer.Domain.FormatDetector

  @ets_table :format_detector_cache
  @sample_lines 5
  @chunk_size 4096

  @doc """
  Detect the format of a log file.

  Returns:
  - `:json_lines` if each sampled line is a valid JSON object
  - `:json_array` if the file starts with `[` and parses as a JSON array of objects
  - `:plain` for everything else (including unreadable files)
  """
  @spec detect(String.t()) :: FormatDetector.format()
  def detect(path) do
    ensure_table()

    case File.stat(path) do
      {:ok, %{mtime: mtime}} ->
        cache_key = {path, mtime}

        case :ets.lookup(@ets_table, cache_key) do
          [{^cache_key, format}] ->
            format

          [] ->
            format = do_detect(path)
            :ets.insert(@ets_table, {cache_key, format})
            format
        end

      {:error, _} ->
        :plain
    end
  end

  defp ensure_table do
    case :ets.whereis(@ets_table) do
      :undefined ->
        :ets.new(@ets_table, [:set, :public, :named_table])

      _ref ->
        :ok
    end
  end

  defp do_detect(path) do
    case File.open(path, [:read, :utf8]) do
      {:ok, device} ->
        try do
          lines = read_lines(device, @sample_lines)

          case lines do
            [] ->
              :plain

            [first | _] ->
              if FormatDetector.array_candidate?(first) do
                classify_array(path)
              else
                FormatDetector.classify_lines(lines)
              end
          end
        after
          File.close(device)
        end

      {:error, _} ->
        :plain
    end
  end

  defp read_lines(_device, 0), do: []

  defp read_lines(device, remaining) do
    case IO.read(device, :line) do
      :eof ->
        []

      {:error, _} ->
        []

      line when is_binary(line) ->
        trimmed = String.trim(line)

        if trimmed == "" do
          read_lines(device, remaining)
        else
          [trimmed | read_lines(device, remaining - 1)]
        end
    end
  end

  defp classify_array(path) do
    case File.open(path, [:read]) do
      {:ok, device} ->
        try do
          case IO.binread(device, @chunk_size) do
            :eof -> :plain
            {:error, _} -> :plain
            data when is_binary(data) -> FormatDetector.classify_array_chunk(data)
          end
        after
          File.close(device)
        end

      {:error, _} ->
        :plain
    end
  end
end
