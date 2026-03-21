defmodule McpLogServer.Domain.TimeFilterTest do
  use ExUnit.Case, async: true

  alias McpLogServer.Domain.TimeFilter

  @since ~U[2026-03-20 10:00:00Z]
  @until ~U[2026-03-20 14:00:00Z]

  describe "in_range?/3 with plain text lines" do
    test "line within range returns true" do
      line = "2026-03-20 12:00:00 INFO inside range"
      assert TimeFilter.in_range?(line, @since, @until) == true
    end

    test "line before range returns false" do
      line = "2026-03-20 08:00:00 INFO before range"
      assert TimeFilter.in_range?(line, @since, @until) == false
    end

    test "line after range returns false" do
      line = "2026-03-20 16:00:00 INFO after range"
      assert TimeFilter.in_range?(line, @since, @until) == false
    end

    test "line exactly at since boundary returns true" do
      line = "2026-03-20 10:00:00 INFO at boundary"
      assert TimeFilter.in_range?(line, @since, @until) == true
    end

    test "line exactly at until boundary returns true" do
      line = "2026-03-20 14:00:00 INFO at boundary"
      assert TimeFilter.in_range?(line, @since, @until) == true
    end

    test "line without parseable timestamp is included (fail-open)" do
      line = "some random text without a timestamp"
      assert TimeFilter.in_range?(line, @since, @until) == true
    end
  end

  describe "in_range?/3 with JSON entries" do
    test "entry within range returns true" do
      entry = %{"timestamp" => "2026-03-20T12:00:00Z", "message" => "inside"}
      assert TimeFilter.in_range?(entry, @since, @until) == true
    end

    test "entry before range returns false" do
      entry = %{"timestamp" => "2026-03-20T08:00:00Z", "message" => "before"}
      assert TimeFilter.in_range?(entry, @since, @until) == false
    end

    test "entry after range returns false" do
      entry = %{"timestamp" => "2026-03-20T16:00:00Z", "message" => "after"}
      assert TimeFilter.in_range?(entry, @since, @until) == false
    end

    test "entry without timestamp is included (fail-open)" do
      entry = %{"message" => "no timestamp"}
      assert TimeFilter.in_range?(entry, @since, @until) == true
    end
  end

  describe "in_range?/3 with nil bounds" do
    test "both nil always returns true" do
      assert TimeFilter.in_range?("anything", nil, nil) == true
    end

    test "only since specified" do
      line = "2026-03-20 12:00:00 INFO test"
      assert TimeFilter.in_range?(line, @since, nil) == true

      early = "2026-03-20 08:00:00 INFO test"
      assert TimeFilter.in_range?(early, @since, nil) == false
    end

    test "only until specified" do
      line = "2026-03-20 12:00:00 INFO test"
      assert TimeFilter.in_range?(line, nil, @until) == true

      late = "2026-03-20 16:00:00 INFO test"
      assert TimeFilter.in_range?(late, nil, @until) == false
    end
  end
end
