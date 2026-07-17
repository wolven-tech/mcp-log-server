defmodule McpLogServer.Domain.Correlator do
  @moduledoc """
  Pure cross-service correlation logic: matching a correlation value
  (e.g. session ID, trace ID) inside line/entry streams, building timeline
  entries, extracting field values, and aggregating them.

  All functions operate on enumerables supplied by the caller; enumerating
  files and streaming their contents lives in the application layer
  (`McpLogServer.UseCases.Correlate`, `McpLogServer.UseCases.TraceIds`)
  behind the `LogSource` port.
  """

  alias McpLogServer.Config.Patterns
  alias McpLogServer.Domain.TimestampParser

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
          timeline: [timeline_entry()],
          unparsed_ts: non_neg_integer()
        }

  @doc """
  Build timeline entries from an enumerable of `{enriched_json_entry, index}`
  tuples that match the correlation `value` (optionally restricted to
  `field`, dot-notation). When `field` is nil, performs deep search.
  """
  @spec json_timeline(Enumerable.t(), String.t(), String.t(), String.t() | nil) ::
          [timeline_entry()]
  def json_timeline(entries, basename, value, field) do
    entries
    |> Stream.filter(fn {entry, _idx} -> matches_json_entry?(entry, value, field) end)
    |> Enum.map(fn {entry, idx} ->
      %{
        file: basename,
        line_number: idx,
        timestamp: entry["_timestamp"],
        severity: entry["_severity"],
        content:
          entry["_message"] ||
            Jason.encode!(Map.drop(entry, ["_severity", "_message", "_timestamp"]))
      }
    end)
  end

  @doc """
  Build timeline entries from an enumerable of `{line, index}` tuples that
  match the correlation `value` (optionally as `field=value` / `field: value`).

  `ts_opts` (declared format, mtime reference) are forwarded to the
  timestamp parser; entries whose timestamp cannot be parsed carry
  `timestamp: nil` and sort last in the timeline.
  """
  @spec plain_timeline(Enumerable.t(), String.t(), String.t(), String.t() | nil, keyword()) ::
          [timeline_entry()]
  def plain_timeline(indexed_lines, basename, value, field, ts_opts \\ []) do
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

    indexed_lines
    |> Stream.filter(fn {line, _idx} -> Regex.match?(regex, line) end)
    |> Enum.map(fn {line, idx} ->
      ts = TimestampParser.extract(line, ts_opts)

      %{
        file: basename,
        line_number: idx,
        timestamp: if(ts, do: DateTime.to_iso8601(ts), else: nil),
        severity: extract_plain_severity(line),
        content: line
      }
    end)
  end

  @doc "Sort timeline entries by timestamp (nil timestamps sort last)."
  @spec sort_timeline([timeline_entry()]) :: [timeline_entry()]
  def sort_timeline(entries) do
    Enum.sort(entries, fn a, b ->
      compare_timestamps(a.timestamp, b.timestamp)
    end)
  end

  @doc """
  Extract `{value, timestamp}` pairs for a dot-notation `field` from an
  enumerable of `{enriched_json_entry, index}` tuples.
  """
  @spec json_field_values(Enumerable.t(), String.t()) :: [{String.t(), String.t() | nil}]
  def json_field_values(entries, field) do
    keys = String.split(field, ".")

    entries
    |> Enum.flat_map(fn {entry, _idx} ->
      value = get_in(entry, keys)
      if value != nil, do: [{to_string(value), entry["_timestamp"]}], else: []
    end)
  end

  @doc """
  Extract `{value, timestamp}` pairs for `field=value` / `field: value`
  occurrences from an enumerable of plain-text lines.
  """
  @spec plain_field_values(Enumerable.t(), String.t()) :: [{String.t(), String.t() | nil}]
  def plain_field_values(lines, field) do
    escaped_field = Regex.escape(field)
    {:ok, regex} = Regex.compile("#{escaped_field}[=:]\\s*([^\\s,;]+)")

    lines
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

  @doc """
  Aggregate `{value, timestamp}` pairs into per-value stats sorted by count
  (descending), capped at `max_values`.
  """
  @spec aggregate_field_values(Enumerable.t(), pos_integer()) :: [map()]
  def aggregate_field_values(pairs, max_values) do
    pairs
    |> Enum.reduce(%{}, fn {value, timestamp}, acc ->
      Map.update(acc, value, %{count: 1, first_seen: timestamp, last_seen: timestamp}, fn stat ->
        %{
          count: stat.count + 1,
          first_seen: min_timestamp(stat.first_seen, timestamp),
          last_seen: max_timestamp(stat.last_seen, timestamp)
        }
      end)
    end)
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
  end

  # -- Matching --

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

  defp extract_plain_severity(line) do
    case Patterns.detect_level(line) do
      nil -> nil
      level -> Atom.to_string(level)
    end
  end

  defp min_timestamp(nil, b), do: b
  defp min_timestamp(a, nil), do: a
  defp min_timestamp(a, b), do: if(a <= b, do: a, else: b)

  defp max_timestamp(nil, b), do: b
  defp max_timestamp(a, nil), do: a
  defp max_timestamp(a, b), do: if(a >= b, do: a, else: b)

  defp compare_timestamps(nil, nil), do: true
  defp compare_timestamps(nil, _), do: false
  defp compare_timestamps(_, nil), do: true

  defp compare_timestamps(a, b) do
    a <= b
  end
end
