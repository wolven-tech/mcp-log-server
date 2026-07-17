defmodule McpLogServer.UseCases.IndexOracleTest do
  @moduledoc """
  The core P7 guarantee: for any query, the indexed path and the linear
  scan return IDENTICAL results (apart from the `index_used` flag). The
  linear scan (`NoIndex`) is the oracle; the real index must agree with it
  on every fixture, including the ones designed to make a naive seek
  unsound (unparsed lines in the prefix, boundary-equal timestamps).
  """
  use ExUnit.Case, async: false

  alias McpLogServer.Infrastructure.LogIndex
  alias McpLogServer.Infrastructure.NoIndex
  alias McpLogServer.UseCases.Aggregate
  alias McpLogServer.UseCases.SearchLogs
  alias McpLogServer.UseCases.Summarize
  alias McpLogServer.UseCases.TailLog

  @tmp_dir System.tmp_dir!() |> Path.join("index_oracle_test")
  # > default checkpoint interval (1000) so the global index has seek points
  @lines 2_500
  @base ~U[2026-07-17 00:00:00Z]

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

  defp ts(i), do: DateTime.add(@base, i, :second) |> DateTime.to_iso8601()

  defp plain_fixture!(name, opts \\ []) do
    unparsed_at = Keyword.get(opts, :unparsed_at)
    path = Path.join(@tmp_dir, name)

    content =
      Enum.map_join(1..@lines, "", fn i ->
        cond do
          i == unparsed_at -> "line without any timestamp marker\n"
          rem(i, 100) == 0 -> "#{ts(i)} ERROR request #{i} failed conn=#{i}\n"
          true -> "#{ts(i)} INFO request #{i} handled\n"
        end
      end)

    File.write!(path, content)
    path
  end

  defp json_fixture!(name) do
    path = Path.join(@tmp_dir, name)

    content =
      Enum.map_join(1..@lines, "", fn i ->
        base = %{"timestamp" => ts(i), "level" => "info", "message" => "req #{i}"}
        base = if rem(i, 250) == 0, do: Map.put(base, "gated", true), else: base
        Jason.encode!(base) <> "\n"
      end)

    File.write!(path, content)
    path
  end

  defp both(fun) do
    {:ok, indexed} = fun.([])
    {:ok, linear} = fun.(index: NoIndex)
    {indexed, linear}
  end

  defp assert_oracle(indexed, linear, index_used) do
    assert Map.delete(indexed, :index_used) == Map.delete(linear, :index_used)
    assert Map.get(indexed, :index_used) == index_used
    assert Map.get(linear, :index_used) in [false, nil]
  end

  describe "tail_log" do
    test "since-bounded tail: identical output, index used" do
      path = plain_fixture!("app.log")
      assert {:ok, _} = LogIndex.build_now(path)

      since = ts(2_000)

      {indexed, linear} =
        both(fn opts -> TailLog.run(@tmp_dir, "app.log", 100, [since: since] ++ opts) end)

      assert_oracle(indexed, linear, true)
      assert indexed.content =~ "request #{@lines} failed"
      assert indexed.unparsed_ts == 0
    end

    test "unparsed line in the prefix forces the full scan — still identical" do
      path = plain_fixture!("app.log", unparsed_at: 50)
      assert {:ok, _} = LogIndex.build_now(path)

      {indexed, linear} =
        both(fn opts -> TailLog.run(@tmp_dir, "app.log", 100, [since: ts(2_000)] ++ opts) end)

      # the fail-open line makes every prefix unsafe: no seek
      assert_oracle(indexed, linear, false)
    end

    test "without since the query is not index-eligible (no flag)" do
      plain_fixture!("app.log")
      {:ok, result} = TailLog.run(@tmp_dir, "app.log", 10)
      refute Map.has_key?(result, :index_used)
    end
  end

  describe "search_logs" do
    test "since-bounded search: identical matches, line numbers, omissions, cursor" do
      path = plain_fixture!("app.log")
      assert {:ok, _} = LogIndex.build_now(path)

      {indexed, linear} =
        both(fn opts ->
          SearchLogs.run(@tmp_dir, "app.log", "ERROR", [since: ts(1_500), max_results: 5] ++ opts)
        end)

      assert_oracle(indexed, linear, true)
      assert indexed.returned_matches == 5
      assert [%{line_number: 1_500} | _] = indexed.matches
      assert indexed.omissions.matches.omitted > 0
    end

    test "context lines disable the seek (context may precede the bound)" do
      path = plain_fixture!("app.log")
      assert {:ok, _} = LogIndex.build_now(path)

      {indexed, linear} =
        both(fn opts ->
          SearchLogs.run(@tmp_dir, "app.log", "ERROR", [since: ts(1_500), context: 2] ++ opts)
        end)

      assert_oracle(indexed, linear, false)
    end

    test "rotation between build and query degrades to the full scan" do
      path = plain_fixture!("app.log")
      assert {:ok, _} = LogIndex.build_now(path)

      # rotate: entirely new content, same name
      File.rm!(path)

      File.write!(
        path,
        Enum.map_join(1..50, "", fn i -> "#{ts(i)} ERROR fresh #{i}\n" end)
      )

      {indexed, linear} =
        both(fn opts ->
          SearchLogs.run(@tmp_dir, "app.log", "fresh", [since: ts(10)] ++ opts)
        end)

      assert_oracle(indexed, linear, false)
      assert indexed.returned_matches > 0
    end
  end

  describe "aggregate" do
    test "since-bounded aggregate on NDJSON (entry semantics): identical counts" do
      path = json_fixture!("app.log")
      assert {:ok, _} = LogIndex.build_now(path)

      {indexed, linear} =
        both(fn opts ->
          Aggregate.run(@tmp_dir, "app.log", "gated", "count", [since: ts(2_000)] ++ opts)
        end)

      assert_oracle(indexed, linear, true)
      assert indexed.occurrences == 3
      assert indexed.unparsed_ts == 0
    end

    test "absence skip: a field proven absent contributes stored totals without a scan" do
      path = json_fixture!("app.log")
      assert {:ok, _} = LogIndex.build_now(path)

      {indexed, linear} =
        both(fn opts ->
          Aggregate.run(@tmp_dir, "app.log", "definitely_absent", "exists", opts)
        end)

      assert_oracle(indexed, linear, true)
      assert indexed.lines_with_field == 0
      assert indexed.lines_without == @lines
      assert indexed.non_json == 0
    end

    test "a present field is never 'absence-skipped'" do
      path = json_fixture!("app.log")
      assert {:ok, _} = LogIndex.build_now(path)

      {indexed, linear} =
        both(fn opts -> Aggregate.run(@tmp_dir, "app.log", "gated", "exists", opts) end)

      assert Map.delete(indexed, :index_used) == Map.delete(linear, :index_used)
      assert indexed.lines_with_field == 10
      assert indexed.sample =~ "gated"
    end

    test "values histogram identical with and without index" do
      path = json_fixture!("app.log")
      assert {:ok, _} = LogIndex.build_now(path)

      {indexed, linear} =
        both(fn opts ->
          Aggregate.run(@tmp_dir, "app.log", "level", "values", [since: ts(2_000)] ++ opts)
        end)

      assert_oracle(indexed, linear, true)
      assert [%{value: "info", count: 501}] = indexed.entries
    end
  end

  describe "summarize" do
    test "windowed diff identical with and without index" do
      path = plain_fixture!("app.log")
      assert {:ok, _} = LogIndex.build_now(path)

      {indexed, linear} =
        both(fn opts ->
          Summarize.run(
            @tmp_dir,
            [file: "app.log", since: ts(2_000), until: ts(@lines)] ++ opts
          )
        end)

      assert_oracle(indexed, linear, true)
      assert indexed.error_rate.window_errors == 6
    end
  end

  describe "disabled / deleted index" do
    test "queries answer correctly when the .index directory is deleted" do
      path = plain_fixture!("app.log")
      assert {:ok, _} = LogIndex.build_now(path)

      # deleting the on-disk index does not affect correctness (ETS still
      # holds the entry; and even a full miss just linear-scans)
      File.rm_rf!(Path.join(McpLogServer.Infrastructure.EnvConfig.log_dir(), ".index"))

      {indexed, linear} =
        both(fn opts -> TailLog.run(@tmp_dir, "app.log", 50, [since: ts(2_400)] ++ opts) end)

      assert Map.delete(indexed, :index_used) == Map.delete(linear, :index_used)
    end
  end
end
