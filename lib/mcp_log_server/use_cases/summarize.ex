defmodule McpLogServer.UseCases.Summarize do
  @moduledoc """
  Use-case: `summarize` (issue #7 P8) — "what's new or unusual in this
  window vs the prior one?" in one call.

  Scans the requested files ONCE, classifying every line into the window
  or the equal-length (by default) baseline immediately before it, and
  folds both into `McpLogServer.Domain.WindowDiff`:

    * `new_templates` — message templates present in the window, absent in
      the baseline (count, `instances_seen`, first_ts, sample)
    * `gone_templates` — present in the baseline, absent in the window
    * `error_rate` — errors/min window vs baseline with delta
    * `volume` — lines/min per source with delta

  Honesty fields throughout: `unparsed_ts` (lines that could not be
  placed in time — folded into BOTH ranges so they can never fabricate a
  diff row), `omissions` (skipped files, capped template lists), and
  `index_used` (whether the persistent index accelerated the scan; the
  result is identical without it, only slower).
  """

  alias McpLogServer.Config.Patterns
  alias McpLogServer.Domain.ErrorExtractor
  alias McpLogServer.Domain.JsonLogParser
  alias McpLogServer.Domain.Omissions
  alias McpLogServer.Domain.SourceTag
  alias McpLogServer.Domain.TimestampParser
  alias McpLogServer.Domain.WindowDiff
  alias McpLogServer.Ports.LogSource
  alias McpLogServer.UseCases.Deps
  alias McpLogServer.UseCases.RollupScan
  alias McpLogServer.UseCases.TsOpts

  @default_max_templates 20

  @doc """
  Summarize a time window against its baseline.

  ## Options

    * `:window` - window length shorthand (`"15m"`, `"2h"`); the window
      ends at `:until` (default now)
    * `:since` / `:until` - explicit window bounds (alternative to
      `:window`; `:until` defaults to now)
    * `:baseline` - baseline length shorthand (default: same as window,
      immediately prior)
    * `:file` - one log file (default: ALL logs)
    * `:max_templates` - cap per template list (default #{@default_max_templates})
    * `:source` / `:index` / `:ts_format` - dependency injection (tests)
  """
  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def run(log_dir, opts \\ []) do
    source = Deps.log_source(opts)
    idx = Deps.log_index(opts)

    with {:ok, bounds} <- resolve_bounds(opts),
         {:ok, files} <- target_files(source, log_dir, Keyword.get(opts, :file)) do
      initial = %{
        diff: WindowDiff.new(bounds.w_since, bounds.w_until, bounds.b_since),
        om: Omissions.new(),
        used: false
      }

      state =
        Enum.reduce(files, initial, fn name, st ->
          case source.resolve_readable(log_dir, name) do
            {:error, reason} ->
              %{st | om: Omissions.skipped_file(st.om, name, reason)}

            {:ok, handle} ->
              scan_file(source, idx, handle, name, bounds.b_since, opts, st)
          end
        end)

      {diff_om, diff} =
        state.diff
        |> WindowDiff.finalize(max_templates: Keyword.get(opts, :max_templates, @default_max_templates))
        |> Map.pop(:omissions)

      result =
        Map.merge(diff, %{
          window: %{since: DateTime.to_iso8601(bounds.w_since), until: DateTime.to_iso8601(bounds.w_until)},
          baseline: %{since: DateTime.to_iso8601(bounds.b_since), until: DateTime.to_iso8601(bounds.w_since)},
          files_scanned: length(files) - length(Map.get(state.om, :skipped_files, [])),
          index_used: state.used
        })

      {:ok, Omissions.attach(result, Map.merge(state.om, diff_om))}
    end
  end

  # -- Bounds --

  defp resolve_bounds(opts) do
    window = Keyword.get(opts, :window)
    since = Keyword.get(opts, :since)

    cond do
      is_binary(window) and window != "" ->
        case WindowDiff.parse_duration(window) do
          {:ok, dur} ->
            w_until = TimestampParser.parse_time(Keyword.get(opts, :until)) || DateTime.utc_now()
            with_baseline(opts, DateTime.add(w_until, -dur, :second), w_until, dur)

          :error ->
            {:error, "Invalid window: #{inspect(window)}. Expected a duration like \"15m\", \"2h\"."}
        end

      since not in [nil, ""] ->
        case TimestampParser.parse_time(since) do
          nil ->
            {:error, "Invalid since: #{inspect(since)}. Expected ISO 8601 or relative shorthand."}

          w_since ->
            w_until = TimestampParser.parse_time(Keyword.get(opts, :until)) || DateTime.utc_now()
            dur = DateTime.diff(w_until, w_since, :second)

            if dur > 0 do
              with_baseline(opts, w_since, w_until, dur)
            else
              {:error, "Window is empty: until must be after since."}
            end
        end

      true ->
        {:error, "window (e.g. \"15m\") or since is required"}
    end
  end

  defp with_baseline(opts, w_since, w_until, dur) do
    baseline_dur =
      case Keyword.get(opts, :baseline) do
        b when b in [nil, ""] ->
          {:ok, dur}

        b ->
          case WindowDiff.parse_duration(b) do
            {:ok, bd} -> {:ok, bd}
            :error -> {:error, "Invalid baseline: #{inspect(b)}. Expected a duration like \"15m\"."}
          end
      end

    with {:ok, bd} <- baseline_dur do
      {:ok, %{w_since: w_since, w_until: w_until, b_since: DateTime.add(w_since, -bd, :second)}}
    end
  end

  # An explicitly named file that cannot be read is an ERROR — only files
  # discovered by the all-logs scan degrade into omissions.skipped_files.
  defp target_files(source, log_dir, file) when file in [nil, ""] do
    {:ok, descriptors} = source.list(log_dir)
    {:ok, Enum.map(descriptors, & &1.name)}
  end

  defp target_files(source, log_dir, file) do
    with {:ok, _handle} <- source.resolve_readable(log_dir, file), do: {:ok, [file]}
  end

  # -- Scanning --

  defp scan_file(source, idx, handle, name, b_since, opts, st) do
    ts_opts = TsOpts.build(source, handle, name, opts)

    case source.format(handle) do
      :json_array ->
        LogSource.stream_entries(source, handle, :json_array)
        |> scan_entries(name, ts_opts, st)

      :json_lines ->
        case seek_stream(source, idx, handle, b_since, :entry) do
          {:ok, stream} ->
            stream |> JsonLogParser.stream_from_lines() |> scan_entries(name, ts_opts, %{st | used: true})

          :miss ->
            LogSource.stream_entries(source, handle, :json_lines)
            |> scan_entries(name, ts_opts, st)
        end

      :plain ->
        case seek_stream(source, idx, handle, b_since, :line) do
          {:ok, stream} -> scan_plain(stream, name, ts_opts, %{st | used: true})
          :miss -> scan_plain(source.stream_lines(handle), name, ts_opts, st)
        end
    end
  end

  # The baseline start is the earliest bound of the whole diff: everything
  # the index PROVES to be before it (in the matching timestamp semantics)
  # is :outside for both ranges and can be skipped.
  defp seek_stream(source, idx, handle, b_since, mode) do
    with {:ok, %{offset: offset}} when offset > 0 <- idx.seek(handle, b_since, mode),
         true <- Code.ensure_loaded?(source) and function_exported?(source, :stream_lines_from, 2) do
      {:ok, source.stream_lines_from(handle, offset)}
    else
      _ -> :miss
    end
  end

  defp scan_plain(stream, name, ts_opts, st) do
    Enum.reduce(stream, st, fn line, st ->
      ts = TimestampParser.extract(line, ts_opts)

      case WindowDiff.classify(st.diff, ts) do
        :outside ->
          st

        _ ->
          info = %{
            content: line,
            instance: SourceTag.source_of(line) || name,
            ts: ts,
            error?: Patterns.matches_level?(line, :error)
          }

          %{st | diff: WindowDiff.add(st.diff, info)}
      end
    end)
  end

  defp scan_entries(stream, name, ts_opts, st) do
    Enum.reduce(stream, st, fn {entry, _idx}, st ->
      ts = TimestampParser.parse_json_value(JsonLogParser.extract_timestamp(entry), ts_opts)

      case WindowDiff.classify(st.diff, ts) do
        :outside ->
          st

        _ ->
          info = %{
            content: RollupScan.json_content(entry),
            instance: name,
            ts: ts,
            error?: ErrorExtractor.severity_at_least?(entry, :error)
          }

          %{st | diff: WindowDiff.add(st.diff, info)}
      end
    end)
  end
end
