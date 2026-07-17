defmodule McpLogServer.UseCases.TailLog do
  @moduledoc """
  Use-case: return the last N lines of a log, with optional time filtering.

  When `:since` is active, lines whose timestamps cannot be parsed still
  pass the filter (fail-open) and are counted in the returned
  `:unparsed_ts` so the degraded filtering is observable. Without a time
  filter no timestamp parsing happens at all and `:unparsed_ts` is `nil`.

  When the file (after filtering) holds more lines than `n`, the returned
  `:omissions` block says how many older lines were withheld — a tail that
  looks complete but is not would be the `flyctl`-style silent cap this
  server refuses to reproduce. The block is empty when everything fit.
  """

  alias McpLogServer.Domain.Omissions
  alias McpLogServer.Domain.TimeFilter
  alias McpLogServer.Domain.TimestampParser
  alias McpLogServer.UseCases.Deps
  alias McpLogServer.UseCases.TsOpts

  @doc """
  Return the last `n` lines of `file`.

  ## Options

    * `:since` - only include lines from this time onward (ISO 8601 or relative shorthand)
    * `:source` - `LogSource` implementation (defaults to configured adapter)
    * `:ts_format` - compiled declared timestamp format override (tests)

  Returns `{:ok, %{content: String.t(), unparsed_ts: non_neg_integer() | nil,
  omissions: Omissions.t()}}`.
  """
  @spec run(String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok,
           %{
             content: String.t(),
             unparsed_ts: non_neg_integer() | nil,
             omissions: Omissions.t()
           }}
          | {:error, String.t()}
  def run(log_dir, file, n, opts \\ []) do
    source = Deps.log_source(opts)
    since = TimestampParser.parse_time(Keyword.get(opts, :since))

    with {:ok, handle} <- source.resolve_readable(log_dir, file) do
      {lines, unparsed} = collect(source, handle, file, since, opts)
      total = length(lines)
      content = lines |> Enum.take(-n) |> Enum.join("\n")

      {:ok,
       %{
         content: content,
         unparsed_ts: unparsed,
         omissions: Omissions.cap(Omissions.new(), :lines, total, n, "newest #{n}")
       }}
    end
  end

  defp collect(source, handle, _file, nil, _opts) do
    {Enum.to_list(source.stream_lines(handle)), nil}
  end

  defp collect(source, handle, file, since, opts) do
    ts_opts = TsOpts.build(source, handle, file, opts)

    {lines, unparsed} =
      source.stream_lines(handle)
      |> Enum.reduce({[], 0}, fn line, {acc, unparsed} ->
        case TimeFilter.classify(line, since, nil, ts_opts) do
          {true, :unparsed} -> {[line | acc], unparsed + 1}
          {true, _} -> {[line | acc], unparsed}
          {false, _} -> {acc, unparsed}
        end
      end)

    {Enum.reverse(lines), unparsed}
  end
end
