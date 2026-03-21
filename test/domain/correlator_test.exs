defmodule McpLogServer.Domain.CorrelatorTest do
  use ExUnit.Case, async: false

  alias McpLogServer.Domain.Correlator

  @tmp_dir System.tmp_dir!() |> Path.join("correlator_test")

  # JSON log file simulating a gateway service
  @gateway_log """
  {"severity":"INFO","message":"Incoming request","timestamp":"2026-01-15T10:30:00Z","sessionId":"abc-123","traceId":"t-001"}
  {"severity":"INFO","message":"Auth check","timestamp":"2026-01-15T10:30:01Z","sessionId":"xyz-999","traceId":"t-002"}
  {"severity":"ERROR","message":"Rate limited","timestamp":"2026-01-15T10:30:02Z","sessionId":"abc-123","traceId":"t-003"}
  {"severity":"INFO","message":"Response sent","timestamp":"2026-01-15T10:30:05Z","sessionId":"abc-123","traceId":"t-001","nested":{"requestId":"abc-123"}}
  """

  # Plain text log file simulating an API service
  @api_log """
  2026-01-15 10:30:00 INFO Processing request sessionId=abc-123 action=create
  2026-01-15 10:30:03 ERROR Failed validation sessionId=xyz-999 action=update
  2026-01-15 10:30:04 WARN Slow query sessionId=abc-123 duration=500ms
  2026-01-15 10:30:06 INFO Completed sessionId=abc-123 status=200
  2026-01-15 10:30:07 DEBUG No session info here
  """

  setup do
    File.mkdir_p!(@tmp_dir)
    File.write!(Path.join(@tmp_dir, "gateway.log"), @gateway_log)
    File.write!(Path.join(@tmp_dir, "api.log"), @api_log)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  describe "correlate/3 across multiple files" do
    test "finds matches in both JSON and plain text files" do
      {:ok, result} = Correlator.correlate(@tmp_dir, "abc-123")

      assert result.value == "abc-123"
      assert result.field == nil
      assert result.total_matches > 0

      files = result.files_matched
      assert "gateway.log" in files
      assert "api.log" in files
    end

    test "returns correct total_matches count" do
      {:ok, result} = Correlator.correlate(@tmp_dir, "abc-123")

      # gateway.log: 3 entries with abc-123 (lines 1, 3, 4 — line 4 also has it in nested)
      # api.log: 3 entries with abc-123 (lines 1, 3, 4)
      assert result.total_matches == 6
    end
  end

  describe "correlate/3 with field parameter" do
    test "searches specific JSON field with exact match" do
      {:ok, result} = Correlator.correlate(@tmp_dir, "abc-123", field: "sessionId")

      json_matches = Enum.filter(result.timeline, &(&1.file == "gateway.log"))
      # Should match entries with sessionId == "abc-123" (lines 1, 3, 4)
      assert length(json_matches) == 3
    end

    test "field search in plain text matches field=value pattern" do
      {:ok, result} = Correlator.correlate(@tmp_dir, "abc-123", field: "sessionId")

      plain_matches = Enum.filter(result.timeline, &(&1.file == "api.log"))
      # Lines with sessionId=abc-123: lines 1, 3, 4
      assert length(plain_matches) == 3
    end

    test "field search does not match entries with different field value" do
      {:ok, result} = Correlator.correlate(@tmp_dir, "abc-123", field: "traceId")

      # traceId is never "abc-123" in gateway.log (they are t-001, t-003, t-001)
      json_matches = Enum.filter(result.timeline, &(&1.file == "gateway.log"))
      assert length(json_matches) == 0
    end
  end

  describe "correlate/3 deep search (no field)" do
    test "finds value in nested JSON objects" do
      {:ok, result} = Correlator.correlate(@tmp_dir, "abc-123")

      # The 4th gateway entry has nested.requestId = "abc-123"
      # It should be found by deep search
      json_matches = Enum.filter(result.timeline, &(&1.file == "gateway.log"))
      assert length(json_matches) == 3
    end

    test "finds value as substring in plain text" do
      {:ok, result} = Correlator.correlate(@tmp_dir, "abc-123")

      plain_matches = Enum.filter(result.timeline, &(&1.file == "api.log"))
      assert length(plain_matches) == 3
    end
  end

  describe "timestamp sorting" do
    test "results are sorted by timestamp ascending" do
      {:ok, result} = Correlator.correlate(@tmp_dir, "abc-123")

      timestamps =
        result.timeline
        |> Enum.map(& &1.timestamp)
        |> Enum.reject(&is_nil/1)

      assert timestamps == Enum.sort(timestamps)
    end

    test "entries with nil timestamps are sorted last" do
      # Create a file with no timestamps
      File.write!(Path.join(@tmp_dir, "nots.log"), "abc-123 no timestamp here\n")

      {:ok, result} = Correlator.correlate(@tmp_dir, "abc-123")

      last_entry = List.last(result.timeline)
      assert last_entry.timestamp == nil
      assert last_entry.file == "nots.log"
    end
  end

  describe "max_results option" do
    test "caps total results across all files" do
      {:ok, result} = Correlator.correlate(@tmp_dir, "abc-123", max_results: 2)

      assert result.total_matches == 2
      assert length(result.timeline) == 2
    end

    test "defaults to 200 max results" do
      # With only 6 matches total, all should be returned
      {:ok, result} = Correlator.correlate(@tmp_dir, "abc-123")

      assert result.total_matches == 6
    end
  end

  describe "timeline_entry structure" do
    test "JSON entries have correct fields" do
      {:ok, result} = Correlator.correlate(@tmp_dir, "abc-123", field: "sessionId")

      json_entry =
        result.timeline
        |> Enum.find(&(&1.file == "gateway.log"))

      assert is_binary(json_entry.file)
      assert is_integer(json_entry.line_number)
      assert is_binary(json_entry.timestamp)
      assert is_binary(json_entry.severity)
      assert is_binary(json_entry.content)
    end

    test "plain text entries have correct fields" do
      {:ok, result} = Correlator.correlate(@tmp_dir, "abc-123", field: "sessionId")

      plain_entry =
        result.timeline
        |> Enum.find(&(&1.file == "api.log"))

      assert is_binary(plain_entry.file)
      assert is_integer(plain_entry.line_number)
      assert is_binary(plain_entry.timestamp)
      assert plain_entry.severity in ["info", "error", "warn"]
      assert is_binary(plain_entry.content)
    end

    test "JSON entry content is the message" do
      {:ok, result} = Correlator.correlate(@tmp_dir, "abc-123", field: "sessionId")

      first_json =
        result.timeline
        |> Enum.filter(&(&1.file == "gateway.log"))
        |> Enum.sort_by(& &1.line_number)
        |> List.first()

      assert first_json.content == "Incoming request"
    end
  end

  describe "edge cases" do
    test "returns empty result when no matches found" do
      {:ok, result} = Correlator.correlate(@tmp_dir, "nonexistent-id-999")

      assert result.total_matches == 0
      assert result.files_matched == []
      assert result.timeline == []
    end

    test "handles empty log directory" do
      empty_dir = Path.join(System.tmp_dir!(), "correlator_empty_test")
      File.mkdir_p!(empty_dir)
      on_exit(fn -> File.rm_rf!(empty_dir) end)

      {:ok, result} = Correlator.correlate(empty_dir, "abc-123")

      assert result.total_matches == 0
      assert result.timeline == []
    end

    test "escapes regex special characters in value" do
      # Write a file with regex special chars
      File.write!(
        Path.join(@tmp_dir, "special.log"),
        "2026-01-15 10:30:00 INFO value is foo.bar+baz(1)\n"
      )

      {:ok, result} = Correlator.correlate(@tmp_dir, "foo.bar+baz(1)")

      special_matches = Enum.filter(result.timeline, &(&1.file == "special.log"))
      assert length(special_matches) == 1
    end
  end
end
