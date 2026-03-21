defmodule McpLogServer.Domain.TimeRangeTest do
  use ExUnit.Case, async: false

  alias McpLogServer.Domain.LogReader

  @tmp_dir System.tmp_dir!() |> Path.join("time_range_test")

  setup do
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  defp write_file(name, content) do
    path = Path.join(@tmp_dir, name)
    File.write!(path, content)
    name
  end

  describe "time_range/2 with plain text" do
    test "extracts earliest and latest timestamps" do
      file =
        write_file("plain.log", """
        2026-03-20 10:00:00 INFO First entry
        2026-03-20 12:30:00 INFO Middle entry
        2026-03-20 14:00:00 ERROR Last entry
        """)

      {:ok, result} = LogReader.time_range(@tmp_dir, file)

      assert result.earliest == "2026-03-20T10:00:00Z"
      assert result.latest == "2026-03-20T14:00:00Z"
      assert result.span == "4h"
      assert result.line_count == 3
      assert result.format == "plain"
    end

    test "returns nil timestamps when no parseable timestamps" do
      file = write_file("no_ts.log", "just text\nmore text\n")

      {:ok, result} = LogReader.time_range(@tmp_dir, file)

      assert result.earliest == nil
      assert result.latest == nil
      assert result.span == nil
    end
  end

  describe "time_range/2 with JSON logs" do
    test "extracts timestamps from JSON entries" do
      file =
        write_file("json.log", """
        {"timestamp":"2026-03-20T08:00:00Z","message":"start"}
        {"timestamp":"2026-03-20T08:30:00Z","message":"middle"}
        {"timestamp":"2026-03-21T07:59:57Z","message":"end"}
        """)

      {:ok, result} = LogReader.time_range(@tmp_dir, file)

      assert result.earliest == "2026-03-20T08:00:00Z"
      assert result.latest == "2026-03-21T07:59:57Z"
      assert result.span == "23h 59m 57s"
      assert result.format == "json_lines"
    end
  end

  describe "time_range/2 with span formatting" do
    test "formats multi-day span" do
      file =
        write_file("days.log", """
        2026-03-18 00:00:00 INFO start
        2026-03-20 12:30:45 INFO end
        """)

      {:ok, result} = LogReader.time_range(@tmp_dir, file)
      assert result.span == "2d 12h 30m 45s"
    end

    test "formats zero span for single timestamp" do
      file = write_file("single.log", "2026-03-20 10:00:00 INFO only\n")

      {:ok, result} = LogReader.time_range(@tmp_dir, file)
      assert result.span == "0s"
    end
  end

  test "returns error for non-existent file" do
    assert {:error, _} = LogReader.time_range(@tmp_dir, "nope.log")
  end
end
