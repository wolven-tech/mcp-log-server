defmodule McpLogServer.Domain.AnchorWindow do
  @moduledoc """
  Pure window math for anchor-mode `correlate` (slice 005, P5).

  During a boot investigation you hold a symptom LINE, not an id. Anchor
  mode turns every regex hit into a time window around it; this module
  parses the window syntax and merges the per-anchor intervals into
  sections.

  Window syntax:

    * symmetric: `"±10s"`, `"±2m"` (`"+-10s"` is accepted too — JSON input
      is often ASCII-only)
    * asymmetric: `%{before: "10s", after: "30s"}` (either side may be
      omitted and defaults to `"0s"`)

  Overlapping anchor windows are MERGED into one section: two anchors 3s
  apart with a ±10s window describe one continuous stretch of time, and
  splitting it would duplicate every timeline entry in the overlap.
  """

  @default_window_s 30

  @duration_regex ~r/^(\d+)([smhd])$/
  @symmetric_regex ~r/^(?:±|\+-|\+\/-)\s*(\d+[smhd])$/u

  @type window :: %{before: non_neg_integer(), after: non_neg_integer()}
  @type section :: %{from: DateTime.t(), to: DateTime.t(), anchor_count: pos_integer()}

  @doc """
  Parse a window spec into `%{before: seconds, after: seconds}`.

  `nil` yields the default (±#{@default_window_s}s). Strings must be
  symmetric (`"±10s"`); maps give asymmetric bounds with string keys
  (`%{"before" => "10s", "after" => "30s"}`) or atom keys.
  """
  @spec parse(String.t() | map() | nil) :: {:ok, window()} | {:error, String.t()}
  def parse(nil), do: {:ok, %{before: @default_window_s, after: @default_window_s}}

  def parse(spec) when is_binary(spec) do
    case Regex.run(@symmetric_regex, String.trim(spec)) do
      [_, duration] ->
        with {:ok, seconds} <- parse_duration(duration) do
          {:ok, %{before: seconds, after: seconds}}
        end

      nil ->
        {:error,
         "Invalid window #{inspect(spec)}: expected \"±<n><unit>\" (e.g. \"±10s\", \"±2m\") " <>
           "or {before, after} durations"}
    end
  end

  def parse(%{} = spec) do
    before_spec = Map.get(spec, "before") || Map.get(spec, :before)
    after_spec = Map.get(spec, "after") || Map.get(spec, :after)

    if before_spec == nil and after_spec == nil do
      {:error, "Invalid window: asymmetric form needs at least one of before/after"}
    else
      with {:ok, before_s} <- parse_duration(before_spec || "0s"),
           {:ok, after_s} <- parse_duration(after_spec || "0s") do
        {:ok, %{before: before_s, after: after_s}}
      end
    end
  end

  def parse(other), do: {:error, "Invalid window: #{inspect(other)}"}

  @doc ~S|Parse a duration like "10s", "2m", "1h", "1d" into seconds.|
  @spec parse_duration(term()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def parse_duration(spec) when is_binary(spec) do
    case Regex.run(@duration_regex, String.trim(spec)) do
      [_, amount, unit] -> {:ok, String.to_integer(amount) * unit_seconds(unit)}
      nil -> {:error, "Invalid duration #{inspect(spec)}: expected e.g. \"10s\", \"2m\", \"1h\""}
    end
  end

  def parse_duration(other), do: {:error, "Invalid duration: #{inspect(other)}"}

  @doc """
  Build merged, time-sorted sections from anchor timestamps.

  Each anchor spans `[anchor - before, anchor + after]`; overlapping or
  touching spans merge into one section carrying the combined
  `anchor_count`. Returns all sections — callers cap and report omissions.
  """
  @spec sections([DateTime.t()], window()) :: [section()]
  def sections(anchor_dts, %{before: before_s, after: after_s}) do
    anchor_dts
    |> Enum.sort(DateTime)
    |> Enum.map(fn dt ->
      %{
        from: DateTime.add(dt, -before_s, :second),
        to: DateTime.add(dt, after_s, :second),
        anchor_count: 1
      }
    end)
    |> merge_sorted([])
  end

  @doc "True when `dt` falls inside `section` (inclusive bounds)."
  @spec in_section?(section(), DateTime.t()) :: boolean()
  def in_section?(%{from: from, to: to}, dt) do
    DateTime.compare(dt, from) != :lt and DateTime.compare(dt, to) != :gt
  end

  @doc "Index of the first section containing `dt`, or `nil`."
  @spec section_index([section()], DateTime.t()) :: non_neg_integer() | nil
  def section_index(sections, dt) do
    Enum.find_index(sections, &in_section?(&1, dt))
  end

  defp merge_sorted([], acc), do: Enum.reverse(acc)

  defp merge_sorted([span | rest], [prev | acc_rest] = acc) do
    if DateTime.compare(span.from, prev.to) != :gt do
      merged = %{
        from: prev.from,
        to: max_dt(prev.to, span.to),
        anchor_count: prev.anchor_count + span.anchor_count
      }

      merge_sorted(rest, [merged | acc_rest])
    else
      merge_sorted(rest, [span | acc])
    end
  end

  defp merge_sorted([span | rest], []), do: merge_sorted(rest, [span])

  defp max_dt(a, b), do: if(DateTime.compare(a, b) == :lt, do: b, else: a)

  defp unit_seconds("s"), do: 1
  defp unit_seconds("m"), do: 60
  defp unit_seconds("h"), do: 3600
  defp unit_seconds("d"), do: 86_400
end
