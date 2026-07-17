defmodule McpLogServer.UseCases.CollectStats do
  @moduledoc """
  Use-case: compute per-log statistics (line/error/warn/fatal counts, size,
  last modified) without returning content. Streams, so it is exempt from
  the read-size guardrail.
  """

  alias McpLogServer.Domain.StatsCollector
  alias McpLogServer.Ports.LogSource
  alias McpLogServer.UseCases.Deps
  alias McpLogServer.Util.Formatting

  @spec run(String.t(), String.t(), keyword()) ::
          {:ok, StatsCollector.file_stats()} | {:error, String.t()}
  def run(log_dir, file, opts \\ []) do
    source = Deps.log_source(opts)

    with {:ok, handle} <- source.resolve(log_dir, file) do
      {:ok, stat} = source.stat(handle)

      {line_count, error_count, warn_count, fatal_count} = count(source, handle)

      {:ok,
       %{
         file: Path.basename(file),
         size_bytes: stat.size_bytes,
         size_human: Formatting.humanize_bytes(stat.size_bytes),
         line_count: line_count,
         error_count: error_count,
         warn_count: warn_count,
         fatal_count: fatal_count,
         modified: stat.modified
       }}
    end
  end

  defp count(source, handle) do
    case source.format(handle) do
      fmt when fmt in [:json_lines, :json_array] ->
        try do
          LogSource.stream_entries(source, handle, fmt)
          |> StatsCollector.count_json()
        rescue
          _ -> count_plain(source, handle)
        end

      :plain ->
        count_plain(source, handle)
    end
  end

  defp count_plain(source, handle) do
    handle
    |> source.stream_lines()
    |> StatsCollector.count_plain()
  end
end
