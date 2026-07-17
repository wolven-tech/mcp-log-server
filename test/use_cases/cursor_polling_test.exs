defmodule McpLogServer.UseCases.CursorPollingTest do
  use ExUnit.Case, async: false

  alias McpLogServer.UseCases.SearchLogs
  alias McpLogServer.UseCases.TailLog

  @tmp_dir System.tmp_dir!() |> Path.join("cursor_polling_test")

  setup do
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  defp path(name), do: Path.join(@tmp_dir, name)

  describe "tail_log polling" do
    test "first call returns a cursor; passing it back yields only new lines" do
      File.write!(path("deploy.log"), "line 1\nline 2\nline 3\n")

      {:ok, first} = TailLog.run(@tmp_dir, "deploy.log", 50)
      assert first.content == "line 1\nline 2\nline 3"
      assert is_binary(first.cursor)
      refute first.cursor_reset

      File.write!(path("deploy.log"), "line 4\nline 5\n", [:append])

      {:ok, second} = TailLog.run(@tmp_dir, "deploy.log", 50, cursor: first.cursor)
      assert second.content == "line 4\nline 5"
      refute second.cursor_reset
    end

    test "no new lines yields empty content and a stable position" do
      File.write!(path("deploy.log"), "line 1\n")

      {:ok, first} = TailLog.run(@tmp_dir, "deploy.log", 50)
      {:ok, second} = TailLog.run(@tmp_dir, "deploy.log", 50, cursor: first.cursor)

      assert second.content == ""
      refute second.cursor_reset

      # and the position is still valid for the poll after that
      File.write!(path("deploy.log"), "line 2\n", [:append])
      {:ok, third} = TailLog.run(@tmp_dir, "deploy.log", 50, cursor: second.cursor)
      assert third.content == "line 2"
    end

    test "monotonic no-overlap-no-gap across successive polls of a growing file" do
      File.write!(path("deploy.log"), "")

      {seen, _cursor} =
        Enum.reduce(1..15, {[], nil}, fn i, {seen, cursor} ->
          File.write!(path("deploy.log"), "event #{i}\n", [:append])

          opts = if cursor, do: [cursor: cursor], else: []
          {:ok, result} = TailLog.run(@tmp_dir, "deploy.log", 50, opts)
          refute result.cursor_reset

          lines = if result.content == "", do: [], else: String.split(result.content, "\n")
          {seen ++ lines, result.cursor}
        end)

      assert seen == for(i <- 1..15, do: "event #{i}")
    end

    test "rotation invalidates the cursor: flagged full window, never wrong increments" do
      File.write!(path("deploy.log"), "old build line 1\nold build line 2\n")
      {:ok, first} = TailLog.run(@tmp_dir, "deploy.log", 50)

      # rotation: file replaced with entirely new content
      File.write!(path("deploy.log"), "new build line A\nnew build line B\nnew build line C\n")

      {:ok, second} = TailLog.run(@tmp_dir, "deploy.log", 50, cursor: first.cursor)

      assert second.cursor_reset == true
      assert second.content == "new build line A\nnew build line B\nnew build line C"
    end

    test "truncation invalidates the cursor" do
      File.write!(path("deploy.log"), "aaa\nbbb\nccc\n")
      {:ok, first} = TailLog.run(@tmp_dir, "deploy.log", 50)

      File.write!(path("deploy.log"), "aaa\n")

      {:ok, second} = TailLog.run(@tmp_dir, "deploy.log", 50, cursor: first.cursor)
      assert second.cursor_reset == true
      assert second.content == "aaa"
    end

    test "garbage cursor resets instead of erroring" do
      File.write!(path("deploy.log"), "line 1\n")

      {:ok, result} = TailLog.run(@tmp_dir, "deploy.log", 50, cursor: "not-a-cursor")
      assert result.cursor_reset == true
      assert result.content == "line 1"
    end

    test "cursor mode still honors the line cap with omissions" do
      File.write!(path("deploy.log"), "seed\n")
      {:ok, first} = TailLog.run(@tmp_dir, "deploy.log", 50)

      for i <- 1..10, do: File.write!(path("deploy.log"), "burst #{i}\n", [:append])

      {:ok, second} = TailLog.run(@tmp_dir, "deploy.log", 3, cursor: first.cursor)
      assert second.content == "burst 8\nburst 9\nburst 10"
      assert second.omissions.lines == %{omitted: 7, showing: "newest 3"}
    end
  end

  describe "search_logs polling" do
    test "search with cursor scans only appended lines, with absolute line numbers" do
      File.write!(path("app.log"), "ERROR one\nINFO ok\n")

      {:ok, first} = SearchLogs.run(@tmp_dir, "app.log", "ERROR")
      assert first.returned_matches == 1
      assert is_binary(first.cursor)
      refute Map.has_key?(first, :cursor_reset)

      File.write!(path("app.log"), "INFO more\nERROR two\n", [:append])

      {:ok, second} = SearchLogs.run(@tmp_dir, "app.log", "ERROR", cursor: first.cursor)
      assert second.returned_matches == 1
      assert [%{line_number: 4, content: "ERROR two"}] = second.matches
    end

    test "rotated file flags cursor_reset and searches the full window" do
      File.write!(path("app.log"), "ERROR old\nfiller line\n")
      {:ok, first} = SearchLogs.run(@tmp_dir, "app.log", "ERROR")

      File.write!(path("app.log"), "ERROR new only\nsomething else entirely\n")

      {:ok, second} = SearchLogs.run(@tmp_dir, "app.log", "ERROR", cursor: first.cursor)
      assert second.cursor_reset == true
      assert [%{line_number: 1, content: "ERROR new only"}] = second.matches
    end

    test "cursor is rejected with field and rollup" do
      File.write!(path("app.log"), ~s({"message":"hi"}\n))

      assert {:error, msg} = SearchLogs.run(@tmp_dir, "app.log", "hi", cursor: "x", field: "message")
      assert msg =~ "cursor cannot be combined with field"

      assert {:error, msg} = SearchLogs.run(@tmp_dir, nil, "hi", cursor: "x", rollup: true)
      assert msg =~ "cursor cannot be combined with rollup"
    end

    test "tail and search cursors are interchangeable on the same file" do
      File.write!(path("app.log"), "seed line\n")
      {:ok, tailed} = TailLog.run(@tmp_dir, "app.log", 50)

      File.write!(path("app.log"), "ERROR after tail\n", [:append])

      {:ok, searched} = SearchLogs.run(@tmp_dir, "app.log", "ERROR", cursor: tailed.cursor)
      assert [%{line_number: 2, content: "ERROR after tail"}] = searched.matches
    end
  end
end
