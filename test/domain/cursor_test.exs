defmodule McpLogServer.Domain.CursorTest do
  use ExUnit.Case, async: true

  alias McpLogServer.Domain.Cursor

  describe "encode/decode round-trip" do
    test "round-trips a cursor state" do
      state = %{file: "api.log", offset: 1234, sig_len: 256, sig: 987_654}
      assert {:ok, decoded} = state |> Cursor.encode() |> Cursor.decode()
      assert decoded == state
    end

    test "rejects garbage, tampered, and non-string input" do
      assert Cursor.decode("not-base64!!") == :error
      assert Cursor.decode(Base.url_encode64("random bytes", padding: false)) == :error
      assert Cursor.decode(nil) == :error
      assert Cursor.decode(123) == :error
    end

    test "rejects an unknown version" do
      bogus =
        {99, "api.log", 0, 0, 0}
        |> :erlang.term_to_binary()
        |> Base.url_encode64(padding: false)

      assert Cursor.decode(bogus) == :error
    end
  end

  describe "state_for/2 and complete_end/1" do
    test "offset lands after the last complete line" do
      content = "line one\nline two\npartial"
      state = Cursor.state_for("a.log", content)
      assert state.offset == byte_size("line one\nline two\n")
    end

    test "offset covers everything when content ends with newline" do
      content = "line one\nline two\n"
      assert Cursor.state_for("a.log", content).offset == byte_size(content)
    end

    test "no newline at all means offset zero" do
      assert Cursor.state_for("a.log", "partial").offset == 0
      assert Cursor.state_for("a.log", "").offset == 0
    end
  end

  describe "validate/3" do
    test "valid when the file only grew" do
      original = "aaa\nbbb\n"
      state = Cursor.state_for("a.log", original)
      grown = original <> "ccc\n"
      assert Cursor.validate(state, "a.log", grown) == :ok
    end

    test "invalid when the file shrank (truncation)" do
      state = Cursor.state_for("a.log", "aaa\nbbb\nccc\n")
      assert Cursor.validate(state, "a.log", "aaa\n") == :invalid
    end

    test "invalid when the first bytes changed (rotation/replacement)" do
      state = Cursor.state_for("a.log", "old content line\nmore\n")
      replaced = "NEW content line\nmore\nplus extra lines to keep it long\n"
      assert Cursor.validate(state, "a.log", replaced) == :invalid
    end

    test "invalid when the file identity differs" do
      state = Cursor.state_for("a.log", "aaa\n")
      assert Cursor.validate(state, "b.log", "aaa\n") == :invalid
    end

    test "sig region is anchored at encode time, so growth past 256 bytes stays valid" do
      short = String.duplicate("x", 100) <> "\n"
      state = Cursor.state_for("a.log", short)
      grown = short <> String.duplicate("y", 500) <> "\n"
      assert Cursor.validate(state, "a.log", grown) == :ok
    end
  end

  describe "resolve/3" do
    test "nil cursor starts at zero without reset" do
      assert Cursor.resolve(nil, "a.log", "aaa\n") == {0, false}
    end

    test "valid cursor resolves to its offset" do
      content = "aaa\nbbb\n"
      encoded = Cursor.encode(Cursor.state_for("a.log", content))
      assert Cursor.resolve(encoded, "a.log", content <> "ccc\n") == {byte_size(content), false}
    end

    test "undecodable cursor resets" do
      assert Cursor.resolve("garbage", "a.log", "aaa\n") == {0, true}
    end

    test "rotated file resets" do
      encoded = Cursor.encode(Cursor.state_for("a.log", "old old old\nmore\n"))
      assert Cursor.resolve(encoded, "a.log", "brand new\n") == {0, true}
    end
  end

  describe "slice_lines/2" do
    test "slices from offset with correct absolute line numbers" do
      content = "one\ntwo\nthree\nfour\n"
      offset = byte_size("one\ntwo\n")
      assert Cursor.slice_lines(content, offset) == {["three", "four"], 3}
    end

    test "from zero returns all lines starting at line 1" do
      assert Cursor.slice_lines("one\ntwo\n", 0) == {["one", "two"], 1}
    end

    test "empty region yields no lines" do
      content = "one\n"
      assert Cursor.slice_lines(content, byte_size(content)) == {[], 2}
    end

    test "a trailing partial line is included" do
      assert Cursor.slice_lines("one\npart", 0) == {["one", "part"], 1}
    end

    test "trailing whitespace is trimmed like stream_lines" do
      assert Cursor.slice_lines("one\r\ntwo  \n", 0) == {["one", "two"], 1}
    end
  end

  describe "no-overlap-no-gap property across successive polls" do
    test "growing file: consecutive slices partition the lines exactly" do
      appends = for i <- 1..20, do: "line #{i}\n"

      {_content, _cursor, seen} =
        Enum.reduce(appends, {"", nil, []}, fn chunk, {content, cursor_str, seen} ->
          content = content <> chunk

          {offset, reset?} = Cursor.resolve(cursor_str, "a.log", content)
          refute reset?

          {lines, _start} = Cursor.slice_lines(content, offset)
          new_cursor = Cursor.encode(Cursor.state_for("a.log", content))
          {content, new_cursor, seen ++ lines}
        end)

      assert seen == for(i <- 1..20, do: "line #{i}")
    end

    test "multi-line appends between polls arrive exactly once" do
      c1 = "a\nb\n"
      c2 = c1 <> "c\nd\ne\n"
      c3 = c2 <> "f\n"

      cur1 = Cursor.encode(Cursor.state_for("a.log", c1))
      {off2, false} = Cursor.resolve(cur1, "a.log", c2)
      assert {["c", "d", "e"], 3} = Cursor.slice_lines(c2, off2)

      cur2 = Cursor.encode(Cursor.state_for("a.log", c2))
      {off3, false} = Cursor.resolve(cur2, "a.log", c3)
      assert {["f"], 6} = Cursor.slice_lines(c3, off3)
    end
  end
end
