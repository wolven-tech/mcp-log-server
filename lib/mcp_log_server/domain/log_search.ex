defmodule McpLogServer.Domain.LogSearch do
  @moduledoc """
  Pure regex search over streams of plain-text lines or JSON-structured
  entries, with time filtering and context lines.

  All functions operate on enumerables supplied by the caller; I/O lives in
  the application layer (`McpLogServer.UseCases.SearchLogs`) and behind the
  `LogSource` port.

  When a time filter is active, results carry an `unparsed_ts` count — the
  number of scanned lines whose timestamp could not be parsed. Those lines
  pass the filter (fail-open), and the counter makes that degradation
  observable instead of silent. The counter is returned as data, never as a
  side effect, and costs nothing when no time filter is applied.

  When the `max_results` cap is actually hit, results carry an `omissions`
  block (`McpLogServer.Domain.Omissions`) saying how many matches were
  withheld — a capped result must never look complete. The block is absent
  when every match was returned.
  """

  alias McpLogServer.Domain.JsonLogParser
  alias McpLogServer.Domain.Omissions
  alias McpLogServer.Domain.TimeFilter

  @type log_entry :: %{line_number: pos_integer(), content: String.t()}
  @type search_result :: %{
          required(:file) => String.t(),
          required(:pattern) => String.t(),
          required(:returned_matches) => non_neg_integer(),
          required(:matches) => [log_entry()],
          optional(:unparsed_ts) => non_neg_integer(),
          optional(:omissions) => Omissions.t(),
          # attached by the search use-case on line-oriented scans (P6)
          optional(:cursor) => String.t(),
          optional(:cursor_reset) => true
        }

  @doc """
  Search an enumerable of `{line, index}` tuples for regex matches.

  `file_name` is only echoed into the result map. Context lines require the
  full line list, so the input is materialized. `ts_opts` (declared format,
  mtime reference) are forwarded to the time filter.
  """
  @spec match_plain(Enumerable.t(), Regex.t(), String.t(), String.t(),
          non_neg_integer(), non_neg_integer(), DateTime.t() | nil, DateTime.t() | nil,
          keyword()) :: {:ok, search_result()}
  def match_plain(indexed_lines, regex, pattern, file_name, max_results, context_lines, since, until_dt, ts_opts \\ []) do
    lines = Enum.to_list(indexed_lines)
    filter_active? = since != nil or until_dt != nil

    {in_range, unparsed} =
      Enum.reduce(lines, {[], 0}, fn {line, idx}, {acc, unparsed} ->
        {included?, status} = TimeFilter.classify(line, since, until_dt, ts_opts)
        unparsed = if status == :unparsed, do: unparsed + 1, else: unparsed
        acc = if included?, do: [{line, idx} | acc], else: acc
        {acc, unparsed}
      end)

    all_matched =
      in_range
      |> Enum.reverse()
      |> Enum.filter(fn {line, _idx} -> Regex.match?(regex, line) end)

    total_matched = length(all_matched)

    matches =
      all_matched
      |> Enum.take(max_results)
      |> Enum.map(fn {line, idx} ->
        entry = %{line_number: idx, content: line}

        if context_lines > 0 do
          ctx =
            lines
            |> Enum.filter(fn {_l, i} ->
              i >= idx - context_lines and i <= idx + context_lines and i != idx
            end)
            |> Enum.map_join("\n", fn {l, i} -> "  #{i}: #{l}" end)

          Map.put(entry, :context, ctx)
        else
          entry
        end
      end)

    result = %{
      file: file_name,
      pattern: pattern,
      returned_matches: length(matches),
      matches: matches
    }

    result = if filter_active?, do: Map.put(result, :unparsed_ts, unparsed), else: result

    omissions =
      Omissions.cap(Omissions.new(), :matches, total_matched, max_results, "first #{max_results}")

    {:ok, Omissions.attach(result, omissions)}
  end

  @doc """
  Search an enumerable of `{enriched_json_entry, index}` tuples for regex
  matches on a specific (dot-notation) field.
  """
  @spec match_json_field(Enumerable.t(), Regex.t(), String.t(), String.t(), String.t(),
          non_neg_integer(), DateTime.t() | nil, DateTime.t() | nil, keyword()) ::
          {:ok, search_result()}
  def match_json_field(entries, regex, pattern, field, file_name, max_results, since, until_dt, ts_opts \\ []) do
    keys = String.split(field, ".")
    filter_active? = since != nil or until_dt != nil
    field_match? = fn entry ->
      value = get_in(entry, keys)
      value != nil and Regex.match?(regex, to_string(value))
    end

    if filter_active? do
      {matched, unparsed} =
        Enum.reduce(entries, {[], 0}, fn {entry, idx}, {acc, unparsed} ->
          {included?, status} = TimeFilter.classify(entry, since, until_dt, ts_opts)
          unparsed = if status == :unparsed, do: unparsed + 1, else: unparsed
          acc = if included? and field_match?.(entry), do: [{entry, idx} | acc], else: acc
          {acc, unparsed}
        end)

      all_matched = Enum.reverse(matched)

      matches =
        all_matched
        |> Enum.take(max_results)
        |> Enum.map(fn {entry, idx} -> JsonLogParser.json_entry_to_toon_map(entry, idx) end)

      omissions =
        Omissions.cap(
          Omissions.new(),
          :matches,
          length(all_matched),
          max_results,
          "first #{max_results}"
        )

      {:ok,
       Omissions.attach(
         %{
           file: file_name,
           pattern: pattern,
           returned_matches: length(matches),
           matches: matches,
           unparsed_ts: unparsed
         },
         omissions
       )}
    else
      # No time filter: keep the lazy early-stop path (zero parse cost).
      # Take one extra match to learn whether the cap was hit; the honest
      # marker is `capped_at` because the full count is unknown here.
      taken =
        entries
        |> Stream.filter(fn {entry, _idx} -> field_match?.(entry) end)
        |> Enum.take(max_results + 1)

      capped? = length(taken) > max_results

      matches =
        taken
        |> Enum.take(max_results)
        |> Enum.map(fn {entry, idx} -> JsonLogParser.json_entry_to_toon_map(entry, idx) end)

      omissions =
        if capped?,
          do: Omissions.capped_at(Omissions.new(), :matches, max_results),
          else: Omissions.new()

      {:ok,
       Omissions.attach(
         %{
           file: file_name,
           pattern: pattern,
           returned_matches: length(matches),
           matches: matches
         },
         omissions
       )}
    end
  end

  @doc "Compile a regex pattern (case-insensitive)."
  @spec compile_pattern(String.t()) :: {:ok, Regex.t()} | {:error, String.t()}
  def compile_pattern(pattern) do
    case Regex.compile(pattern, "i") do
      {:ok, regex} -> {:ok, regex}
      {:error, _} -> {:error, "Invalid regex: #{pattern}"}
    end
  end
end
