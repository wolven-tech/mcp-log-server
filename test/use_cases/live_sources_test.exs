defmodule McpLogServer.UseCases.LiveSourcesTest do
  use ExUnit.Case, async: false

  alias McpLogServer.Infrastructure.SourceStatus
  alias McpLogServer.UseCases

  @tmp_dir System.tmp_dir!() |> Path.join("live_sources_test")

  # Streamed ingest file: tagged lines, as SourceWorker writes them.
  @fly_log """
  [src:fly] 2026-07-17T10:00:01Z app[d891] req-123 accepted
  [src:fly] 2026-07-17T10:00:03Z app[d891] req-123 upstream timeout
  [src:fly] 2026-07-17T10:00:04Z app[d891] req-456 accepted
  """

  # Ordinary static file, no tags.
  @web_log """
  2026-07-17T10:00:02Z INFO web handling req-123
  2026-07-17T10:00:05Z INFO web done req-456
  """

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    SourceStatus.ensure_table()

    File.write!(Path.join(@tmp_dir, "fly.log"), @fly_log)
    File.write!(Path.join(@tmp_dir, "fly.1.log"), "[src:fly] rotated history\n")
    File.write!(Path.join(@tmp_dir, "web.log"), @web_log)
    SourceStatus.put("fly", :running)

    on_exit(fn ->
      SourceStatus.delete("fly")
      File.rm_rf!(@tmp_dir)
    end)

    :ok
  end

  describe "list_logs live-source visibility" do
    test "marks the ingest file live with source name and status" do
      {:ok, files} = UseCases.ListLogs.run(@tmp_dir)

      fly = Enum.find(files, &(&1.name == "fly.log"))
      assert fly.live == true
      assert fly.source == "fly"
      assert fly.status == :running

      web = Enum.find(files, &(&1.name == "web.log"))
      assert web.live == false
      assert web.source == nil
      assert web.status == nil

      # Rotated files are static snapshots, not live.
      rotated = Enum.find(files, &(&1.name == "fly.1.log"))
      assert rotated.live == false
    end

    test "reflects backing-off and dead worker states" do
      for status <- [:backing_off, :dead] do
        SourceStatus.put("fly", status)
        {:ok, files} = UseCases.ListLogs.run(@tmp_dir)
        assert Enum.find(files, &(&1.name == "fly.log")).status == status
      end
    end
  end

  describe "tag round-trip through existing tools (no special-casing)" do
    test "search finds values inside tagged lines" do
      {:ok, result} = UseCases.SearchLogs.run(@tmp_dir, "fly.log", "req-123")

      assert result.returned_matches == 2
      assert Enum.all?(result.matches, &(&1.content =~ "[src:fly] "))
    end

    test "tail reads the live file like any other" do
      {:ok, %{content: content}} = UseCases.TailLog.run(@tmp_dir, "fly.log", 2)
      assert content =~ "req-456"
    end

    test "correlate merges tagged and untagged files into one ordered timeline" do
      {:ok, result} = UseCases.Correlate.run(@tmp_dir, "req-123")

      assert result.total_matches == 3
      assert Enum.sort(result.files_matched) == ["fly.log", "web.log"]

      # The source tag survives the timestamp parser: every entry parsed.
      assert result.unparsed_ts == 0

      # Timeline interleaves sources in true time order...
      assert Enum.map(result.timeline, & &1.file) == ["fly.log", "web.log", "fly.log"]
      # ...and tagged content keeps its in-line source attribution.
      assert List.first(result.timeline).content =~ "[src:fly] "
    end
  end
end
