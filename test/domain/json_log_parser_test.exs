defmodule McpLogServer.Domain.JsonLogParserTest do
  use ExUnit.Case, async: true

  alias McpLogServer.Domain.JsonLogParser

  @tmp_dir System.tmp_dir!() |> Path.join("json_log_parser_test")

  setup do
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  defp write_file(name, content) do
    path = Path.join(@tmp_dir, name)
    File.write!(path, content)
    path
  end

  # -- GCP Cloud Logging sample --

  @gcp_sample """
  {"severity":"ERROR","message":"Connection refused","timestamp":"2026-01-15T10:30:00.123Z","httpRequest":{"method":"GET"}}
  {"severity":"INFO","message":"Request handled","timestamp":"2026-01-15T10:30:01.456Z","httpRequest":{"method":"POST"}}
  {"severity":"WARNING","message":"Slow query detected","timestamp":"2026-01-15T10:30:02.789Z"}
  """

  # -- Pino sample --

  @pino_sample """
  {"level":30,"time":1705312200000,"msg":"Server started","pid":1234}
  {"level":50,"time":1705312201000,"msg":"Database error","pid":1234}
  {"level":10,"time":1705312202000,"msg":"Trace detail","pid":1234}
  """

  describe "parse_entries/2 with json_lines" do
    test "parses GCP Cloud Logging entries" do
      path = write_file("gcp.log", @gcp_sample)
      {:ok, entries} = JsonLogParser.parse_entries(path, :json_lines)

      assert length(entries) == 3

      [error, info, warning] = entries
      assert error["_severity"] == "error"
      assert error["_message"] == "Connection refused"
      assert error["_timestamp"] == "2026-01-15T10:30:00.123Z"

      assert info["_severity"] == "info"
      assert info["_message"] == "Request handled"

      assert warning["_severity"] == "warning"
      assert warning["_message"] == "Slow query detected"
    end

    test "parses Pino entries with numeric levels and epoch timestamps" do
      path = write_file("pino.log", @pino_sample)
      {:ok, entries} = JsonLogParser.parse_entries(path, :json_lines)

      assert length(entries) == 3

      [info, error, trace] = entries
      assert info["_severity"] == "info"
      assert info["_message"] == "Server started"
      assert info["_timestamp"] == "2024-01-15T09:50:00.000Z"

      assert error["_severity"] == "error"
      assert error["_message"] == "Database error"

      assert trace["_severity"] == "trace"
    end
  end

  describe "parse_entries/2 with json_array" do
    test "parses JSON array format" do
      content = ~s|[{"level":"info","message":"hello"},{"level":"warn","message":"watch out"}]|
      path = write_file("array.log", content)

      {:ok, entries} = JsonLogParser.parse_entries(path, :json_array)

      assert length(entries) == 2
      assert hd(entries)["_severity"] == "info"
      assert hd(entries)["_message"] == "hello"
    end

    test "returns error for invalid JSON array" do
      path = write_file("bad.log", "not json")
      assert {:error, _} = JsonLogParser.parse_entries(path, :json_array)
    end
  end

  describe "extract_severity/1" do
    test "checks fields in priority order" do
      assert JsonLogParser.extract_severity(%{"severity" => "ERROR", "level" => "info"}) == "error"
    end

    test "handles nested log.level" do
      assert JsonLogParser.extract_severity(%{"log" => %{"level" => "DEBUG"}}) == "debug"
    end

    test "maps Pino numeric levels" do
      assert JsonLogParser.extract_severity(%{"level" => 10}) == "trace"
      assert JsonLogParser.extract_severity(%{"level" => 20}) == "debug"
      assert JsonLogParser.extract_severity(%{"level" => 30}) == "info"
      assert JsonLogParser.extract_severity(%{"level" => 40}) == "warn"
      assert JsonLogParser.extract_severity(%{"level" => 50}) == "error"
      assert JsonLogParser.extract_severity(%{"level" => 60}) == "fatal"
    end

    test "returns unknown for unmapped numeric level" do
      assert JsonLogParser.extract_severity(%{"level" => 99}) == "unknown"
    end

    test "returns nil when no severity field present" do
      assert JsonLogParser.extract_severity(%{"foo" => "bar"}) == nil
    end

    test "handles levelname field" do
      assert JsonLogParser.extract_severity(%{"levelname" => "CRITICAL"}) == "critical"
    end

    test "handles loglevel field" do
      assert JsonLogParser.extract_severity(%{"loglevel" => "Info"}) == "info"
    end
  end

  describe "extract_message/1" do
    test "checks fields in priority order" do
      assert JsonLogParser.extract_message(%{"message" => "first", "msg" => "second"}) == "first"
    end

    test "falls back to msg" do
      assert JsonLogParser.extract_message(%{"msg" => "pino message"}) == "pino message"
    end

    test "falls back to textPayload" do
      assert JsonLogParser.extract_message(%{"textPayload" => "gcp text"}) == "gcp text"
    end

    test "falls back to @message" do
      assert JsonLogParser.extract_message(%{"@message" => "logstash msg"}) == "logstash msg"
    end

    test "returns nil when no message field present" do
      assert JsonLogParser.extract_message(%{"data" => "value"}) == nil
    end
  end

  describe "extract_timestamp/1" do
    test "returns ISO string timestamp as-is" do
      assert JsonLogParser.extract_timestamp(%{"timestamp" => "2026-01-01T00:00:00Z"}) ==
               "2026-01-01T00:00:00Z"
    end

    test "converts Pino epoch ms to ISO 8601" do
      result = JsonLogParser.extract_timestamp(%{"time" => 1705312200000})
      assert result == "2024-01-15T09:50:00.000Z"
    end

    test "checks fields in priority order" do
      map = %{"timestamp" => "first", "time" => "second"}
      assert JsonLogParser.extract_timestamp(map) == "first"
    end

    test "handles @timestamp (ELK)" do
      assert JsonLogParser.extract_timestamp(%{"@timestamp" => "2026-01-01T00:00:00Z"}) ==
               "2026-01-01T00:00:00Z"
    end

    test "handles receiveTimestamp (GCP)" do
      assert JsonLogParser.extract_timestamp(%{"receiveTimestamp" => "2026-01-01T00:00:00Z"}) ==
               "2026-01-01T00:00:00Z"
    end

    test "returns nil when no timestamp field present" do
      assert JsonLogParser.extract_timestamp(%{"foo" => "bar"}) == nil
    end
  end

  describe "parse_entries/2 edge cases" do
    test "returns error for non-existent file" do
      assert {:error, _} = JsonLogParser.parse_entries("/nonexistent/path.log", :json_lines)
    end

    test "skips non-JSON lines in json_lines mode" do
      content = """
      {"level":"info","message":"good"}
      not json
      {"level":"warn","message":"also good"}
      """

      path = write_file("mixed.log", content)
      {:ok, entries} = JsonLogParser.parse_entries(path, :json_lines)
      assert length(entries) == 2
    end

    test "preserves original fields alongside extracted ones" do
      path = write_file("fields.log", ~s|{"level":"info","message":"hi","custom":"data"}|)
      {:ok, [entry]} = JsonLogParser.parse_entries(path, :json_lines)
      assert entry["custom"] == "data"
      assert entry["_severity"] == "info"
    end
  end
end
