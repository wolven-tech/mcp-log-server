defmodule McpLogServer.Domain.SparseIndexTest do
  use ExUnit.Case, async: true

  alias McpLogServer.Domain.SparseIndex

  defp build(lines, opts \\ [], ts_opts \\ []) do
    Enum.reduce(lines, SparseIndex.new(Keyword.put_new(opts, :interval, 2)), fn line, b ->
      SparseIndex.add_line(b, line <> "\n", ts_opts)
    end)
    |> SparseIndex.finish()
  end

  defp iso(minute), do: "2026-07-17T10:#{String.pad_leading(to_string(minute), 2, "0")}:00Z"

  describe "checkpoints" do
    test "one checkpoint per interval, with exact byte offsets and cumulative stats" do
      lines = for m <- 0..5, do: "#{iso(m)} line #{m}"
      summary = build(lines)

      assert length(summary.checkpoints) == 3
      [cp1, cp2, cp3] = summary.checkpoints

      assert cp1.lines == 2
      assert cp2.lines == 4
      assert cp3.lines == 6

      # Offsets are exact byte positions (each line + newline)
      expected1 = Enum.take(lines, 2) |> Enum.map(&(byte_size(&1) + 1)) |> Enum.sum()
      assert cp1.offset == expected1
      assert summary.bytes == Enum.map(lines, &(byte_size(&1) + 1)) |> Enum.sum()

      # max_ts grows monotonically
      assert cp1.line_max_us < cp2.line_max_us
      assert cp2.line_max_us < cp3.line_max_us
      assert Enum.all?(summary.checkpoints, &(&1.line_unparsed == 0))
    end

    test "unparsed lines are counted cumulatively" do
      lines = ["#{iso(0)} ok", "no timestamp here", "#{iso(2)} ok", "#{iso(3)} ok"]
      summary = build(lines)

      [cp1, cp2] = summary.checkpoints
      assert cp1.line_unparsed == 1
      assert cp2.line_unparsed == 1
      assert summary.line_unparsed == 1
    end
  end

  describe "seek/3 soundness" do
    test "seeks to the deepest checkpoint strictly before since" do
      lines = for m <- 0..9, do: "#{iso(m)} line #{m}"
      summary = build(lines)

      # since 10:07 — checkpoints at lines 2,4,6 (max 10:01,10:03,10:05) all
      # qualify; the one at 8 (max 10:07) does NOT (equality is inclusion).
      {:ok, %{offset: offset, lines: n}} =
        SparseIndex.seek(summary, ~U[2026-07-17 10:07:00Z], :line)

      assert n == 6
      assert offset == Enum.take(lines, 6) |> Enum.map(&(byte_size(&1) + 1)) |> Enum.sum()
    end

    test "a timestamp exactly equal to since blocks that checkpoint" do
      lines = for m <- 0..3, do: "#{iso(m)} line"
      summary = build(lines)

      # cp1 covers 10:00,10:01 (max 10:01). since == 10:01 must include the
      # 10:01 line, so cp1 is not a safe skip; no checkpoint qualifies.
      assert SparseIndex.seek(summary, ~U[2026-07-17 10:01:00Z], :line) == :miss
      # since just past it qualifies cp1
      assert {:ok, %{lines: 2}} =
               SparseIndex.seek(summary, ~U[2026-07-17 10:01:00.000001Z], :line)
    end

    test "any unparsed line in the prefix blocks the seek (fail-open honesty)" do
      lines = ["no ts at all", "#{iso(1)} b", "#{iso(2)} c", "#{iso(3)} d"]
      summary = build(lines)

      assert SparseIndex.seek(summary, ~U[2026-07-17 10:59:00Z], :line) == :miss
    end

    test "line and entry semantics are independent" do
      # JSON lines whose "time" field (entry semantics) differs from the
      # ISO string embedded in the message (line semantics).
      lines =
        for m <- 0..3 do
          Jason.encode!(%{
            "time" => iso(m),
            "message" => "replay of 2020-01-01T00:00:00Z event"
          })
        end

      summary = build(lines)

      # Entry semantics: parsed from "time" — seek possible past 10:01.
      assert {:ok, _} = SparseIndex.seek(summary, ~U[2026-07-17 10:02:00Z], :entry)
      # Line semantics: the regex finds 2026-... first (it appears in "time"
      # serialized), so this still parses — but the two maxes are tracked
      # separately and must not be conflated.
      assert summary.entry_max_us != nil
      assert summary.line_max_us != nil
    end

    test "no checkpoints means miss" do
      summary = build(["#{iso(0)} only line"])
      assert SparseIndex.seek(summary, ~U[2026-07-17 11:00:00Z], :line) == :miss
    end
  end

  describe "reference sensitivity" do
    test "time-only formats mark the summary ref_sensitive" do
      ref = ~U[2026-07-17 12:00:00Z]
      summary = build(["14:00:00 dev server line", "14:00:01 another"], [], reference: ref)
      assert summary.ref_sensitive
    end

    test "date-carrying formats do not" do
      summary = build(["#{iso(0)} a", "#{iso(1)} b"], [], reference: ~U[2026-07-17 12:00:00Z])
      refute summary.ref_sensitive
    end
  end

  describe "field keys" do
    test "present paths include every ancestor; lists and deep maps are opaque" do
      line = Jason.encode!(%{"a" => %{"b" => %{"c" => 1}}, "items" => [1, 2], "flat" => "x"})
      summary = build([line])

      assert MapSet.member?(summary.present, "a")
      assert MapSet.member?(summary.present, "a.b")
      assert MapSet.member?(summary.present, "a.b.c")
      assert MapSet.member?(summary.present, "items")
      assert MapSet.member?(summary.opaque, "items")
      refute MapSet.member?(summary.opaque, "flat")

      assert summary.json_lines == 1
      assert summary.non_json == 0
    end

    test "key_absent? proves absence only when sound" do
      line = Jason.encode!(%{"a" => %{"b" => 1}, "items" => [%{"id" => 1}]})
      summary = build([line, "plain line"])

      assert summary.non_json == 1
      # genuinely absent
      assert SparseIndex.key_absent?(summary, ["missing"])
      assert SparseIndex.key_absent?(summary, ["a", "zzz"])
      # present — not absent
      refute SparseIndex.key_absent?(summary, ["a", "b"])
      # under an opaque list — could resolve via numeric index, no proof
      refute SparseIndex.key_absent?(summary, ["items", "0", "id"])
    end

    test "capped path sets refuse every absence proof" do
      line = Jason.encode!(Map.new(1..20, fn i -> {"k#{i}", i} end))
      summary = build([line], max_paths: 5)

      assert summary.fields_capped
      refute SparseIndex.key_absent?(summary, ["definitely_not_there"])
    end
  end

  describe "resume/2" do
    test "extending a builder continues counters and offsets exactly" do
      first = for m <- 0..3, do: "#{iso(m)} line #{m}"
      rest = for m <- 4..7, do: "#{iso(m)} line #{m}"

      full = build(first ++ rest)

      partial = build(first)

      extended =
        Enum.reduce(rest, SparseIndex.resume(partial, interval: 2), fn line, b ->
          SparseIndex.add_line(b, line <> "\n", [])
        end)
        |> SparseIndex.finish()

      assert extended == full
    end
  end
end
