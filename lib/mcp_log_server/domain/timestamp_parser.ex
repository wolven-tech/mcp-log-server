defmodule McpLogServer.Domain.TimestampParser do
  @moduledoc """
  Extracts timestamps from plain text log lines and parses relative time
  shorthands.

  ANSI color escape sequences (`\\e[...m`) are stripped before matching, so
  colorized dev-server output (Vite, webpack, etc.) parses like plain text.
  Source tags (`[src:<name>] ` prefixes written by streamed `LOG_SOURCES`
  ingestion, see `McpLogServer.Domain.SourceTag`) are stripped the same way,
  so tagged lines parse exactly like their untagged originals.

  ## Time-only formats and the midnight-rollover rule

  Dev-server formats (`HH:MM:SS` prefix, `[HH:MM:SS]`, `[vite] HH:MM:SS`)
  carry no date. The date is resolved from a `:reference` DateTime — the
  file's last-modified time, supplied by the caller as data (this module
  stays pure and does no I/O). The rule:

    * resolve the time-of-day against the reference's date;
    * if the resolved instant would be LATER than the reference, shift it
      back one day.

  Why: a log line cannot be written after its file's last modification, so
  any time-of-day "in the future" relative to the mtime must belong to the
  previous day. For any file spanning less than 24 hours this keeps line
  ordering monotonic across a midnight rollover (23:59 resolves to the day
  before mtime, 00:01 to mtime's day). Without a reference, "now" (UTC) is
  used — correct for the common case of a still-growing dev-server log.
  """

  alias McpLogServer.Domain.SourceTag
  alias McpLogServer.Domain.TsFormat

  # ANSI SGR escape sequences: \e[...m
  @ansi_regex ~r/\x1b\[[0-9;]*m/

  # ISO 8601: 2026-03-20T14:00:00.123Z or 2026-03-20T14:00:00+00:00
  @iso8601_regex ~r/(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)/

  # Bracketed ISO: [2026-03-20T14:00:00.123Z]
  @bracketed_iso_regex ~r/\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)\]/

  # Syslog: Mar 20 14:00:00
  @syslog_regex ~r/^([A-Z][a-z]{2})\s+(\d{1,2})\s+(\d{2}:\d{2}:\d{2})/

  # Common log format: 20/Mar/2026:14:00:00 +0000
  @clf_regex ~r|(\d{2})/([A-Z][a-z]{2})/(\d{4}):(\d{2}:\d{2}:\d{2})\s+([+-]\d{4})|

  # Date space time: 2026-03-20 14:00:00 or 2026-03-20 14:00:00.123
  @date_space_time_regex ~r/(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2}:\d{2}(?:\.\d+)?)/

  # Time-only dev-server formats (date resolved via the rollover rule):
  # [14:00:00] or [2:00:00 PM]
  @bracketed_time_regex ~r/\[(\d{1,2}:\d{2}:\d{2}(?:\.\d+)?)(?:\s?([AP]M))?\]/
  # [vite] 14:00:00 (any bracketed tag followed by a time)
  @tagged_time_regex ~r/^\[[^\]]+\]\s+(\d{1,2}:\d{2}:\d{2}(?:\.\d+)?)(?:\s?([AP]M))?(?![\d.])/
  # 14:00:00 at line start
  @time_prefix_regex ~r/^(\d{1,2}:\d{2}:\d{2}(?:\.\d+)?)(?:\s?([AP]M))?(?![\d.])/

  # Relative: 30s, 5m, 2h, 1d, 1w
  @relative_regex ~r/^(\d+)([smhdw])$/

  @months %{
    "Jan" => 1, "Feb" => 2, "Mar" => 3, "Apr" => 4,
    "May" => 5, "Jun" => 6, "Jul" => 7, "Aug" => 8,
    "Sep" => 9, "Oct" => 10, "Nov" => 11, "Dec" => 12
  }

  @doc """
  Extract a timestamp from a log line string.

  Auto-detected formats (in order):
  - ISO 8601: `2026-03-20T14:00:00.123Z` (also bracketed)
  - Common Log Format: `20/Mar/2026:14:00:00 +0000`
  - Date space time: `2026-03-20 14:00:00`
  - Syslog: `Mar 20 14:00:00`
  - Time-only dev-server formats: `14:00:00` prefix, `[14:00:00]`,
    `[vite] 14:00:00` (with optional `AM`/`PM`)

  ANSI color codes are stripped before matching.

  ## Options

    * `:format` — a compiled `McpLogServer.Domain.TsFormat` declared for the
      source file; tried FIRST, before auto-detection.
    * `:reference` — DateTime anchoring time-only formats to a date (the
      file's mtime). Defaults to now (UTC). See the moduledoc for the
      midnight-rollover rule.

  Returns `DateTime.t()` or `nil`.
  """
  @spec extract(String.t(), keyword()) :: DateTime.t() | nil
  def extract(line, opts \\ []) when is_binary(line) do
    line = line |> strip_ansi() |> SourceTag.strip()
    reference = Keyword.get(opts, :reference)

    case Keyword.get(opts, :format) do
      nil -> auto_extract(line, reference)
      format -> TsFormat.extract(format, line, reference) || auto_extract(line, reference)
    end
  end

  @doc "Strip ANSI SGR escape sequences (`\\e[...m`) from a line."
  @spec strip_ansi(String.t()) :: String.t()
  def strip_ansi(line), do: String.replace(line, @ansi_regex, "")

  @doc """
  Parse a timestamp value taken from a structured (JSON) log entry.

  Tries the declared `:format` first (when given), then ISO 8601 for
  strings. Integer values parse only when the declared format is `epoch_ms`
  or `epoch_s`. Returns `DateTime.t()` or `nil`.
  """
  @spec parse_json_value(term(), keyword()) :: DateTime.t() | nil
  def parse_json_value(value, opts \\ [])
  def parse_json_value(nil, _opts), do: nil

  def parse_json_value(value, opts) when is_binary(value) do
    declared =
      case Keyword.get(opts, :format) do
        nil -> nil
        format -> TsFormat.extract(format, value, Keyword.get(opts, :reference))
      end

    declared ||
      case DateTime.from_iso8601(value) do
        {:ok, dt, _} -> dt
        _ -> nil
      end
  end

  def parse_json_value(value, opts) when is_integer(value) do
    case Keyword.get(opts, :format) do
      %{kind: :epoch_ms} -> ok_or_nil(DateTime.from_unix(value, :millisecond))
      %{kind: :epoch_s} -> ok_or_nil(DateTime.from_unix(value, :second))
      _ -> nil
    end
  end

  def parse_json_value(_value, _opts), do: nil

  @doc """
  Resolve a time-of-day to a full DateTime using `reference` (default: now,
  UTC) as the anchor.

  Rule: use the reference's date; if that instant would be later than the
  reference itself, shift back one day. A log line cannot postdate its
  file's last modification, so a "future" time-of-day must belong to the
  previous day — this keeps ordering monotonic across midnight for files
  spanning under 24 hours.
  """
  @spec resolve_time_only(Time.t(), DateTime.t() | nil) :: DateTime.t()
  def resolve_time_only(%Time{} = time, reference) do
    ref = reference || DateTime.utc_now()
    candidate = DateTime.new!(DateTime.to_date(ref), time, "Etc/UTC")

    if DateTime.compare(candidate, ref) == :gt do
      DateTime.add(candidate, -86_400, :second)
    else
      candidate
    end
  end

  @doc """
  Parse a user-supplied time argument: ISO 8601 first, then relative
  shorthand (`"30m"`, `"2h"`, ...). Returns `nil` for anything else.
  """
  @spec parse_time(any()) :: DateTime.t() | nil
  def parse_time(nil), do: nil

  def parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> parse_relative(value)
    end
  end

  def parse_time(_), do: nil

  @doc """
  Parse a relative time shorthand into an absolute DateTime.

  Supports: "30s", "5m", "2h", "1d", "1w"
  Returns a DateTime that many units in the past from now.
  """
  @spec parse_relative(String.t()) :: DateTime.t() | nil
  def parse_relative(input) do
    case Regex.run(@relative_regex, String.trim(input)) do
      [_, amount_str, unit] ->
        amount = String.to_integer(amount_str)
        seconds = unit_to_seconds(unit) * amount
        DateTime.utc_now() |> DateTime.add(-seconds, :second)

      _ ->
        nil
    end
  end

  defp unit_to_seconds("s"), do: 1
  defp unit_to_seconds("m"), do: 60
  defp unit_to_seconds("h"), do: 3600
  defp unit_to_seconds("d"), do: 86400
  defp unit_to_seconds("w"), do: 604_800

  # Existing date-carrying formats first (regression safety), then the
  # ambiguous time-only formats.
  defp auto_extract(line, reference) do
    with nil <- try_bracketed_iso(line),
         nil <- try_iso8601(line),
         nil <- try_clf(line),
         nil <- try_date_space_time(line),
         nil <- try_syslog(line),
         nil <- try_time_only(@bracketed_time_regex, line, reference),
         nil <- try_time_only(@tagged_time_regex, line, reference),
         nil <- try_time_only(@time_prefix_regex, line, reference) do
      nil
    end
  end

  defp ok_or_nil({:ok, dt}), do: dt
  defp ok_or_nil(_), do: nil

  defp try_bracketed_iso(line) do
    case Regex.run(@bracketed_iso_regex, line) do
      [_, ts] -> parse_iso8601(ts)
      _ -> nil
    end
  end

  defp try_iso8601(line) do
    case Regex.run(@iso8601_regex, line) do
      [_, ts] -> parse_iso8601(ts)
      _ -> nil
    end
  end

  defp parse_iso8601(ts) do
    # Ensure timezone info
    ts =
      cond do
        String.contains?(ts, "Z") or Regex.match?(~r/[+-]\d{2}:?\d{2}$/, ts) -> ts
        true -> ts <> "Z"
      end

    case DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp try_clf(line) do
    case Regex.run(@clf_regex, line) do
      [_, day, month, year, time, offset] ->
        month_num = Map.get(@months, month)

        if month_num do
          [hour, minute, second] = String.split(time, ":") |> Enum.map(&String.to_integer/1)

          offset_hours = String.slice(offset, 0, 3) |> String.to_integer()
          offset_mins = String.slice(offset, 3, 2) |> String.to_integer()
          offset_seconds = offset_hours * 3600 + offset_mins * 60

          case NaiveDateTime.new(
                 String.to_integer(year),
                 month_num,
                 String.to_integer(day),
                 hour,
                 minute,
                 second
               ) do
            {:ok, ndt} ->
              DateTime.from_naive!(ndt, "Etc/UTC")
              |> DateTime.add(-offset_seconds, :second)

            _ ->
              nil
          end
        else
          nil
        end

      _ ->
        nil
    end
  end

  defp try_date_space_time(line) do
    case Regex.run(@date_space_time_regex, line) do
      [_, date, time] ->
        parse_iso8601("#{date}T#{time}")

      _ ->
        nil
    end
  end

  defp try_syslog(line) do
    case Regex.run(@syslog_regex, line) do
      [_, month_str, day, time] ->
        month_num = Map.get(@months, month_str)

        if month_num do
          year = DateTime.utc_now().year
          [hour, minute, second] = String.split(time, ":") |> Enum.map(&String.to_integer/1)

          case NaiveDateTime.new(year, month_num, String.to_integer(day), hour, minute, second) do
            {:ok, ndt} -> DateTime.from_naive!(ndt, "Etc/UTC")
            _ -> nil
          end
        else
          nil
        end

      _ ->
        nil
    end
  end

  # -- Time-only dev-server formats --

  defp try_time_only(regex, line, reference) do
    case Regex.run(regex, line) do
      [_, time_str] -> clock_to_datetime(time_str, nil, reference)
      [_, time_str, meridiem] -> clock_to_datetime(time_str, meridiem, reference)
      _ -> nil
    end
  end

  defp clock_to_datetime(time_str, meridiem, reference) do
    case parse_clock(time_str, meridiem) do
      {:ok, time} -> resolve_time_only(time, reference)
      _ -> nil
    end
  end

  defp parse_clock(time_str, meridiem) do
    {hms, frac} =
      case String.split(time_str, ".", parts: 2) do
        [hms] -> {hms, nil}
        [hms, frac] -> {hms, frac}
      end

    with [h, m, s] <- String.split(hms, ":"),
         {hour, ""} <- Integer.parse(h),
         {minute, ""} <- Integer.parse(m),
         {second, ""} <- Integer.parse(s),
         {:ok, hour} <- apply_meridiem(hour, meridiem) do
      Time.new(hour, minute, second, frac_to_microsecond(frac))
    else
      _ -> {:error, :invalid_clock}
    end
  end

  defp apply_meridiem(hour, nil), do: {:ok, hour}
  defp apply_meridiem(hour, "AM") when hour in 1..12, do: {:ok, rem(hour, 12)}
  defp apply_meridiem(hour, "PM") when hour in 1..12, do: {:ok, rem(hour, 12) + 12}
  defp apply_meridiem(_hour, _), do: {:error, :invalid_meridiem}

  defp frac_to_microsecond(nil), do: {0, 0}

  defp frac_to_microsecond(frac) do
    digits = String.slice(frac, 0, 6)

    case Integer.parse(digits) do
      {n, ""} ->
        precision = String.length(digits)
        {n * pow10(6 - precision), precision}

      _ ->
        {0, 0}
    end
  end

  defp pow10(0), do: 1
  defp pow10(n), do: 10 * pow10(n - 1)
end
