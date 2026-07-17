defmodule McpLogServer.UseCases.GetErrors do
  @moduledoc """
  Use-case: extract error/warning entries from one log, plain-text or JSON,
  with severity, exclusion, and time filtering.
  """

  alias McpLogServer.Domain.ErrorExtractor
  alias McpLogServer.Domain.TimestampParser
  alias McpLogServer.Ports.LogSource
  alias McpLogServer.UseCases.Deps

  @doc """
  Extract error entries from `file`, keeping the last `max_lines` matches.

  ## Options

    * `:level` - minimum severity level atom (default `:warn`)
    * `:exclude` - regex string; matching entries are rejected
    * `:since` / `:until` - time range bounds
    * `:source` - `LogSource` implementation (defaults to configured adapter)
  """
  @spec run(String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, [map()]} | {:error, String.t()}
  def run(log_dir, file, max_lines, opts \\ []) do
    source = Deps.log_source(opts)
    level = Keyword.get(opts, :level, :warn)
    exclude_str = Keyword.get(opts, :exclude)
    since = TimestampParser.parse_time(Keyword.get(opts, :since))
    until_dt = TimestampParser.parse_time(Keyword.get(opts, :until))

    with {:ok, handle} <- source.resolve_readable(log_dir, file),
         {:ok, exclude_regex} <- ErrorExtractor.compile_exclude(exclude_str) do
      case source.format(handle) do
        fmt when fmt in [:json_lines, :json_array] ->
          LogSource.stream_entries(source, handle, fmt)
          |> ErrorExtractor.filter_json(max_lines, level, exclude_regex, since, until_dt)

        :plain ->
          handle
          |> source.stream_lines()
          |> Stream.with_index(1)
          |> ErrorExtractor.filter_plain(max_lines, level, exclude_regex, since, until_dt)
      end
    end
  end
end
