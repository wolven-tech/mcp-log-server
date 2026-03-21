defmodule McpLogServer.Domain.FormatDetector do
  @moduledoc """
  Auto-detects whether a log file contains JSON-structured entries.
  Results are cached per {path, mtime} in an ETS table.
  """

  @type format :: :plain | :json_lines | :json_array

  @ets_table :format_detector_cache

  @doc """
  Detect the format of a log file.

  Returns:
  - `:json_lines` if each line is a valid JSON object
  - `:json_array` if the file starts with `[` and parses as a JSON array
  - `:plain` for everything else
  """
  @spec detect(String.t()) :: format()
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

  @sample_lines 5
  @chunk_size 4096

  defp do_detect(path) do
    case File.open(path, [:read, :utf8]) do
      {:ok, device} ->
        try do
          lines = read_lines(device, @sample_lines)

          case lines do
            [] ->
              :plain

            [first | _] ->
              first_trimmed = String.trim(first)

              if String.starts_with?(first_trimmed, "[") do
                detect_json_array(path)
              else
                detect_json_lines(lines)
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

  defp detect_json_array(path) do
    case File.open(path, [:read]) do
      {:ok, device} ->
        try do
          chunk = IO.binread(device, @chunk_size)

          case chunk do
            :eof ->
              :plain

            {:error, _} ->
              :plain

            data when is_binary(data) ->
              trimmed = String.trim(data)

              case Jason.decode(trimmed) do
                {:ok, list} when is_list(list) ->
                  if Enum.all?(list, &is_map/1), do: :json_array, else: :plain

                _ ->
                  # Possibly truncated — try appending "]"
                  case Jason.decode(trimmed <> "]") do
                    {:ok, list} when is_list(list) ->
                      if Enum.all?(list, &is_map/1), do: :json_array, else: :plain

                    _ ->
                      :plain
                  end
              end
          end
        after
          File.close(device)
        end

      {:error, _} ->
        :plain
    end
  end

  defp detect_json_lines(lines) do
    if lines == [] do
      :plain
    else
      all_json? =
        Enum.all?(lines, fn line ->
          case Jason.decode(line) do
            {:ok, decoded} when is_map(decoded) -> true
            _ -> false
          end
        end)

      if all_json?, do: :json_lines, else: :plain
    end
  end
end
