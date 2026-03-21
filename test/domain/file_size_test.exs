defmodule McpLogServer.Domain.FileSizeTest do
  use ExUnit.Case, async: false

  alias McpLogServer.Domain.FileAccess
  alias McpLogServer.Domain.LogReader

  @tmp_dir System.tmp_dir!() |> Path.join("file_size_test")

  setup do
    File.mkdir_p!(@tmp_dir)
    # Set a very low limit for testing (1 KB)
    Application.put_env(:mcp_log_server, :max_log_file_mb, 0)
    on_exit(fn ->
      File.rm_rf!(@tmp_dir)
      Application.put_env(:mcp_log_server, :max_log_file_mb, 100)
    end)
    :ok
  end

  defp write_file(name, content) do
    path = Path.join(@tmp_dir, name)
    File.write!(path, content)
    path
  end

  describe "check_size/1" do
    test "returns error for file exceeding limit" do
      # With max_log_file_mb=0, any non-empty file exceeds
      path = write_file("big.log", String.duplicate("x", 2000))
      assert {:error, msg} = FileAccess.check_size(path)
      assert String.contains?(msg, "File too large")
      assert String.contains?(msg, "MAX_LOG_FILE_MB")
    end

    test "returns ok for file under limit" do
      Application.put_env(:mcp_log_server, :max_log_file_mb, 100)
      path = write_file("small.log", "just a line\n")
      assert {:ok, ^path} = FileAccess.check_size(path)
    end
  end

  describe "resolve_with_size_check/2" do
    test "rejects oversized files" do
      write_file("oversized.log", String.duplicate("ERROR big\n", 200))
      assert {:error, msg} = FileAccess.resolve_with_size_check(@tmp_dir, "oversized.log")
      assert String.contains?(msg, "File too large")
    end
  end

  describe "list_files/1 warning field" do
    test "includes warning for oversized files" do
      write_file("warn.log", String.duplicate("data\n", 500))
      {:ok, files} = FileAccess.list_files(@tmp_dir)
      file = Enum.find(files, &(&1.name == "warn.log"))
      assert file.warning != nil
      assert String.contains?(file.warning, "exceeds max size")
    end

    test "no warning for files under limit" do
      Application.put_env(:mcp_log_server, :max_log_file_mb, 100)
      write_file("ok.log", "small\n")
      {:ok, files} = FileAccess.list_files(@tmp_dir)
      file = Enum.find(files, &(&1.name == "ok.log"))
      refute Map.has_key?(file, :warning)
    end
  end

  describe "tools respect size limit" do
    test "get_errors returns error for oversized file" do
      write_file("huge.log", String.duplicate("ERROR problem\n", 200))
      assert {:error, msg} = LogReader.get_errors(@tmp_dir, "huge.log", 100)
      assert String.contains?(msg, "File too large")
    end

    test "search returns error for oversized file" do
      write_file("huge.log", String.duplicate("ERROR problem\n", 200))
      assert {:error, msg} = LogReader.search(@tmp_dir, "huge.log", "problem")
      assert String.contains?(msg, "File too large")
    end

    test "log_stats still works on oversized file (exempt)" do
      write_file("huge.log", String.duplicate("ERROR problem\n", 200))
      assert {:ok, stats} = LogReader.get_stats(@tmp_dir, "huge.log")
      assert stats.line_count == 200
    end
  end
end
