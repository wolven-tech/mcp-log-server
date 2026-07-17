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
  alias McpLogServer.Domain.Omissions
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

  Returns `{:ok, %{entries: entries, unparsed_ts: n | nil, omissions: om}}`
  where `unparsed_ts` counts scanned lines whose timestamp could not be
  parsed while a time filter was active (they pass the filter — fail-open;
  `nil` when no time filter was applied, zero cost), and `omissions` is a
  `McpLogServer.Domain.Omissions` block reporting how many matching entries
  the `max_lines` cap withheld (empty map when none were).
  """
  @spec filter_plain(Enumerable.t(), pos_integer(), atom(), Regex.t() | nil,
          DateTime.t() | nil, DateTime.t() | nil, keyword()) ::
          {:ok,
           %{
             entries: [log_entry()],
             unparsed_ts: non_neg_integer() | nil,
             omissions: Omissions.t()
           }}
  def filter_plain(indexed_lines, max_lines, level, exclude_regex, since, until_dt, ts_opts \\ []) do
    filter_active? = since != nil or until_dt != nil

    {kept, unparsed} =
      Enum.reduce(indexed_lines, {[], 0}, fn {line, idx}, {acc, unparsed} ->
        {included?, status} = TimeFilter.classify(line, since, until_dt, ts_opts)
        unparsed = if status == :unparsed, do: unparsed + 1, else: unparsed

        acc =
          if included? and Patterns.matches_level?(line, level) and
               not excluded?(line, exclude_regex) do
            [%{line_number: idx, content: line} | acc]
          else
            acc
          end

        {acc, unparsed}
      end)

    total = length(kept)
    entries = kept |> Enum.reverse() |> Enum.take(-max_lines)

    {:ok,
     %{
       entries: entries,
       unparsed_ts: if(filter_active?, do: unparsed, else: nil),
       omissions: Omissions.cap(Omissions.new(), :matches, total, max_lines, "newest #{max_lines}")
     }}
  end

  @doc """
  Filter an enumerable of `{enriched_json_entry, index}` tuples down to
  error entries, using the entry's extracted `_severity`.

  Same result shape, `unparsed_ts`, and `omissions` semantics as
  `filter_plain/7`.
  """
  @spec filter_json(Enumerable.t(), pos_integer(), atom(), Regex.t() | nil,
          DateTime.t() | nil, DateTime.t() | nil, keyword()) ::
          {:ok,
           %{entries: [map()], unparsed_ts: non_neg_integer() | nil, omissions: Omissions.t()}}
  def filter_json(entries, max_lines, level, exclude_regex, since, until_dt, ts_opts \\ []) do
    filter_active? = since != nil or until_dt != nil

    severity_match? = fn entry ->
      severity_at_least?(entry, level) and
        not excluded?(entry["_message"] || "", exclude_regex)
    end

    {kept, unparsed} =
      Enum.reduce(entries, {[], 0}, fn {entry, idx}, {acc, unparsed} ->
        {included?, status} = TimeFilter.classify(entry, since, until_dt, ts_opts)
        unparsed = if status == :unparsed, do: unparsed + 1, else: unparsed
        acc = if included? and severity_match?.(entry), do: [{entry, idx} | acc], else: acc
        {acc, unparsed}
      end)

    total = length(kept)

    errors =
      kept
      |> Enum.reverse()
      |> Enum.take(-max_lines)
      |> Enum.map(fn {entry, idx} -> JsonLogParser.json_entry_to_toon_map(entry, idx) end)

    {:ok,
     %{
       entries: errors,
       unparsed_ts: if(filter_active?, do: unparsed, else: nil),
       omissions: Omissions.cap(Omissions.new(), :matches, total, max_lines, "newest #{max_lines}")
     }}
  end

  @doc """
  Does an enriched JSON entry's extracted `_severity` meet the minimum
  `level`? Shared by `filter_json/7` and the rollup scan.
  """
  @spec severity_at_least?(map(), atom()) :: boolean()
  def severity_at_least?(entry, level) do
    atom_level = Map.get(@json_severity_to_atom, entry["_severity"])
    atom_level != nil and Patterns.level_value(atom_level) >= Patterns.level_value(level)
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
