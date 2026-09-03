defmodule McpLogServer.Tools.SourceManifest do
  @moduledoc "Describe log coverage, freshness, timestamp quality, and source health."

  @behaviour McpLogServer.Tools.Tool

  alias McpLogServer.UseCases

  @impl true
  def name, do: "source_manifest"

  @impl true
  def description,
    do:
      "Inspect source coverage, freshness, retention evidence, timestamp quality, and warnings before searching logs"

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        file: %{type: "string", description: "Optional exact log file name"}
      }
    }
  end

  @impl true
  def execute(args, log_dir) do
    requested_file = Map.get(args, "file")

    with {:ok, files} <- UseCases.ListLogs.run(log_dir) do
      files =
        case requested_file do
          file when is_binary(file) and file != "" -> Enum.filter(files, &(&1.name == file))
          _ -> files
        end

      if requested_file not in [nil, ""] and files == [] do
        {:error, "log source not found: #{requested_file}"}
      else
        sources = Enum.map(files, &describe(log_dir, &1))

        latest =
          sources |> Enum.map(& &1.latest) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end)

        Jason.encode(%{
          freshThrough: latest,
          sourceCount: length(sources),
          sources: sources,
          completeness: %{
            complete: Enum.all?(sources, &is_nil(&1.warning)),
            reason: if(Enum.any?(sources, & &1.warning), do: "source_warning", else: nil),
            sourcesRequested: length(files),
            sourcesRead: Enum.count(sources, &is_nil(&1.warning)),
            sourcesSkipped: Enum.filter(sources, & &1.warning) |> Enum.map(& &1.id)
          }
        })
        |> case do
          {:ok, json} -> {:ok, json}
          {:error, error} -> {:error, Exception.message(error)}
        end
      end
    end
  end

  defp describe(log_dir, file) do
    stats = value_or_warning(UseCases.CollectStats.run(log_dir, file.name))
    range = value_or_warning(UseCases.TimeRange.run(log_dir, file.name))

    %{
      id: file.source || file.name,
      file: file.name,
      live: file.live,
      status: file.status,
      sizeBytes: value(stats, :size_bytes, file.size_bytes),
      lines: value(stats, :line_count),
      oldest: value(range, :earliest),
      latest: value(range, :latest),
      timestampParseRatio: value(stats, :ts_parse_ratio),
      timestampParseSample: value(stats, :ts_parse_sample),
      modified: file.modified,
      warning: Map.get(file, :warning) || value(stats, :warning) || value(range, :warning)
    }
  end

  defp value_or_warning({:ok, value}), do: value
  defp value_or_warning({:error, warning}), do: %{warning: warning}

  defp value(map, key, default \\ nil), do: Map.get(map, key, default)
end
