defmodule McpLogServer.Domain.StatsCollector do
  @moduledoc """
  Pure severity counting over streams of plain-text lines or JSON-structured
  entries, plus a sampled timestamp parse-success ratio.

  The first 1000 lines are sampled for timestamp parseability so
  `log_stats` can reveal a file whose stamps the parser cannot read (the
  dangerous silent case behind fail-open time filtering). Counters are
  returned as data, never as side effects.

  All functions operate on enumerables supplied by the caller; I/O and result
  shaping live in the application layer (`McpLogServer.UseCases.CollectStats`).
  """

  alias McpLogServer.Config.Patterns
  alias McpLogServer.Domain.TimestampParser

  @ts_sample_size 1000

  @type file_stats :: %{
          file: String.t(),
          size_bytes: non_neg_integer(),
          size_human: String.t(),
          line_count: non_neg_integer(),
          error_count: non_neg_integer(),
          warn_count: non_neg_integer(),
          fatal_count: non_neg_integer(),
          modified: String.t(),
          ts_parse_ratio: float() | nil,
          ts_parse_sample: non_neg_integer()
        }

  @type counts :: %{
          lines: non_neg_integer(),
          errors: non_neg_integer(),
          warns: non_neg_integer(),
          fatals: non_neg_integer(),
          ts_sampled: non_neg_integer(),
          ts_parsed: non_neg_integer()
        }

  @json_error_severities ~w(error fatal exception)
  @json_fatal_severities ~w(fatal)

  @doc "The number of lines sampled for the timestamp parse ratio."
  @spec ts_sample_size() :: pos_integer()
  def ts_sample_size, do: @ts_sample_size

  @doc """
  Count severities over an enumerable of plain-text lines using the
  configured severity patterns, sampling the first #{@ts_sample_size} lines
  for timestamp parseability (`ts_opts` — declared format, mtime reference —
  are forwarded to the parser).
  """
  @spec count_plain(Enumerable.t(), keyword()) :: counts()
  def count_plain(lines, ts_opts \\ []) do
    Enum.reduce(lines, empty_counts(), fn line, acc ->
      detected = Patterns.detect_level(line)

      acc
      |> bump_severity(detected)
      |> sample_ts(fn -> TimestampParser.extract(line, ts_opts) != nil end)
      |> Map.update!(:lines, &(&1 + 1))
    end)
  end

  @doc """
  Count severities over an enumerable of `{enriched_json_entry, index}`
  tuples using the extracted `_severity`, sampling the first
  #{@ts_sample_size} entries for timestamp parseability.
  """
  @spec count_json(Enumerable.t(), keyword()) :: counts()
  def count_json(entries, ts_opts \\ []) do
    Enum.reduce(entries, empty_counts(), fn {entry, _idx}, acc ->
      severity = entry["_severity"]

      acc =
        cond do
          severity in @json_fatal_severities -> Map.update!(acc, :fatals, &(&1 + 1))
          severity in @json_error_severities -> Map.update!(acc, :errors, &(&1 + 1))
          severity == "warn" or severity == "warning" -> Map.update!(acc, :warns, &(&1 + 1))
          true -> acc
        end

      acc
      |> sample_ts(fn ->
        TimestampParser.parse_json_value(entry["_timestamp"], ts_opts) != nil
      end)
      |> Map.update!(:lines, &(&1 + 1))
    end)
  end

  defp empty_counts do
    %{lines: 0, errors: 0, warns: 0, fatals: 0, ts_sampled: 0, ts_parsed: 0}
  end

  defp bump_severity(acc, :error), do: Map.update!(acc, :errors, &(&1 + 1))
  defp bump_severity(acc, :warn), do: Map.update!(acc, :warns, &(&1 + 1))
  defp bump_severity(acc, :fatal), do: Map.update!(acc, :fatals, &(&1 + 1))
  defp bump_severity(acc, _), do: acc

  defp sample_ts(%{ts_sampled: sampled} = acc, parse_fn) when sampled < @ts_sample_size do
    parsed_increment = if parse_fn.(), do: 1, else: 0
    %{acc | ts_sampled: sampled + 1, ts_parsed: acc.ts_parsed + parsed_increment}
  end

  defp sample_ts(acc, _parse_fn), do: acc
end
