defmodule McpLogServer.UseCases.RollupScan do
  @moduledoc """
  Shared scanning engine for rollup mode (`rollup: true` on `search_logs`
  and `all_errors`).

  Streams every requested file, keeps lines accepted by the caller's
  matcher, and collapses them into message templates
  (`McpLogServer.Domain.Rollup`) with per-template counts, distinct
  instances, and first/last timestamps.

  The instance dimension is the line's source tag (`[src:<name>] `, slice
  003) when present, else the file name — so N streamed sources rolled into
  one directory still count as N instances, and rotated files
  (`fly.1.log`) collapse into their logical source instead of inflating the
  denominator.

  Truncation honesty: files rejected by the read-size guardrail
  (`MAX_LOG_FILE_MB`) are NOT silently dropped — they appear in the
  result's `omissions.skipped_files`, because a scan that quietly excluded
  the biggest file is the exact silent failure this exists to prevent.
  """

  alias McpLogServer.Domain.Omissions
  alias McpLogServer.Domain.Rollup
  alias McpLogServer.Domain.SourceTag
  alias McpLogServer.Domain.TimeFilter
  alias McpLogServer.Domain.TimestampParser
  alias McpLogServer.Ports.LogSource
  alias McpLogServer.UseCases.Deps
  alias McpLogServer.UseCases.TsOpts

  @type matchers :: %{plain: (String.t() -> boolean()), json: (map() -> boolean())}
  @type rollup_result :: %{
          required(:rollup) => true,
          required(:sources_scanned) => non_neg_integer(),
          required(:entries) => [Rollup.row()],
          optional(:unparsed_ts) => non_neg_integer(),
          optional(:omissions) => Omissions.t()
        }

  @doc """
  Scan `file_names` under `log_dir`, rolling matched lines into templates.

  `matchers.plain` receives each raw line; `matchers.json` receives each
  enriched JSON entry. Honors `:since` / `:until` (fail-open, counted in
  `unparsed_ts` exactly like non-rollup scans) and the usual `:source` /
  `:ts_format` injection points.
  """
  @spec scan(String.t(), [String.t()], matchers(), keyword()) :: {:ok, rollup_result()}
  def scan(log_dir, file_names, matchers, opts \\ []) do
    source = Deps.log_source(opts)
    since = TimestampParser.parse_time(Keyword.get(opts, :since))
    until_dt = TimestampParser.parse_time(Keyword.get(opts, :until))
    filter? = since != nil or until_dt != nil

    initial = %{
      acc: Rollup.new(),
      universe: MapSet.new(),
      unparsed: 0,
      om: Omissions.new()
    }

    state =
      Enum.reduce(file_names, initial, fn name, state ->
        case source.resolve_readable(log_dir, name) do
          {:error, reason} ->
            %{state | om: Omissions.skipped_file(state.om, name, reason)}

          {:ok, handle} ->
            scan_file(source, handle, name, matchers, {since, until_dt, filter?}, opts, state)
        end
      end)

    result = %{
      rollup: true,
      sources_scanned: MapSet.size(state.universe),
      entries: Rollup.finalize(state.acc, MapSet.size(state.universe))
    }

    result = if filter?, do: Map.put(result, :unparsed_ts, state.unparsed), else: result
    {:ok, Omissions.attach(result, state.om)}
  end

  defp scan_file(source, handle, name, matchers, bounds, opts, state) do
    ts_opts = TsOpts.build(source, handle, name, opts)

    case source.format(handle) do
      fmt when fmt in [:json_lines, :json_array] ->
        scan_json(source, handle, name, fmt, matchers.json, bounds, ts_opts, state)

      :plain ->
        scan_plain(source, handle, name, matchers.plain, bounds, ts_opts, state)
    end
  end

  defp scan_plain(source, handle, name, match?, {since, until_dt, filter?}, ts_opts, state) do
    {acc, unparsed, instances, first} =
      source.stream_lines(handle)
      |> Enum.reduce({state.acc, state.unparsed, MapSet.new(), nil}, fn line,
                                                                        {acc, unparsed, insts,
                                                                         first} ->
        # The file's own instance identity, from its first line's tag (a
        # tagged file carries one tag throughout), else the file name.
        first = first || SourceTag.source_of(line) || name

        {included?, status} =
          if filter?,
            do: TimeFilter.classify(line, since, until_dt, ts_opts),
            else: {true, :no_filter}

        unparsed = if status == :unparsed, do: unparsed + 1, else: unparsed

        if included? and match?.(line) do
          instance = SourceTag.source_of(line) || name
          ts = TimestampParser.extract(line, ts_opts)
          {Rollup.add(acc, line, instance, ts), unparsed, MapSet.put(insts, instance), first}
        else
          {acc, unparsed, insts, first}
        end
      end)

    universe =
      state.universe
      |> MapSet.union(instances)
      |> MapSet.put(first || name)

    %{state | acc: acc, unparsed: unparsed, universe: universe}
  end

  defp scan_json(source, handle, name, fmt, match?, {since, until_dt, filter?}, ts_opts, state) do
    {acc, unparsed} =
      LogSource.stream_entries(source, handle, fmt)
      |> Enum.reduce({state.acc, state.unparsed}, fn {entry, _idx}, {acc, unparsed} ->
        {included?, status} =
          if filter?,
            do: TimeFilter.classify(entry, since, until_dt, ts_opts),
            else: {true, :no_filter}

        unparsed = if status == :unparsed, do: unparsed + 1, else: unparsed

        if included? and match?.(entry) do
          ts = TimestampParser.parse_json_value(entry["_timestamp"], ts_opts)
          {Rollup.add(acc, json_content(entry), name, ts), unparsed}
        else
          {acc, unparsed}
        end
      end)

    %{state | acc: acc, unparsed: unparsed, universe: MapSet.put(state.universe, name)}
  end

  @doc "The searchable text of an enriched JSON entry: its message, else the raw payload."
  @spec json_content(map()) :: String.t()
  def json_content(entry) do
    entry["_message"] ||
      Jason.encode!(Map.drop(entry, ["_severity", "_message", "_timestamp"]))
  end
end
