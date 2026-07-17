defmodule McpLogServer.UseCases.ListLogs do
  @moduledoc """
  Use-case: enumerate available logs.

  Projects `LogSource` descriptors down to the presentation shape so
  adapter-internal metadata (e.g. `live?`) never leaks into tool output.
  """

  alias McpLogServer.UseCases.Deps

  @output_keys [:name, :path, :size_bytes, :modified, :warning]

  @spec run(String.t(), keyword()) :: {:ok, [map()]}
  def run(log_dir, opts \\ []) do
    {:ok, files} = Deps.log_source(opts).list(log_dir)
    {:ok, Enum.map(files, &Map.take(&1, @output_keys))}
  end
end
