defmodule McpLogServer.UseCases.CollectStats do
  @moduledoc """
  Use-case: compute per-log statistics (line/error/warn/fatal counts, size,
  last modified) without returning content. Streams, so it is exempt from
  the read-size guardrail.
  """

  alias McpLogServer.Domain.StatsCollector
  alias McpLogServer.Ports.LogSource
  alias McpLogServer.UseCases.Deps
  alias McpLogServer.UseCases.TsOpts
  alias McpLogServer.Util.Formatting

  @spec run(String.t(), String.t(), keyword()) ::
          {:ok, StatsCollector.file_stats()} | {:error, String.t()}
  def run(log_dir, file, opts \\ []) do
    source = Deps.log_source(opts)

    with {:ok, handle} <- source.resolve(log_dir, file) do
      {:ok, stat} = source.stat(handle)

      ts_opts = TsOpts.build(source, handle, file, opts)
      counts = count(source, handle, ts_opts)

      ts_parse_ratio =
        if counts.ts_sampled > 0,
          do: Float.round(counts.ts_parsed / counts.ts_sampled, 3),
          else: nil

      {:ok,
       %{
         file: Path.basename(file),
         size_bytes: stat.size_bytes,
         size_human: Formatting.humanize_bytes(stat.size_bytes),
         line_count: counts.lines,
         error_count: counts.errors,
         warn_count: counts.warns,
         fatal_count: counts.fatals,
         modified: stat.modified,
         ts_parse_ratio: ts_parse_ratio,
         ts_parse_sample: counts.ts_sampled
       }}
    end
  end

  defp count(source, handle, ts_opts) do
    case source.format(handle) do
      fmt when fmt in [:json_lines, :json_array] ->
        try do
          LogSource.stream_entries(source, handle, fmt)
          |> StatsCollector.count_json(ts_opts)
        rescue
          _ -> count_plain(source, handle, ts_opts)
        end

      :plain ->
        count_plain(source, handle, ts_opts)
    end
  end

  defp count_plain(source, handle, ts_opts) do
    handle
    |> source.stream_lines()
    |> StatsCollector.count_plain(ts_opts)
  end
end
