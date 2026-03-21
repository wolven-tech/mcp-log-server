defmodule McpLogServer.Tools.AllErrorsTest do
  use ExUnit.Case, async: false

  alias McpLogServer.Tools.Dispatcher

  @tmp_dir System.tmp_dir!() |> Path.join("all_errors_test")

  @log1 """
  2026-01-15 10:30:00 INFO Request handled
  2026-01-15 10:30:01 WARN Slow query detected
  2026-01-15 10:30:02 ERROR Connection failed
  2026-01-15 10:30:03 FATAL Out of memory
  2026-01-15 10:30:04 INFO Health check OK
  """

  @log2 """
  2026-01-15 10:30:00 INFO Service started
  2026-01-15 10:30:01 ERROR Timeout on upstream
  2026-01-15 10:30:02 WARN deprecated API call
  """

  setup do
    File.mkdir_p!(@tmp_dir)
    File.write!(Path.join(@tmp_dir, "app.log"), @log1)
    File.write!(Path.join(@tmp_dir, "svc.log"), @log2)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  describe "all_errors with level param" do
    test "level: error returns only ERROR and FATAL lines" do
      {:ok, output} = Dispatcher.call("all_errors", %{"level" => "error"}, @tmp_dir)

      assert String.contains?(output, "ERROR")
      assert String.contains?(output, "FATAL")
      refute String.contains?(output, "WARN")
      refute String.contains?(output, "INFO")
    end

    test "level: fatal returns only FATAL lines" do
      {:ok, output} = Dispatcher.call("all_errors", %{"level" => "fatal"}, @tmp_dir)

      assert String.contains?(output, "FATAL")
      refute String.contains?(output, "ERROR")
      refute String.contains?(output, "WARN")
    end

    test "default level returns WARN, ERROR, and FATAL" do
      {:ok, output} = Dispatcher.call("all_errors", %{}, @tmp_dir)

      assert String.contains?(output, "WARN")
      assert String.contains?(output, "ERROR")
      assert String.contains?(output, "FATAL")
      refute String.contains?(output, "INFO")
    end
  end

  describe "all_errors with exclude param" do
    test "exclude removes matching lines" do
      {:ok, output} = Dispatcher.call("all_errors", %{"exclude" => "Timeout"}, @tmp_dir)

      refute String.contains?(output, "Timeout")
      assert String.contains?(output, "Connection failed")
    end

    test "exclude combined with level" do
      {:ok, output} =
        Dispatcher.call("all_errors", %{"level" => "error", "exclude" => "Connection"}, @tmp_dir)

      refute String.contains?(output, "Connection")
      refute String.contains?(output, "WARN")
      assert String.contains?(output, "FATAL")
      assert String.contains?(output, "Timeout")
    end
  end
end
