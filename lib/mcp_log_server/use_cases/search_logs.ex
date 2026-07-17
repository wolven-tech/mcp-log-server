defmodule McpLogServer.UseCases.SearchLogs do
  @moduledoc """
  Use-case: search one log for a regex pattern, plain-text or JSON
  field-level, with time filtering and context lines.

  With `rollup: true` the search collapses matching lines into message
  templates (`McpLogServer.Domain.MessageTemplate`) instead of listing
  them: one row per template with count, distinct instances
  (`instances_seen: "1/3"`), and first/last timestamps — the one-call
  answer to "did X happen, on how many instances, when?". In rollup mode
  `file` may be omitted to scan ALL logs; files skipped by the read-size
  guardrail are reported in the result's `omissions`, never dropped
  silently.
  """

  alias McpLogServer.Domain.Cursor
  alias McpLogServer.Domain.LogSearch
  alias McpLogServer.Domain.TimestampParser
  alias McpLogServer.Ports.LogSource
  alias McpLogServer.UseCases.Deps
  alias McpLogServer.UseCases.IndexSeek
  alias McpLogServer.UseCases.RollupScan
  alias McpLogServer.UseCases.TsOpts

  @doc """
  Search `file` for `pattern`.

  ## Options

    * `:since` / `:until` - time range bounds
    * `:field` - JSON field to search in (dot-notation)
    * `:max_results` - max results (default: 50)
    * `:context` - context lines around match (default: 0)
    * `:rollup` - collapse matches into message templates (default: false);
      `file` may be `nil`/`""` to scan all logs
    * `:cursor` - opaque cursor from a previous call; only lines appended
      since are searched (line-oriented path only — incompatible with
      `:field` and `:rollup`)
    * `:source` - `LogSource` implementation (defaults to configured adapter)
  """
  @spec run(String.t(), String.t() | nil, String.t(), keyword()) ::
          {:ok, LogSearch.search_result() | RollupScan.rollup_result()} | {:error, String.t()}
  def run(log_dir, file, pattern, opts \\ []) do
    cursor_arg = Keyword.get(opts, :cursor)

    cond do
      Keyword.get(opts, :rollup, false) and cursor_arg != nil ->
        {:error, "cursor cannot be combined with rollup"}

      Keyword.get(opts, :rollup, false) ->
        run_rollup(log_dir, file, pattern, opts)

      true ->
        run_search(log_dir, file, pattern, opts)
    end
  end

  defp run_search(log_dir, file, pattern, opts) do
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
          if Keyword.get(opts, :cursor) != nil do
            {:error, "cursor cannot be combined with field (JSON field search)"}
          else
            LogSource.stream_entries(source, handle, fmt)
            |> LogSearch.match_json_field(regex, pattern, field, file_name, max_results, since, until_dt, ts_opts)
          end

        _ ->
          # Line-oriented path: read the whole content once so the polling
          # cursor (byte offset + rotation guard) can be computed. The
          # returned cursor lets the next poll search only appended lines.
          with {:ok, content} <- source.read(handle) do
            cursor_arg = Keyword.get(opts, :cursor)
            {start_offset, reset?} = Cursor.resolve(cursor_arg, file_name, content)

            # Index seek (issue #7 P7): with a since bound, no cursor, and
            # no context lines, skip the prefix the index PROVES excluded.
            # Context is index-incompatible: context lines around an early
            # match may lie before the bound (the full scan keeps them),
            # so seeking would change output — linear scan instead.
            {start_offset, index_used} =
              if cursor_arg == nil and context_lines == 0 do
                IndexSeek.content_offset(Deps.log_index(opts), handle, since, content)
              else
                {start_offset, if(since != nil and cursor_arg == nil, do: false, else: nil)}
              end

            {lines, start_line} = Cursor.slice_lines(content, start_offset)

            {:ok, result} =
              lines
              |> Enum.with_index(start_line)
              |> LogSearch.match_plain(regex, pattern, file_name, max_results, context_lines, since, until_dt, ts_opts)

            result = Map.put(result, :cursor, Cursor.encode(Cursor.state_for(file_name, content)))
            result = if reset?, do: Map.put(result, :cursor_reset, true), else: result

            result =
              if index_used != nil, do: Map.put(result, :index_used, index_used), else: result

            {:ok, result}
          end
      end
    end
  end

  defp run_rollup(log_dir, file, pattern, opts) do
    source = Deps.log_source(opts)
    field = Keyword.get(opts, :field)

    with {:ok, regex} <- LogSearch.compile_pattern(pattern) do
      files =
        case file do
          f when f in [nil, ""] ->
            {:ok, descriptors} = source.list(log_dir)
            Enum.map(descriptors, & &1.name)

          f ->
            [f]
        end

      matchers = %{
        plain: fn line -> Regex.match?(regex, line) end,
        json: json_matcher(regex, field)
      }

      {:ok, result} = RollupScan.scan(log_dir, files, matchers, opts)
      {:ok, Map.put(result, :pattern, pattern)}
    end
  end

  defp json_matcher(regex, nil) do
    fn entry -> Regex.match?(regex, RollupScan.json_content(entry)) end
  end

  defp json_matcher(regex, field) do
    keys = String.split(field, ".")

    fn entry ->
      value = get_in(entry, keys)
      value != nil and Regex.match?(regex, to_string(value))
    end
  end
end
