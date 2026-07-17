defmodule McpLogServer.Domain.WindowDiff do
  @moduledoc """
  Pure aggregation behind the `summarize` tool (issue #7 P8): "what's new
  or unusual in this window vs the prior one?" in one pass.

  Lines are classified into a **window** `[w_since, w_until]` and a
  **baseline** `[b_since, w_since)` (half-open at the boundary so a line
  exactly at `w_since` lands in the window, never both). Each in-range
  line folds into its range's accumulator: message-template groups
  (`McpLogServer.Domain.MessageTemplate`), error count, and per-source
  line counts.

  ## Honesty rules

  * A line whose timestamp cannot be parsed can't be placed in time. It is
    folded into BOTH ranges (fail-open, slice 002) and counted once in
    `unparsed_ts`. Because it lands on the same template in both ranges it
    can never fabricate a `new_templates` or `gone_templates` row — the
    diff degrades conservatively, and the count makes the degradation
    observable. It does inflate both rates equally, which leaves the
    error-rate DELTA honest.
  * Template lists are capped; a hit cap is reported via
    `McpLogServer.Domain.Omissions` (`new_templates` / `gone_templates`
    keys), never silent.
  """

  alias McpLogServer.Domain.MessageTemplate
  alias McpLogServer.Domain.Omissions

  @type line_info :: %{
          content: String.t(),
          instance: String.t(),
          ts: DateTime.t() | nil,
          error?: boolean()
        }

  @doc "Fresh state for the given bounds (`b_since <= w_since <= w_until`)."
  @spec new(DateTime.t(), DateTime.t(), DateTime.t()) :: map()
  def new(%DateTime{} = w_since, %DateTime{} = w_until, %DateTime{} = b_since) do
    %{
      w_since: w_since,
      w_until: w_until,
      b_since: b_since,
      unparsed: 0,
      instances: MapSet.new(),
      window: range_acc(),
      baseline: range_acc()
    }
  end

  defp range_acc, do: %{templates: %{}, lines: 0, errors: 0, by_source: %{}}

  @doc "Classify a parsed timestamp (or nil) against the bounds."
  @spec classify(map(), DateTime.t() | nil) :: :window | :baseline | :outside | :unparsed
  def classify(_state, nil), do: :unparsed

  def classify(%{w_since: ws, w_until: wu, b_since: bs}, ts) do
    cond do
      DateTime.compare(ts, ws) != :lt and DateTime.compare(ts, wu) != :gt -> :window
      DateTime.compare(ts, bs) != :lt and DateTime.compare(ts, ws) == :lt -> :baseline
      true -> :outside
    end
  end

  @doc "Fold one line into the state."
  @spec add(map(), line_info()) :: map()
  def add(state, info) do
    case classify(state, info.ts) do
      :outside ->
        state

      :window ->
        state |> fold(:window, info) |> seen(info.instance)

      :baseline ->
        state |> fold(:baseline, info) |> seen(info.instance)

      :unparsed ->
        %{state | unparsed: state.unparsed + 1}
        |> fold(:window, info)
        |> fold(:baseline, info)
        |> seen(info.instance)
    end
  end

  @doc """
  Render the diff. `opts`: `:max_templates` (cap per list, default 20).

  Returns a map with `new_templates`, `gone_templates`, `error_rate`,
  `volume`, `unparsed_ts`, `sources_seen`, and an `omissions` block (only
  the caps that were actually hit).
  """
  @spec finalize(map(), keyword()) :: map()
  def finalize(state, opts \\ []) do
    max_templates = Keyword.get(opts, :max_templates, 20)
    w_min = minutes_between(state.w_since, state.w_until)
    b_min = minutes_between(state.b_since, state.w_since)
    n = MapSet.size(state.instances)

    w_hashes = state.window.templates |> Map.keys() |> MapSet.new()
    b_hashes = state.baseline.templates |> Map.keys() |> MapSet.new()

    new_rows =
      MapSet.difference(w_hashes, b_hashes)
      |> Enum.map(fn h ->
        g = state.window.templates[h]

        %{
          template: g.template,
          count: g.count,
          instances_seen: "#{MapSet.size(g.instances)}/#{n}",
          first_ts: iso(g.first_ts),
          sample: g.sample
        }
      end)
      |> Enum.sort_by(&{-&1.count, &1.template})

    gone_rows =
      MapSet.difference(b_hashes, w_hashes)
      |> Enum.map(fn h ->
        g = state.baseline.templates[h]
        %{template: g.template, baseline_count: g.count, last_ts: iso(g.last_ts)}
      end)
      |> Enum.sort_by(&{-&1.baseline_count, &1.template})

    om =
      Omissions.new()
      |> Omissions.cap(:new_templates, length(new_rows), max_templates, "top #{max_templates} by count")
      |> Omissions.cap(:gone_templates, length(gone_rows), max_templates, "top #{max_templates} by baseline count")

    %{
      new_templates: Enum.take(new_rows, max_templates),
      gone_templates: Enum.take(gone_rows, max_templates),
      error_rate: %{
        window_errors: state.window.errors,
        baseline_errors: state.baseline.errors,
        window_per_min: rate(state.window.errors, w_min),
        baseline_per_min: rate(state.baseline.errors, b_min),
        delta_per_min: Float.round(rate(state.window.errors, w_min) - rate(state.baseline.errors, b_min), 2)
      },
      volume: volume_rows(state, w_min, b_min),
      unparsed_ts: state.unparsed,
      sources_seen: n,
      omissions: om
    }
  end

  @doc ~S|Parse a duration shorthand ("15m", "2h", "1d", "45s", "1w") into seconds.|
  @spec parse_duration(String.t() | nil) :: {:ok, pos_integer()} | :error
  def parse_duration(value) when is_binary(value) do
    case Regex.run(~r/^(\d+)([smhdw])$/, String.trim(value)) do
      [_, amount, unit] ->
        seconds = String.to_integer(amount) * unit_seconds(unit)
        if seconds > 0, do: {:ok, seconds}, else: :error

      _ ->
        :error
    end
  end

  def parse_duration(_), do: :error

  # -- internals --

  defp seen(state, instance), do: %{state | instances: MapSet.put(state.instances, instance)}

  defp fold(state, key, info) do
    r = Map.fetch!(state, key)
    %{template: template, hash: hash} = MessageTemplate.normalize(info.content)

    templates =
      Map.update(
        r.templates,
        hash,
        %{
          template: template,
          count: 1,
          instances: MapSet.new([info.instance]),
          first_ts: info.ts,
          last_ts: info.ts,
          sample: info.content
        },
        fn g ->
          %{
            g
            | count: g.count + 1,
              instances: MapSet.put(g.instances, info.instance),
              first_ts: min_ts(g.first_ts, info.ts),
              last_ts: max_ts(g.last_ts, info.ts)
          }
        end
      )

    r = %{
      r
      | templates: templates,
        lines: r.lines + 1,
        errors: r.errors + if(info.error?, do: 1, else: 0),
        by_source: Map.update(r.by_source, info.instance, 1, &(&1 + 1))
    }

    Map.put(state, key, r)
  end

  defp volume_rows(state, w_min, b_min) do
    sources =
      MapSet.union(
        state.window.by_source |> Map.keys() |> MapSet.new(),
        state.baseline.by_source |> Map.keys() |> MapSet.new()
      )

    sources
    |> Enum.map(fn src ->
      w = Map.get(state.window.by_source, src, 0)
      b = Map.get(state.baseline.by_source, src, 0)
      w_rate = rate(w, w_min)
      b_rate = rate(b, b_min)

      %{
        source: src,
        window_lines: w,
        baseline_lines: b,
        window_per_min: w_rate,
        baseline_per_min: b_rate,
        delta_per_min: Float.round(w_rate - b_rate, 2)
      }
    end)
    |> Enum.sort_by(&{-abs(&1.delta_per_min), &1.source})
  end

  defp minutes_between(a, b), do: DateTime.diff(b, a, :second) / 60

  defp rate(_count, minutes) when minutes <= 0, do: 0.0
  defp rate(count, minutes), do: Float.round(count / minutes, 2)

  defp unit_seconds("s"), do: 1
  defp unit_seconds("m"), do: 60
  defp unit_seconds("h"), do: 3600
  defp unit_seconds("d"), do: 86_400
  defp unit_seconds("w"), do: 604_800

  defp min_ts(nil, b), do: b
  defp min_ts(a, nil), do: a
  defp min_ts(a, b), do: if(DateTime.compare(a, b) == :gt, do: b, else: a)

  defp max_ts(nil, b), do: b
  defp max_ts(a, nil), do: a
  defp max_ts(a, b), do: if(DateTime.compare(a, b) == :lt, do: b, else: a)

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
