defmodule McpLogServer.Protocol.ResponseFormatter do
  @moduledoc """
  Centralised response formatting for all tool modules.

  Each tool produces structured data and delegates formatting here,
  keeping tool modules focused on argument parsing and domain calls.
  """

  alias McpLogServer.Protocol.ToonEncoder

  @type shape ::
          :entries
          | :tail
          | :search_results
          | :error_results
          | :stats
          | :correlation
          | :multi_file_errors
          | :rollup

  @doc """
  Format structured tool output into a string ready for the MCP response.

  * `shape`      – describes the kind of data (see `t:shape/0`)
  * `data`       – the structured data produced by the domain layer
  * `format_opt` – `"toon"`, `"json"`, or `nil` (auto)
  """
  @spec format(shape(), term(), String.t() | nil) :: String.t()
  def format(shape, data, format_opt \\ nil)

  # :entries — simple tabular list (list_logs, trace_ids). A map form
  # carries metadata next to the rows (e.g. an omissions block); the meta
  # line only appears when metadata is present, so complete results stay
  # identical to the bare-list form.
  def format(:entries, items, _format_opt) when is_list(items) do
    ToonEncoder.format_response(%{entries: items})
  end

  def format(:entries, %{entries: _} = data, format_opt) do
    ToonEncoder.format_response(data, format_opt)
  end

  # :tail — raw content with a header line (tail_log). When a time filter
  # was active, `unparsed_ts` (lines that passed the filter because their
  # timestamp could not be parsed — fail-open) is appended to the header.
  # When the line cap was hit, the omissions block is appended too — a
  # truncated tail must say so.
  def format(:tail, %{file: file, lines: lines, content: content} = data, format_opt) do
    unparsed_ts = Map.get(data, :unparsed_ts)
    omissions = Map.get(data, :omissions)

    if format_opt == "json" do
      payload = %{file: file, lines: lines, content: content}

      payload =
        if unparsed_ts != nil, do: Map.put(payload, :unparsed_ts, unparsed_ts), else: payload

      payload = if omissions != nil, do: Map.put(payload, :omissions, omissions), else: payload

      Jason.encode!(payload)
    else
      header = "# tail #{file} (last #{lines} lines)"
      header = if unparsed_ts != nil, do: header <> "\n# unparsed_ts: #{unparsed_ts}", else: header

      header =
        if omissions != nil,
          do: header <> "\n# omissions: #{Jason.encode!(omissions)}",
          else: header

      "#{header}\n#{content}"
    end
  end

  # :search_results — tabular with metadata (search_logs)
  def format(:search_results, results, format_opt) do
    ToonEncoder.format_response(results, format_opt)
  end

  # :error_results — tabular with metadata (get_errors)
  def format(:error_results, %{file: _, error_count: _, matches: _} = data, format_opt) do
    ToonEncoder.format_response(data, format_opt)
  end

  # :stats — JSON map (log_stats, time_range)
  def format(:stats, map, _format_opt) when is_map(map) do
    Jason.encode!(map)
  end

  # :correlation — timeline with meta (correlate). The omissions block
  # rides in the meta line only when the match cap was actually hit.
  def format(:correlation, result, format_opt) do
    if format_opt == "json" do
      Jason.encode!(result)
    else
      meta_map = %{
        value: result.value,
        total_matches: result.total_matches,
        files_matched: result.files_matched,
        unparsed_ts: Map.get(result, :unparsed_ts, 0)
      }

      meta_map =
        case Map.get(result, :omissions) do
          nil -> meta_map
          omissions -> Map.put(meta_map, :omissions, omissions)
        end

      toon = ToonEncoder.format_response(%{matches: result.timeline})
      "# #{Jason.encode!(meta_map)}\n#{toon}"
    end
  end

  # :rollup — message-template rows with meta (search_logs / all_errors
  # with rollup: true)
  def format(:rollup, data, format_opt) do
    ToonEncoder.format_response(data, format_opt)
  end

  # :multi_file_errors — aggregated per-file errors (all_errors)
  def format(:multi_file_errors, [], _format_opt) do
    "No errors found in any log file."
  end

  def format(:multi_file_errors, results, _format_opt) when is_list(results) do
    Enum.map_join(results, "\n\n", fn r ->
      "--- #{r.file} (#{r.error_count} errors) ---\n" <>
        ToonEncoder.format_response(%{matches: r.matches})
    end)
  end
end
