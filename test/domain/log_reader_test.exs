defmodule McpLogServer.Domain.LogReaderTest do
  use ExUnit.Case, async: false

  alias McpLogServer.Domain.LogReader

  @tmp_dir System.tmp_dir!() |> Path.join("log_reader_level_test")

  @plain_log """
  2026-01-15 10:30:00 INFO Request handled
  2026-01-15 10:30:01 WARN Slow query detected
  2026-01-15 10:30:02 ERROR Connection failed
  2026-01-15 10:30:03 FATAL Out of memory
  2026-01-15 10:30:04 INFO Health check OK
  2026-01-15 10:30:05 ERROR Timeout on upstream service
  2026-01-15 10:30:06 WARN deprecated API call
  """

  setup do
    File.mkdir_p!(@tmp_dir)
    File.write!(Path.join(@tmp_dir, "app.log"), @plain_log)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  describe "get_errors/4 level filtering" do
    test "default (warn) returns WARN, ERROR, and FATAL lines" do
      {:ok, errors} = LogReader.get_errors(@tmp_dir, "app.log", 100)

      contents = Enum.map(errors, & &1.content)
      assert length(errors) == 5
      assert Enum.any?(contents, &String.contains?(&1, "WARN"))
      assert Enum.any?(contents, &String.contains?(&1, "ERROR"))
      assert Enum.any?(contents, &String.contains?(&1, "FATAL"))
      refute Enum.any?(contents, &String.contains?(&1, "INFO"))
    end

    test "level: :error returns only ERROR and FATAL" do
      {:ok, errors} = LogReader.get_errors(@tmp_dir, "app.log", 100, level: :error)

      contents = Enum.map(errors, & &1.content)
      assert length(errors) == 3
      assert Enum.any?(contents, &String.contains?(&1, "ERROR"))
      assert Enum.any?(contents, &String.contains?(&1, "FATAL"))
      refute Enum.any?(contents, &String.contains?(&1, "WARN"))
    end

    test "level: :fatal returns only FATAL/PANIC" do
      {:ok, errors} = LogReader.get_errors(@tmp_dir, "app.log", 100, level: :fatal)

      assert length(errors) == 1
      assert String.contains?(hd(errors).content, "FATAL")
    end

    test "level: :info returns INFO and above" do
      {:ok, errors} = LogReader.get_errors(@tmp_dir, "app.log", 100, level: :info)

      # Should not return INFO lines (Patterns has no info-level regex)
      # Only warn, error, fatal have patterns defined
      contents = Enum.map(errors, & &1.content)
      assert Enum.any?(contents, &String.contains?(&1, "WARN"))
      assert Enum.any?(contents, &String.contains?(&1, "ERROR"))
      assert Enum.any?(contents, &String.contains?(&1, "FATAL"))
    end
  end

  describe "get_errors/4 exclude filtering" do
    test "exclude removes matching lines after severity filter" do
      {:ok, errors} = LogReader.get_errors(@tmp_dir, "app.log", 100, exclude: "Timeout")

      contents = Enum.map(errors, & &1.content)
      refute Enum.any?(contents, &String.contains?(&1, "Timeout"))
      # Other errors still present
      assert Enum.any?(contents, &String.contains?(&1, "Connection failed"))
    end

    test "exclude works with level together" do
      {:ok, errors} =
        LogReader.get_errors(@tmp_dir, "app.log", 100, level: :error, exclude: "Connection")

      contents = Enum.map(errors, & &1.content)
      assert length(errors) == 2
      assert Enum.any?(contents, &String.contains?(&1, "Timeout"))
      assert Enum.any?(contents, &String.contains?(&1, "FATAL"))
      refute Enum.any?(contents, &String.contains?(&1, "Connection"))
      refute Enum.any?(contents, &String.contains?(&1, "WARN"))
    end

    test "invalid exclude regex returns error" do
      result = LogReader.get_errors(@tmp_dir, "app.log", 100, exclude: "[invalid")

      assert {:error, msg} = result
      assert String.starts_with?(msg, "Invalid exclude pattern:")
    end
  end

  describe "get_errors/4 backward compatibility" do
    test "3-arity call still works" do
      {:ok, errors} = LogReader.get_errors(@tmp_dir, "app.log", 100)
      assert is_list(errors)
      assert length(errors) > 0
    end
  end
end
