defmodule McpLogServer.Domain.Rollup do
  @moduledoc """
  Pure aggregation of matched log lines into per-template groups.

  Each matched line is normalized (`McpLogServer.Domain.MessageTemplate`)
  and folded into a group keyed by the template hash, tracking:

    * `count` — how many lines collapsed into this template
    * `instances` — the distinct instances (source tags, else file names)
      that emitted it — the "ran on 1/9 machines" dimension
    * `first_ts` / `last_ts` — earliest/latest parsed timestamp
    * `sample` — one raw line, kept verbatim for context

  `finalize/2` renders groups as rows sorted by count (descending), with
  `instances_seen` shown as `"3/9"` where the denominator is the number of
  sources scanned — supplied by the caller, because the domain layer never
  enumerates files itself.
  """

  alias McpLogServer.Domain.MessageTemplate

  @type group :: %{
          template: String.t(),
          count: pos_integer(),
          instances: MapSet.t(String.t()),
          first_ts: DateTime.t() | nil,
          last_ts: DateTime.t() | nil,
          sample: String.t()
        }
  @type acc :: %{optional(String.t()) => group()}
  @type row :: %{
          template: String.t(),
          count: pos_integer(),
          instances_seen: String.t(),
          first_ts: String.t() | nil,
          last_ts: String.t() | nil,
          sample: String.t()
        }

  @doc "An empty accumulator."
  @spec new() :: acc()
  def new, do: %{}

  @doc """
  Fold one matched line into the accumulator.

  `instance` is the line's origin (source tag when present, else file
  name); `ts` its parsed timestamp or `nil` (lines without a parseable
  timestamp still count, they just cannot move first/last).
  `opts` are forwarded to `MessageTemplate.normalize/2`.
  """
  @spec add(acc(), String.t(), String.t(), DateTime.t() | nil, keyword()) :: acc()
  def add(acc, raw_line, instance, ts \\ nil, opts \\ []) do
    %{template: template, hash: hash} = MessageTemplate.normalize(raw_line, opts)

    Map.update(
      acc,
      hash,
      %{
        template: template,
        count: 1,
        instances: MapSet.new([instance]),
        first_ts: ts,
        last_ts: ts,
        sample: raw_line
      },
      fn group ->
        %{
          group
          | count: group.count + 1,
            instances: MapSet.put(group.instances, instance),
            first_ts: min_ts(group.first_ts, ts),
            last_ts: max_ts(group.last_ts, ts)
        }
      end
    )
  end

  @doc """
  Render the accumulator as rows sorted by count (descending).

  `sources_scanned` is the denominator of `instances_seen`.
  """
  @spec finalize(acc(), non_neg_integer()) :: [row()]
  def finalize(acc, sources_scanned) do
    acc
    |> Map.values()
    |> Enum.map(fn group ->
      %{
        template: group.template,
        count: group.count,
        instances_seen: "#{MapSet.size(group.instances)}/#{sources_scanned}",
        first_ts: iso(group.first_ts),
        last_ts: iso(group.last_ts),
        sample: group.sample
      }
    end)
    |> Enum.sort_by(&{-&1.count, &1.template})
  end

  defp min_ts(nil, b), do: b
  defp min_ts(a, nil), do: a
  defp min_ts(a, b), do: if(DateTime.compare(a, b) == :gt, do: b, else: a)

  defp max_ts(nil, b), do: b
  defp max_ts(a, nil), do: a
  defp max_ts(a, b), do: if(DateTime.compare(a, b) == :lt, do: b, else: a)

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
