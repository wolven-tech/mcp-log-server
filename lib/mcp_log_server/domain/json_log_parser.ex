defmodule McpLogServer.Domain.JsonLogParser do
  @moduledoc """
  Parses JSON log entries and extracts severity, timestamp, and message
  from standard fields across common logging frameworks.
  """

  @severity_fields ["severity", "level", "log.level", "levelname", "loglevel"]
  @message_fields ["message", "msg", "textPayload", "@message"]
  @timestamp_fields ["timestamp", "time", "@timestamp", "receiveTimestamp"]

  @pino_levels %{
    10 => "trace",
    20 => "debug",
    30 => "info",
    40 => "warn",
    50 => "error",
    60 => "fatal"
  }

  @doc """
  Read a file and return a list of parsed JSON maps with extracted fields.

  `format` must be `:json_lines` or `:json_array`.
  Each returned map includes the original fields plus:
  - `_severity` - normalized severity string (lowercase)
  - `_message` - extracted message
  - `_timestamp` - extracted timestamp (ISO 8601 string)

  Note: For `:json_array`, the entire file must be loaded into memory to parse
  the JSON array. For large files, prefer `:json_lines` (NDJSON) format and
  use `stream_entries/2` for memory-efficient processing.
  """
  @spec parse_entries(String.t(), :json_lines | :json_array) ::
          {:ok, [map()]} | {:error, String.t()}
  def parse_entries(path, format) do
    case File.read(path) do
      {:ok, content} ->
        parse_content(content, format)

      {:error, reason} ->
        {:error, "Failed to read file: #{reason}"}
    end
  end

  @doc """
  Stream enriched JSON entries from an NDJSON file one at a time.

  Returns a stream of `{enriched_map, line_number}` tuples. Memory usage
  is constant regardless of file size. Only works for `:json_lines` format.

  For `:json_array`, falls back to `parse_entries/2` (full memory load required).
  """
  @spec stream_entries(String.t(), :json_lines | :json_array) :: Enumerable.t()
  def stream_entries(path, :json_lines) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim_trailing/1)
    |> Stream.with_index(1)
    |> Stream.flat_map(fn {line, idx} ->
      case Jason.decode(line) do
        {:ok, map} when is_map(map) -> [{enrich(map), idx}]
        _ -> []
      end
    end)
  end

  def stream_entries(path, :json_array) do
    case parse_entries(path, :json_array) do
      {:ok, entries} -> entries |> Enum.with_index(1) |> Stream.map(& &1)
      {:error, _} -> Stream.map([], & &1)
    end
  end

  defp parse_content(content, :json_lines) do
    entries =
      content
      |> String.split("\n", trim: true)
      |> Enum.reduce([], fn line, acc ->
        case Jason.decode(line) do
          {:ok, map} when is_map(map) -> [enrich(map) | acc]
          _ -> acc
        end
      end)
      |> Enum.reverse()

    {:ok, entries}
  end

  defp parse_content(content, :json_array) do
    case Jason.decode(String.trim(content)) do
      {:ok, list} when is_list(list) ->
        entries =
          list
          |> Enum.filter(&is_map/1)
          |> Enum.map(&enrich/1)

        {:ok, entries}

      _ ->
        {:error, "File content is not a valid JSON array"}
    end
  end

  @doc "Enrich a raw JSON map with extracted _severity, _message, _timestamp fields."
  @spec enrich(map()) :: map()
  def enrich(map) do
    map
    |> Map.put("_severity", extract_severity(map))
    |> Map.put("_message", extract_message(map))
    |> Map.put("_timestamp", extract_timestamp(map))
  end

  @doc "Extract and normalize severity from a JSON log entry."
  @spec extract_severity(map()) :: String.t() | nil
  def extract_severity(map) do
    value = find_first(map, @severity_fields)

    case value do
      nil -> nil
      n when is_integer(n) -> Map.get(@pino_levels, n, "unknown")
      s when is_binary(s) -> String.downcase(s)
      _ -> nil
    end
  end

  @doc "Extract message from a JSON log entry."
  @spec extract_message(map()) :: String.t() | nil
  def extract_message(map) do
    find_first(map, @message_fields)
  end

  @doc "Extract and normalize timestamp from a JSON log entry."
  @spec extract_timestamp(map()) :: String.t() | nil
  def extract_timestamp(map) do
    value = find_first(map, @timestamp_fields)

    case value do
      nil -> nil
      n when is_integer(n) -> epoch_ms_to_iso8601(n)
      s when is_binary(s) -> s
      _ -> nil
    end
  end

  defp find_first(map, fields) do
    Enum.find_value(fields, fn field ->
      case get_nested(map, field) do
        nil -> nil
        value -> value
      end
    end)
  end

  defp get_nested(map, field) do
    case String.split(field, ".") do
      [key] -> Map.get(map, key)
      keys -> get_in(map, keys)
    end
  end

  @doc "Convert an enriched JSON entry into a toon-friendly map with line_number, severity, timestamp, and message."
  @spec json_entry_to_toon_map(map(), pos_integer()) :: map()
  def json_entry_to_toon_map(entry, line_number) do
    %{
      line_number: line_number,
      severity: entry["_severity"] || "",
      timestamp: entry["_timestamp"] || "",
      message: entry["_message"] || ""
    }
  end

  defp epoch_ms_to_iso8601(ms) when is_integer(ms) do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_iso8601()
  end
end
