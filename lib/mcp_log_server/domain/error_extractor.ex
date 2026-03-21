defmodule McpLogServer.Domain.ErrorExtractor do
  @moduledoc """
  Extracts error, warning, and fatal log entries from both plain-text
  and JSON-structured log files with severity filtering and exclusion patterns.
  """

  alias McpLogServer.Config.Patterns
  alias McpLogServer.Domain.FileAccess
  alias McpLogServer.Domain.FormatDispatch
  alias McpLogServer.Domain.JsonLogParser
  alias McpLogServer.Domain.TimeFilter
  alias McpLogServer.Domain.TimestampParser

  @type log_entry :: %{line_number: pos_integer(), content: String.t()}

  @json_severity_to_atom %{
    "fatal" => :fatal,
    "error" => :error,
    "exception" => :error,
    "warn" => :warn,
    "warning" => :warn,
    "info" => :info,
    "debug" => :debug,
    "trace" => :trace
  }

  @doc """
  Extract error/warning lines from a log file.

  ## Options

    * `:level` — minimum severity level (atom). Default `:warn`.
      - `:fatal` — only FATAL/PANIC
      - `:error` — ERROR and FATAL
      - `:warn`  — WARN, ERROR, and FATAL (backward compatible default)
      - `:info`  — INFO and above
    * `:exclude` — regex string; matching lines are rejected after severity filtering.
    * `:since` — only include lines from this time onward
    * `:until` — only include lines up to this time
  """
  @spec get_errors(String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, [log_entry()]} | {:error, String.t()}
  def get_errors(log_dir, file, max_lines, opts \\ []) do
    level = Keyword.get(opts, :level, :warn)
    exclude_str = Keyword.get(opts, :exclude)
    since = parse_time_opt(Keyword.get(opts, :since))
    until_dt = parse_time_opt(Keyword.get(opts, :until))

    with {:ok, path} <- FileAccess.resolve_with_size_check(log_dir, file),
         {:ok, exclude_regex} <- compile_exclude(exclude_str) do
      FormatDispatch.dispatch(
        path,
        fn fmt -> get_errors_json(path, fmt, max_lines, level, exclude_regex, since, until_dt) end,
        fn -> get_errors_plain(path, max_lines, level, exclude_regex, since, until_dt) end
      )
    end
  end

  @doc false
  def compile_exclude(nil), do: {:ok, nil}

  def compile_exclude(pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} -> {:ok, regex}
      {:error, {msg, _}} -> {:error, "Invalid exclude pattern: #{msg}"}
      {:error, msg} -> {:error, "Invalid exclude pattern: #{msg}"}
    end
  end

  @doc false
  def excluded?(_, nil), do: false
  def excluded?(text, regex), do: Regex.match?(regex, text)

  @doc false
  def get_errors_plain(path, max_lines, level, exclude_regex, since, until_dt) do
    errors =
      path
      |> File.stream!()
      |> Stream.map(&String.trim_trailing/1)
      |> Stream.with_index(1)
      |> Stream.filter(fn {line, _idx} ->
        TimeFilter.in_range?(line, since, until_dt) and
          Patterns.matches_level?(line, level) and
          not excluded?(line, exclude_regex)
      end)
      |> Enum.take(-max_lines)
      |> Enum.map(fn {line, idx} -> %{line_number: idx, content: line} end)

    {:ok, errors}
  end

  @doc false
  def get_errors_json(path, format, max_lines, level, exclude_regex, since, until_dt) do
    threshold = Patterns.level_value(level)

    errors =
      JsonLogParser.stream_entries(path, format)
      |> Stream.filter(fn {entry, _idx} ->
        severity = entry["_severity"]
        atom_level = Map.get(@json_severity_to_atom, severity)

        TimeFilter.in_range?(entry, since, until_dt) and
          atom_level != nil and
          Patterns.level_value(atom_level) >= threshold and
          not excluded?(entry["_message"] || "", exclude_regex)
      end)
      |> Enum.to_list()
      |> Enum.take(-max_lines)
      |> Enum.map(fn {entry, idx} ->
        JsonLogParser.json_entry_to_toon_map(entry, idx)
      end)

    {:ok, errors}
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
