defmodule McpLogServer.Domain.Backoff do
  @moduledoc """
  Pure exponential-backoff schedule for restarting streamed source commands.

  Defaults: 1s -> 2s -> 4s -> ... capped at 60s. A run that stayed up for at
  least the healthy period (30s) resets the schedule, so a stream that
  reconnects and holds is not punished for a crash-loop it recovered from.

  All timings are injectable (`:initial_ms`, `:cap_ms`, `:healthy_after_ms`)
  so tests can exercise the schedule in milliseconds without real sleeps.
  """

  @initial_ms 1_000
  @cap_ms 60_000
  @healthy_after_ms 30_000

  @doc "The first restart delay."
  @spec initial_ms(keyword()) :: pos_integer()
  def initial_ms(opts \\ []), do: Keyword.get(opts, :initial_ms, @initial_ms)

  @doc """
  Decide the restart delay after a command exit.

  * `current_ms` — the delay the schedule had queued for the next failure
  * `uptime_ms`  — how long the command ran before exiting

  Returns `{delay_ms, next_ms}`: the delay to wait now, and the delay to
  queue for the following failure (doubled, capped). An uptime of at least
  `:healthy_after_ms` resets the schedule to `:initial_ms` first.
  """
  @spec on_exit(pos_integer(), non_neg_integer(), keyword()) ::
          {pos_integer(), pos_integer()}
  def on_exit(current_ms, uptime_ms, opts \\ []) do
    initial = Keyword.get(opts, :initial_ms, @initial_ms)
    cap = Keyword.get(opts, :cap_ms, @cap_ms)
    healthy = Keyword.get(opts, :healthy_after_ms, @healthy_after_ms)

    delay = if uptime_ms >= healthy, do: initial, else: min(current_ms, cap)
    {delay, min(delay * 2, cap)}
  end
end
