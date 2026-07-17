defmodule McpLogServer.Infrastructure.FileLogSourceTest do
  use ExUnit.Case, async: false

  alias McpLogServer.Infrastructure.FileLogSource

  @tmp_dir System.tmp_dir!() |> Path.join("file_log_source_test")

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

  describe "list/1" do
    test "lists .log files sorted by name with full descriptors" do
      write_file("b.log", "two\n")
      write_file("a.log", "one\n")
      write_file("ignored.txt", "not a log\n")

      {:ok, files} = FileLogSource.list(@tmp_dir)

      assert Enum.map(files, & &1.name) == ["a.log", "b.log"]

      [a | _] = files
      assert a.path == Path.join(@tmp_dir, "a.log")
      assert a.size_bytes == 4
      assert is_binary(a.modified)
      assert a.live? == false
    end

    test "returns empty list for empty directory" do
      assert {:ok, []} = FileLogSource.list(@tmp_dir)
    end
  end

  describe "resolve/2" do
    test "resolves an existing basename" do
      path = write_file("app.log", "line\n")
      assert {:ok, ^path} = FileLogSource.resolve(@tmp_dir, "app.log")
    end

    test "rejects path separators" do
      assert {:error, msg} = FileLogSource.resolve(@tmp_dir, "../etc/passwd")
      assert msg =~ "path separators not allowed"
    end

    test "rejects unknown files" do
      assert {:error, msg} = FileLogSource.resolve(@tmp_dir, "nope.log")
      assert msg =~ "File not found"
    end
  end

  describe "resolve_readable/2" do
    test "rejects files over the size limit" do
      Application.put_env(:mcp_log_server, :max_log_file_mb, 0)
      on_exit(fn -> Application.put_env(:mcp_log_server, :max_log_file_mb, 100) end)

      write_file("big.log", String.duplicate("x", 2048))
      assert {:error, msg} = FileLogSource.resolve_readable(@tmp_dir, "big.log")
      assert msg =~ "File too large"
    end

    test "accepts files under the limit" do
      path = write_file("small.log", "ok\n")
      assert {:ok, ^path} = FileLogSource.resolve_readable(@tmp_dir, "small.log")
    end
  end

  describe "stream_lines/1" do
    test "streams lines with trailing whitespace trimmed" do
      path = write_file("app.log", "first  \nsecond\nthird\n")
      assert FileLogSource.stream_lines(path) |> Enum.to_list() == ["first", "second", "third"]
    end
  end

  describe "read/1" do
    test "reads entire content" do
      path = write_file("app.log", "raw content")
      assert {:ok, "raw content"} = FileLogSource.read(path)
    end

    test "returns error for missing file" do
      assert {:error, msg} = FileLogSource.read(Path.join(@tmp_dir, "nope.log"))
      assert msg =~ "Failed to read file"
    end
  end

  describe "stat/1" do
    test "returns size and modified" do
      path = write_file("app.log", "12345")
      assert {:ok, %{size_bytes: 5, modified: modified}} = FileLogSource.stat(path)
      assert is_binary(modified)
    end

    test "returns error for missing file" do
      assert {:error, msg} = FileLogSource.stat(Path.join(@tmp_dir, "nope.log"))
      assert msg =~ "Cannot stat file"
    end
  end

  describe "format/1" do
    test "detects NDJSON" do
      path = write_file("json.log", ~s|{"level":"info","message":"hi"}\n|)
      assert FileLogSource.format(path) == :json_lines
    end

    test "detects plain text" do
      path = write_file("plain.log", "2026-01-01 00:00:00 INFO hi\n")
      assert FileLogSource.format(path) == :plain
    end
  end

  describe "parse_entries/2" do
    test "parses NDJSON into enriched entries" do
      path = write_file("json.log", ~s|{"level":"error","message":"boom"}\n|)
      {:ok, [entry]} = FileLogSource.parse_entries(path, :json_lines)
      assert entry["_severity"] == "error"
      assert entry["_message"] == "boom"
    end

    test "propagates read errors" do
      assert {:error, _} = FileLogSource.parse_entries(Path.join(@tmp_dir, "nope.log"), :json_lines)
    end
  end
end
