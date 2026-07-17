defmodule McpLogServer.Domain.SparseIndex do
  @moduledoc """
  Pure construction and querying of the sparse per-file index (issue #7 P7).

  A builder folds a file's raw lines (with their byte lengths) into:

    * **sparse checkpoints** — every `interval` lines, a snapshot of
      `{byte_offset, lines_so_far, max_ts, unparsed_count}` in TWO
      timestamp semantics:
      - `:line` — `TimestampParser.extract/2` on the raw line, the
        semantics `tail_log`/`search_logs` filter with;
      - `:entry` — for lines that decode to a JSON object, the JSON
        entry timestamp (`JsonLogParser.extract_timestamp/1` +
        `TimestampParser.parse_json_value/2`), the semantics `aggregate`
        filters with; non-JSON lines fall back to `:line`.
      A seek is only sound when it uses the same semantics as the scan it
      replaces — the two CAN disagree (an epoch field vs. an ISO string
      embedded in the message), and mixing them would skip lines the
      linear scan would have returned.
    * **field-key knowledge** — the set of JSON dot-paths `present` in the
      file, plus `opaque` paths (lists, or maps beyond the depth cap)
      under which unknown keys may hide, plus `json_lines`/`non_json`
      line totals. `key_absent?/2` uses these to PROVE a field absent.

  ## The seek soundness rule

  `seek/3` returns the deepest checkpoint whose skipped prefix provably
  contains only lines a `since`-filtered scan would exclude:

    * `unparsed == 0` — slice 002's fail-open rule means a line whose
      timestamp cannot be parsed is INCLUDED by time filters and counted
      in `unparsed_ts`; skipping even one would silently drop fail-open
      lines and corrupt the count. Zero tolerance.
    * `max_ts < since` (strictly) — every parsed timestamp in the prefix
      is before the bound, so the filter excludes all of them; a
      timestamp exactly equal to `since` is included by the filter
      (`>=`), so equality blocks the seek.

  Under this rule an indexed scan returns byte-identical results to the
  linear scan — the oracle property the tests enforce.

  ## Reference sensitivity

  Time-only formats (dev-server `HH:MM:SS`) resolve their date against the
  file's mtime (`TimestampParser` midnight-rollover rule). Their resolved
  instants CHANGE when the file's mtime changes, so checkpoints built from
  them are only valid while the file is byte-identical to what was
  indexed. The builder detects this by re-extracting each parsed timestamp
  with the reference shifted one day: any difference marks the summary
  `ref_sensitive: true`. Date-carrying formats are immune and keep their
  checkpoints valid across appends.
  """

  alias McpLogServer.Domain.JsonLogParser
  alias McpLogServer.Domain.TimestampParser

  @default_interval 1000
  @default_max_paths 500
  @default_max_depth 6
  # Fixed probe anchor used when no reference is supplied: the main
  # extraction then uses "now", which is inherently reference-sensitive,
  # and the probe (a fixed past date) is guaranteed to differ for
  # time-only formats.
  @probe_ref ~U[2000-06-15 12:00:00Z]

  @type checkpoint :: %{
          offset: non_neg_integer(),
          lines: non_neg_integer(),
          line_max_us: integer() | nil,
          line_unparsed: non_neg_integer(),
          entry_max_us: integer() | nil,
          entry_unparsed: non_neg_integer()
        }

  @type summary :: %{
          checkpoints: [checkpoint()],
          bytes: non_neg_integer(),
          lines: non_neg_integer(),
          line_max_us: integer() | nil,
          line_unparsed: non_neg_integer(),
          entry_max_us: integer() | nil,
          entry_unparsed: non_neg_integer(),
          ref_sensitive: boolean(),
          present: MapSet.t(String.t()),
          opaque: MapSet.t(String.t()),
          fields_capped: boolean(),
          json_lines: non_neg_integer(),
          non_json: non_neg_integer()
        }

  @doc "Fresh builder. Options: `:interval` (lines per checkpoint), `:max_paths`, `:max_depth`."
  @spec new(keyword()) :: map()
  def new(opts \\ []) do
    %{
      interval: Keyword.get(opts, :interval, @default_interval),
      max_paths: Keyword.get(opts, :max_paths, @default_max_paths),
      max_depth: Keyword.get(opts, :max_depth, @default_max_depth),
      checkpoints: [],
      bytes: 0,
      lines: 0,
      line_max_us: nil,
      line_unparsed: 0,
      entry_max_us: nil,
      entry_unparsed: 0,
      ref_sensitive: false,
      present: MapSet.new(),
      opaque: MapSet.new(),
      fields_capped: false,
      json_lines: 0,
      non_json: 0
    }
  end

  @doc """
  Builder resuming from a previous `summary` — the incremental path for a
  file that only grew (append-only extension). Never valid for
  `ref_sensitive` summaries (the caller must full-rebuild those).
  """
  @spec resume(summary(), keyword()) :: map()
  def resume(summary, opts \\ []) do
    new(opts)
    |> Map.merge(Map.take(summary, [
      :bytes, :lines, :line_max_us, :line_unparsed, :entry_max_us, :entry_unparsed,
      :ref_sensitive, :present, :opaque, :fields_capped, :json_lines, :non_json
    ]))
    |> Map.put(:checkpoints, Enum.reverse(summary.checkpoints))
  end

  @doc """
  Fold one raw line (INCLUDING its newline byte, so offsets stay exact)
  into the builder. `ts_opts` are the same `:format`/`:reference` options
  the query-time scans use — build and query MUST parse identically.
  """
  @spec add_line(map(), binary(), keyword()) :: map()
  def add_line(builder, raw_line, ts_opts) do
    trimmed = String.trim_trailing(raw_line)

    {line_us, line_sensitive?} = extract_line_ts(trimmed, ts_opts, builder.ref_sensitive)

    {decoded, builder} = decode_and_index_fields(builder, trimmed)

    {entry_us, entry_sensitive?} =
      case decoded do
        {:ok, map} -> extract_entry_ts(map, ts_opts, builder.ref_sensitive)
        :error -> {line_us, false}
      end

    builder = %{
      builder
      | bytes: builder.bytes + byte_size(raw_line),
        lines: builder.lines + 1,
        line_max_us: max_us(builder.line_max_us, line_us),
        line_unparsed: builder.line_unparsed + if(line_us == nil, do: 1, else: 0),
        entry_max_us: max_us(builder.entry_max_us, entry_us),
        entry_unparsed: builder.entry_unparsed + if(entry_us == nil, do: 1, else: 0),
        ref_sensitive: builder.ref_sensitive or line_sensitive? or entry_sensitive?
    }

    maybe_checkpoint(builder)
  end

  @doc "Finish the builder into a persistable summary."
  @spec finish(map()) :: summary()
  def finish(builder) do
    builder
    |> Map.take([
      :bytes, :lines, :line_max_us, :line_unparsed, :entry_max_us, :entry_unparsed,
      :ref_sensitive, :present, :opaque, :fields_capped, :json_lines, :non_json
    ])
    |> Map.put(:checkpoints, Enum.reverse(builder.checkpoints))
  end

  @doc """
  Find the deepest safe seek point for a `since` bound.

  `mode` selects the timestamp semantics: `:line` for line-regex scans
  (`tail_log`, `search_logs`, plain summarize), `:entry` for JSON-aware
  scans (`aggregate`). Returns `{:ok, %{offset: o, lines: n}}` — the scan
  may start at byte `o` (line `n + 1`) — or `:miss` when no prefix is
  provably skippable.
  """
  @spec seek(summary(), DateTime.t(), :line | :entry) ::
          {:ok, %{offset: non_neg_integer(), lines: non_neg_integer()}} | :miss
  def seek(%{checkpoints: checkpoints}, %DateTime{} = since, mode) when mode in [:line, :entry] do
    since_us = DateTime.to_unix(since, :microsecond)
    {max_key, unparsed_key} = keys_for(mode)

    checkpoints
    |> Enum.take_while(fn cp ->
      Map.fetch!(cp, unparsed_key) == 0 and
        Map.fetch!(cp, max_key) != nil and
        Map.fetch!(cp, max_key) < since_us
    end)
    |> List.last()
    |> case do
      nil -> :miss
      cp -> {:ok, %{offset: cp.offset, lines: cp.lines}}
    end
  end

  def seek(_summary, _since, _mode), do: :miss

  @doc """
  Can the field at dot-path `keys` be PROVEN absent from every JSON line
  of the summarized file? `false` on any doubt: the path (or an ancestor)
  is present, an ancestor is opaque (a list or a beyond-depth map whose
  children were not recorded), or the path set was capped.
  """
  @spec key_absent?(summary() | map(), [String.t()]) :: boolean()
  def key_absent?(%{fields_capped: true}, _keys), do: false

  def key_absent?(%{present: present, opaque: opaque}, keys) when is_list(keys) do
    path = Enum.join(keys, ".")

    not MapSet.member?(present, path) and
      not Enum.any?(prefixes(keys), &MapSet.member?(opaque, &1))
  end

  # -- internals --

  defp keys_for(:line), do: {:line_max_us, :line_unparsed}
  defp keys_for(:entry), do: {:entry_max_us, :entry_unparsed}

  defp maybe_checkpoint(%{interval: interval} = b) when rem(b.lines, interval) == 0 do
    cp = %{
      offset: b.bytes,
      lines: b.lines,
      line_max_us: b.line_max_us,
      line_unparsed: b.line_unparsed,
      entry_max_us: b.entry_max_us,
      entry_unparsed: b.entry_unparsed
    }

    %{b | checkpoints: [cp | b.checkpoints]}
  end

  defp maybe_checkpoint(b), do: b

  defp max_us(nil, b), do: b
  defp max_us(a, nil), do: a
  defp max_us(a, b), do: max(a, b)

  # Line-semantics timestamp + reference-sensitivity probe. The probe
  # re-extracts with the reference shifted one day: date-carrying formats
  # are unaffected; time-only formats shift, flagging the file.
  defp extract_line_ts(line, ts_opts, already_sensitive?) do
    case TimestampParser.extract(line, ts_opts) do
      nil ->
        {nil, false}

      dt ->
        sensitive? =
          already_sensitive? or
            probe_differs?(dt, fn ref -> TimestampParser.extract(line, Keyword.put(ts_opts, :reference, ref)) end, ts_opts)

        {DateTime.to_unix(dt, :microsecond), sensitive?}
    end
  end

  defp extract_entry_ts(map, ts_opts, already_sensitive?) do
    value = JsonLogParser.extract_timestamp(map)

    case TimestampParser.parse_json_value(value, ts_opts) do
      nil ->
        {nil, false}

      dt ->
        sensitive? =
          already_sensitive? or
            probe_differs?(dt, fn ref -> TimestampParser.parse_json_value(value, Keyword.put(ts_opts, :reference, ref)) end, ts_opts)

        {DateTime.to_unix(dt, :microsecond), sensitive?}
    end
  end

  defp probe_differs?(dt, re_extract, ts_opts) do
    ref = Keyword.get(ts_opts, :reference) || @probe_ref
    alt = re_extract.(DateTime.add(ref, -86_400, :second))
    alt == nil or DateTime.compare(alt, dt) != :eq
  end

  # JSON decode with EXACTLY the semantics of the query-time scans
  # (`Jason.decode/1` + `is_map/1` on the trimmed line): a line counts as
  # a JSON line here iff `aggregate`'s scan would treat it as one.
  defp decode_and_index_fields(builder, line) do
    case Jason.decode(line) do
      {:ok, map} when is_map(map) ->
        {{:ok, map}, index_fields(%{builder | json_lines: builder.json_lines + 1}, map)}

      _ ->
        {:error, %{builder | non_json: builder.non_json + 1}}
    end
  end

  defp index_fields(%{fields_capped: true} = b, _map), do: b

  defp index_fields(b, map) do
    {present, opaque} = walk_fields(map, "", b.max_depth, {b.present, b.opaque})

    if MapSet.size(present) > b.max_paths do
      %{b | present: present, opaque: opaque, fields_capped: true}
    else
      %{b | present: present, opaque: opaque}
    end
  end

  defp walk_fields(map, prefix, depth, acc) do
    Enum.reduce(map, acc, fn {k, v}, {present, opaque} ->
      path = if prefix == "", do: to_string(k), else: prefix <> "." <> to_string(k)
      present = MapSet.put(present, path)

      cond do
        is_map(v) and map_size(v) == 0 -> {present, opaque}
        is_map(v) and depth > 1 -> walk_fields(v, path, depth - 1, {present, opaque})
        is_map(v) -> {present, MapSet.put(opaque, path)}
        is_list(v) and v != [] -> {present, MapSet.put(opaque, path)}
        true -> {present, opaque}
      end
    end)
  end

  defp prefixes(keys) do
    keys
    |> Enum.scan(nil, fn k, acc -> if acc, do: acc <> "." <> k, else: k end)
  end
end
