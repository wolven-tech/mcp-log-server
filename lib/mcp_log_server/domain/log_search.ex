defmodule McpLogServer.Domain.LogSearch do
  @moduledoc """
  Searches log files for lines matching a regex pattern, supporting
  both plain-text and JSON field-level searches with time filtering.
  """

  alias McpLogServer.Domain.FileAccess
  alias McpLogServer.Domain.FormatDetector
  alias McpLogServer.Domain.JsonLogParser
  alias McpLogServer.Domain.TimeFilter
  alias McpLogServer.Domain.TimestampParser

  @type log_entry :: %{line_number: pos_integer(), content: String.t()}
  @type search_result :: %{
          file: String.t(),
          pattern: String.t(),
          returned_matches: non_neg_integer(),
          matches: [log_entry()]
        }

  @doc """
  Search a log file for lines matching a regex pattern.

  ## Options

    * `:since` - only include lines from this time onward
    * `:until` - only include lines up to this time
    * `:field` - JSON field to search in (dot-notation)
    * `:max_results` - max results (default: 50)
    * `:context` - context lines around match (default: 0)
  """
  @spec search(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, search_result()} | {:error, String.t()}
  def search(log_dir, file, pattern, opts \\ []) do
    max_results = Keyword.get(opts, :max_results, 50)
    context_lines = Keyword.get(opts, :context, 0)
    field = Keyword.get(opts, :field)
    since = parse_time_opt(Keyword.get(opts, :since))
    until_dt = parse_time_opt(Keyword.get(opts, :until))

    with {:ok, path} <- FileAccess.resolve(log_dir, file),
         {:ok, regex} <- compile_pattern(pattern) do
      format = FormatDetector.detect(path)

      case {format, field} do
        {fmt, field} when fmt in [:json_lines, :json_array] and field != nil ->
          search_json_field(path, fmt, regex, pattern, field, max_results, since, until_dt)

        _ ->
          search_plain(path, regex, pattern, max_results, context_lines, since, until_dt)
      end
    end
  end

  @doc false
  def search_plain(path, regex, pattern, max_results, context_lines, since, until_dt) do
    lines = FileAccess.read_indexed(path)

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
       file: Path.basename(path),
       pattern: pattern,
       returned_matches: length(matches),
       matches: matches
     }}
  end

  @doc false
  def search_json_field(path, format, regex, pattern, field, max_results, since, until_dt) do
    case JsonLogParser.parse_entries(path, format) do
      {:ok, entries} ->
        keys = String.split(field, ".")

        matches =
          entries
          |> Enum.with_index(1)
          |> Enum.filter(fn {entry, _idx} ->
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
           file: Path.basename(path),
           pattern: pattern,
           returned_matches: length(matches),
           matches: matches
         }}

      {:error, reason} ->
        {:error, reason}
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

  defp parse_time_opt(nil), do: nil

  defp parse_time_opt(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> TimestampParser.parse_relative(value)
    end
  end

  defp parse_time_opt(_), do: nil
end
