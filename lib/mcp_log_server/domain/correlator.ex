defmodule McpLogServer.Domain.Correlator do
  @moduledoc """
  Cross-service log correlation. Searches for a correlation value (e.g. session
  ID, trace ID) across ALL log files in a directory and returns a unified
  timeline sorted by timestamp.
  """

  alias McpLogServer.Config.Patterns
  alias McpLogServer.Domain.FormatDetector
  alias McpLogServer.Domain.JsonLogParser
  alias McpLogServer.Domain.FileAccess
  alias McpLogServer.Domain.TimestampParser

  @default_max_results 200

  @type timeline_entry :: %{
          file: String.t(),
          line_number: pos_integer(),
          timestamp: String.t() | nil,
          severity: String.t() | nil,
          content: String.t()
        }

  @type correlation_result :: %{
          value: String.t(),
          field: String.t() | nil,
          total_matches: non_neg_integer(),
          files_matched: [String.t()],
          timeline: [timeline_entry()]
        }

  @doc """
  Search for `value` across all log files in `log_dir`.

  ## Options

    * `:field` - restrict matching to this field (dot-notation for JSON,
      pattern matching for plain text). When nil, performs deep search.
    * `:max_results` - cap on total results across all files (default #{@default_max_results}).
  """
  @spec correlate(String.t(), String.t(), keyword()) ::
          {:ok, correlation_result()}
  def correlate(log_dir, value, opts \\ []) do
    field = Keyword.get(opts, :field)
    max_results = Keyword.get(opts, :max_results, @default_max_results)

    {:ok, files} = FileAccess.list_files(log_dir)

    all_entries =
      files
      |> Enum.flat_map(fn file_info ->
        search_file(file_info.path, value, field)
      end)

    sorted = sort_by_timestamp(all_entries)
    capped = Enum.take(sorted, max_results)

    files_matched =
      capped
      |> Enum.map(& &1.file)
      |> Enum.uniq()

    {:ok,
     %{
       value: value,
       field: field,
       total_matches: length(capped),
       files_matched: files_matched,
       timeline: capped
     }}
  end

  # -- Private: per-file search --

  defp search_file(path, value, field) do
    format = FormatDetector.detect(path)
    basename = Path.basename(path)

    case format do
      fmt when fmt in [:json_lines, :json_array] ->
        search_json_file(path, basename, fmt, value, field)

      :plain ->
        search_plain_file(path, basename, value, field)
    end
  end

  # -- JSON file search --

  defp search_json_file(path, basename, :json_lines, value, field) do
    # Stream NDJSON line-by-line to avoid loading entire file
    path
    |> File.stream!()
    |> Stream.map(&String.trim_trailing/1)
    |> Stream.with_index(1)
    |> Stream.filter(fn {line, _idx} -> line != "" end)
    |> Stream.map(fn {line, idx} ->
      case Jason.decode(line) do
        {:ok, map} when is_map(map) ->
          entry = JsonLogParser.enrich(map)
          {entry, idx}

        _ ->
          nil
      end
    end)
    |> Stream.reject(&is_nil/1)
    |> Stream.filter(fn {entry, _idx} -> matches_json_entry?(entry, value, field) end)
    |> Enum.map(fn {entry, idx} ->
      %{
        file: basename,
        line_number: idx,
        timestamp: entry["_timestamp"],
        severity: entry["_severity"],
        content: entry["_message"] || Jason.encode!(Map.drop(entry, ["_severity", "_message", "_timestamp"]))
      }
    end)
  end

  defp search_json_file(path, basename, :json_array, value, field) do
    # JSON arrays must be fully parsed
    case JsonLogParser.parse_entries(path, :json_array) do
      {:ok, entries} ->
        entries
        |> Enum.with_index(1)
        |> Enum.filter(fn {entry, _idx} -> matches_json_entry?(entry, value, field) end)
        |> Enum.map(fn {entry, idx} ->
          %{
            file: basename,
            line_number: idx,
            timestamp: entry["_timestamp"],
            severity: entry["_severity"],
            content: entry["_message"] || Jason.encode!(Map.drop(entry, ["_severity", "_message", "_timestamp"]))
          }
        end)

      {:error, _} ->
        []
    end
  end

  defp matches_json_entry?(entry, value, nil) do
    deep_search(entry, value)
  end

  defp matches_json_entry?(entry, value, field) do
    keys = String.split(field, ".")
    field_value = get_in(entry, keys)
    field_value != nil and to_string(field_value) == value
  end

  defp deep_search(map, value) when is_map(map) do
    Enum.any?(map, fn {_k, v} -> deep_search(v, value) end)
  end

  defp deep_search(list, value) when is_list(list) do
    Enum.any?(list, fn v -> deep_search(v, value) end)
  end

  defp deep_search(str, value) when is_binary(str) do
    String.contains?(str, value)
  end

  defp deep_search(_other, _value), do: false

  # -- Plain text file search (streaming) --

  defp search_plain_file(path, basename, value, field) do
    escaped = Regex.escape(value)

    regex =
      if field do
        # Match field=value or field: value patterns
        {:ok, r} = Regex.compile("#{Regex.escape(field)}[=:]\\s*#{escaped}")
        r
      else
        {:ok, r} = Regex.compile(escaped)
        r
      end

    path
    |> File.stream!()
    |> Stream.map(&String.trim_trailing/1)
    |> Stream.with_index(1)
    |> Stream.filter(fn {line, _idx} -> Regex.match?(regex, line) end)
    |> Enum.map(fn {line, idx} ->
      ts = TimestampParser.extract(line)

      %{
        file: basename,
        line_number: idx,
        timestamp: if(ts, do: DateTime.to_iso8601(ts), else: nil),
        severity: extract_plain_severity(line),
        content: line
      }
    end)
  end

  defp extract_plain_severity(line) do
    case Patterns.detect_level(line) do
      nil -> nil
      level -> Atom.to_string(level)
    end
  end

  @doc """
  Extract unique values for a correlation field across log files.

  ## Options

    * `:file` - scan a single file instead of all files
    * `:max_values` - max unique values to return (default: 50)
  """
  @spec extract_trace_ids(String.t(), String.t(), keyword()) :: {:ok, [map()]}
  def extract_trace_ids(log_dir, field, opts \\ []) do
    max_values = Keyword.get(opts, :max_values, 50)
    file_filter = Keyword.get(opts, :file)

    {:ok, files} = FileAccess.list_files(log_dir)

    files =
      if file_filter do
        Enum.filter(files, &(&1.name == file_filter))
      else
        files
      end

    value_stats =
      files
      |> Enum.reduce(%{}, fn file_info, acc ->
        extract_field_values(file_info.path, field)
        |> Enum.reduce(acc, fn {value, timestamp}, acc ->
          Map.update(acc, value, %{count: 1, first_seen: timestamp, last_seen: timestamp}, fn stat ->
            %{
              count: stat.count + 1,
              first_seen: min_timestamp(stat.first_seen, timestamp),
              last_seen: max_timestamp(stat.last_seen, timestamp)
            }
          end)
        end)
      end)

    results =
      value_stats
      |> Enum.map(fn {value, stat} ->
        %{
          value: value,
          count: stat.count,
          first_seen: stat.first_seen,
          last_seen: stat.last_seen
        }
      end)
      |> Enum.sort_by(& &1.count, :desc)
      |> Enum.take(max_values)

    {:ok, results}
  end

  defp extract_field_values(path, field) do
    format = FormatDetector.detect(path)

    case format do
      fmt when fmt in [:json_lines, :json_array] ->
        extract_json_field_values(path, fmt, field)

      :plain ->
        extract_plain_field_values(path, field)
    end
  end

  defp extract_json_field_values(path, :json_lines, field) do
    keys = String.split(field, ".")

    path
    |> File.stream!()
    |> Stream.map(&String.trim_trailing/1)
    |> Stream.reject(&(&1 == ""))
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, map} when is_map(map) ->
          entry = JsonLogParser.enrich(map)
          value = get_in(entry, keys)
          if value != nil, do: [{to_string(value), entry["_timestamp"]}], else: []

        _ ->
          []
      end
    end)
  end

  defp extract_json_field_values(path, :json_array, field) do
    case JsonLogParser.parse_entries(path, :json_array) do
      {:ok, entries} ->
        keys = String.split(field, ".")

        Enum.flat_map(entries, fn entry ->
          value = get_in(entry, keys)
          if value != nil, do: [{to_string(value), entry["_timestamp"]}], else: []
        end)

      {:error, _} ->
        []
    end
  end

  defp extract_plain_field_values(path, field) do
    escaped_field = Regex.escape(field)
    {:ok, regex} = Regex.compile("#{escaped_field}[=:]\\s*([^\\s,;]+)")

    path
    |> File.stream!()
    |> Stream.map(&String.trim_trailing/1)
    |> Enum.flat_map(fn line ->
      case Regex.run(regex, line) do
        [_, value] ->
          ts = TimestampParser.extract(line)
          [{value, ts && DateTime.to_iso8601(ts)}]

        _ ->
          []
      end
    end)
  end

  defp min_timestamp(nil, b), do: b
  defp min_timestamp(a, nil), do: a
  defp min_timestamp(a, b), do: if(a <= b, do: a, else: b)

  defp max_timestamp(nil, b), do: b
  defp max_timestamp(a, nil), do: a
  defp max_timestamp(a, b), do: if(a >= b, do: a, else: b)

  # -- Sorting --

  defp sort_by_timestamp(entries) do
    Enum.sort(entries, fn a, b ->
      compare_timestamps(a.timestamp, b.timestamp)
    end)
  end

  defp compare_timestamps(nil, nil), do: true
  defp compare_timestamps(nil, _), do: false
  defp compare_timestamps(_, nil), do: true

  defp compare_timestamps(a, b) do
    a <= b
  end
end
