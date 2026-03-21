defmodule McpLogServer.Domain.LogReaderJsonTest do
  use ExUnit.Case, async: false

  alias McpLogServer.Domain.LogReader

  @tmp_dir System.tmp_dir!() |> Path.join("log_reader_json_test")

  @json_log """
  {"severity":"INFO","message":"Request handled","timestamp":"2026-01-15T10:30:00Z"}
  {"severity":"ERROR","message":"Connection failed","timestamp":"2026-01-15T10:30:01Z"}
  {"severity":"INFO","message":"The upload failed to validate","timestamp":"2026-01-15T10:30:02Z"}
  {"severity":"FATAL","message":"Out of memory","timestamp":"2026-01-15T10:30:03Z"}
  {"severity":"WARNING","message":"Slow query","timestamp":"2026-01-15T10:30:04Z"}
  {"severity":"DEBUG","message":"Cache hit","timestamp":"2026-01-15T10:30:05Z"}
  """

  @plain_log """
  2026-01-15 10:30:00 INFO Request handled
  2026-01-15 10:30:01 ERROR Connection failed
  2026-01-15 10:30:02 INFO The upload failed to validate
  2026-01-15 10:30:03 FATAL Out of memory
  2026-01-15 10:30:04 WARN Slow query
  """

  setup do
    File.mkdir_p!(@tmp_dir)
    File.write!(Path.join(@tmp_dir, "json.log"), @json_log)
    File.write!(Path.join(@tmp_dir, "plain.log"), @plain_log)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  describe "get_errors/3 with JSON logs" do
    test "default level (:warn) returns WARN, ERROR, and FATAL entries" do
      {:ok, errors} = LogReader.get_errors(@tmp_dir, "json.log", 100)

      messages = Enum.map(errors, & &1.message)
      severities = Enum.map(errors, & &1.severity)

      # Should include ERROR, FATAL, and WARNING
      assert "Connection failed" in messages
      assert "Out of memory" in messages
      assert "Slow query" in messages

      # Should NOT include INFO entry that contains "failed" (zero false positives)
      refute "The upload failed to validate" in messages

      # Should NOT include DEBUG
      refute "Cache hit" in messages

      assert length(errors) == 3
      assert Enum.all?(severities, &(&1 in ["error", "fatal", "warning"]))
    end

    test "level: :error returns only ERROR/FATAL entries" do
      {:ok, errors} = LogReader.get_errors(@tmp_dir, "json.log", 100, level: :error)

      messages = Enum.map(errors, & &1.message)
      assert length(errors) == 2
      assert "Connection failed" in messages
      assert "Out of memory" in messages
      refute "Slow query" in messages
    end
  end

  describe "get_errors/3 with plain text logs (regression)" do
    test "still uses regex matching for plain text logs" do
      {:ok, errors} = LogReader.get_errors(@tmp_dir, "plain.log", 100)

      # Plain text should use regex, so "failed" matches too
      contents = Enum.map(errors, & &1.content)
      assert Enum.any?(contents, &String.contains?(&1, "ERROR"))
      assert Enum.any?(contents, &String.contains?(&1, "FATAL"))
      assert Enum.any?(contents, &String.contains?(&1, "failed"))
      assert Enum.any?(contents, &String.contains?(&1, "WARN"))
    end
  end

  describe "search/4 with field option on JSON logs" do
    test "searches specific JSON field" do
      {:ok, result} = LogReader.search(@tmp_dir, "json.log", "Connection", field: "message")

      assert result.returned_matches == 1
      [match] = result.matches
      assert match.message == "Connection failed"
    end

    test "field option is ignored for plain text logs" do
      {:ok, result} = LogReader.search(@tmp_dir, "plain.log", "ERROR", field: "message")

      # Should still work with regex on full line
      assert result.returned_matches >= 1
    end
  end

  describe "get_stats/2 with JSON logs" do
    test "counts errors/warns using severity field" do
      {:ok, stats} = LogReader.get_stats(@tmp_dir, "json.log")

      assert stats.line_count == 6
      # ERROR only (not counting FATAL or INFO with "failed")
      assert stats.error_count == 1
      # FATAL = 1
      assert stats.fatal_count == 1
      # WARNING = 1
      assert stats.warn_count == 1
    end
  end

  describe "TOON output for JSON logs" do
    test "get_errors produces severity|timestamp|message columns in TOON" do
      alias McpLogServer.Protocol.ToonEncoder

      {:ok, errors} = LogReader.get_errors(@tmp_dir, "json.log", 100)
      toon = ToonEncoder.format_response(%{file: "json.log", error_count: length(errors), matches: errors})

      # Should have structured columns, not just content
      assert String.contains?(toon, "severity")
      assert String.contains?(toon, "timestamp")
      assert String.contains?(toon, "message")
      assert String.contains?(toon, "line_number")
    end

    test "search with field parameter produces structured TOON output" do
      alias McpLogServer.Protocol.ToonEncoder

      {:ok, result} = LogReader.search(@tmp_dir, "json.log", "Connection", field: "message")
      toon = ToonEncoder.format_response(result)

      assert String.contains?(toon, "severity")
      assert String.contains?(toon, "Connection failed")
    end
  end

  describe "get_stats/2 with plain text logs (regression)" do
    test "still uses regex for plain text" do
      {:ok, stats} = LogReader.get_stats(@tmp_dir, "plain.log")

      assert stats.line_count == 5
      # ERROR only via regex (FATAL counted separately)
      assert stats.error_count == 1
      # FATAL via regex
      assert stats.fatal_count == 1
      # WARN via regex
      assert stats.warn_count == 1
    end
  end
end
