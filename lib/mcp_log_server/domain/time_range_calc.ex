defmodule McpLogServer.Domain.TimeRangeCalc do
  @moduledoc """
  Pure computation of a log's time range (earliest and latest timestamps)
  by sampling the first and last lines of a line stream. Supports plain-text
  and JSON formats.

  The result also reports `ts_parse_ratio` / `ts_parse_sample`: the share of
  sampled lines whose timestamp parsed. A ratio of 0.0 means `since`/`until`
  filtering on this file is effectively disabled (fail-open includes
  everything) — the loud signal for the formerly silent failure mode.

  Operates on enumerables supplied by the caller; I/O lives in the
  application layer (`McpLogServer.UseCases.TimeRange`).
  """

  alias McpLogServer.Domain.JsonLogParser
  alias McpLogServer.Domain.TimestampParser
  alias McpLogServer.Util.Formatting

  @doc """
  Compute the time range over an enumerable of (already trimmed) lines.

  Pure over its input: samples the first and last 10 lines in a single pass,
  extracts timestamps according to `format`, and shapes the result.
  `file_name` is only echoed into the result map. `ts_opts` (declared
  format, mtime reference) are forwarded to the timestamp parser.
  """
  @spec compute(Enumerable.t(), atom(), String.t(), keyword()) :: {:ok, map()}
  def compute(lines, format, file_name, ts_opts \\ []) do
    {line_count, head, tail} = sample_head_tail(lines, 10)
    sample = Enum.uniq(head ++ tail)

    timestamps =
      case format do
        fmt when fmt in [:json_lines, :json_array] ->
          extract_timestamps_json(sample, ts_opts)

        :plain ->
          Enum.map(sample, &TimestampParser.extract(&1, ts_opts))
      end

    sample_size = length(sample)
    parsed_count = Enum.count(timestamps, &(&1 != nil))

    parse_ratio =
      if sample_size > 0, do: Float.round(parsed_count / sample_size, 3), else: nil

    sorted =
      timestamps
      |> Enum.reject(&is_nil/1)
      |> Enum.sort(DateTime)

    {earliest, latest} =
      case sorted do
        [] -> {nil, nil}
        [single] -> {single, single}
        list -> {List.first(list), List.last(list)}
      end

    span =
      if earliest && latest do
        Formatting.humanize_span(DateTime.diff(latest, earliest, :second))
      else
        nil
      end

    {:ok,
     %{
       file: file_name,
       earliest: earliest && DateTime.to_iso8601(earliest),
       latest: latest && DateTime.to_iso8601(latest),
       span: span,
       line_count: line_count,
       format: to_string(format),
       ts_parse_ratio: parse_ratio,
       ts_parse_sample: sample_size
     }}
  end

  @doc """
  Single-pass sampling: captures first N lines, last N lines, and total count
  without materializing the enumerable.
  """
  @spec sample_head_tail(Enumerable.t(), pos_integer()) ::
          {non_neg_integer(), [String.t()], [String.t()]}
  def sample_head_tail(lines, n) do
    lines
    |> Enum.reduce({0, [], :queue.new()}, fn line, {count, head, tail_q} ->
      head =
        if count < n do
          head ++ [line]
        else
          head
        end

      tail_q = :queue.in(line, tail_q)

      tail_q =
        if :queue.len(tail_q) > n do
          {_, q} = :queue.out(tail_q)
          q
        else
          tail_q
        end

      {count + 1, head, tail_q}
    end)
    |> then(fn {count, head, tail_q} ->
      {count, head, :queue.to_list(tail_q)}
    end)
  end

  @doc false
  def extract_timestamps_json(lines, ts_opts \\ []) do
    Enum.map(lines, fn line ->
      case Jason.decode(line) do
        {:ok, map} when is_map(map) ->
          map
          |> JsonLogParser.extract_timestamp()
          |> TimestampParser.parse_json_value(ts_opts)

        _ ->
          nil
      end
    end)
  end
end
