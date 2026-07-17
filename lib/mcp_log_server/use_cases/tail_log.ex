defmodule McpLogServer.UseCases.TailLog do
  @moduledoc """
  Use-case: return the last N lines of a log, with optional time filtering.
  """

  alias McpLogServer.Domain.TimeFilter
  alias McpLogServer.Domain.TimestampParser
  alias McpLogServer.UseCases.Deps

  @doc """
  Return the last `n` lines of `file` as a single string.

  ## Options

    * `:since` - only include lines from this time onward (ISO 8601 or relative shorthand)
    * `:source` - `LogSource` implementation (defaults to configured adapter)
  """
  @spec run(String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def run(log_dir, file, n, opts \\ []) do
    source = Deps.log_source(opts)
    since = TimestampParser.parse_time(Keyword.get(opts, :since))

    with {:ok, handle} <- source.resolve_readable(log_dir, file) do
      content =
        handle
        |> source.stream_lines()
        |> Stream.filter(fn line -> TimeFilter.in_range?(line, since, nil) end)
        |> Enum.to_list()
        |> Enum.take(-n)
        |> Enum.join("\n")

      {:ok, content}
    end
  end
end
