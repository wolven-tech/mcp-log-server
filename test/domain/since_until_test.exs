defmodule McpLogServer.Domain.SinceUntilTest do
  use ExUnit.Case, async: false

  alias McpLogServer.Domain.LogReader

  @tmp_dir System.tmp_dir!() |> Path.join("since_until_test")

  @plain_log """
  2026-03-20 08:00:00 INFO Boot
  2026-03-20 10:00:00 ERROR Disk full
  2026-03-20 12:00:00 WARN Memory high
  2026-03-20 14:00:00 ERROR Timeout
  2026-03-20 16:00:00 INFO Shutdown
  """

  @json_log """
  {"severity":"INFO","message":"Boot","timestamp":"2026-03-20T08:00:00Z"}
  {"severity":"ERROR","message":"Disk full","timestamp":"2026-03-20T10:00:00Z"}
  {"severity":"WARN","message":"Memory high","timestamp":"2026-03-20T12:00:00Z"}
  {"severity":"ERROR","message":"Timeout","timestamp":"2026-03-20T14:00:00Z"}
  {"severity":"INFO","message":"Shutdown","timestamp":"2026-03-20T16:00:00Z"}
  """

  setup do
    File.mkdir_p!(@tmp_dir)
    File.write!(Path.join(@tmp_dir, "plain.log"), @plain_log)
    File.write!(Path.join(@tmp_dir, "json.log"), @json_log)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  describe "get_errors with since/until (plain text)" do
    test "since filters out early errors" do
      {:ok, errors} =
        LogReader.get_errors(@tmp_dir, "plain.log", 100, since: "2026-03-20T11:00:00Z")

      contents = Enum.map(errors, & &1.content)
      refute Enum.any?(contents, &String.contains?(&1, "Disk full"))
      assert Enum.any?(contents, &String.contains?(&1, "Timeout"))
    end

    test "until filters out late errors" do
      {:ok, errors} =
        LogReader.get_errors(@tmp_dir, "plain.log", 100, until: "2026-03-20T11:00:00Z")

      contents = Enum.map(errors, & &1.content)
      assert Enum.any?(contents, &String.contains?(&1, "Disk full"))
      refute Enum.any?(contents, &String.contains?(&1, "Timeout"))
    end

    test "since + until combined" do
      {:ok, errors} =
        LogReader.get_errors(@tmp_dir, "plain.log", 100,
          since: "2026-03-20T09:00:00Z",
          until: "2026-03-20T13:00:00Z"
        )

      contents = Enum.map(errors, & &1.content)
      assert Enum.any?(contents, &String.contains?(&1, "Disk full"))
      assert Enum.any?(contents, &String.contains?(&1, "Memory high"))
      refute Enum.any?(contents, &String.contains?(&1, "Timeout"))
    end
  end

  describe "get_errors with since/until (JSON)" do
    test "since filters JSON errors by timestamp" do
      {:ok, errors} =
        LogReader.get_errors(@tmp_dir, "json.log", 100, since: "2026-03-20T11:00:00Z")

      messages = Enum.map(errors, & &1.message)
      refute "Disk full" in messages
      assert "Timeout" in messages
    end
  end

  describe "search_logs with since/until" do
    test "absolute range on search" do
      {:ok, result} =
        LogReader.search(@tmp_dir, "plain.log", ".",
          since: "2026-03-20T09:00:00Z",
          until: "2026-03-20T13:00:00Z"
        )

      contents = Enum.map(result.matches, & &1.content)
      assert Enum.any?(contents, &String.contains?(&1, "Disk full"))
      assert Enum.any?(contents, &String.contains?(&1, "Memory high"))
      refute Enum.any?(contents, &String.contains?(&1, "Boot"))
      refute Enum.any?(contents, &String.contains?(&1, "Timeout"))
    end
  end

  describe "tail_log with since" do
    test "since filters tail output" do
      {:ok, content} =
        LogReader.tail(@tmp_dir, "plain.log", 50, since: "2026-03-20T13:00:00Z")

      refute String.contains?(content, "Boot")
      refute String.contains?(content, "Disk full")
      assert String.contains?(content, "Timeout")
      assert String.contains?(content, "Shutdown")
    end
  end

  describe "omitting since/until" do
    test "no filtering when both are nil" do
      {:ok, errors} = LogReader.get_errors(@tmp_dir, "plain.log", 100)
      # All errors/warns should be present
      assert length(errors) >= 3
    end
  end

  describe "relative shorthands" do
    test "relative since filters correctly with dynamic fixture" do
      # Generate fixture with timestamps relative to now
      now = DateTime.utc_now()
      two_hours_ago = DateTime.add(now, -7200, :second) |> DateTime.to_iso8601()
      thirty_min_ago = DateTime.add(now, -1800, :second) |> DateTime.to_iso8601()

      # Use ISO timestamps that TimestampParser can extract
      ts_old = two_hours_ago |> String.slice(0, 19) |> String.replace("T", " ")
      ts_recent = thirty_min_ago |> String.slice(0, 19) |> String.replace("T", " ")

      File.write!(Path.join(@tmp_dir, "relative.log"), """
      #{ts_old} ERROR Old error
      #{ts_recent} ERROR Recent error
      """)

      # "1h" since should include the 30-min-ago error but exclude the 2-hour-ago one
      {:ok, errors} = LogReader.get_errors(@tmp_dir, "relative.log", 100, since: "1h")

      contents = Enum.map(errors, & &1.content)
      assert Enum.any?(contents, &String.contains?(&1, "Recent error"))
      refute Enum.any?(contents, &String.contains?(&1, "Old error"))
    end

    test "relative since does not crash with various units" do
      {:ok, _} = LogReader.get_errors(@tmp_dir, "plain.log", 100, since: "30s")
      {:ok, _} = LogReader.get_errors(@tmp_dir, "plain.log", 100, since: "5m")
      {:ok, _} = LogReader.get_errors(@tmp_dir, "plain.log", 100, since: "2h")
      {:ok, _} = LogReader.get_errors(@tmp_dir, "plain.log", 100, since: "1d")
      {:ok, _} = LogReader.get_errors(@tmp_dir, "plain.log", 100, since: "1w")
    end
  end
end
