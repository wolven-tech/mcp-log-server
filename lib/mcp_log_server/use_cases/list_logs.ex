defmodule McpLogServer.UseCases.ListLogs do
  @moduledoc """
  Use-case: enumerate available logs.

  Projects `LogSource` descriptors down to the presentation shape. Live
  streamed sources (declared via `LOG_SOURCES`) are surfaced as
  `live: true` with their source name and worker `status`
  (`:running` / `:backing_off` / `:dead`); static files carry
  `live: false`. Every entry carries the same key set so tabular (TOON)
  rendering keeps consistent columns regardless of which entry comes first.
  """

  alias McpLogServer.UseCases.Deps

  @output_keys [:name, :path, :size_bytes, :modified, :warning]

  @spec run(String.t(), keyword()) :: {:ok, [map()]}
  def run(log_dir, opts \\ []) do
    {:ok, files} = Deps.log_source(opts).list(log_dir)
    {:ok, Enum.map(files, &present/1)}
  end

  defp present(descriptor) do
    descriptor
    |> Map.take(@output_keys)
    |> Map.merge(%{
      live: Map.get(descriptor, :live?, false),
      source: Map.get(descriptor, :source),
      status: Map.get(descriptor, :status)
    })
  end
end
