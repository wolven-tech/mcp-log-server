defmodule McpLogServer.Domain.TraceIdsTest do
  use ExUnit.Case, async: false

  alias McpLogServer.Domain.Correlator
  alias McpLogServer.Tools.Dispatcher

  @tmp_dir System.tmp_dir!() |> Path.join("trace_ids_test")

  @gateway_log """
  {"severity":"INFO","message":"Request","timestamp":"2026-01-15T10:30:00Z","sessionId":"abc-123"}
  {"severity":"ERROR","message":"Failed","timestamp":"2026-01-15T10:30:01Z","sessionId":"abc-123"}
  {"severity":"INFO","message":"Request","timestamp":"2026-01-15T10:30:02Z","sessionId":"xyz-999"}
  {"severity":"INFO","message":"Request","timestamp":"2026-01-15T10:30:05Z","sessionId":"xyz-999"}
  """

  @api_log """
  2026-01-15 10:30:00 INFO Processing sessionId=abc-123 action=create
  2026-01-15 10:30:03 ERROR Timeout sessionId=def-456 action=update
  2026-01-15 10:30:04 WARN Slow sessionId=abc-123 duration=500ms
  """

  setup do
    File.mkdir_p!(@tmp_dir)
    File.write!(Path.join(@tmp_dir, "gateway.log"), @gateway_log)
    File.write!(Path.join(@tmp_dir, "api.log"), @api_log)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  describe "extract_trace_ids/3" do
    test "returns unique values with counts sorted by count desc" do
      {:ok, results} = Correlator.extract_trace_ids(@tmp_dir, "sessionId")

      values = Enum.map(results, & &1.value)
      assert "abc-123" in values
      assert "xyz-999" in values

      # abc-123 appears 4 times (2 JSON + 2 plain), xyz-999 appears 2 times (JSON)
      abc = Enum.find(results, &(&1.value == "abc-123"))
      assert abc.count == 4

      xyz = Enum.find(results, &(&1.value == "xyz-999"))
      assert xyz.count == 2

      # Should be sorted by count desc
      counts = Enum.map(results, & &1.count)
      assert counts == Enum.sort(counts, :desc)
    end

    test "includes first_seen and last_seen timestamps" do
      {:ok, results} = Correlator.extract_trace_ids(@tmp_dir, "sessionId")

      abc = Enum.find(results, &(&1.value == "abc-123"))
      assert abc.first_seen != nil
      assert abc.last_seen != nil
    end

    test "max_values caps results" do
      {:ok, results} = Correlator.extract_trace_ids(@tmp_dir, "sessionId", max_values: 1)
      assert length(results) == 1
    end

    test "file option scans only one file" do
      {:ok, results} = Correlator.extract_trace_ids(@tmp_dir, "sessionId", file: "gateway.log")

      values = Enum.map(results, & &1.value)
      assert "abc-123" in values
      assert "xyz-999" in values

      # Only JSON counts, not plain text
      abc = Enum.find(results, &(&1.value == "abc-123"))
      assert abc.count == 2
    end

    test "extracts from plain text key=value patterns" do
      {:ok, results} = Correlator.extract_trace_ids(@tmp_dir, "sessionId", file: "api.log")

      values = Enum.map(results, & &1.value)
      assert "abc-123" in values
      assert "def-456" in values
    end
  end

  describe "trace_ids tool via dispatcher" do
    test "returns TOON output with correct columns" do
      {:ok, output} = Dispatcher.call("trace_ids", %{"field" => "sessionId"}, @tmp_dir)

      assert String.contains?(output, "value")
      assert String.contains?(output, "count")
      assert String.contains?(output, "first_seen")
      assert String.contains?(output, "last_seen")
      assert String.contains?(output, "abc-123")
    end
  end
end
