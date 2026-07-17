defmodule McpLogServer.Tools.TimeRange do
  @moduledoc "Get the earliest and latest timestamps in a log file."

  @behaviour McpLogServer.Tools.Tool

  alias McpLogServer.Protocol.ResponseFormatter
  alias McpLogServer.UseCases

  @impl true
  def name, do: "time_range"

  @impl true
  def description,
    do: "Get the earliest and latest timestamps in a log file, plus the time span. Works with plain text and JSON logs."

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

    case UseCases.TimeRange.run(log_dir, file) do
      {:ok, range} -> {:ok, ResponseFormatter.format(:stats, range)}
      {:error, reason} -> {:error, reason}
    end
  end
end
