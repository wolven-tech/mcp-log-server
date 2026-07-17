defmodule McpLogServer.UseCases.AllErrors do
  @moduledoc """
  Use-case: extract errors from every log at once for a health overview.

  Nothing is withheld silently: logs that exceed the read-size guardrail
  are reported in the result's `omissions.skipped_files` (the exact silent
  failure from the incident this fixes — "line absent" when the truth was
  "file skipped"), and error entries dropped by the per-file cap are
  counted in `omissions.matches`. The block is absent when the scan was
  complete.

  With `rollup: true` the per-file listing is replaced by message-template
  rows (`McpLogServer.UseCases.RollupScan`): one row per template with
  count, `instances_seen`, and first/last timestamps.
  """

  alias McpLogServer.Domain.ErrorExtractor
  alias McpLogServer.Domain.Omissions
  alias McpLogServer.Config.Patterns
  alias McpLogServer.UseCases.Deps
  alias McpLogServer.UseCases.GetErrors
  alias McpLogServer.UseCases.RollupScan

  @doc """
  Collect errors from all logs in `log_dir`, at most `lines_per_file` each.

  Returns `{:ok, %{results: [...], unparsed_ts: n | nil, omissions: om}}`
  where `results` holds per-file error maps, `unparsed_ts` is the total
  count (across all scanned files) of lines whose timestamp could not be
  parsed while a time filter was active — those lines pass the filter
  (fail-open); `nil` when no time filter was applied — and `omissions`
  reports skipped files and capped entries (empty map when complete).

  With `rollup: true`, returns `{:ok, rollup_result}` instead (see
  `McpLogServer.UseCases.RollupScan.scan/4`), with the effective `:level`
  echoed back.

  Accepts the same filtering options as `McpLogServer.UseCases.GetErrors.run/4`.
  """
  @spec run(String.t(), pos_integer(), keyword()) ::
          {:ok,
           %{
             results: [map()],
             unparsed_ts: non_neg_integer() | nil,
             omissions: Omissions.t()
           }
           | RollupScan.rollup_result()}
          | {:error, String.t()}
  def run(log_dir, lines_per_file, opts \\ []) do
    if Keyword.get(opts, :rollup, false) do
      run_rollup(log_dir, opts)
    else
      run_listing(log_dir, lines_per_file, opts)
    end
  end

  defp run_listing(log_dir, lines_per_file, opts) do
    source = Deps.log_source(opts)
    filter_active? = Keyword.get(opts, :since) != nil or Keyword.get(opts, :until) != nil

    {:ok, files} = source.list(log_dir)

    {results, unparsed_total, omissions, omitted_total} =
      Enum.reduce(files, {[], 0, Omissions.new(), 0}, fn %{name: name}, {res, unparsed, om, omitted} ->
        case source.resolve_readable(log_dir, name) do
          {:error, reason} ->
            {res, unparsed, Omissions.skipped_file(om, name, reason), omitted}

          {:ok, _handle} ->
            case GetErrors.run(log_dir, name, lines_per_file, opts) do
              {:ok, %{entries: errors, unparsed_ts: file_unparsed} = file_result} ->
                unparsed = unparsed + (file_unparsed || 0)
                omitted = omitted + omitted_count(Map.get(file_result, :omissions, %{}))

                if errors != [] do
                  {res ++ [%{file: name, error_count: length(errors), matches: errors}],
                   unparsed, om, omitted}
                else
                  {res, unparsed, om, omitted}
                end

              _ ->
                {res, unparsed, om, omitted}
            end
        end
      end)

    omissions =
      Omissions.omitted(omissions, :matches, omitted_total, "newest #{lines_per_file} per file")

    {:ok,
     %{
       results: results,
       unparsed_ts: if(filter_active?, do: unparsed_total, else: nil),
       omissions: omissions
     }}
  end

  defp run_rollup(log_dir, opts) do
    source = Deps.log_source(opts)
    level = Keyword.get(opts, :level, :warn)
    exclude_str = Keyword.get(opts, :exclude)

    with {:ok, exclude_regex} <- ErrorExtractor.compile_exclude(exclude_str) do
      {:ok, files} = source.list(log_dir)

      matchers = %{
        plain: fn line ->
          Patterns.matches_level?(line, level) and
            not ErrorExtractor.excluded?(line, exclude_regex)
        end,
        json: fn entry ->
          ErrorExtractor.severity_at_least?(entry, level) and
            not ErrorExtractor.excluded?(entry["_message"] || "", exclude_regex)
        end
      }

      {:ok, result} = RollupScan.scan(log_dir, Enum.map(files, & &1.name), matchers, opts)
      {:ok, Map.put(result, :level, level)}
    end
  end

  defp omitted_count(%{matches: %{omitted: n}}), do: n
  defp omitted_count(_), do: 0
end
