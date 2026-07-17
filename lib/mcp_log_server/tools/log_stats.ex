defmodule McpLogServer.Tools.LogStats do
  @moduledoc "Get stats for a log file."

  @behaviour McpLogServer.Tools.Tool

  alias McpLogServer.Protocol.ResponseFormatter
  alias McpLogServer.UseCases

  @impl true
  def name, do: "log_stats"

  @impl true
  def description,
    do: "Get stats: line count, error count, warn count, file size. Auto-detects JSON format and uses severity field for accurate counting."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        file: %{type: "string", description: "Log file name"}
      },
      required: ["file"]
    }
  end

  @impl true
  def execute(args, log_dir) do
    file = Map.get(args, "file", "")

    case UseCases.CollectStats.run(log_dir, file) do
      {:ok, stats} -> {:ok, ResponseFormatter.format(:stats, stats)}
      {:error, reason} -> {:error, reason}
    end
  end
end
