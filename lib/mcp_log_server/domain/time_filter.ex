defmodule McpLogServer.Domain.TimeFilter do
  @moduledoc """
  Filters log lines/entries by time range.

  Lines without parseable timestamps are included (fail-open policy): during
  an incident, silently hiding lines is strictly worse than including too
  many. The degraded filtering is made OBSERVABLE instead — `classify/4`
  reports whether each line's timestamp parsed, so callers can count and
  surface `unparsed_ts` in tool results.
  """

  alias McpLogServer.Domain.JsonLogParser
  alias McpLogServer.Domain.TimestampParser

  @type parse_status :: :no_filter | :parsed | :unparsed

  @doc """
  Classify a log line or JSON entry against the given time range.

  Returns `{included?, parse_status}`:

    * `{true, :no_filter}` — no bounds given; nothing was parsed (zero cost)
    * `{_, :parsed}` — timestamp parsed; `included?` reflects the bounds
    * `{true, :unparsed}` — timestamp could not be parsed; the line is
      included (fail-open) and the caller should count it as `unparsed_ts`

  ## Options

    * `:format` — compiled declared format (`McpLogServer.Domain.TsFormat`),
      tried before auto-detection
    * `:reference` — DateTime anchoring time-only formats (file mtime)
  """
  @spec classify(String.t() | map(), DateTime.t() | nil, DateTime.t() | nil, keyword()) ::
          {boolean(), parse_status()}
  def classify(line_or_entry, since, until, opts \\ [])

  def classify(_line, nil, nil, _opts), do: {true, :no_filter}

  def classify(line, since, until, opts) when is_binary(line) do
    case TimestampParser.extract(line, opts) do
      nil -> {true, :unparsed}
      ts -> {check_bounds(ts, since, until), :parsed}
    end
  end

  def classify(entry, since, until, opts) when is_map(entry) do
    ts_value = JsonLogParser.extract_timestamp(entry)

    case TimestampParser.parse_json_value(ts_value, opts) do
      nil -> {true, :unparsed}
      ts -> {check_bounds(ts, since, until), :parsed}
    end
  end

  @doc """
  Check if a log line or JSON entry falls within the given time range.

  - `line` can be a string (plain text) or a map (parsed JSON entry)
  - `since` and `until` are optional DateTime values (nil means unbounded)
  - Lines without parseable timestamps are always included (fail-open)
  - `opts` are forwarded to `classify/4`
  """
  @spec in_range?(String.t() | map(), DateTime.t() | nil, DateTime.t() | nil, keyword()) ::
          boolean()
  def in_range?(line, since, until, opts \\ []) do
    {included?, _status} = classify(line, since, until, opts)
    included?
  end

  defp check_bounds(ts, since, until) do
    after_since? = since == nil or DateTime.compare(ts, since) in [:gt, :eq]
    before_until? = until == nil or DateTime.compare(ts, until) in [:lt, :eq]
    after_since? and before_until?
  end
end
