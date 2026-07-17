defmodule McpLogServer.UseCases.TraceIds do
  @moduledoc """
  Use-case: discover unique values for a correlation field across logs,
  with per-value counts and first/last seen timestamps.
  """

  alias McpLogServer.Domain.Correlator
  alias McpLogServer.Ports.LogSource
  alias McpLogServer.UseCases.Deps

  @doc """
  Extract unique values for `field` across all logs in `log_dir`.

  ## Options

    * `:file` - scan a single file instead of all files
    * `:max_values` - max unique values to return (default: 50)
    * `:source` - `LogSource` implementation (defaults to configured adapter)
  """
  @spec run(String.t(), String.t(), keyword()) :: {:ok, [map()]}
  def run(log_dir, field, opts \\ []) do
    source = Deps.log_source(opts)
    max_values = Keyword.get(opts, :max_values, 50)
    file_filter = Keyword.get(opts, :file)

    {:ok, files} = source.list(log_dir)

    files =
      if file_filter do
        Enum.filter(files, &(&1.name == file_filter))
      else
        files
      end

    pairs =
      Enum.flat_map(files, fn file_info ->
        case source.resolve(log_dir, file_info.name) do
          {:ok, handle} -> field_values(source, handle, field)
          {:error, _} -> []
        end
      end)

    {:ok, Correlator.aggregate_field_values(pairs, max_values)}
  end

  defp field_values(source, handle, field) do
    case source.format(handle) do
      fmt when fmt in [:json_lines, :json_array] ->
        LogSource.stream_entries(source, handle, fmt)
        |> Correlator.json_field_values(field)

      :plain ->
        handle
        |> source.stream_lines()
        |> Correlator.plain_field_values(field)
    end
  end
end
