defmodule McpLogServer.Infrastructure.LogIndexTest do
  use ExUnit.Case, async: false

  alias McpLogServer.Infrastructure.LogIndex

  @tmp_dir System.tmp_dir!() |> Path.join("log_index_test")

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  defp uniq(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

  defp start_index!(opts \\ []) do
    name = uniq("idx_server")
    table = uniq("idx_table")
    dets = uniq("idx_dets")
    dir = Keyword.get(opts, :dir, Path.join(@tmp_dir, ".index"))

    pid =
      start_supervised!(
        {LogIndex,
         name: name, table: table, dets: dets, dir: dir, interval: Keyword.get(opts, :interval, 5)},
        id: name
      )

    %{pid: pid, name: name, table: table, dets: dets, dir: dir, opts: [table: table, server: name]}
  end

  defp iso(minute), do: "2026-07-17T10:#{String.pad_leading(to_string(minute), 2, "0")}:00Z"

  defp write_log!(name, lines) do
    path = Path.join(@tmp_dir, name)
    File.write!(path, Enum.map_join(lines, "", &(&1 <> "\n")))
    path
  end

  defp ts_lines(range), do: for(m <- range, do: "#{iso(m)} line #{m}")

  test "build then seek: returns a line-boundary offset that skips the proven prefix" do
    idx = start_index!()
    path = write_log!("app.log", ts_lines(0..19))

    assert {:ok, _meta} = LogIndex.build_now(path, idx.name)

    assert {:ok, %{offset: offset, lines: lines}} =
             LogIndex.seek(path, ~U[2026-07-17 10:12:00Z], :line, idx.opts)

    assert lines == 10
    # boundary: the byte before the offset is a newline
    content = File.read!(path)
    assert :binary.at(content, offset - 1) == ?\n
    # everything skipped is strictly before since
    skipped = binary_part(content, 0, offset)
    refute skipped =~ iso(12)
  end

  test "unindexed file misses (and queries never block)" do
    idx = start_index!()
    path = write_log!("app.log", ts_lines(0..19))

    assert LogIndex.seek(path, ~U[2026-07-17 10:12:00Z], :line, idx.opts) == :miss
  end

  test "missing process / table: miss, never crash" do
    path = write_log!("app.log", ts_lines(0..9))

    assert LogIndex.seek(path, ~U[2026-07-17 10:05:00Z], :line,
             table: :no_such_table,
             server: :no_such_server
           ) == :miss

    assert LogIndex.field_stats(path, table: :no_such_table, server: :no_such_server) == :miss
  end

  test "append-only growth keeps the prefix seekable and extends incrementally" do
    idx = start_index!()
    path = write_log!("app.log", ts_lines(0..9))
    assert {:ok, meta1} = LogIndex.build_now(path, idx.name)

    File.write!(path, Enum.map_join(10..19, "", &("#{iso(&1)} line #{&1}\n")), [:append])

    # Old checkpoints still valid for the unchanged prefix
    assert {:ok, %{lines: 5}} = LogIndex.seek(path, ~U[2026-07-17 10:07:00Z], :line, idx.opts)

    # Extension continues from the indexed bytes (same prefix checkpoints)
    assert {:ok, meta2} = LogIndex.build_now(path, idx.name)
    assert meta2.summary.lines == 20
    assert Enum.take(meta2.summary.checkpoints, length(meta1.summary.checkpoints)) ==
             meta1.summary.checkpoints

    assert {:ok, %{lines: 15}} = LogIndex.seek(path, ~U[2026-07-17 10:17:00Z], :line, idx.opts)
  end

  test "rotation (content replaced) invalidates: miss, then rebuild serves the new file" do
    idx = start_index!()
    path = write_log!("app.log", ts_lines(0..19))
    assert {:ok, _} = LogIndex.build_now(path, idx.name)

    # replace with entirely different content (rotation)
    File.rm!(path)
    write_log!("app.log", for(m <- 30..49, do: "#{iso(m)} rotated #{m}"))

    assert LogIndex.seek(path, ~U[2026-07-17 10:40:00Z], :line, idx.opts) == :miss

    assert {:ok, _} = LogIndex.build_now(path, idx.name)
    assert {:ok, %{lines: 10}} = LogIndex.seek(path, ~U[2026-07-17 10:42:00Z], :line, idx.opts)
  end

  test "truncation invalidates the seek" do
    idx = start_index!()
    path = write_log!("app.log", ts_lines(0..19))
    assert {:ok, _} = LogIndex.build_now(path, idx.name)

    write_log!("app.log", ts_lines(0..3))
    assert LogIndex.seek(path, ~U[2026-07-17 10:02:00Z], :line, idx.opts) == :miss
  end

  test "explicit invalidate drops the entry" do
    idx = start_index!()
    path = write_log!("app.log", ts_lines(0..19))
    assert {:ok, _} = LogIndex.build_now(path, idx.name)
    assert {:ok, _} = LogIndex.seek(path, ~U[2026-07-17 10:12:00Z], :line, idx.opts)

    LogIndex.invalidate(path, idx.name)
    # cast — wait for it to be processed
    assert :sys.get_state(idx.pid)
    assert LogIndex.seek(path, ~U[2026-07-17 10:12:00Z], :line, idx.opts) == :miss
  end

  test "field_stats requires a byte-identical fully-indexed file" do
    idx = start_index!()
    lines = [Jason.encode!(%{"a" => %{"b" => 1}}), "plain line"]
    path = write_log!("app.log", lines)
    assert {:ok, _} = LogIndex.build_now(path, idx.name)

    assert {:ok, fs} = LogIndex.field_stats(path, idx.opts)
    assert fs.json_lines == 1
    assert fs.non_json == 1
    assert MapSet.member?(fs.present, "a.b")
    refute fs.capped

    # any append invalidates absence proofs
    File.write!(path, "another line\n", [:append])
    assert LogIndex.field_stats(path, idx.opts) == :miss
  end

  test "trailing partial line (no newline) is left unindexed" do
    idx = start_index!()
    path = Path.join(@tmp_dir, "app.log")
    File.write!(path, "#{iso(0)} full line\n#{iso(1)} partial without newline")

    assert {:ok, meta} = LogIndex.build_now(path, idx.name)
    assert meta.summary.lines == 1
    assert meta.summary.bytes < File.stat!(path).size
    # not fully indexed → no absence proofs
    assert LogIndex.field_stats(path, idx.opts) == :miss
  end

  test "DETS persistence: a new instance serves seeks without rebuilding" do
    dir = Path.join(@tmp_dir, ".index")
    idx1 = start_index!(dir: dir)
    path = write_log!("app.log", ts_lines(0..19))
    assert {:ok, _} = LogIndex.build_now(path, idx1.name)
    :ok = stop_supervised(idx1.name)

    idx2 = start_index!(dir: dir)
    # no build_now on idx2 — the entry was loaded from DETS
    assert {:ok, %{lines: 10}} =
             LogIndex.seek(path, ~U[2026-07-17 10:12:00Z], :line, idx2.opts)
  end

  test "corrupt DETS file self-heals: server starts, queries answer, rebuild works" do
    dir = Path.join(@tmp_dir, ".index")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "log_index.dets"), "this is not a dets file at all \x00\x01\x02")

    idx = start_index!(dir: dir)
    path = write_log!("app.log", ts_lines(0..19))

    assert LogIndex.seek(path, ~U[2026-07-17 10:12:00Z], :line, idx.opts) == :miss
    assert {:ok, _} = LogIndex.build_now(path, idx.name)
    assert {:ok, _} = LogIndex.seek(path, ~U[2026-07-17 10:12:00Z], :line, idx.opts)
  end

  test "schema version mismatch drops all entries and rebuilds lazily" do
    dir = Path.join(@tmp_dir, ".index")
    idx1 = start_index!(dir: dir)
    path = write_log!("app.log", ts_lines(0..19))
    assert {:ok, _} = LogIndex.build_now(path, idx1.name)
    :ok = stop_supervised(idx1.name)

    # tamper: rewrite the stored schema version
    tamper = uniq("tamper")
    file = Path.join(dir, "log_index.dets") |> String.to_charlist()
    {:ok, ^tamper} = :dets.open_file(tamper, file: file)
    :ok = :dets.insert(tamper, {:__schema__, 999_999})
    :ok = :dets.close(tamper)

    idx2 = start_index!(dir: dir)
    assert LogIndex.seek(path, ~U[2026-07-17 10:12:00Z], :line, idx2.opts) == :miss
    assert {:ok, _} = LogIndex.build_now(path, idx2.name)
    assert {:ok, _} = LogIndex.seek(path, ~U[2026-07-17 10:12:00Z], :line, idx2.opts)
  end

  test "oversized files are never indexed (the guardrail forbids reading them)" do
    idx = start_index!()
    path = write_log!("app.log", ts_lines(0..19))

    original = Application.get_env(:mcp_log_server, :max_log_file_mb)
    Application.put_env(:mcp_log_server, :max_log_file_mb, 0)
    on_exit(fn -> Application.put_env(:mcp_log_server, :max_log_file_mb, original) end)

    assert {:error, _} = LogIndex.build_now(path, idx.name)
    assert LogIndex.seek(path, ~U[2026-07-17 10:12:00Z], :line, idx.opts) == :miss
  end
end
