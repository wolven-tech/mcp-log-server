defmodule McpLogServer.Domain.TimeFilter do
  @moduledoc """
  Filters log lines/entries by time range.
  Lines without parseable timestamps are included (fail-open policy).
  """

  alias McpLogServer.Domain.TimestampParser
  alias McpLogServer.Domain.JsonLogParser

  @doc """
  Check if a log line or JSON entry falls within the given time range.

  - `line` can be a string (plain text) or a map (parsed JSON entry)
  - `since` and `until` are optional DateTime values (nil means unbounded)
  - Lines without parseable timestamps are always included (fail-open)
  """
  @spec in_range?(String.t() | map(), DateTime.t() | nil, DateTime.t() | nil) :: boolean()
  def in_range?(_line, nil, nil), do: true

  def in_range?(line, since, until) when is_binary(line) do
    case TimestampParser.extract(line) do
      nil -> true
      ts -> check_bounds(ts, since, until)
    end
  end

  def in_range?(entry, since, until) when is_map(entry) do
    ts_value = JsonLogParser.extract_timestamp(entry)

    case parse_json_timestamp(ts_value) do
      nil -> true
      ts -> check_bounds(ts, since, until)
    end
  end

  defp check_bounds(ts, since, until) do
    after_since? = since == nil or DateTime.compare(ts, since) in [:gt, :eq]
    before_until? = until == nil or DateTime.compare(ts, until) in [:lt, :eq]
    after_since? and before_until?
  end

  defp parse_json_timestamp(nil), do: nil

  defp parse_json_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_json_timestamp(_), do: nil
end
