defmodule McpLogServer.Util.Formatting do
  @moduledoc """
  Human-readable formatting utilities for byte sizes and time spans.
  """

  @doc "Format a byte count as a human-readable string (e.g. \"1.5 KB\")."
  @spec humanize_bytes(non_neg_integer()) :: String.t()
  def humanize_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  def humanize_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  def humanize_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  @doc "Format a duration in seconds as a human-readable string (e.g. \"2d 3h 15m 4s\")."
  @spec humanize_span(integer()) :: String.t()
  def humanize_span(seconds) when seconds < 0, do: humanize_span(-seconds)

  def humanize_span(seconds) do
    days = div(seconds, 86400)
    rem_after_days = rem(seconds, 86400)
    hours = div(rem_after_days, 3600)
    rem_after_hours = rem(rem_after_days, 3600)
    minutes = div(rem_after_hours, 60)
    secs = rem(rem_after_hours, 60)

    parts =
      [
        days > 0 && "#{days}d",
        hours > 0 && "#{hours}h",
        minutes > 0 && "#{minutes}m",
        secs > 0 && "#{secs}s"
      ]
      |> Enum.filter(& &1)

    case parts do
      [] -> "0s"
      _ -> Enum.join(parts, " ")
    end
  end
end
