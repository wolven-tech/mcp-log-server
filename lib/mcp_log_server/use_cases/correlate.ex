defmodule McpLogServer.UseCases.Correlate do
  @moduledoc """
  Use-case: search for a correlation value (session ID, trace ID, ...) across
  ALL logs of a source and return a unified timeline sorted by timestamp.
  """

  alias McpLogServer.Domain.Correlator
  alias McpLogServer.Ports.LogSource
  alias McpLogServer.UseCases.Deps
  alias McpLogServer.UseCases.TsOpts

  @default_max_results 200

  @doc """
  Search for `value` across all logs in `log_dir`.

  ## Options

    * `:field` - restrict matching to this field (dot-notation for JSON,
      pattern matching for plain text). When nil, performs deep search.
    * `:max_results` - cap on total results across all files (default #{@default_max_results})
    * `:source` - `LogSource` implementation (defaults to configured adapter)
  """
  @spec run(String.t(), String.t(), keyword()) :: {:ok, Correlator.correlation_result()}
  def run(log_dir, value, opts \\ []) do
    source = Deps.log_source(opts)
    field = Keyword.get(opts, :field)
    max_results = Keyword.get(opts, :max_results, @default_max_results)

    {:ok, files} = source.list(log_dir)

    all_entries =
      Enum.flat_map(files, fn file_info ->
        case source.resolve(log_dir, file_info.name) do
          {:ok, handle} -> search_one(source, handle, file_info.name, value, field, opts)
          {:error, _} -> []
        end
      end)

    capped =
      all_entries
      |> Correlator.sort_timeline()
      |> Enum.take(max_results)

    files_matched =
      capped
      |> Enum.map(& &1.file)
      |> Enum.uniq()

    # Matched entries whose timestamp could not be parsed cannot be placed
    # in the timeline order (they sort last) — surface the count instead of
    # failing silently.
    unparsed_ts = Enum.count(capped, &is_nil(&1.timestamp))

    {:ok,
     %{
       value: value,
       field: field,
       total_matches: length(capped),
       files_matched: files_matched,
       timeline: capped,
       unparsed_ts: unparsed_ts
     }}
  end

  defp search_one(source, handle, basename, value, field, opts) do
    case source.format(handle) do
      fmt when fmt in [:json_lines, :json_array] ->
        LogSource.stream_entries(source, handle, fmt)
        |> Correlator.json_timeline(basename, value, field)

      :plain ->
        ts_opts = TsOpts.build(source, handle, basename, opts)

        handle
        |> source.stream_lines()
        |> Stream.with_index(1)
        |> Correlator.plain_timeline(basename, value, field, ts_opts)
    end
  end
end
