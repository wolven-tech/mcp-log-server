defmodule McpLogServer.UseCases.CorrelateAnchorTest do
  use ExUnit.Case, async: false

  alias McpLogServer.UseCases.Correlate

  @tmp_dir System.tmp_dir!() |> Path.join("correlate_anchor_test")

  # Three source files around a boot incident at 10:00:05 and a second
  # symptom occurrence at 10:30:00. Source-tagged lines (slice 003) in
  # web.log; JSON in gateway.log; plain in db.log.
  @web_log """
  [src:web-1] 2026-01-15T10:00:00Z INFO boot starting
  [src:web-1] 2026-01-15T10:00:04Z WARN config missing key FEATURE_X
  [src:web-1] 2026-01-15T10:00:05Z ERROR boot loop detected
  [src:web-1] 2026-01-15T10:00:09Z INFO retrying boot
  [src:web-1] 2026-01-15T10:15:00Z INFO steady state
  [src:web-1] 2026-01-15T10:30:00Z ERROR boot loop detected
  [src:web-1] 2026-01-15T10:30:04Z INFO retrying boot
  """

  @gateway_log """
  {"severity":"INFO","message":"upstream healthy","timestamp":"2026-01-15T10:00:01Z"}
  {"severity":"ERROR","message":"upstream refused connection","timestamp":"2026-01-15T10:00:06Z"}
  {"severity":"INFO","message":"unrelated traffic","timestamp":"2026-01-15T10:20:00Z"}
  {"severity":"WARN","message":"upstream flapping","timestamp":"2026-01-15T10:30:02Z"}
  """

  @db_log """
  2026-01-15 10:00:03 INFO connection pool ready
  2026-01-15 10:00:07 ERROR too many connections
  2026-01-15 10:45:00 INFO vacuum complete
  """

  setup do
    File.mkdir_p!(@tmp_dir)
    File.write!(Path.join(@tmp_dir, "web.log"), @web_log)
    File.write!(Path.join(@tmp_dir, "gateway.log"), @gateway_log)
    File.write!(Path.join(@tmp_dir, "db.log"), @db_log)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  describe "anchor mode across 3 source files" do
    test "each anchor hit yields a merged, source-tagged, time-sorted window section" do
      {:ok, result} = Correlate.run_anchor(@tmp_dir, "boot loop detected", window: "±5s")

      assert result.anchor == "boot loop detected"
      assert result.total_anchors == 2
      assert result.anchors_unparsed_ts == 0
      assert length(result.sections) == 2

      [first, second] = result.sections

      # First window: 10:00:00 .. 10:00:10 — lines from all three files
      first_files = first.entries |> Enum.map(& &1.file) |> Enum.uniq() |> Enum.sort()
      assert first_files == ["db.log", "gateway.log", "web.log"]

      # merged and time-sorted across sources
      timestamps = Enum.map(first.entries, & &1.timestamp)
      assert timestamps == Enum.sort(timestamps)

      # the window excludes lines outside ±5s (10:15:00 steady state)
      refute Enum.any?(first.entries, &(&1.content =~ "steady state"))
      assert Enum.any?(first.entries, &(&1.content =~ "too many connections"))
      assert Enum.any?(first.entries, &(&1.content =~ "upstream refused"))

      # source tags stay visible in plain-line content (slice 003)
      assert Enum.any?(first.entries, &(&1.content =~ "[src:web-1]"))

      # Second window around 10:30:00 includes the gateway flap, not vacuum
      assert Enum.any?(second.entries, &(&1.content =~ "upstream flapping"))
      refute Enum.any?(second.entries, &(&1.content =~ "vacuum"))
    end

    test "overlapping anchor windows merge into one section" do
      # Both anchors (10:00:05 and 10:30:00) fall in one merged window at ±30m
      {:ok, result} = Correlate.run_anchor(@tmp_dir, "boot loop detected", window: "±30m")

      assert [section] = result.sections
      assert section.anchor_count == 2
    end

    test "asymmetric window" do
      {:ok, result} =
        Correlate.run_anchor(@tmp_dir, "boot loop detected",
          window: %{"before" => "0s", "after" => "5s"}
        )

      assert result.window == "-0s/+5s"
      [first, _second] = result.sections

      # 10:00:04 (1s before anchor) is excluded, 10:00:09 (4s after) included
      refute Enum.any?(first.entries, &(&1.content =~ "config missing"))
      assert Enum.any?(first.entries, &(&1.content =~ "retrying boot"))
    end

    test "no anchor matches yields empty sections without error" do
      {:ok, result} = Correlate.run_anchor(@tmp_dir, "never happens xyz")

      assert result.total_anchors == 0
      assert result.sections == []
      assert result.files_matched == []
    end

    test "invalid window spec is a descriptive error" do
      assert {:error, msg} = Correlate.run_anchor(@tmp_dir, "boot", window: "10 fortnights")
      assert msg =~ "Invalid window"
    end

    test "invalid regex is an error" do
      assert {:error, msg} = Correlate.run_anchor(@tmp_dir, "([")
      assert msg =~ "Invalid regex"
    end
  end

  describe "caps and honesty" do
    test "section cap is reported in omissions" do
      {:ok, result} =
        Correlate.run_anchor(@tmp_dir, "boot loop detected", window: "±5s", max_sections: 1)

      assert length(result.sections) == 1
      assert result.omissions.sections == %{omitted: 1, showing: "first 1 by time"}
    end

    test "total entry cap is reported in omissions" do
      {:ok, result} =
        Correlate.run_anchor(@tmp_dir, "boot loop detected", window: "±5s", max_results: 3)

      assert result.total_entries == 3
      assert %{omitted: _, showing: "first 3 by time"} = result.omissions.matches
    end

    test "anchor matches without parseable timestamps are counted, not dropped silently" do
      File.write!(Path.join(@tmp_dir, "nots.log"), "boot loop detected with no timestamp\n")

      {:ok, result} = Correlate.run_anchor(@tmp_dir, "boot loop detected", window: "±5s")

      assert result.anchors_unparsed_ts == 1
      assert result.total_anchors == 3
    end

    test "lines that cannot be time-placed are counted in unparsed_ts" do
      File.write!(Path.join(@tmp_dir, "nots.log"), "some line without any timestamp\n")

      {:ok, result} = Correlate.run_anchor(@tmp_dir, "boot loop detected", window: "±5s")

      assert result.unparsed_ts >= 1
    end
  end
end
