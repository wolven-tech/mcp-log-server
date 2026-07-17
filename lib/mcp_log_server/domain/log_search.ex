defmodule McpLogServer.Domain.LogSearch do
  @moduledoc """
  Pure regex search over streams of plain-text lines or JSON-structured
  entries, with time filtering and context lines.

  All functions operate on enumerables supplied by the caller; I/O lives in
  the application layer (`McpLogServer.UseCases.SearchLogs`) and behind the
  `LogSource` port.
  """

  alias McpLogServer.Domain.JsonLogParser
  alias McpLogServer.Domain.TimeFilter

  @type log_entry :: %{line_number: pos_integer(), content: String.t()}
  @type search_result :: %{
          file: String.t(),
          pattern: String.t(),
          returned_matches: non_neg_integer(),
          matches: [log_entry()]
        }

  @doc """
  Search an enumerable of `{line, index}` tuples for regex matches.

  `file_name` is only echoed into the result map. Context lines require the
  full line list, so the input is materialized.
  """
  @spec match_plain(Enumerable.t(), Regex.t(), String.t(), String.t(),
          non_neg_integer(), non_neg_integer(), DateTime.t() | nil, DateTime.t() | nil) ::
          {:ok, search_result()}
  def match_plain(indexed_lines, regex, pattern, file_name, max_results, context_lines, since, until_dt) do
    lines = Enum.to_list(indexed_lines)

    matches =
      lines
      |> Enum.filter(fn {line, _idx} ->
        TimeFilter.in_range?(line, since, until_dt) and Regex.match?(regex, line)
      end)
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

    {:ok,
     %{
       file: file_name,
       pattern: pattern,
       returned_matches: length(matches),
       matches: matches
     }}
  end

  @doc """
  Search an enumerable of `{enriched_json_entry, index}` tuples for regex
  matches on a specific (dot-notation) field.
  """
  @spec match_json_field(Enumerable.t(), Regex.t(), String.t(), String.t(), String.t(),
          non_neg_integer(), DateTime.t() | nil, DateTime.t() | nil) :: {:ok, search_result()}
  def match_json_field(entries, regex, pattern, field, file_name, max_results, since, until_dt) do
    keys = String.split(field, ".")

    matches =
      entries
      |> Stream.filter(fn {entry, _idx} ->
        value = get_in(entry, keys)

        TimeFilter.in_range?(entry, since, until_dt) and
          value != nil and
          Regex.match?(regex, to_string(value))
      end)
      |> Enum.take(max_results)
      |> Enum.map(fn {entry, idx} ->
        JsonLogParser.json_entry_to_toon_map(entry, idx)
      end)

    {:ok,
     %{
       file: file_name,
       pattern: pattern,
       returned_matches: length(matches),
       matches: matches
     }}
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
