defmodule McpLogServer.Domain.ErrorExtractor do
  @moduledoc """
  Pure error/warning extraction from streams of plain-text lines or
  JSON-structured entries, with severity filtering and exclusion patterns.

  All functions operate on enumerables supplied by the caller; I/O lives in
  the application layer (`McpLogServer.UseCases.GetErrors`) and behind the
  `LogSource` port.
  """

  alias McpLogServer.Config.Patterns
  alias McpLogServer.Domain.JsonLogParser
  alias McpLogServer.Domain.TimeFilter

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
  Filter an enumerable of `{line, index}` tuples down to error entries.

  Applies time-range, severity, and exclusion filters, keeps the last
  `max_lines` matches, and shapes them as log entries.

  `level` is the minimum severity level (atom), default semantics:
    - `:fatal` — only FATAL/PANIC
    - `:error` — ERROR and FATAL
    - `:warn`  — WARN, ERROR, and FATAL
    - `:info`  — INFO and above
  """
  @spec filter_plain(Enumerable.t(), pos_integer(), atom(), Regex.t() | nil,
          DateTime.t() | nil, DateTime.t() | nil) :: {:ok, [log_entry()]}
  def filter_plain(indexed_lines, max_lines, level, exclude_regex, since, until_dt) do
    errors =
      indexed_lines
      |> Stream.filter(fn {line, _idx} ->
        TimeFilter.in_range?(line, since, until_dt) and
          Patterns.matches_level?(line, level) and
          not excluded?(line, exclude_regex)
      end)
      |> Enum.take(-max_lines)
      |> Enum.map(fn {line, idx} -> %{line_number: idx, content: line} end)

    {:ok, errors}
  end

  @doc """
  Filter an enumerable of `{enriched_json_entry, index}` tuples down to
  error entries, using the entry's extracted `_severity`.
  """
  @spec filter_json(Enumerable.t(), pos_integer(), atom(), Regex.t() | nil,
          DateTime.t() | nil, DateTime.t() | nil) :: {:ok, [map()]}
  def filter_json(entries, max_lines, level, exclude_regex, since, until_dt) do
    threshold = Patterns.level_value(level)

    errors =
      entries
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

  @doc "Compile an optional exclusion regex. `nil` compiles to no filter."
  @spec compile_exclude(String.t() | nil) :: {:ok, Regex.t() | nil} | {:error, String.t()}
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
end
