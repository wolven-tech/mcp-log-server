defmodule McpLogServer.Domain.BackoffTest do
  use ExUnit.Case, async: true

  alias McpLogServer.Domain.Backoff

  test "defaults: 1s initial, doubling to a 60s cap on immediate exits" do
    schedule =
      Enum.scan(1..8, {nil, Backoff.initial_ms()}, fn _, {_, next} ->
        Backoff.on_exit(next, 0)
      end)
      |> Enum.map(fn {delay, _next} -> delay end)

    assert schedule == [1_000, 2_000, 4_000, 8_000, 16_000, 32_000, 60_000, 60_000]
  end

  test "a healthy run resets the schedule to the initial delay" do
    # Deep into the schedule...
    {delay, next} = Backoff.on_exit(32_000, 0)
    assert {delay, next} == {32_000, 60_000}

    # ...then a run that survived the healthy period resets.
    assert Backoff.on_exit(next, 30_000) == {1_000, 2_000}
  end

  test "an unhealthy run keeps escalating" do
    assert Backoff.on_exit(2_000, 29_999) == {2_000, 4_000}
  end

  test "timings are injectable for tests" do
    opts = [initial_ms: 10, cap_ms: 40, healthy_after_ms: 100]

    assert Backoff.initial_ms(opts) == 10
    assert Backoff.on_exit(10, 0, opts) == {10, 20}
    assert Backoff.on_exit(20, 0, opts) == {20, 40}
    assert Backoff.on_exit(40, 0, opts) == {40, 40}
    assert Backoff.on_exit(40, 150, opts) == {10, 20}
  end
end
