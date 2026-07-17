defmodule McpLogServer.UseCases.SummarizeTest do
  use ExUnit.Case, async: false

  alias McpLogServer.Infrastructure.NoIndex
  alias McpLogServer.UseCases.Summarize

  @tmp_dir System.tmp_dir!() |> Path.join("summarize_uc_test")

  @w_since "2026-07-17T10:15:00Z"
  @w_until "2026-07-17T10:30:00Z"

  setup_all do
    McpLogServer.Config.Patterns.init()
    :ok
  end

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  defp write!(name, lines) do
    File.write!(Path.join(@tmp_dir, name), Enum.map_join(lines, "", &(&1 <> "\n")))
  end

  defp run(opts), do: Summarize.run(@tmp_dir, [index: NoIndex] ++ opts)

  defp incident_fixture! do
    write!("app.log", [
      # baseline 10:00-10:15
      "2026-07-17T10:03:00Z INFO request 1 handled",
      "2026-07-17T10:05:00Z INFO request 2 handled",
      "2026-07-17T10:05:30Z ERROR db timeout id=9",
      "2026-07-17T10:10:00Z INFO cron sweep 7 done",
      # window 10:15-10:30
      "2026-07-17T10:16:00Z INFO request 3 handled",
      "2026-07-17T10:20:00Z ERROR redis connection refused conn=ab12cd34ef",
      "2026-07-17T10:21:00Z ERROR redis connection refused conn=99887766aa",
      "2026-07-17T10:24:00Z ERROR redis connection refused conn=deadbeef11"
    ])

    write!("web.log", [
      "2026-07-17T10:04:00Z INFO GET /health 200",
      "2026-07-17T10:22:00Z INFO GET /health 200",
      "2026-07-17T10:23:00Z INFO GET /health 200"
    ])
  end

  describe "incident drill" do
    test "a novel template on one source surfaces in new_templates with instances_seen" do
      incident_fixture!()

      {:ok, result} = run(since: @w_since, until: @w_until)

      assert [row] = result.new_templates
      assert row.template =~ "redis connection refused"
      assert row.count == 3
      assert row.instances_seen == "1/2"
      assert row.first_ts == "2026-07-17T10:20:00Z"
      assert row.sample =~ "conn=ab12cd34ef"

      gone = Enum.map(result.gone_templates, & &1.template)
      assert Enum.any?(gone, &(&1 =~ "db timeout"))
      assert Enum.any?(gone, &(&1 =~ "cron sweep"))

      # "request N handled" and "GET /health 200" exist in both — in neither list
      refute Enum.any?(result.new_templates ++ result.gone_templates, &(&1.template =~ "handled"))

      assert result.files_scanned == 2
      assert result.sources_seen == 2
      assert result.index_used == false
      assert result.unparsed_ts == 0
    end

    test "error rate delta: 3 window errors vs 1 baseline error over 15-minute halves" do
      incident_fixture!()

      {:ok, result} = run(since: @w_since, until: @w_until)

      assert result.error_rate.window_errors == 3
      assert result.error_rate.baseline_errors == 1
      assert result.error_rate.window_per_min == 0.2
      assert result.error_rate.baseline_per_min == 0.07
      assert result.error_rate.delta_per_min == 0.13
    end

    test "volume rows per source with delta" do
      incident_fixture!()

      {:ok, result} = run(since: @w_since, until: @w_until)

      app = Enum.find(result.volume, &(&1.source == "app.log"))
      web = Enum.find(result.volume, &(&1.source == "web.log"))

      assert app.window_lines == 4
      assert app.baseline_lines == 4
      assert web.window_lines == 2
      assert web.baseline_lines == 1
    end

    test "window/baseline bounds are echoed" do
      incident_fixture!()

      {:ok, result} = run(since: @w_since, until: @w_until)

      assert result.window == %{since: @w_since, until: @w_until}
      assert result.baseline == %{since: "2026-07-17T10:00:00Z", until: @w_since}
    end
  end

  describe "windows and baselines" do
    test "window shorthand anchors to now" do
      now = DateTime.utc_now()
      in_window = DateTime.add(now, -300, :second) |> DateTime.to_iso8601()
      in_baseline = DateTime.add(now, -1200, :second) |> DateTime.to_iso8601()

      write!("app.log", [
        "#{in_baseline} INFO steady state",
        "#{in_window} ERROR novel explosion code=7f7f7f7f7f"
      ])

      {:ok, result} = run(window: "15m")

      assert [row] = result.new_templates
      assert row.template =~ "novel explosion"
    end

    test "baseline overrides the baseline length" do
      incident_fixture!()

      {:ok, result} = run(since: @w_since, until: @w_until, baseline: "5m")
      assert result.baseline == %{since: "2026-07-17T10:10:00Z", until: @w_since}

      # only cron sweep (10:10) is inside the 5m baseline now
      gone = Enum.map(result.gone_templates, & &1.template)
      assert Enum.any?(gone, &(&1 =~ "cron sweep"))
      refute Enum.any?(gone, &(&1 =~ "db timeout"))
    end

    test "scoping to one file" do
      incident_fixture!()

      {:ok, result} = run(since: @w_since, until: @w_until, file: "web.log")
      assert result.files_scanned == 1
      assert result.new_templates == []
    end
  end

  describe "honesty" do
    test "unparsed lines fold into both ranges and are counted" do
      write!("app.log", [
        "2026-07-17T10:20:00Z INFO normal line",
        "mystery line with no timestamp whatsoever"
      ])

      {:ok, result} = run(since: @w_since, until: @w_until)

      assert result.unparsed_ts == 1
      refute Enum.any?(result.new_templates, &(&1.template =~ "mystery"))
      refute Enum.any?(result.gone_templates, &(&1.template =~ "mystery"))
    end

    test "JSON files classify by entry severity and timestamp" do
      write!("app.log", [
        Jason.encode!(%{"timestamp" => "2026-07-17T10:05:00Z", "level" => "info", "message" => "steady"}),
        Jason.encode!(%{"timestamp" => "2026-07-17T10:20:00Z", "level" => "error", "message" => "kaboom in shard 4"})
      ])

      {:ok, result} = run(since: @w_since, until: @w_until)

      assert result.error_rate.window_errors == 1
      assert result.error_rate.baseline_errors == 0
      assert [row] = result.new_templates
      assert row.template =~ "kaboom in shard"
    end

    test "oversized files land in omissions.skipped_files" do
      incident_fixture!()

      original = Application.get_env(:mcp_log_server, :max_log_file_mb)
      Application.put_env(:mcp_log_server, :max_log_file_mb, 0)
      on_exit(fn -> Application.put_env(:mcp_log_server, :max_log_file_mb, original) end)

      {:ok, result} = run(since: @w_since, until: @w_until)

      assert result.files_scanned == 0
      assert length(result.omissions.skipped_files) == 2
    end

    test "template caps are reported" do
      lines =
        for i <- 1..5 do
          "2026-07-17T10:2#{i}:00Z ERROR unique#{i}gremlin#{i}x appeared"
        end

      write!("app.log", lines)

      {:ok, result} = run(since: @w_since, until: @w_until, max_templates: 2)

      assert length(result.new_templates) == 2
      assert result.omissions.new_templates == %{omitted: 3, showing: "top 2 by count"}
    end
  end

  describe "validation" do
    test "missing window and since" do
      assert {:error, msg} = run([])
      assert msg =~ "window"
    end

    test "invalid window shorthand" do
      assert {:error, msg} = run(window: "banana")
      assert msg =~ "Invalid window"
    end

    test "empty window (until before since)" do
      assert {:error, msg} = run(since: @w_until, until: @w_since)
      assert msg =~ "empty"
    end

    test "invalid baseline" do
      incident_fixture!()
      assert {:error, msg} = run(since: @w_since, baseline: "nope")
      assert msg =~ "Invalid baseline"
    end

    test "explicitly named unreadable file is an error" do
      assert {:error, _} = run(since: @w_since, file: "nope.log")
    end
  end
end
