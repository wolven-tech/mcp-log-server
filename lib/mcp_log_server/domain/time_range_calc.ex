defmodule McpLogServer.Domain.TimeRangeCalc do
  @moduledoc """
  Computes the time range (earliest and latest timestamps) of a log file
  by sampling the first and last lines. Supports plain-text and JSON formats.
  """

  alias McpLogServer.Domain.FileAccess
  alias McpLogServer.Domain.FormatDetector
  alias McpLogServer.Domain.JsonLogParser
  alias McpLogServer.Domain.TimestampParser
  alias McpLogServer.Util.Formatting

  @doc """
  Return the time range of a log file by reading first and last 10 lines.

  Returns `{:ok, map}` with keys: earliest, latest, span, line_count, format.
  """
  @spec time_range(String.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def time_range(log_dir, file) do
    with {:ok, path} <- FileAccess.resolve_with_size_check(log_dir, file) do
      format = FormatDetector.detect(path)

      path
      |> File.stream!()
      |> Stream.map(&String.trim_trailing/1)
      |> compute(format, Path.basename(path))
    end
  end

  @doc """
  Compute the time range over an enumerable of (already trimmed) lines.

  Pure over its input: samples the first and last 10 lines in a single pass,
  extracts timestamps according to `format`, and shapes the result.
  `file_name` is only echoed into the result map.
  """
  @spec compute(Enumerable.t(), atom(), String.t()) :: {:ok, map()}
  def compute(lines, format, file_name) do
    {line_count, head, tail} = sample_head_tail(lines, 10)
    sample = Enum.uniq(head ++ tail)

    timestamps =
      case format do
        fmt when fmt in [:json_lines, :json_array] ->
          extract_timestamps_json(sample)

        :plain ->
          Enum.map(sample, &TimestampParser.extract/1)
      end
      |> Enum.reject(&is_nil/1)
      |> Enum.sort(DateTime)

    {earliest, latest} =
      case timestamps do
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
       format: to_string(format)
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
  def extract_timestamps_json(lines) do
    Enum.map(lines, fn line ->
      case Jason.decode(line) do
        {:ok, map} when is_map(map) ->
          ts = JsonLogParser.extract_timestamp(map)

          case ts do
            nil ->
              nil

            s when is_binary(s) ->
              case DateTime.from_iso8601(s) do
                {:ok, dt, _} -> dt
                _ -> nil
              end

            _ ->
              nil
          end

        _ ->
          nil
      end
    end)
  end
end
