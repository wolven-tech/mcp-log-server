defmodule McpLogServer.Domain.TsFormatTest do
  use ExUnit.Case, async: true

  alias McpLogServer.Domain.TsFormat

  describe "parse_declarations/1" do
    test "nil and empty strings yield no declarations" do
      assert TsFormat.parse_declarations(nil) == {:ok, []}
      assert TsFormat.parse_declarations("") == {:ok, []}
    end

    test "parses the documented example declaration" do
      raw = "fly-*.log=%FT%T%.fZ; app*.log=epoch_ms; dev-*.log=%H:%M:%S"

      assert {:ok, [fly, app, dev]} = TsFormat.parse_declarations(raw)
      assert fly.glob == "fly-*.log"
      assert fly.format.kind == :strftime
      assert app.format.kind == :epoch_ms
      assert dev.format.kind == :strftime
    end

    test "rejects an entry without '='" do
      assert {:error, message} = TsFormat.parse_declarations("fly-*.log")
      assert message =~ "glob=format"
    end

    test "rejects an unknown named format" do
      assert {:error, message} = TsFormat.parse_declarations("app.log=epoch_us")
      assert message =~ "epoch_us"
    end

    test "rejects an unsupported strftime directive" do
      assert {:error, message} = TsFormat.parse_declarations("app.log=%Q:%M")
      assert message =~ "%Q"
    end

    test "rejects a dangling percent" do
      assert {:error, message} = TsFormat.parse_declarations("app.log=%H:%M:%S%")
      assert message =~ "dangling"
    end

    test "rejects empty glob or format" do
      assert {:error, _} = TsFormat.parse_declarations("=epoch_ms")
      assert {:error, _} = TsFormat.parse_declarations("app.log=")
    end
  end

  describe "for_file/2" do
    setup do
      {:ok, decls} =
        TsFormat.parse_declarations("fly-*.log=rfc3339; app?.log=epoch_ms; *.log=epoch_s")

      %{decls: decls}
    end

    test "first matching glob wins", %{decls: decls} do
      assert %{kind: :rfc3339} = TsFormat.for_file(decls, "fly-api.log")
      assert %{kind: :epoch_ms} = TsFormat.for_file(decls, "app1.log")
      assert %{kind: :epoch_s} = TsFormat.for_file(decls, "other.log")
    end

    test "glob is anchored to the whole basename", %{decls: decls} do
      # app?.log requires exactly one character after 'app'
      assert %{kind: :epoch_s} = TsFormat.for_file(decls, "app12.log")
    end

    test "returns nil when nothing matches", %{decls: decls} do
      assert TsFormat.for_file(decls, "notes.txt") == nil
    end
  end

  describe "extract/3 - named formats" do
    test "rfc3339" do
      {:ok, fmt} = TsFormat.compile("rfc3339")
      assert TsFormat.extract(fmt, "2026-03-20T14:00:00.5Z hello", nil) ==
               ~U[2026-03-20 14:00:00.5Z]
      assert TsFormat.extract(fmt, "no timestamp", nil) == nil
    end

    test "epoch_ms requires exactly 13 digits" do
      {:ok, fmt} = TsFormat.compile("epoch_ms")
      dt = TsFormat.extract(fmt, "ts=1742479200123 msg=hi", nil)
      assert DateTime.to_unix(dt, :millisecond) == 1_742_479_200_123
      assert TsFormat.extract(fmt, "ts=17424792001234 too long", nil) == nil
      assert TsFormat.extract(fmt, "ts=1742479200 too short", nil) == nil
    end

    test "epoch_s requires exactly 10 digits" do
      {:ok, fmt} = TsFormat.compile("epoch_s")
      dt = TsFormat.extract(fmt, "1742479200 boot", nil)
      assert DateTime.to_unix(dt) == 1_742_479_200
      assert TsFormat.extract(fmt, "174247920012 nope", nil) == nil
    end
  end

  describe "extract/3 - strftime formats" do
    test "%FT%T%.fZ parses fly-style timestamps" do
      {:ok, fmt} = TsFormat.compile("%FT%T%.fZ")

      assert TsFormat.extract(fmt, "2026-03-20T14:00:00.123Z app[abcd] out", nil) ==
               ~U[2026-03-20 14:00:00.123Z]

      # fraction is optional under %.f
      assert TsFormat.extract(fmt, "2026-03-20T14:00:00Z plain", nil) ==
               ~U[2026-03-20 14:00:00Z]
    end

    test "%Y-%m-%d %H:%M:%S with offset %z" do
      {:ok, fmt} = TsFormat.compile("%Y-%m-%d %H:%M:%S %z")
      dt = TsFormat.extract(fmt, "2026-03-20 14:00:00 +0530 req done", nil)
      assert dt == ~U[2026-03-20 08:30:00Z]
    end

    test "time-only %H:%M:%S resolves against the reference with rollover" do
      {:ok, fmt} = TsFormat.compile("%H:%M:%S")
      reference = ~U[2026-03-21 00:30:00Z]

      assert TsFormat.extract(fmt, "23:50:00 late line", reference) == ~U[2026-03-20 23:50:00Z]
      assert TsFormat.extract(fmt, "00:20:00 early line", reference) == ~U[2026-03-21 00:20:00Z]
    end

    test "%b month abbreviation with reference year" do
      {:ok, fmt} = TsFormat.compile("%b %d %H:%M:%S")
      reference = ~U[2026-06-01 00:00:00Z]
      dt = TsFormat.extract(fmt, "Mar 20 14:00:00 host proc: msg", reference)
      assert dt == ~U[2026-03-20 14:00:00Z]
    end

    test "digit guards prevent matching inside longer digit runs" do
      {:ok, fmt} = TsFormat.compile("%H:%M:%S")
      assert TsFormat.extract(fmt, "114:00:005 not a time", nil) == nil
    end

    test "non-matching line returns nil" do
      {:ok, fmt} = TsFormat.compile("%FT%T")
      assert TsFormat.extract(fmt, "no timestamp here", nil) == nil
    end
  end
end
