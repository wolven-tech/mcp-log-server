defmodule McpLogServer.Domain.FieldAggregator do
  @moduledoc """
  Pure aggregation over structured (JSON) log lines: dot-path field
  extraction plus the three `aggregate` ops (`exists` / `values` / `count`).

  WHY this exists: regex + severity cannot prove structured-field
  presence/absence cheaply. "Did any line emit `fields.gated`?" must be one
  deterministic query, not a grep whose empty result is ambiguous between
  "field absent" and "regex wrong".

  Honesty rules (slices 002/004) apply:

    * non-JSON lines cannot carry a structured field — they are counted
      separately (`non_json`), never silently ignored;
    * the `values` histogram caps distinct values and reports the cap via
      an `omissions` block, so a truncated histogram never looks complete.

  All functions are pure over caller-supplied data; file enumeration and
  streaming live in `McpLogServer.UseCases.Aggregate`.
  """

  alias McpLogServer.Domain.Omissions

  @type acc :: %{
          with_field: non_neg_integer(),
          without_field: non_neg_integer(),
          non_json: non_neg_integer(),
          sample: String.t() | nil,
          values: %{optional(String.t()) => non_neg_integer()}
        }

  @doc """
  Extract the value at a dot-path from a decoded JSON map.

  Returns `{:ok, value}` when every path segment resolves (a present key
  holding JSON `null` still counts as present), `:missing` otherwise.
  Numeric segments index into arrays (`items.0.id`); any other segment
  applied to a non-map (string, number, array) is `:missing`.
  """
  @spec get_path(term(), [String.t()] | String.t()) :: {:ok, term()} | :missing
  def get_path(entry, path) when is_binary(path), do: get_path(entry, String.split(path, "."))
  def get_path(value, []), do: {:ok, value}

  def get_path(map, [key | rest]) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> get_path(value, rest)
      :error -> :missing
    end
  end

  def get_path(list, [key | rest]) when is_list(list) do
    case Integer.parse(key) do
      {idx, ""} when idx >= 0 ->
        case Enum.fetch(list, idx) do
          {:ok, value} -> get_path(value, rest)
          :error -> :missing
        end

      _ ->
        :missing
    end
  end

  def get_path(_other, _keys), do: :missing

  @doc "Fresh accumulator."
  @spec new() :: acc()
  def new do
    %{with_field: 0, without_field: 0, non_json: 0, sample: nil, values: %{}}
  end

  @doc """
  Fold one decoded JSON entry into the accumulator. `sample_line` is the
  raw line kept as the `exists` sample the first time the field is seen.
  """
  @spec add_entry(acc(), [String.t()], map(), String.t()) :: acc()
  def add_entry(acc, keys, entry, sample_line) do
    case get_path(entry, keys) do
      {:ok, value} ->
        %{
          acc
          | with_field: acc.with_field + 1,
            sample: acc.sample || sample_line,
            values: Map.update(acc.values, normalize_value(value), 1, &(&1 + 1))
        }

      :missing ->
        %{acc | without_field: acc.without_field + 1}
    end
  end

  @doc "Count a line that did not decode to a JSON object."
  @spec add_non_json(acc()) :: acc()
  def add_non_json(acc), do: %{acc | non_json: acc.non_json + 1}

  @doc """
  Produce the result for an op. Returns `{result_map, omissions}` — the
  omissions block is non-empty only when the `values` histogram was capped.
  """
  @spec finalize(acc(), :exists | :values | :count, pos_integer()) :: {map(), Omissions.t()}
  def finalize(acc, :exists, _max_values) do
    result = %{
      lines_with_field: acc.with_field,
      lines_without: acc.without_field,
      non_json: acc.non_json
    }

    result = if acc.sample, do: Map.put(result, :sample, acc.sample), else: result
    {result, Omissions.new()}
  end

  def finalize(acc, :count, _max_values) do
    {%{
       occurrences: acc.with_field,
       lines_without: acc.without_field,
       non_json: acc.non_json
     }, Omissions.new()}
  end

  def finalize(acc, :values, max_values) do
    sorted =
      acc.values
      |> Enum.map(fn {value, count} -> %{value: value, count: count} end)
      |> Enum.sort_by(fn %{value: v, count: c} -> {-c, v} end)

    distinct = length(sorted)

    omissions =
      Omissions.cap(Omissions.new(), :values, distinct, max_values, "top #{max_values} by count")

    {%{
       distinct_values: distinct,
       non_json: acc.non_json,
       entries: Enum.take(sorted, max_values)
     }, omissions}
  end

  # Histogram keys must be flat strings: scalars verbatim, JSON `null` as
  # "null", compound values re-encoded so structurally equal maps bucket
  # together.
  defp normalize_value(v) when is_binary(v), do: v
  defp normalize_value(nil), do: "null"
  defp normalize_value(v) when is_number(v) or is_boolean(v), do: to_string(v)
  defp normalize_value(v), do: Jason.encode!(v)
end
