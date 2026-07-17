defmodule McpLogServer.UseCases.Aggregate do
  @moduledoc """
  Use-case: aggregate/facet on a JSON field across one log or all logs
  (slice 005, P4).

  Answers the structured-field questions regex cannot answer cheaply:

    * `exists` — "did ANY line emit `fields.gated`?" → counts of lines
      with/without the field plus one sample matching line
    * `values` — "group by `fields.region`" → a capped histogram of
      distinct values (cap reported via `omissions`)
    * `count`  — total occurrences of the field

  Honesty rules from slices 002/004:

    * lines that do not decode to a JSON object are counted in `non_json` —
      a plain-text file cannot prove field absence, and pretending it can
      would be the silent failure this server refuses to reproduce;
    * with `since`/`until` active, `unparsed_ts` counts fail-open lines;
    * files skipped by the read-size guardrail land in
      `omissions.skipped_files`, never disappear.
  """

  alias McpLogServer.Domain.FieldAggregator
  alias McpLogServer.Domain.JsonLogParser
  alias McpLogServer.Domain.LogSearch
  alias McpLogServer.Domain.Omissions
  alias McpLogServer.Domain.TimeFilter
  alias McpLogServer.Domain.TimestampParser
  alias McpLogServer.UseCases.Deps
  alias McpLogServer.UseCases.RollupScan
  alias McpLogServer.UseCases.TsOpts

  @default_max_values 50
  @ops ~w(exists values count)

  @doc """
  Aggregate `field` (dot-path) with `op` over `file` (or ALL logs when
  `file` is nil/"").

  ## Options

    * `:pattern` - regex pre-filter; only lines matching it are considered
    * `:since` / `:until` - time range bounds (fail-open, `unparsed_ts`)
    * `:max_values` - histogram cap for `op: values` (default #{@default_max_values})
    * `:source` - `LogSource` implementation (defaults to configured adapter)
  """
  @spec run(String.t(), String.t() | nil, String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def run(log_dir, file, field, op, opts \\ [])

  def run(_log_dir, _file, field, _op, _opts) when field in [nil, ""] do
    {:error, "field is required (dot-path into JSON lines, e.g. \"fields.region\")"}
  end

  def run(log_dir, file, field, op, opts) do
    with {:ok, op} <- validate_op(op),
         {:ok, regex} <- compile_pattern(Keyword.get(opts, :pattern)) do
      source = Deps.log_source(opts)
      max_values = Keyword.get(opts, :max_values, @default_max_values)
      since = TimestampParser.parse_time(Keyword.get(opts, :since))
      until_dt = TimestampParser.parse_time(Keyword.get(opts, :until))
      filter? = since != nil or until_dt != nil
      keys = String.split(field, ".")

      with {:ok, files} <- target_files(source, log_dir, file) do
        initial = %{agg: FieldAggregator.new(), unparsed: 0, om: Omissions.new()}

        state =
          Enum.reduce(files, initial, fn name, state ->
            case source.resolve_readable(log_dir, name) do
              {:error, reason} ->
                %{state | om: Omissions.skipped_file(state.om, name, reason)}

              {:ok, handle} ->
                scan_file(source, handle, name, keys, regex, {since, until_dt, filter?}, opts, state)
            end
          end)

        {result, values_om} = FieldAggregator.finalize(state.agg, op, max_values)

        result =
          Map.merge(result, %{
            field: field,
            op: Atom.to_string(op),
            files_scanned: length(files) - length(Map.get(state.om, :skipped_files, []))
          })

        result = if filter?, do: Map.put(result, :unparsed_ts, state.unparsed), else: result
        {:ok, Omissions.attach(result, Map.merge(state.om, values_om))}
      end
    end
  end

  # An explicitly named file that cannot be read is an ERROR — only files
  # discovered by the all-logs scan degrade into omissions.skipped_files.
  defp target_files(source, log_dir, file) when file in [nil, ""] do
    {:ok, descriptors} = source.list(log_dir)
    {:ok, Enum.map(descriptors, & &1.name)}
  end

  defp target_files(source, log_dir, file) do
    with {:ok, _handle} <- source.resolve_readable(log_dir, file), do: {:ok, [file]}
  end

  defp scan_file(source, handle, name, keys, regex, bounds, opts, state) do
    ts_opts = TsOpts.build(source, handle, name, opts)

    case source.format(handle) do
      :json_array ->
        scan_array_entries(source, handle, keys, regex, bounds, ts_opts, state)

      _line_oriented ->
        scan_lines(source, handle, keys, regex, bounds, ts_opts, state)
    end
  end

  # :plain and :json_lines both scan line by line; JSON-ness is decided per
  # line so a mixed file (NDJSON with stray plain lines) counts honestly.
  defp scan_lines(source, handle, keys, regex, {since, until_dt, filter?}, ts_opts, state) do
    source.stream_lines(handle)
    |> Enum.reduce(state, fn line, state ->
      case Jason.decode(line) do
        {:ok, map} when is_map(map) ->
          entry = JsonLogParser.enrich(map)
          fold(state, {:entry, entry, line}, regex, keys, {since, until_dt, filter?}, ts_opts)

        _ ->
          fold(state, {:non_json, line}, regex, keys, {since, until_dt, filter?}, ts_opts)
      end
    end)
  end

  defp scan_array_entries(source, handle, keys, regex, bounds, ts_opts, state) do
    McpLogServer.Ports.LogSource.stream_entries(source, handle, :json_array)
    |> Enum.reduce(state, fn {entry, _idx}, state ->
      fold(state, {:entry, entry, RollupScan.json_content(entry)}, regex, keys, bounds, ts_opts)
    end)
  end

  defp fold(state, item, regex, keys, {since, until_dt, filter?}, ts_opts) do
    {classified, raw} =
      case item do
        {:entry, entry, raw} -> {entry, raw}
        {:non_json, line} -> {line, line}
      end

    {included?, status} =
      if filter?,
        do: TimeFilter.classify(classified, since, until_dt, ts_opts),
        else: {true, :no_filter}

    state = if status == :unparsed, do: %{state | unparsed: state.unparsed + 1}, else: state

    if included? and (regex == nil or Regex.match?(regex, raw)) do
      case item do
        {:entry, entry, raw} -> %{state | agg: FieldAggregator.add_entry(state.agg, keys, entry, raw)}
        {:non_json, _line} -> %{state | agg: FieldAggregator.add_non_json(state.agg)}
      end
    else
      state
    end
  end

  defp validate_op(op) when op in @ops, do: {:ok, String.to_existing_atom(op)}
  defp validate_op(op) when is_atom(op) and op in [:exists, :values, :count], do: {:ok, op}

  defp validate_op(op),
    do: {:error, "Invalid op: #{inspect(op)}. Expected one of: #{Enum.join(@ops, ", ")}"}

  defp compile_pattern(nil), do: {:ok, nil}
  defp compile_pattern(pattern), do: LogSearch.compile_pattern(pattern)
end
