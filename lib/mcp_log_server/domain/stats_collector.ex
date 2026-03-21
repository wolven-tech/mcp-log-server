defmodule McpLogServer.Domain.StatsCollector do
  @moduledoc """
  Computes statistics for log files: line counts, error/warn/fatal counts,
  file size, and last-modified time. Supports both plain-text and JSON formats.
  """

  alias McpLogServer.Config.Patterns
  alias McpLogServer.Domain.FileAccess
  alias McpLogServer.Domain.FormatDispatch
  alias McpLogServer.Domain.JsonLogParser
  alias McpLogServer.Util.Formatting

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

  @doc "Compute stats for a log file without returning its content."
  @spec get_stats(String.t(), String.t()) :: {:ok, file_stats()} | {:error, String.t()}
  def get_stats(log_dir, file) do
    with {:ok, path} <- FileAccess.resolve(log_dir, file) do
      stat = File.stat!(path)

      {line_count, error_count, warn_count, fatal_count} =
        FormatDispatch.dispatch(
          path,
          fn fmt -> get_stats_json(path, fmt) end,
          fn -> get_stats_plain(path) end
        )

      {:ok,
       %{
         file: Path.basename(path),
         size_bytes: stat.size,
         size_human: Formatting.humanize_bytes(stat.size),
         line_count: line_count,
         error_count: error_count,
         warn_count: warn_count,
         fatal_count: fatal_count,
         modified: NaiveDateTime.to_iso8601(stat.mtime |> NaiveDateTime.from_erl!())
       }}
    end
  end

  @doc false
  def get_stats_plain(path) do
    path
    |> File.stream!()
    |> Enum.reduce({0, 0, 0, 0}, fn line, {lines, errors, warns, fatals} ->
      detected = Patterns.detect_level(line)

      {
        lines + 1,
        if(detected == :error, do: errors + 1, else: errors),
        if(detected == :warn, do: warns + 1, else: warns),
        if(detected == :fatal, do: fatals + 1, else: fatals)
      }
    end)
  end

  @doc false
  def get_stats_json(path, format) do
    case JsonLogParser.parse_entries(path, format) do
      {:ok, entries} ->
        Enum.reduce(entries, {0, 0, 0, 0}, fn entry, {lines, errors, warns, fatals} ->
          severity = entry["_severity"]

          {
            lines + 1,
            if(severity in @json_error_severities and severity not in @json_fatal_severities,
              do: errors + 1,
              else: errors
            ),
            if(severity == "warn" or severity == "warning", do: warns + 1, else: warns),
            if(severity in @json_fatal_severities, do: fatals + 1, else: fatals)
          }
        end)

      {:error, _} ->
        get_stats_plain(path)
    end
  end
end
