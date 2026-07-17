defmodule McpLogServer.UseCases.TraceIds do
  @moduledoc """
  Use-case: discover unique values for a correlation field across logs,
  with per-value counts and first/last seen timestamps.
  """

  alias McpLogServer.Domain.Correlator
  alias McpLogServer.Domain.Omissions
  alias McpLogServer.Ports.LogSource
  alias McpLogServer.UseCases.Deps

  @doc """
  Extract unique values for `field` across all logs in `log_dir`.

  Returns `{:ok, %{entries: rows}}`; when the `max_values` cap withheld
  values, the result also carries an `omissions` block saying how many —
  a capped list must never look exhaustive.

  ## Options

    * `:file` - scan a single file instead of all files
    * `:max_values` - max unique values to return (default: 50)
    * `:source` - `LogSource` implementation (defaults to configured adapter)
  """
  @spec run(String.t(), String.t(), keyword()) ::
          {:ok, %{required(:entries) => [map()], optional(:omissions) => Omissions.t()}}
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

    all_values = Correlator.aggregate_field_values(pairs)
    rows = Enum.take(all_values, max_values)

    omissions =
      Omissions.cap(
        Omissions.new(),
        :values,
        length(all_values),
        max_values,
        "top #{max_values} by count"
      )

    {:ok, Omissions.attach(%{entries: rows}, omissions)}
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
