defmodule McpLogServer.UseCases.TailLog do
  @moduledoc """
  Use-case: return the last N lines of a log, with optional time filtering
  and an opaque polling cursor.

  When `:since` is active, lines whose timestamps cannot be parsed still
  pass the filter (fail-open) and are counted in the returned
  `:unparsed_ts` so the degraded filtering is observable. Without a time
  filter no timestamp parsing happens at all and `:unparsed_ts` is `nil`.

  When the file (after filtering) holds more lines than `n`, the returned
  `:omissions` block says how many older lines were withheld — a tail that
  looks complete but is not would be the `flyctl`-style silent cap this
  server refuses to reproduce. The block is empty when everything fit.

  Every result carries a fresh `:cursor` (`McpLogServer.Domain.Cursor`).
  Passing it back via `:cursor` returns only lines appended since — the
  polling loop for a live deploy without re-fetching the same window. If
  the file was rotated/truncated (cursor invalid), the result is a flagged
  full window with `:cursor_reset` true instead of wrong increments.
  """

  alias McpLogServer.Domain.Cursor
  alias McpLogServer.Domain.Omissions
  alias McpLogServer.Domain.TimeFilter
  alias McpLogServer.Domain.TimestampParser
  alias McpLogServer.UseCases.Deps
  alias McpLogServer.UseCases.TsOpts

  @doc """
  Return the last `n` lines of `file`.

  ## Options

    * `:since` - only include lines from this time onward (ISO 8601 or relative shorthand)
    * `:cursor` - opaque cursor from a previous call; only lines after it are returned
    * `:source` - `LogSource` implementation (defaults to configured adapter)
    * `:ts_format` - compiled declared timestamp format override (tests)

  Returns `{:ok, %{content: String.t(), unparsed_ts: non_neg_integer() | nil,
  cursor: String.t(), cursor_reset: boolean(), omissions: Omissions.t()}}`.
  """
  @spec run(String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok,
           %{
             content: String.t(),
             unparsed_ts: non_neg_integer() | nil,
             cursor: String.t(),
             cursor_reset: boolean(),
             omissions: Omissions.t()
           }}
          | {:error, String.t()}
  def run(log_dir, file, n, opts \\ []) do
    source = Deps.log_source(opts)
    since = TimestampParser.parse_time(Keyword.get(opts, :since))

    with {:ok, handle} <- source.resolve_readable(log_dir, file),
         {:ok, content} <- source.read(handle) do
      basename = Path.basename(file)
      {start_offset, reset?} = Cursor.resolve(Keyword.get(opts, :cursor), basename, content)
      {lines, _start_line} = Cursor.slice_lines(content, start_offset)

      {lines, unparsed} = filter(source, handle, file, lines, since, opts)
      total = length(lines)
      out = lines |> Enum.take(-n) |> Enum.join("\n")

      {:ok,
       %{
         content: out,
         unparsed_ts: unparsed,
         cursor: Cursor.encode(Cursor.state_for(basename, content)),
         cursor_reset: reset?,
         omissions: Omissions.cap(Omissions.new(), :lines, total, n, "newest #{n}")
       }}
    end
  end

  defp filter(_source, _handle, _file, lines, nil, _opts), do: {lines, nil}

  defp filter(source, handle, file, lines, since, opts) do
    ts_opts = TsOpts.build(source, handle, file, opts)

    {kept, unparsed} =
      Enum.reduce(lines, {[], 0}, fn line, {acc, unparsed} ->
        case TimeFilter.classify(line, since, nil, ts_opts) do
          {true, :unparsed} -> {[line | acc], unparsed + 1}
          {true, _} -> {[line | acc], unparsed}
          {false, _} -> {acc, unparsed}
        end
      end)

    {Enum.reverse(kept), unparsed}
  end
end
