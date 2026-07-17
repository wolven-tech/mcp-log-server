defmodule McpLogServer.UseCases.GetErrors do
  @moduledoc """
  Use-case: extract error/warning entries from one log, plain-text or JSON,
  with severity, exclusion, and time filtering.
  """

  alias McpLogServer.Domain.ErrorExtractor
  alias McpLogServer.Domain.TimestampParser
  alias McpLogServer.Ports.LogSource
  alias McpLogServer.UseCases.Deps
  alias McpLogServer.UseCases.TsOpts

  @doc """
  Extract error entries from `file`, keeping the last `max_lines` matches.

  ## Options

    * `:level` - minimum severity level atom (default `:warn`)
    * `:exclude` - regex string; matching entries are rejected
    * `:since` / `:until` - time range bounds
    * `:source` - `LogSource` implementation (defaults to configured adapter)
    * `:ts_format` - compiled declared timestamp format override (tests)

  Returns `{:ok, %{entries: entries, unparsed_ts: n | nil, omissions: om}}` —
  `unparsed_ts` counts scanned lines whose timestamp could not be parsed
  while a time filter was active (fail-open: they pass the filter); `nil`
  when no time filter was applied. `omissions` reports how many matching
  entries the `max_lines` cap withheld (empty map when none were).
  """
  @spec run(String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok,
           %{
             entries: [map()],
             unparsed_ts: non_neg_integer() | nil,
             omissions: McpLogServer.Domain.Omissions.t()
           }}
          | {:error, String.t()}
  def run(log_dir, file, max_lines, opts \\ []) do
    source = Deps.log_source(opts)
    level = Keyword.get(opts, :level, :warn)
    exclude_str = Keyword.get(opts, :exclude)
    since = TimestampParser.parse_time(Keyword.get(opts, :since))
    until_dt = TimestampParser.parse_time(Keyword.get(opts, :until))

    with {:ok, handle} <- source.resolve_readable(log_dir, file),
         {:ok, exclude_regex} <- ErrorExtractor.compile_exclude(exclude_str) do
      ts_opts = TsOpts.build(source, handle, file, opts)

      case source.format(handle) do
        fmt when fmt in [:json_lines, :json_array] ->
          LogSource.stream_entries(source, handle, fmt)
          |> ErrorExtractor.filter_json(max_lines, level, exclude_regex, since, until_dt, ts_opts)

        :plain ->
          handle
          |> source.stream_lines()
          |> Stream.with_index(1)
          |> ErrorExtractor.filter_plain(max_lines, level, exclude_regex, since, until_dt, ts_opts)
      end
    end
  end
end
