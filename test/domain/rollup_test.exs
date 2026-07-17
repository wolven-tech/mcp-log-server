defmodule McpLogServer.Domain.RollupTest do
  use ExUnit.Case, async: true

  alias McpLogServer.Domain.Rollup

  defp dt(iso) do
    {:ok, dt, _} = DateTime.from_iso8601(iso)
    dt
  end

  test "groups near-identical lines, counts instances, tracks first/last" do
    acc =
      Rollup.new()
      |> Rollup.add("conn 4f9a12cd lost after 30s", "a", dt("2026-07-17T10:00:00Z"))
      |> Rollup.add("conn 77b1e0f2 lost after 12s", "b", dt("2026-07-17T09:00:00Z"))
      |> Rollup.add("conn 00c0ffee lost after 7s", "a", dt("2026-07-17T11:00:00Z"))
      |> Rollup.add("disk full", "c", dt("2026-07-17T10:30:00Z"))

    assert [lost, disk] = Rollup.finalize(acc, 9)

    assert lost.template == "conn <HEX> lost after <N>s"
    assert lost.count == 3
    assert lost.instances_seen == "2/9"
    assert lost.first_ts == "2026-07-17T09:00:00Z"
    assert lost.last_ts == "2026-07-17T11:00:00Z"
    assert lost.sample == "conn 4f9a12cd lost after 30s"

    assert disk.count == 1
    assert disk.instances_seen == "1/9"
  end

  test "nil timestamps count but cannot move first/last" do
    acc =
      Rollup.new()
      |> Rollup.add("boom 1", "a", nil)
      |> Rollup.add("boom 2", "a", dt("2026-07-17T10:00:00Z"))
      |> Rollup.add("boom 3", "a", nil)

    assert [row] = Rollup.finalize(acc, 1)
    assert row.count == 3
    assert row.first_ts == "2026-07-17T10:00:00Z"
    assert row.last_ts == "2026-07-17T10:00:00Z"
  end

  test "all-nil timestamps finalize as nil" do
    acc = Rollup.add(Rollup.new(), "boom", "a", nil)
    assert [%{first_ts: nil, last_ts: nil}] = Rollup.finalize(acc, 1)
  end

  test "rows sort by count descending, then template" do
    acc =
      Rollup.new()
      |> Rollup.add("rare event", "a", nil)
      |> Rollup.add("common event", "a", nil)
      |> Rollup.add("common event", "a", nil)

    assert [%{template: "common event"}, %{template: "rare event"}] = Rollup.finalize(acc, 1)
  end
end
