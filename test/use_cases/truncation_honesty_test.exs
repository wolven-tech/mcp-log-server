defmodule McpLogServer.UseCases.TruncationHonestyTest do
  @moduledoc """
  Issue #7 P3: never truncate silently. Every tool that bounds its output
  must say so IN THE RESULT when the bound was actually hit — and stay
  byte-identical to before when it was not (no `omitted: 0` noise).
  """

  use ExUnit.Case, async: false

  alias McpLogServer.Tools.Dispatcher
  alias McpLogServer.UseCases

  @tmp_dir System.tmp_dir!() |> Path.join("truncation_honesty_test")

  setup do
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  defp write_log(name, content) do
    File.write!(Path.join(@tmp_dir, name), content)
    name
  end

  defp numbered_errors(n) do
    Enum.map_join(1..n, "\n", &"2026-07-17T10:00:#{String.pad_leading("#{rem(&1, 60)}", 2, "0")}Z ERROR failure number #{&1}") <>
      "\n"
  end

  describe "search_logs max_results cap" do
    test "capped plain search reports how many matches were withheld" do
      file = write_log("app.log", numbered_errors(30))

      {:ok, result} = UseCases.SearchLogs.run(@tmp_dir, file, "failure", max_results: 10)

      assert result.returned_matches == 10
      assert result.omissions == %{matches: %{omitted: 20, showing: "first 10"}}
    end

    test "uncapped plain search carries no omissions" do
      file = write_log("app.log", numbered_errors(5))

      {:ok, result} = UseCases.SearchLogs.run(@tmp_dir, file, "failure", max_results: 10)

      assert result.returned_matches == 5
      refute Map.has_key?(result, :omissions)
    end

    test "capped JSON field search (lazy path) marks capped_at" do
      lines =
        Enum.map_join(1..20, "\n", fn i ->
          ~s({"severity":"ERROR","message":"payment #{i} failed","timestamp":"2026-07-17T10:00:00Z"})
        end)

      file = write_log("svc.log", lines <> "\n")

      {:ok, result} =
        UseCases.SearchLogs.run(@tmp_dir, file, "payment", field: "message", max_results: 5)

      assert result.returned_matches == 5
      assert result.omissions == %{matches: %{capped_at: 5}}
    end

    test "capped JSON field search with a time filter reports the exact count" do
      lines =
        Enum.map_join(1..20, "\n", fn i ->
          ~s({"severity":"ERROR","message":"payment #{i} failed","timestamp":"2026-07-17T10:00:00Z"})
        end)

      file = write_log("svc.log", lines <> "\n")

      {:ok, result} =
        UseCases.SearchLogs.run(@tmp_dir, file, "payment",
          field: "message",
          max_results: 5,
          since: "2026-01-01T00:00:00Z"
        )

      assert result.omissions == %{matches: %{omitted: 15, showing: "first 5"}}
    end
  end

  describe "get_errors lines cap" do
    test "capped extraction reports omitted matches" do
      file = write_log("app.log", numbered_errors(25))

      {:ok, %{entries: entries, omissions: omissions}} =
        UseCases.GetErrors.run(@tmp_dir, file, 10)

      assert length(entries) == 10
      assert omissions == %{matches: %{omitted: 15, showing: "newest 10"}}
    end

    test "complete extraction carries an empty block (tool emits nothing)" do
      file = write_log("app.log", numbered_errors(3))

      {:ok, %{omissions: omissions}} = UseCases.GetErrors.run(@tmp_dir, file, 10)
      assert omissions == %{}

      {:ok, output} = Dispatcher.call("get_errors", %{"file" => file, "lines" => 10}, @tmp_dir)
      refute output =~ "omissions"
    end

    test "tool output includes the marker when capped" do
      file = write_log("app.log", numbered_errors(25))

      {:ok, output} = Dispatcher.call("get_errors", %{"file" => file, "lines" => 10}, @tmp_dir)
      assert output =~ ~s("omissions":{"matches":{"omitted":15,"showing":"newest 10"}})
    end
  end

  describe "tail_log line cap" do
    test "a tail shorter than the file reports the withheld older lines" do
      file = write_log("app.log", numbered_errors(120))

      {:ok, %{omissions: omissions}} = UseCases.TailLog.run(@tmp_dir, file, 100)
      assert omissions == %{lines: %{omitted: 20, showing: "newest 100"}}

      {:ok, output} = Dispatcher.call("tail_log", %{"file" => file, "lines" => 100}, @tmp_dir)
      assert output =~ ~s(# omissions: {"lines":{"omitted":20,"showing":"newest 100"}})
    end

    test "a tail that fits carries no marker" do
      file = write_log("app.log", numbered_errors(5))

      {:ok, %{omissions: omissions}} = UseCases.TailLog.run(@tmp_dir, file, 100)
      assert omissions == %{}

      {:ok, output} = Dispatcher.call("tail_log", %{"file" => file, "lines" => 100}, @tmp_dir)
      refute output =~ "omissions"
    end
  end

  describe "correlate max_results cap" do
    test "capped timeline reports omitted matches" do
      write_log("a.log", numbered_errors(10))
      write_log("b.log", numbered_errors(10))

      {:ok, result} = UseCases.Correlate.run(@tmp_dir, "failure", max_results: 8)

      assert length(result.timeline) == 8
      assert result.omissions == %{matches: %{omitted: 12, showing: "first 8 by time"}}
    end

    test "complete timeline carries no marker, tool meta includes it only when capped" do
      write_log("a.log", numbered_errors(3))

      {:ok, result} = UseCases.Correlate.run(@tmp_dir, "failure")
      refute Map.has_key?(result, :omissions)

      {:ok, output} = Dispatcher.call("correlate", %{"value" => "failure"}, @tmp_dir)
      refute output =~ "omissions"

      {:ok, capped_output} =
        Dispatcher.call("correlate", %{"value" => "failure", "max_results" => 2}, @tmp_dir)

      assert capped_output =~ ~s("omissions":{"matches":{"omitted":1,"showing":"first 2 by time"}})
    end
  end

  describe "trace_ids max_values cap (tool output)" do
    test "capped value list carries the marker; exhaustive list does not" do
      write_log("api.log", """
      2026-07-17T10:00:00Z INFO sessionId=aaa
      2026-07-17T10:00:01Z INFO sessionId=bbb
      2026-07-17T10:00:02Z INFO sessionId=ccc
      """)

      {:ok, capped} =
        Dispatcher.call("trace_ids", %{"field" => "sessionId", "max_values" => 1}, @tmp_dir)

      assert capped =~ ~s("omissions":{"values":{"omitted":2,"showing":"top 1 by count"}})

      {:ok, full} = Dispatcher.call("trace_ids", %{"field" => "sessionId"}, @tmp_dir)
      refute full =~ "omissions"
    end
  end

  describe "the incident case: MAX_LOG_FILE_MB silently skipping files" do
    setup do
      Application.put_env(:mcp_log_server, :max_log_file_mb, 0)
      on_exit(fn -> Application.put_env(:mcp_log_server, :max_log_file_mb, 100) end)
      :ok
    end

    test "all_errors names every skipped file and the reason in omissions" do
      write_log("huge.log", String.duplicate("ERROR beyond the buffer\n", 200))

      {:ok, %{results: results, omissions: omissions}} = UseCases.AllErrors.run(@tmp_dir, 20)

      assert results == []
      assert [%{file: "huge.log", reason: reason}] = omissions.skipped_files
      assert reason =~ "File too large"
      assert reason =~ "MAX_LOG_FILE_MB"
    end

    test "all_errors tool output carries the skipped_files marker" do
      write_log("huge.log", String.duplicate("ERROR beyond the buffer\n", 200))

      {:ok, output} = Dispatcher.call("all_errors", %{}, @tmp_dir)

      assert output =~ "# omissions:"
      assert output =~ ~s("file":"huge.log")
      assert output =~ "File too large"
    end
  end

  describe "all_errors per-file cap" do
    test "sums omitted entries across files" do
      write_log("a.log", numbered_errors(8))
      write_log("b.log", numbered_errors(5))

      {:ok, %{results: results, omissions: omissions}} = UseCases.AllErrors.run(@tmp_dir, 3)

      assert Enum.all?(results, &(&1.error_count == 3))
      assert omissions == %{matches: %{omitted: 7, showing: "newest 3 per file"}}
    end

    test "no marker when every file fit" do
      write_log("a.log", numbered_errors(2))

      {:ok, %{omissions: omissions}} = UseCases.AllErrors.run(@tmp_dir, 20)
      assert omissions == %{}

      {:ok, output} = Dispatcher.call("all_errors", %{}, @tmp_dir)
      refute output =~ "omissions"
    end
  end
end
