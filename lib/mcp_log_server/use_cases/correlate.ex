defmodule McpLogServer.UseCases.Correlate do
  @moduledoc """
  Use-case: search for a correlation value (session ID, trace ID, ...) across
  ALL logs of a source and return a unified timeline sorted by timestamp.

  Anchor mode (`run_anchor/3`, slice 005 P5) needs no id at all: every match
  of a symptom regex becomes a time anchor, and the result is the unified
  source-tagged timeline of ALL lines (across every file) inside a window
  around each anchor. Overlapping anchor windows merge into one section.
  """

  alias McpLogServer.Domain.AnchorWindow
  alias McpLogServer.Domain.Correlator
  alias McpLogServer.Domain.LogSearch
  alias McpLogServer.Domain.Omissions
  alias McpLogServer.Domain.TimestampParser
  alias McpLogServer.Config.Patterns
  alias McpLogServer.Ports.LogSource
  alias McpLogServer.UseCases.Deps
  alias McpLogServer.UseCases.RollupScan
  alias McpLogServer.UseCases.TsOpts

  @default_max_results 200
  @default_max_sections 5

  @doc """
  Search for `value` across all logs in `log_dir`.

  ## Options

    * `:field` - restrict matching to this field (dot-notation for JSON,
      pattern matching for plain text). When nil, performs deep search.
    * `:max_results` - cap on total results across all files (default #{@default_max_results})
    * `:source` - `LogSource` implementation (defaults to configured adapter)
  """
  @spec run(String.t(), String.t(), keyword()) :: {:ok, Correlator.correlation_result()}
  def run(log_dir, value, opts \\ []) do
    source = Deps.log_source(opts)
    field = Keyword.get(opts, :field)
    max_results = Keyword.get(opts, :max_results, @default_max_results)

    {:ok, files} = source.list(log_dir)

    all_entries =
      Enum.flat_map(files, fn file_info ->
        case source.resolve(log_dir, file_info.name) do
          {:ok, handle} -> search_one(source, handle, file_info.name, value, field, opts)
          {:error, _} -> []
        end
      end)

    sorted = Correlator.sort_timeline(all_entries)
    total = length(sorted)
    capped = Enum.take(sorted, max_results)

    files_matched =
      capped
      |> Enum.map(& &1.file)
      |> Enum.uniq()

    # Matched entries whose timestamp could not be parsed cannot be placed
    # in the timeline order (they sort last) — surface the count instead of
    # failing silently.
    unparsed_ts = Enum.count(capped, &is_nil(&1.timestamp))

    # A capped timeline must say so: without the marker, "the trail ends
    # here" and "the buffer ended here" are indistinguishable.
    omissions =
      Omissions.cap(Omissions.new(), :matches, total, max_results, "first #{max_results} by time")

    {:ok,
     Omissions.attach(
       %{
         value: value,
         field: field,
         total_matches: length(capped),
         files_matched: files_matched,
         timeline: capped,
         unparsed_ts: unparsed_ts
       },
       omissions
     )}
  end

  defp search_one(source, handle, basename, value, field, opts) do
    case source.format(handle) do
      fmt when fmt in [:json_lines, :json_array] ->
        LogSource.stream_entries(source, handle, fmt)
        |> Correlator.json_timeline(basename, value, field)

      :plain ->
        ts_opts = TsOpts.build(source, handle, basename, opts)

        handle
        |> source.stream_lines()
        |> Stream.with_index(1)
        |> Correlator.plain_timeline(basename, value, field, ts_opts)
    end
  end

  # -- Anchor mode (P5) --

  @doc """
  Correlate around a regex anchor instead of a known id.

  Pass 1 finds every `pattern` match across all logs and takes its parsed
  timestamp as an anchor (matches whose timestamp cannot be parsed cannot
  place a window — counted in `anchors_unparsed_ts`). Anchor windows are
  merged into sections (`McpLogServer.Domain.AnchorWindow`). Pass 2 streams
  every file again and collects ALL lines whose timestamp falls inside a
  section, merged and time-sorted across files/sources; lines whose
  timestamp cannot be parsed cannot be placed in any window and are counted
  in `unparsed_ts` (slice 002 honesty — the window filter is degraded, not
  silently wrong).

  ## Options

    * `:window` - `"±10s"` string or `%{before: "10s", after: "30s"}` map
      (default ±30s)
    * `:max_sections` - cap on window sections (default #{@default_max_sections}); a hit cap is
      reported in `omissions.sections`
    * `:max_results` - cap on total timeline entries across sections
      (default #{@default_max_results}); reported in `omissions.matches`
    * `:source` / `:ts_format` - usual injection points
  """
  @spec run_anchor(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def run_anchor(log_dir, pattern, opts \\ []) do
    source = Deps.log_source(opts)
    max_sections = Keyword.get(opts, :max_sections, @default_max_sections)
    max_results = Keyword.get(opts, :max_results, @default_max_results)

    with {:ok, regex} <- LogSearch.compile_pattern(pattern),
         {:ok, window} <- AnchorWindow.parse(Keyword.get(opts, :window)) do
      {:ok, files} = source.list(log_dir)
      names = Enum.map(files, & &1.name)

      # Pass 1: anchor timestamps only (cheap; nothing materialized).
      {anchor_dts, anchors_unparsed} =
        Enum.reduce(names, {[], 0}, fn name, acc ->
          scan_anchors(source, log_dir, name, regex, opts, acc)
        end)

      all_sections = AnchorWindow.sections(anchor_dts, window)
      sections = Enum.take(all_sections, max_sections)

      omissions =
        Omissions.cap(
          Omissions.new(),
          :sections,
          length(all_sections),
          max_sections,
          "first #{max_sections} by time"
        )

      # Pass 2: assign every line of every file to its section (if any).
      {filled, unparsed} =
        if sections == [] do
          {Enum.map(sections, &Map.put(&1, :entries, [])), 0}
        else
          collect_sections(source, log_dir, names, sections, opts)
        end

      {capped_sections, total_entries, omissions} =
        cap_entries(filled, max_results, omissions)

      files_matched =
        capped_sections
        |> Enum.flat_map(fn s -> Enum.map(s.entries, & &1.file) end)
        |> Enum.uniq()

      {:ok,
       Omissions.attach(
         %{
           anchor: pattern,
           window: window_label(window),
           total_anchors: length(anchor_dts) + anchors_unparsed,
           anchors_unparsed_ts: anchors_unparsed,
           sections: Enum.map(capped_sections, &render_section/1),
           total_entries: total_entries,
           files_matched: files_matched,
           unparsed_ts: unparsed
         },
         omissions
       )}
    end
  end

  defp scan_anchors(source, log_dir, name, regex, opts, {dts, unparsed}) do
    case source.resolve(log_dir, name) do
      {:error, _} ->
        {dts, unparsed}

      {:ok, handle} ->
        stream_dated(source, handle, name, opts)
        |> Enum.reduce({dts, unparsed}, fn %{content: content, dt: dt}, {dts, unparsed} ->
          cond do
            not Regex.match?(regex, content) -> {dts, unparsed}
            dt == nil -> {dts, unparsed + 1}
            true -> {[dt | dts], unparsed}
          end
        end)
    end
  end

  defp collect_sections(source, log_dir, names, sections, opts) do
    buckets = List.duplicate([], length(sections))

    {buckets, unparsed} =
      Enum.reduce(names, {buckets, 0}, fn name, acc ->
        case source.resolve(log_dir, name) do
          {:error, _} -> acc
          {:ok, handle} -> collect_file(source, handle, name, sections, opts, acc)
        end
      end)

    filled =
      sections
      |> Enum.with_index()
      |> Enum.map(fn {section, idx} ->
        entries =
          buckets
          |> Enum.at(idx)
          |> Enum.map(fn %{dt: dt} = e ->
            e
            |> Map.put(:timestamp, DateTime.to_iso8601(dt))
            |> Map.delete(:dt)
          end)
          # Deterministic merge order: time first, then file/line so
          # same-instant lines keep a stable, readable ordering.
          |> Enum.sort_by(&{&1.timestamp, &1.file, &1.line_number})

        Map.put(section, :entries, entries)
      end)

    {filled, unparsed}
  end

  defp collect_file(source, handle, name, sections, opts, {buckets, unparsed}) do
    stream_dated(source, handle, name, opts)
    |> Enum.reduce({buckets, unparsed}, fn %{dt: dt} = entry, {buckets, unparsed} ->
      cond do
        dt == nil ->
          {buckets, unparsed + 1}

        idx = AnchorWindow.section_index(sections, dt) ->
          {List.update_at(buckets, idx, &[entry | &1]), unparsed}

        true ->
          {buckets, unparsed}
      end
    end)
  end

  # Stream EVERY line/entry of a file as %{file, line_number, content,
  # severity, dt} — anchor mode needs the whole neighbourhood, not just
  # matches. Timestamp parsing reuses slice 002's declared formats + mtime
  # reference via TsOpts.
  defp stream_dated(source, handle, name, opts) do
    ts_opts = TsOpts.build(source, handle, name, opts)

    case source.format(handle) do
      fmt when fmt in [:json_lines, :json_array] ->
        LogSource.stream_entries(source, handle, fmt)
        |> Stream.map(fn {entry, idx} ->
          %{
            file: name,
            line_number: idx,
            content: RollupScan.json_content(entry),
            severity: entry["_severity"],
            dt: TimestampParser.parse_json_value(entry["_timestamp"], ts_opts)
          }
        end)

      :plain ->
        source.stream_lines(handle)
        |> Stream.with_index(1)
        |> Stream.map(fn {line, idx} ->
          %{
            file: name,
            line_number: idx,
            content: line,
            severity: plain_severity(line),
            dt: TimestampParser.extract(line, ts_opts)
          }
        end)
    end
  end

  # Total-entry cap across sections, in section (time) order. The honest
  # marker rides in omissions.matches, same key as id-mode.
  defp cap_entries(sections, max_results, omissions) do
    total = sections |> Enum.map(&length(&1.entries)) |> Enum.sum()

    {capped, _left} =
      Enum.map_reduce(sections, max_results, fn section, left ->
        kept = Enum.take(section.entries, left)
        {%{section | entries: kept}, left - length(kept)}
      end)

    shown = capped |> Enum.map(&length(&1.entries)) |> Enum.sum()

    {capped, shown,
     Omissions.cap(omissions, :matches, total, shown, "first #{max_results} by time")}
  end

  defp render_section(section) do
    %{
      from: DateTime.to_iso8601(section.from),
      to: DateTime.to_iso8601(section.to),
      anchor_count: section.anchor_count,
      entries: section.entries
    }
  end

  defp window_label(%{before: b, after: a}) when b == a, do: "±#{b}s"
  defp window_label(%{before: b, after: a}), do: "-#{b}s/+#{a}s"

  defp plain_severity(line) do
    case Patterns.detect_level(line) do
      nil -> nil
      level -> Atom.to_string(level)
    end
  end
end
