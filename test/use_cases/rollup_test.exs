defmodule McpLogServer.UseCases.RollupTest do
  @moduledoc """
  Issue #7 P2: multi-instance rollup. The incident question — "did X
  happen, on how many instances, first/last when?" — must be answerable in
  ONE call across a directory of per-source logs.
  """

  use ExUnit.Case, async: false

  alias McpLogServer.Tools.Dispatcher
  alias McpLogServer.UseCases

  @tmp_dir System.tmp_dir!() |> Path.join("rollup_test")

  setup do
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  defp write_log(name, content) do
    File.write!(Path.join(@tmp_dir, name), content)
    name
  end

  # Three streamed sources (slice 003 tagging): the OOM message appears on
  # exactly ONE of them — the easy-to-miss 1-of-N signal.
  defp write_three_sources do
    write_log("web-1.log", """
    [src:web-1] 2026-07-17T17:59:21Z proxy[a1b2c3d4] upstream 10.0.0.7:8080 timed out after 30s
    [src:web-1] 2026-07-17T18:00:00Z INFO healthy
    [src:web-1] 2026-07-17T18:04:10Z proxy[a1b2c3d4] upstream 10.0.0.7:8080 timed out after 9s
    """)

    write_log("web-2.log", """
    [src:web-2] 2026-07-17T17:59:30Z proxy[99ffe012] upstream 10.0.1.9:8080 timed out after 12s
    [src:web-2] 2026-07-17T17:59:21Z ERROR out of memory: killed worker 4411
    [src:web-2] 2026-07-17T18:03:33Z ERROR out of memory: killed worker 5522
    """)

    write_log("web-3.log", """
    [src:web-3] 2026-07-17T18:01:00Z INFO healthy
    [src:web-3] 2026-07-17T18:02:00Z proxy[0f0f0f0f] upstream 10.0.2.2:8080 timed out after 7s
    """)
  end

  describe "search_logs rollup across all files" do
    test "a message on 1 of 3 sources shows instances_seen 1/3 with first/last" do
      write_three_sources()

      {:ok, result} = UseCases.SearchLogs.run(@tmp_dir, nil, "out of memory", rollup: true)

      assert result.rollup == true
      assert result.sources_scanned == 3
      assert [row] = result.entries

      assert row.template == "<TS> ERROR out of memory: killed worker <N>"
      assert row.count == 2
      assert row.instances_seen == "1/3"
      assert row.first_ts == "2026-07-17T17:59:21Z"
      assert row.last_ts == "2026-07-17T18:03:33Z"
      assert row.sample =~ "killed worker 4411"
    end

    test "a message on all sources shows instances_seen 3/3" do
      write_three_sources()

      {:ok, result} = UseCases.SearchLogs.run(@tmp_dir, nil, "timed out", rollup: true)

      assert [row] = result.entries
      assert row.template == "<TS> proxy[<HEX>] upstream <IP> timed out after <N>s"
      assert row.count == 4
      assert row.instances_seen == "3/3"
      assert row.first_ts == "2026-07-17T17:59:21Z"
      assert row.last_ts == "2026-07-17T18:04:10Z"
    end

    test "rotated files collapse into their logical source (no denominator inflation)" do
      write_three_sources()
      # Rotated history of web-2 keeps its tags (slice 003) — it must count
      # as the SAME instance, not a fourth source.
      write_log("web-2.1.log", """
      [src:web-2] 2026-07-17T16:00:00Z ERROR out of memory: killed worker 1100
      """)

      {:ok, result} = UseCases.SearchLogs.run(@tmp_dir, nil, "out of memory", rollup: true)

      assert result.sources_scanned == 3
      assert [row] = result.entries
      assert row.count == 3
      assert row.instances_seen == "1/3"
      assert row.first_ts == "2026-07-17T16:00:00Z"
    end

    test "untagged files count by file name" do
      write_log("api.log", "2026-07-17T10:00:00Z ERROR boom 1\n")
      write_log("worker.log", "2026-07-17T11:00:00Z ERROR boom 2\n")

      {:ok, result} = UseCases.SearchLogs.run(@tmp_dir, nil, "boom", rollup: true)

      assert result.sources_scanned == 2
      assert [%{instances_seen: "2/2", count: 2}] = result.entries
    end

    test "single-file rollup scans just that file" do
      write_three_sources()

      {:ok, result} = UseCases.SearchLogs.run(@tmp_dir, "web-2.log", "timed out", rollup: true)

      assert result.sources_scanned == 1
      assert [%{count: 1, instances_seen: "1/1"}] = result.entries
    end

    test "JSON logs roll up on their message field" do
      write_log("svc.log", """
      {"severity":"ERROR","message":"payment 111 failed","timestamp":"2026-07-17T10:00:00Z"}
      {"severity":"ERROR","message":"payment 222 failed","timestamp":"2026-07-17T11:00:00Z"}
      """)

      {:ok, result} = UseCases.SearchLogs.run(@tmp_dir, nil, "payment", rollup: true)

      assert [row] = result.entries
      assert row.template == "payment <N> failed"
      assert row.count == 2
      assert row.first_ts == "2026-07-17T10:00:00Z"
      assert row.last_ts == "2026-07-17T11:00:00Z"
    end

    test "respects since/until and reports unparsed_ts" do
      write_log("app.log", """
      2026-07-17T10:00:00Z ERROR boom old
      no timestamp ERROR boom noise
      #{DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()} ERROR boom new
      """)

      {:ok, result} = UseCases.SearchLogs.run(@tmp_dir, nil, "boom", rollup: true, since: "30m")

      assert result.unparsed_ts == 1
      # old line filtered out; noise line fail-open + new line remain
      assert Enum.sum(Enum.map(result.entries, & &1.count)) == 2
    end

    test "non-rollup default behavior is untouched" do
      write_three_sources()

      {:ok, result} = UseCases.SearchLogs.run(@tmp_dir, "web-2.log", "out of memory")

      assert result.returned_matches == 2
      refute Map.has_key?(result, :rollup)
      assert [%{line_number: _, content: _} | _] = result.matches
    end
  end

  describe "all_errors rollup" do
    test "collapses errors across sources with severity filtering" do
      write_three_sources()

      {:ok, result} = UseCases.AllErrors.run(@tmp_dir, 20, rollup: true, level: :error)

      assert result.rollup == true
      assert result.level == :error
      assert result.sources_scanned == 3
      assert [row] = result.entries
      assert row.template == "<TS> ERROR out of memory: killed worker <N>"
      assert row.instances_seen == "1/3"
    end

    test "exclude pattern applies in rollup mode" do
      write_three_sources()

      {:ok, result} =
        UseCases.AllErrors.run(@tmp_dir, 20, rollup: true, level: :error, exclude: "out of memory")

      assert result.entries == []
    end
  end

  describe "oversized files are never silently dropped from a rollup scan" do
    test "search_logs rollup names the skipped file and the reason" do
      write_three_sources()
      write_log("huge.log", String.duplicate("ERROR out of memory big\n", 200))
      Application.put_env(:mcp_log_server, :max_log_file_mb, 0)
      on_exit(fn -> Application.put_env(:mcp_log_server, :max_log_file_mb, 100) end)

      {:ok, result} = UseCases.SearchLogs.run(@tmp_dir, nil, "out of memory", rollup: true)

      # max_log_file_mb 0 skips every non-empty file — all named, none scanned
      assert result.sources_scanned == 0
      skipped = result.omissions.skipped_files
      assert Enum.any?(skipped, &(&1.file == "huge.log"))
      assert Enum.all?(skipped, &(&1.reason =~ "File too large"))
    end
  end

  describe "rollup via the tool dispatcher" do
    test "search_logs tool renders TOON rows with instances_seen" do
      write_three_sources()

      {:ok, output} =
        Dispatcher.call("search_logs", %{"pattern" => "out of memory", "rollup" => true}, @tmp_dir)

      assert output =~ "instances_seen"
      assert output =~ "1/3"
      assert output =~ "out of memory: killed worker <N>"
      assert output =~ ~s("sources_scanned":3)
    end

    test "search_logs tool without file and without rollup errors loudly" do
      {:error, msg} = Dispatcher.call("search_logs", %{"pattern" => "x"}, @tmp_dir)
      assert msg =~ "file is required"
    end

    test "all_errors tool renders rollup rows" do
      write_three_sources()

      {:ok, output} = Dispatcher.call("all_errors", %{"rollup" => true, "level" => "error"}, @tmp_dir)

      assert output =~ "instances_seen"
      assert output =~ "1/3"
    end
  end
end
