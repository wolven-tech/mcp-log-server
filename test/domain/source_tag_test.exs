defmodule McpLogServer.Domain.SourceTagTest do
  use ExUnit.Case, async: true

  alias McpLogServer.Domain.SourceTag
  alias McpLogServer.Domain.TimestampParser

  test "tag_line/2 round-trips through strip/1 and source_of/1" do
    line = "2026-07-17T10:00:00Z proxy connection reset"
    tagged = SourceTag.tag_line("fly", line)

    assert tagged == "[src:fly] " <> line
    assert SourceTag.strip(tagged) == line
    assert SourceTag.source_of(tagged) == "fly"
  end

  test "strip/1 leaves untagged lines alone" do
    assert SourceTag.strip("plain line") == "plain line"
    assert SourceTag.source_of("plain line") == nil
  end

  test "strip/1 does not eat bracketed content that is not a source tag" do
    assert SourceTag.strip("[vite] 14:00:00 hmr update") == "[vite] 14:00:00 hmr update"
    assert SourceTag.strip("[src:bad name] x") == "[src:bad name] x"
  end

  test "strip/1 only removes ONE leading tag (nested content preserved)" do
    tagged = SourceTag.tag_line("a", "[src:b] inner")
    assert SourceTag.strip(tagged) == "[src:b] inner"
  end

  test "tagged lines timestamp-parse exactly like their untagged originals" do
    for line <- [
          "2026-07-17T10:00:00.123Z ERROR boom",
          "2026-07-17 10:00:00 INFO started",
          "Jul 17 10:00:00 host daemon[1]: msg",
          "[14:00:00] hmr update"
        ] do
      untagged = TimestampParser.extract(line)
      tagged = TimestampParser.extract(SourceTag.tag_line("fly", line))
      assert tagged == untagged, "mismatch for #{inspect(line)}"
      refute is_nil(tagged)
    end
  end
end
