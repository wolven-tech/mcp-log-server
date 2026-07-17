defmodule McpLogServer.Domain.StatsCollector do
  @moduledoc """
  Pure severity counting over streams of plain-text lines or JSON-structured
  entries.

  All functions operate on enumerables supplied by the caller; I/O and result
  shaping live in the application layer (`McpLogServer.UseCases.CollectStats`).
  """

  alias McpLogServer.Config.Patterns

  @type file_stats :: %{
          file: String.t(),
          size_bytes: non_neg_integer(),
          size_human: String.t(),
          line_count: non_neg_integer(),
          error_count: non_neg_integer(),
          warn_count: non_neg_integer(),
          fatal_count: non_neg_integer(),
          modified: String.t()
        }

  @json_error_severities ~w(error fatal exception)
  @json_fatal_severities ~w(fatal)

  @doc """
  Count `{lines, errors, warns, fatals}` over an enumerable of plain-text
  lines using the configured severity patterns.
  """
  @spec count_plain(Enumerable.t()) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def count_plain(lines) do
    Enum.reduce(lines, {0, 0, 0, 0}, fn line, {count, errors, warns, fatals} ->
      detected = Patterns.detect_level(line)

      {
        count + 1,
        if(detected == :error, do: errors + 1, else: errors),
        if(detected == :warn, do: warns + 1, else: warns),
        if(detected == :fatal, do: fatals + 1, else: fatals)
      }
    end)
  end

  @doc """
  Count `{lines, errors, warns, fatals}` over an enumerable of
  `{enriched_json_entry, index}` tuples using the extracted `_severity`.
  """
  @spec count_json(Enumerable.t()) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def count_json(entries) do
    Enum.reduce(entries, {0, 0, 0, 0}, fn {entry, _idx}, {count, errors, warns, fatals} ->
      severity = entry["_severity"]

      {
        count + 1,
        if(severity in @json_error_severities and severity not in @json_fatal_severities,
          do: errors + 1,
          else: errors
        ),
        if(severity == "warn" or severity == "warning", do: warns + 1, else: warns),
        if(severity in @json_fatal_severities, do: fatals + 1, else: fatals)
      }
    end)
  end
end
