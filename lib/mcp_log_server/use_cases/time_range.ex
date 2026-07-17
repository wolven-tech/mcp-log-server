defmodule McpLogServer.UseCases.TimeRange do
  @moduledoc """
  Use-case: report the earliest/latest timestamps and span of one log by
  sampling its first and last lines.
  """

  alias McpLogServer.Domain.TimeRangeCalc
  alias McpLogServer.UseCases.Deps
  alias McpLogServer.UseCases.TsOpts

  @spec run(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def run(log_dir, file, opts \\ []) do
    source = Deps.log_source(opts)

    with {:ok, handle} <- source.resolve_readable(log_dir, file) do
      format = source.format(handle)
      ts_opts = TsOpts.build(source, handle, file, opts)

      handle
      |> source.stream_lines()
      |> TimeRangeCalc.compute(format, Path.basename(file), ts_opts)
    end
  end
end
