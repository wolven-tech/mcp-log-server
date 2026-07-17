defmodule McpLogServer.Infrastructure.LogIndex do
  @moduledoc """
  `McpLogServer.Ports.LogIndex` adapter: the incremental persistent index
  (ETS + DETS — see docs/decisions/001-index-storage.md).

  ## Read path (never blocks, never crashes)

  `seek/3` and `field_stats/1` read a named ETS table directly from the
  caller's process — no GenServer call. Any doubt (table absent because
  indexing is disabled or the process died, no entry, stat/signature
  mismatch, ref-sensitive timestamps with a changed file, offset not on a
  line boundary) returns `:miss`, and a background (re)build is requested
  with a fire-and-forget cast. Queries take whatever index state exists.

  ## Write path (one process, background)

  The owning GenServer serializes all builds. Builds stream the file's raw
  lines through the pure `McpLogServer.Domain.SparseIndex` builder using
  the SAME timestamp options the query-time scans use (declared
  `LOG_TS_FORMATS` + mtime reference), so build-time and query-time
  parsing agree. Append-only growth extends the existing index from
  `indexed bytes` (only the delta is read); anything else — rotation,
  truncation, mtime/size regression, ref-sensitive files — drops the
  file's entries and rebuilds from scratch. A trailing line without a
  newline is never indexed (it may still be mid-append; the next build
  picks it up complete).

  ## Persistence and self-healing

  DETS under `LOG_DIR/.index/log_index.dets` (the `.index` directory is
  invisible to `list_logs` and every scan, which glob `*.log`). On boot
  the DETS content is loaded into ETS, pruning entries for files that no
  longer exist. A stored schema version guards format changes: mismatch →
  all entries dropped, lazy rebuild. An unopenable/corrupt DETS file is
  deleted and recreated; if that also fails the index runs memory-only.
  `init/1` cannot crash the server, and every build is exception-guarded —
  a wrong index MUST degrade to `:miss` + rebuild, never take the MCP
  session down.
  """

  use GenServer

  @behaviour McpLogServer.Ports.LogIndex

  alias McpLogServer.Domain.SparseIndex
  alias McpLogServer.Infrastructure.EnvConfig

  @table :mcp_log_index
  @dets :mcp_log_index_dets
  @schema_version 1
  @sig_bytes 256
  @build_timeout 120_000

  # -- Supervision --

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  # -- Port implementation (ETS reads; :miss on any doubt) --

  @impl McpLogServer.Ports.LogIndex
  def seek(path, since, mode), do: seek(path, since, mode, [])

  @doc "Like `seek/3`; `opts` may name a test instance (`:table`, `:server`)."
  @spec seek(term(), DateTime.t(), :line | :entry, keyword()) ::
          {:ok, McpLogServer.Ports.LogIndex.seek_point()} | :miss
  def seek(path, %DateTime{} = since, mode, opts) when is_binary(path) do
    table = Keyword.get(opts, :table, @table)
    server = Keyword.get(opts, :server, __MODULE__)

    with {:ok, meta} <- lookup(table, path),
         {:ok, stat} <- seekable(meta, path),
         {:ok, pos} <- SparseIndex.seek(meta.summary, since, mode),
         true <- line_boundary?(path, pos.offset) do
      # The prefix is seekable, but the file may have grown past the
      # indexed range — extend in the background so the NEXT query seeks
      # deeper. This query proceeds now with what exists.
      if stat.size > meta.summary.bytes, do: request_build(server, path)
      {:ok, pos}
    else
      _ ->
        request_build(server, path)
        :miss
    end
  end

  def seek(_path, _since, _mode, _opts), do: :miss

  @impl McpLogServer.Ports.LogIndex
  def field_stats(path), do: field_stats(path, [])

  @doc "Like `field_stats/1`; `opts` may name a test instance (`:table`, `:server`)."
  @spec field_stats(term(), keyword()) ::
          {:ok, McpLogServer.Ports.LogIndex.field_stats()} | :miss
  def field_stats(path, opts) when is_binary(path) do
    table = Keyword.get(opts, :table, @table)
    server = Keyword.get(opts, :server, __MODULE__)

    with {:ok, meta} <- lookup(table, path),
         true <- fully_current?(meta, path) do
      s = meta.summary

      {:ok,
       %{
         present: s.present,
         opaque: s.opaque,
         capped: s.fields_capped,
         json_lines: s.json_lines,
         non_json: s.non_json
       }}
    else
      _ ->
        request_build(server, path)
        :miss
    end
  end

  def field_stats(_path, _opts), do: :miss

  # -- Ingest hooks and maintenance (all fire-and-forget safe) --

  @doc "Notify that `path` was appended to; extends its index in the background."
  @spec appended(String.t(), GenServer.server()) :: :ok
  def appended(path, server \\ __MODULE__), do: request_build(server, path)

  @doc "Request a background (re)build of `path`'s index if it is stale."
  @spec ensure(String.t(), GenServer.server()) :: :ok
  def ensure(path, server \\ __MODULE__), do: request_build(server, path)

  @doc "Drop `path`'s index entries (rotation/truncation). Rebuild happens lazily."
  @spec invalidate(String.t(), GenServer.server()) :: :ok
  def invalidate(path, server \\ __MODULE__), do: GenServer.cast(server, {:invalidate, path})

  @doc "Synchronously (re)build `path`'s index — tests and benchmarks only."
  @spec build_now(String.t(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  def build_now(path, server \\ __MODULE__) do
    GenServer.call(server, {:build_now, path}, @build_timeout)
  catch
    :exit, reason -> {:error, reason}
  end

  # -- GenServer --

  @impl GenServer
  def init(opts) do
    # Trap exits so terminate/2 runs on supervisor shutdown and the DETS
    # table is closed (flushed) properly instead of relying on auto_save.
    Process.flag(:trap_exit, true)
    table = Keyword.get(opts, :table, @table)
    dets = Keyword.get(opts, :dets, @dets)
    dir = Keyword.get_lazy(opts, :dir, fn -> Path.join(EnvConfig.log_dir(), ".index") end)
    interval = Keyword.get(opts, :interval, 1000)

    :ets.new(table, [:named_table, :set, :protected, read_concurrency: true])

    dets_ref =
      try do
        open_dets(dets, dir)
      rescue
        _ -> :none
      catch
        _, _ -> :none
      end

    load_from_dets(dets_ref, table)

    {:ok, %{table: table, dets: dets_ref, dir: dir, interval: interval}}
  end

  @impl GenServer
  def handle_cast({:build, path}, state) do
    safely(fn -> maybe_build(path, state) end)
    {:noreply, state}
  end

  def handle_cast({:invalidate, path}, state) do
    safely(fn -> drop(path, state) end)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:build_now, path}, _from, state) do
    result =
      safely(fn ->
        build(path, state)

        case lookup(state.table, path) do
          {:ok, meta} -> {:ok, meta}
          :error -> {:error, :not_indexed}
        end
      end) || {:error, :build_failed}

    {:reply, result, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    if state.dets != :none, do: :dets.close(state.dets)
    :ok
  end

  # -- Validity checks (read path) --

  defp lookup(table, path) do
    case :ets.lookup(table, path) do
      [{^path, meta}] -> {:ok, meta}
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  # Seekable: the indexed PREFIX still matches (size did not shrink below
  # it, signature bytes agree) and, for ref-sensitive timestamp formats,
  # the file is byte-identical to what was indexed (their resolved
  # instants depend on the file's mtime).
  defp seekable(meta, path) do
    case File.stat(path) do
      {:ok, stat} ->
        cond do
          stat.size < meta.summary.bytes -> :error
          not range_intact?(path, meta) -> :error
          meta.summary.ref_sensitive and not same_file?(stat, meta) -> :error
          true -> {:ok, stat}
        end

      _ ->
        :error
    end
  end

  # Field absence proofs must cover EVERY line: the file must be
  # byte-identical to what was indexed AND fully indexed (no trailing
  # partial line left out).
  defp fully_current?(meta, path) do
    case File.stat(path) do
      {:ok, stat} ->
        same_file?(stat, meta) and meta.summary.bytes == stat.size and range_intact?(path, meta)

      _ ->
        false
    end
  end

  defp same_file?(stat, meta), do: stat.size == meta.file_size and stat.mtime == meta.mtime

  # Signature over BOTH ends of the indexed range. The head alone (the
  # cursor-style rotation guard) is not enough here: a rewrite whose first
  # bytes coincide with the old file (same format, same first lines) would
  # otherwise validate stale checkpoints whose byte offsets no longer land
  # on this file's line boundaries. Appends never touch either sample, so
  # live files stay seekable.
  defp range_intact?(_path, %{sig_len: 0}), do: true

  defp range_intact?(path, %{sig_len: len, sig: sig, tail_sig: tail_sig} = meta) do
    range_bytes = meta.summary.bytes

    head_ok =
      case pread(path, 0, len) do
        {:ok, bytes} when byte_size(bytes) == len -> :erlang.phash2(bytes) == sig
        _ -> false
      end

    tail_ok =
      case pread(path, range_bytes - len, len) do
        {:ok, bytes} when byte_size(bytes) == len -> :erlang.phash2(bytes) == tail_sig
        _ -> false
      end

    head_ok and tail_ok
  end

  defp line_boundary?(_path, 0), do: true

  defp line_boundary?(path, offset) do
    match?({:ok, "\n"}, pread(path, offset - 1, 1))
  end

  defp pread(path, position, len) do
    case :file.open(path, [:read, :raw, :binary]) do
      {:ok, io} ->
        try do
          case :file.pread(io, position, len) do
            {:ok, data} -> {:ok, data}
            _ -> :error
          end
        after
          :file.close(io)
        end

      _ ->
        :error
    end
  end

  defp request_build(server, path) when is_binary(path) do
    GenServer.cast(server, {:build, path})
  end

  defp request_build(_server, _path), do: :ok

  # -- Build path (server side, exception-guarded by callers) --

  defp maybe_build(path, state) do
    case lookup(state.table, path) do
      {:ok, meta} ->
        if fully_current?(meta, path), do: :ok, else: build(path, state)

      :error ->
        build(path, state)
    end
  end

  defp build(path, state) do
    case File.stat(path) do
      {:error, _} ->
        drop(path, state)

      {:ok, stat} ->
        max_bytes = EnvConfig.max_log_file_mb() * 1_048_576

        if stat.size > max_bytes do
          # The read-size guardrail makes this file unreadable by every
          # tool; indexing it would cost the very scan the guardrail
          # forbids. Drop any stale entry instead.
          drop(path, state)
        else
          do_build(path, stat, state)
        end
    end
  end

  defp do_build(path, stat, state) do
    {builder, start_offset} = builder_for(path, stat, state)
    ts_opts = build_ts_opts(path, stat)

    summary =
      path
      |> stream_raw_lines(start_offset)
      |> Enum.reduce(builder, fn raw, b ->
        # A final line without a newline may still be mid-append: leave it
        # unindexed; the next build reads it complete.
        if String.ends_with?(raw, "\n"), do: SparseIndex.add_line(b, raw, ts_opts), else: b
      end)
      |> SparseIndex.finish()

    case File.stat(path) do
      {:ok, after_stat} when after_stat.size >= summary.bytes ->
        if summary.ref_sensitive and after_stat.mtime != stat.mtime do
          # The file changed while we were indexing it with the OLD mtime
          # as timestamp reference — storing this summary would lie. Drop;
          # the next ensure rebuilds against the settled file.
          drop(path, state)
        else
          sig_len = min(summary.bytes, @sig_bytes)

          meta = %{
            summary: summary,
            file_size: after_stat.size,
            mtime: after_stat.mtime,
            sig_len: sig_len,
            sig: hash_at(path, 0, sig_len),
            tail_sig: hash_at(path, summary.bytes - sig_len, sig_len)
          }

          store(path, meta, state)
        end

      _ ->
        # Shrank (or vanished) mid-build: the summary indexes bytes that
        # no longer exist. Drop and let the next query trigger a rebuild.
        drop(path, state)
    end
  end

  defp builder_for(path, stat, state) do
    opts = [interval: state.interval]

    with {:ok, meta} <- lookup(state.table, path),
         false <- meta.summary.ref_sensitive,
         true <- stat.size >= meta.summary.bytes,
         true <- range_intact?(path, meta) do
      {SparseIndex.resume(meta.summary, opts), meta.summary.bytes}
    else
      _ -> {SparseIndex.new(opts), 0}
    end
  end

  defp hash_at(path, position, len) do
    case pread(path, position, len) do
      {:ok, bytes} -> :erlang.phash2(bytes)
      _ -> 0
    end
  end

  # Same ts options the query-time scans build via `UseCases.TsOpts`:
  # declared format for the basename, file mtime as reference.
  defp build_ts_opts(path, stat) do
    format =
      try do
        McpLogServer.Config.TsFormats.for_file(Path.basename(path))
      rescue
        _ -> nil
      catch
        _, _ -> nil
      end

    [format: format, reference: mtime_to_datetime(stat.mtime)]
  end

  defp mtime_to_datetime(mtime) do
    case NaiveDateTime.from_erl(mtime) do
      {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
      _ -> nil
    end
  end

  defp stream_raw_lines(path, offset) do
    Stream.resource(
      fn ->
        case :file.open(path, [:read, :raw, :binary, {:read_ahead, 65_536}]) do
          {:ok, io} ->
            case :file.position(io, offset) do
              {:ok, _} -> io
              _ -> (:file.close(io) && :halted) || :halted
            end

          _ ->
            :halted
        end
      end,
      fn
        :halted ->
          {:halt, :halted}

        io ->
          case :file.read_line(io) do
            {:ok, data} -> {[data], io}
            _ -> {:halt, io}
          end
      end,
      fn
        :halted -> :ok
        io -> :file.close(io)
      end
    )
  end

  # -- Storage --

  defp store(path, meta, state) do
    :ets.insert(state.table, {path, meta})
    if state.dets != :none, do: :dets.insert(state.dets, {path, meta})
    :ok
  end

  defp drop(path, state) do
    :ets.delete(state.table, path)
    if state.dets != :none, do: :dets.delete(state.dets, path)
    :ok
  end

  # -- DETS self-healing --

  defp open_dets(dets_name, dir) do
    File.mkdir_p!(dir)
    file = Path.join(dir, "log_index.dets")

    case try_open(dets_name, file) do
      {:ok, ref} ->
        ref

      :error ->
        # Corrupt beyond repair: the index is a cache — delete and start
        # fresh. If even that fails, run memory-only.
        File.rm(file)

        case try_open(dets_name, file) do
          {:ok, ref} -> ref
          :error -> :none
        end
    end
  end

  defp try_open(dets_name, file) do
    case :dets.open_file(dets_name, file: String.to_charlist(file), auto_save: 5_000) do
      {:ok, ref} ->
        case :dets.lookup(ref, :__schema__) do
          [{:__schema__, @schema_version}] ->
            {:ok, ref}

          _ ->
            # Fresh file or version mismatch: drop everything, stamp the
            # current version. Entries rebuild lazily.
            :dets.delete_all_objects(ref)
            :dets.insert(ref, {:__schema__, @schema_version})
            {:ok, ref}
        end

      {:error, _} ->
        :error
    end
  rescue
    _ -> :error
  end

  defp load_from_dets(:none, _table), do: :ok

  defp load_from_dets(dets, table) do
    prune =
      :dets.foldl(
        fn
          {:__schema__, _}, acc ->
            acc

          {path, %{summary: _} = meta}, acc when is_binary(path) ->
            if File.exists?(path) do
              :ets.insert(table, {path, meta})
              acc
            else
              [path | acc]
            end

          other, acc ->
            # Malformed record: prune it.
            [elem_or_self(other) | acc]
        end,
        [],
        dets
      )

    Enum.each(prune, &:dets.delete(dets, &1))
    :ok
  rescue
    _ -> :ok
  end

  defp elem_or_self(tuple) when is_tuple(tuple) and tuple_size(tuple) > 0, do: elem(tuple, 0)
  defp elem_or_self(other), do: other

  defp safely(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end
end
