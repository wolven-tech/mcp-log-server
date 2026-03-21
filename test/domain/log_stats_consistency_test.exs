defmodule McpLogServer.Domain.LogStatsConsistencyTest do
  use ExUnit.Case, async: false

  alias McpLogServer.Domain.LogReader

  @tmp_dir System.tmp_dir!() |> Path.join("log_stats_consistency_test")

  @plain_log """
  2026-01-15 10:30:00 INFO Request handled
  2026-01-15 10:30:01 WARN Slow query detected
  2026-01-15 10:30:02 ERROR Connection failed
  2026-01-15 10:30:03 FATAL Out of memory
  2026-01-15 10:30:04 INFO Health check OK
  """

  setup do
    File.mkdir_p!(@tmp_dir)
    File.write!(Path.join(@tmp_dir, "app.log"), @plain_log)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  test "log_stats counts are consistent with get_errors results" do
    {:ok, stats} = LogReader.get_stats(@tmp_dir, "app.log")

    # get_errors with level: :error returns ERROR + FATAL
    {:ok, error_and_fatal} = LogReader.get_errors(@tmp_dir, "app.log", 1000, level: :error)
    assert stats.error_count + stats.fatal_count == length(error_and_fatal)

    # get_errors with level: :warn returns WARN + ERROR + FATAL
    {:ok, warn_and_above} = LogReader.get_errors(@tmp_dir, "app.log", 1000, level: :warn)
    assert stats.warn_count + stats.error_count + stats.fatal_count == length(warn_and_above)
  end

  test "log_stats includes fatal_count" do
    {:ok, stats} = LogReader.get_stats(@tmp_dir, "app.log")

    assert Map.has_key?(stats, :fatal_count)
    assert stats.fatal_count == 1
    assert stats.error_count == 1
    assert stats.warn_count == 1
  end
end
