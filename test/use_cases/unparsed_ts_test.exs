defmodule McpLogServer.UseCases.UnparsedTsTest do
  @moduledoc """
  Issue #6 regression (tail_log `since` on dev-server log formats) and
  issue #7 P0.2 (observable timestamp-parse failures: `unparsed_ts`,
  `ts_parse_ratio`).
  """

  use ExUnit.Case, async: false

  alias McpLogServer.UseCases

  @tmp_dir System.tmp_dir!() |> Path.join("unparsed_ts_test")

  setup do
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  defp write_log(name, content) do
    File.write!(Path.join(@tmp_dir, name), content)
    name
  end

  defp clock(offset_seconds) do
    DateTime.utc_now()
    |> DateTime.add(offset_seconds, :second)
    |> Calendar.strftime("%H:%M:%S")
  end

  defp iso(offset_seconds) do
    DateTime.utc_now()
    |> DateTime.add(offset_seconds, :second)
    |> DateTime.to_iso8601()
  end

  describe "issue #6: tail_log since on a Vite-style dev-server log" do
    test "pre-boundary lines are excluded and leftovers are counted" do
      # Mixed dev-server output: ANSI-wrapped time prefixes, [vite] tags,
      # bracketed times, and timestamp-less continuation lines.
      file =
        write_log("dev-vite.log", """
        \e[2m#{clock(-3600)}\e[0m \e[36m[vite]\e[0m dev server started
        [#{clock(-3000)}] hmr update /src/Old.tsx
        [vite] #{clock(-2400)} page reload src/old-main.ts
        \e[2m#{clock(-600)}\e[0m \e[36m[vite]\e[0m hmr update /src/App.tsx
        [#{clock(-300)}] hmr update /src/New.tsx
        stack trace line without any timestamp
        """)

      {:ok, %{content: content, unparsed_ts: unparsed_ts}} =
        UseCases.TailLog.run(@tmp_dir, file, 50, since: "15m")

      # Pre-boundary (older than 15m) lines are gone
      refute content =~ "dev server started"
      refute content =~ "Old.tsx"
      refute content =~ "old-main.ts"

      # In-window lines survive
      assert content =~ "App.tsx"
      assert content =~ "New.tsx"

      # The timestamp-less line passed the filter (fail-open) and is counted
      assert content =~ "stack trace line without any timestamp"
      assert unparsed_ts == 1
    end

    test "without a time filter, unparsed_ts is nil (zero cost)" do
      file = write_log("dev-plain.log", "no timestamps\nanywhere here\n")

      {:ok, %{content: content, unparsed_ts: unparsed_ts}} =
        UseCases.TailLog.run(@tmp_dir, file, 50)

      assert content =~ "no timestamps"
      assert unparsed_ts == nil
    end
  end

  describe "the dangerous silent case: a file with 0% parseable timestamps" do
    test "unparsed_ts equals the scanned line count" do
      file =
        write_log("opaque.log", """
        ERROR something broke
        WARN something odd
        plain line one
        plain line two
        """)

      {:ok, %{content: content, unparsed_ts: unparsed_ts}} =
        UseCases.TailLog.run(@tmp_dir, file, 50, since: "5m")

      # Fail-open: every line is included...
      assert content =~ "ERROR something broke"
      assert content =~ "plain line two"
      # ...and the counter says filtering was fully degraded.
      assert unparsed_ts == 4
    end

    test "log_stats reports a 0.0 parse ratio with the sample size" do
      file = write_log("opaque.log", "no ts one\nno ts two\nno ts three\n")

      {:ok, stats} = UseCases.CollectStats.run(@tmp_dir, file)

      assert stats.ts_parse_ratio == 0.0
      assert stats.ts_parse_sample == 3
    end

    test "time_range reports a 0.0 parse ratio over its sample" do
      file = write_log("opaque.log", "no ts one\nno ts two\n")

      {:ok, range} = UseCases.TimeRange.run(@tmp_dir, file)

      assert range.ts_parse_ratio == 0.0
      assert range.ts_parse_sample == 2
      assert range.earliest == nil
    end
  end

  describe "counter accuracy across tools" do
    setup do
      file =
        write_log("mixed.log", """
        #{iso(-7200)} ERROR old failure
        #{iso(-600)} ERROR recent failure
        unstamped noise line
        another unstamped ERROR line
        #{iso(-300)} INFO recent ok
        """)

      %{log_file: file}
    end

    test "get_errors counts every scanned unparsed line, not just matches", %{log_file: file} do
      {:ok, %{entries: entries, unparsed_ts: unparsed_ts}} =
        UseCases.GetErrors.run(@tmp_dir, file, 100, since: "1h")

      contents = Enum.map(entries, & &1.content)
      refute Enum.any?(contents, &(&1 =~ "old failure"))
      assert Enum.any?(contents, &(&1 =~ "recent failure"))
      # Fail-open: the unstamped ERROR line is kept
      assert Enum.any?(contents, &(&1 =~ "another unstamped ERROR line"))
      # Both unstamped lines were scanned while filtering
      assert unparsed_ts == 2
    end

    test "get_errors without a time filter reports nil", %{log_file: file} do
      {:ok, %{unparsed_ts: unparsed_ts}} = UseCases.GetErrors.run(@tmp_dir, file, 100)
      assert unparsed_ts == nil
    end

    test "search_logs includes unparsed_ts only when a time filter is active", %{log_file: file} do
      {:ok, filtered} = UseCases.SearchLogs.run(@tmp_dir, file, "ERROR", since: "1h")
      assert filtered.unparsed_ts == 2
      refute Enum.any?(filtered.matches, &(&1.content =~ "old failure"))

      {:ok, unfiltered} = UseCases.SearchLogs.run(@tmp_dir, file, "ERROR")
      refute Map.has_key?(unfiltered, :unparsed_ts)
    end

    test "all_errors sums unparsed_ts across scanned files", %{log_file: file} do
      write_log("second.log", """
      #{iso(-300)} ERROR another service
      also unstamped here
      """)

      {:ok, %{results: results, unparsed_ts: unparsed_ts}} =
        UseCases.AllErrors.run(@tmp_dir, 100, since: "1h")

      assert length(results) == 2
      assert unparsed_ts == 3

      {:ok, %{unparsed_ts: nil}} = UseCases.AllErrors.run(@tmp_dir, 100)
      _ = file
    end

    test "correlate counts timeline entries without a parseable timestamp", %{log_file: file} do
      {:ok, result} = UseCases.Correlate.run(@tmp_dir, "ERROR")

      assert result.unparsed_ts == 1
      assert result.total_matches >= 3
      # Unparseable entries sort last in the timeline
      assert List.last(result.timeline).timestamp == nil
      _ = file
    end
  end

  describe "declared formats (LOG_TS_FORMATS) beat auto-detection" do
    test "an epoch_ms declaration makes an otherwise-unparseable file filterable" do
      old_ms = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.to_unix(:millisecond)
      new_ms = DateTime.utc_now() |> DateTime.add(-300, :second) |> DateTime.to_unix(:millisecond)

      file =
        write_log("epoch.log", """
        #{old_ms} ERROR old failure
        #{new_ms} ERROR recent failure
        """)

      {:ok, epoch_ms} = McpLogServer.Domain.TsFormat.compile("epoch_ms")

      # Without the declaration both lines are unparseable -> fail-open keeps both
      {:ok, %{entries: without, unparsed_ts: 2}} =
        UseCases.GetErrors.run(@tmp_dir, file, 100, since: "1h")

      assert length(without) == 2

      # With the declared format, filtering actually works
      {:ok, %{entries: with_fmt, unparsed_ts: 0}} =
        UseCases.GetErrors.run(@tmp_dir, file, 100, since: "1h", ts_format: epoch_ms)

      assert [%{content: content}] = with_fmt
      assert content =~ "recent failure"
    end

    test "a declaration via config wins for matching globs end-to-end" do
      original = Application.get_env(:mcp_log_server, :ts_formats)
      Application.put_env(:mcp_log_server, :ts_formats, "epoch-*.log=epoch_s")
      McpLogServer.Config.TsFormats.init!()

      on_exit(fn ->
        Application.put_env(:mcp_log_server, :ts_formats, original)
        McpLogServer.Config.TsFormats.init!()
      end)

      old_s = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.to_unix()
      new_s = DateTime.utc_now() |> DateTime.add(-300, :second) |> DateTime.to_unix()

      file =
        write_log("epoch-svc.log", """
        #{old_s} ERROR old failure
        #{new_s} ERROR recent failure
        """)

      {:ok, %{entries: entries, unparsed_ts: 0}} =
        UseCases.GetErrors.run(@tmp_dir, file, 100, since: "1h")

      assert [%{content: content}] = entries
      assert content =~ "recent failure"
    end
  end
end
