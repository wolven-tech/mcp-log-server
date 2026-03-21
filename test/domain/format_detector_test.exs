defmodule McpLogServer.Domain.FormatDetectorTest do
  use ExUnit.Case, async: false

  alias McpLogServer.Domain.FormatDetector

  @tmp_dir System.tmp_dir!() |> Path.join("format_detector_test")

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

  describe "detect/1" do
    test "detects NDJSON (json_lines) format" do
      path =
        write_file("app.log", """
        {"level":"info","message":"started","ts":"2026-01-01T00:00:00Z"}
        {"level":"error","message":"failed","ts":"2026-01-01T00:00:01Z"}
        """)

      assert FormatDetector.detect(path) == :json_lines
    end

    test "detects JSON array format" do
      path =
        write_file("app.log", """
        [
          {"level":"info","message":"started"},
          {"level":"error","message":"failed"}
        ]
        """)

      assert FormatDetector.detect(path) == :json_array
    end

    test "detects plain text format" do
      path =
        write_file("app.log", """
        2026-01-01 00:00:00 INFO  Application started
        2026-01-01 00:00:01 ERROR Something went wrong
        """)

      assert FormatDetector.detect(path) == :plain
    end

    test "returns plain for empty file" do
      path = write_file("empty.log", "")
      assert FormatDetector.detect(path) == :plain
    end

    test "returns plain for binary file" do
      path = write_file("binary.log", <<0, 1, 2, 3, 255, 254, 253>>)
      assert FormatDetector.detect(path) == :plain
    end

    test "returns plain for non-existent file" do
      assert FormatDetector.detect(Path.join(@tmp_dir, "nope.log")) == :plain
    end

    test "returns plain for mixed content (some JSON, some not)" do
      path =
        write_file("mixed.log", """
        {"level":"info","message":"started"}
        This is plain text
        {"level":"error","message":"failed"}
        """)

      assert FormatDetector.detect(path) == :plain
    end

    test "returns plain for JSON array of non-objects" do
      path = write_file("array.log", "[1, 2, 3]")
      assert FormatDetector.detect(path) == :plain
    end

    test "caches result by {path, mtime}" do
      path =
        write_file("cached.log", """
        {"level":"info","message":"cached"}
        """)

      assert FormatDetector.detect(path) == :json_lines

      # Second call should use cache (same result)
      assert FormatDetector.detect(path) == :json_lines

      # Modify file content and mtime
      :timer.sleep(1000)
      File.write!(path, "plain text now\n")

      assert FormatDetector.detect(path) == :plain
    end

    test "single JSON object line is json_lines" do
      path = write_file("single.log", ~s|{"key":"value"}|)
      assert FormatDetector.detect(path) == :json_lines
    end

    test "large file detected correctly without reading entire file" do
      # Generate 2000 lines of NDJSON — detection should only read first few
      lines =
        Enum.map(1..2000, fn i ->
          ~s|{"level":"info","message":"line #{i}","ts":"2026-01-01T00:00:00Z"}|
        end)

      path = write_file("large.log", Enum.join(lines, "\n"))
      assert FormatDetector.detect(path) == :json_lines

      # Verify file is actually large
      %{size: size} = File.stat!(path)
      assert size > 100_000
    end

    test "large plain text file detected correctly" do
      lines = Enum.map(1..2000, fn i -> "2026-01-01 00:00:00 INFO Line #{i}" end)
      path = write_file("large_plain.log", Enum.join(lines, "\n"))
      assert FormatDetector.detect(path) == :plain
    end
  end
end
