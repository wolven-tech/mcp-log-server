defmodule McpLogServer.UseCases.SearchLogs do
  @moduledoc """
  Use-case: search one log for a regex pattern, plain-text or JSON
  field-level, with time filtering and context lines.
  """

  alias McpLogServer.Domain.LogSearch
  alias McpLogServer.Domain.TimestampParser
  alias McpLogServer.Ports.LogSource
  alias McpLogServer.UseCases.Deps
  alias McpLogServer.UseCases.TsOpts

  @doc """
  Search `file` for `pattern`.

  ## Options

    * `:since` / `:until` - time range bounds
    * `:field` - JSON field to search in (dot-notation)
    * `:max_results` - max results (default: 50)
    * `:context` - context lines around match (default: 0)
    * `:source` - `LogSource` implementation (defaults to configured adapter)
  """
  @spec run(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, LogSearch.search_result()} | {:error, String.t()}
  def run(log_dir, file, pattern, opts \\ []) do
    source = Deps.log_source(opts)
    max_results = Keyword.get(opts, :max_results, 50)
    context_lines = Keyword.get(opts, :context, 0)
    field = Keyword.get(opts, :field)
    since = TimestampParser.parse_time(Keyword.get(opts, :since))
    until_dt = TimestampParser.parse_time(Keyword.get(opts, :until))

    with {:ok, handle} <- source.resolve_readable(log_dir, file),
         {:ok, regex} <- LogSearch.compile_pattern(pattern) do
      file_name = Path.basename(file)
      ts_opts = TsOpts.build(source, handle, file, opts)

      case {source.format(handle), field} do
        {fmt, field} when fmt in [:json_lines, :json_array] and field != nil ->
          LogSource.stream_entries(source, handle, fmt)
          |> LogSearch.match_json_field(regex, pattern, field, file_name, max_results, since, until_dt, ts_opts)

        _ ->
          handle
          |> source.stream_lines()
          |> Stream.with_index(1)
          |> LogSearch.match_plain(regex, pattern, file_name, max_results, context_lines, since, until_dt, ts_opts)
      end
    end
  end
end
