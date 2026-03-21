defmodule McpLogServer.Tools.CorrelateToolTest do
  use ExUnit.Case, async: false

  alias McpLogServer.Tools.Dispatcher

  @tmp_dir System.tmp_dir!() |> Path.join("correlate_tool_test")

  @gateway_log """
  {"severity":"INFO","message":"Request in","timestamp":"2026-01-15T10:30:00Z","sessionId":"abc-123"}
  {"severity":"ERROR","message":"Auth failed","timestamp":"2026-01-15T10:30:01Z","sessionId":"abc-123"}
  {"severity":"INFO","message":"Other request","timestamp":"2026-01-15T10:30:02Z","sessionId":"xyz-999"}
  """

  @api_log """
  2026-01-15 10:30:00 INFO Processing sessionId=abc-123
  2026-01-15 10:30:03 ERROR Timeout sessionId=abc-123
  2026-01-15 10:30:04 INFO Done sessionId=xyz-999
  """

  @worker_log """
  {"severity":"INFO","message":"Job started","timestamp":"2026-01-15T10:30:01Z","requestId":"abc-123"}
  """

  setup do
    File.mkdir_p!(@tmp_dir)
    File.write!(Path.join(@tmp_dir, "gateway.log"), @gateway_log)
    File.write!(Path.join(@tmp_dir, "api.log"), @api_log)
    File.write!(Path.join(@tmp_dir, "worker.log"), @worker_log)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  describe "correlate tool (TOON format)" do
    test "returns unified timeline across 3 files" do
      {:ok, output} = Dispatcher.call("correlate", %{"value" => "abc-123"}, @tmp_dir)

      # Should have metadata line
      assert String.contains?(output, "abc-123")
      assert String.contains?(output, "total_matches")

      # Should have TOON columns
      assert String.contains?(output, "file")
      assert String.contains?(output, "severity")
      assert String.contains?(output, "timestamp")

      # Should include entries from all 3 files
      assert String.contains?(output, "gateway.log")
      assert String.contains?(output, "api.log")
      assert String.contains?(output, "worker.log")
    end
  end

  describe "correlate tool with field parameter" do
    test "restricts to field-specific matches" do
      {:ok, output} =
        Dispatcher.call("correlate", %{"value" => "abc-123", "field" => "sessionId"}, @tmp_dir)

      # Should match gateway.log (sessionId field) and api.log (sessionId=abc-123)
      assert String.contains?(output, "gateway.log")
      assert String.contains?(output, "api.log")

      # worker.log has requestId, not sessionId
      refute String.contains?(output, "worker.log")
    end
  end

  describe "correlate tool (JSON format)" do
    test "returns full result as JSON" do
      {:ok, output} =
        Dispatcher.call("correlate", %{"value" => "abc-123", "format" => "json"}, @tmp_dir)

      result = Jason.decode!(output)
      assert result["value"] == "abc-123"
      assert is_integer(result["total_matches"])
      assert is_list(result["files_matched"])
      assert is_list(result["timeline"])
    end
  end
end
