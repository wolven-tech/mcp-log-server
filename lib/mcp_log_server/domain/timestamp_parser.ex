defmodule McpLogServer.Domain.TimestampParser do
  @moduledoc """
  Extracts timestamps from plain text log lines and parses relative time shorthands.
  """

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

  # Relative: 30s, 5m, 2h, 1d, 1w
  @relative_regex ~r/^(\d+)([smhdw])$/

  @months %{
    "Jan" => 1, "Feb" => 2, "Mar" => 3, "Apr" => 4,
    "May" => 5, "Jun" => 6, "Jul" => 7, "Aug" => 8,
    "Sep" => 9, "Oct" => 10, "Nov" => 11, "Dec" => 12
  }

  @doc """
  Extract a timestamp from a log line string.

  Supports:
  - ISO 8601: `2026-03-20T14:00:00.123Z`
  - Bracketed ISO: `[2026-03-20T14:00:00.123Z]`
  - Syslog: `Mar 20 14:00:00`
  - Common Log Format: `20/Mar/2026:14:00:00 +0000`
  - Date space time: `2026-03-20 14:00:00`

  Returns `DateTime.t()` or `nil`.
  """
  @spec extract(String.t()) :: DateTime.t() | nil
  def extract(line) do
    # Try formats in specificity order
    with nil <- try_bracketed_iso(line),
         nil <- try_iso8601(line),
         nil <- try_clf(line),
         nil <- try_date_space_time(line),
         nil <- try_syslog(line) do
      nil
    end
  end

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
end
