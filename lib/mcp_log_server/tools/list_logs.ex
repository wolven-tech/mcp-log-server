defmodule McpLogServer.Tools.ListLogs do
  @moduledoc "List all available log files with size and last modified time."

  @behaviour McpLogServer.Tools.Tool

  alias McpLogServer.Domain.FileAccess
  alias McpLogServer.Protocol.ResponseFormatter

  @impl true
  def name, do: "list_logs"

  @impl true
  def description, do: "List all available log files with size and last modified time"

  @impl true
  def schema do
    %{type: "object", properties: %{}, required: []}
  end

  @impl true
  def execute(_args, log_dir) do
    case FileAccess.list_files(log_dir) do
      {:ok, files} -> {:ok, ResponseFormatter.format(:entries, files)}
    end
  end
end
