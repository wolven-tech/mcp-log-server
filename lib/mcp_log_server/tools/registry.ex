defmodule McpLogServer.Tools.Registry do
  @moduledoc """
  Tool definitions for the MCP tools/list response.
  Delegates to individual tool modules that implement the Tool behaviour.
  """

  @tools [
    McpLogServer.Tools.ListLogs,
    McpLogServer.Tools.TailLog,
    McpLogServer.Tools.SearchLogs,
    McpLogServer.Tools.GetErrors,
    McpLogServer.Tools.LogStats,
    McpLogServer.Tools.TimeRange,
    McpLogServer.Tools.CorrelateTool,
    McpLogServer.Tools.TraceIds,
    McpLogServer.Tools.AllErrors,
    McpLogServer.Tools.Aggregate,
    McpLogServer.Tools.Summarize,
    McpLogServer.Tools.SourceManifest,
    McpLogServer.Tools.SyncLogs
  ]

  @tool_map Map.new(@tools, fn mod -> {mod.name(), mod} end)

  @spec definitions() :: [map()]
  def definitions do
    Enum.map(@tools, fn mod ->
      read_only? = mod.name() != "sync_logs"

      %{
        name: mod.name(),
        title: title(mod.name()),
        description: mod.description(),
        inputSchema: mod.schema(),
        outputSchema: %{
          type: "object",
          properties: %{
            context: %{type: "object"},
            result: %{}
          },
          required: ["context", "result"],
          additionalProperties: true
        },
        annotations: %{
          readOnlyHint: read_only?,
          destructiveHint: false,
          idempotentHint: true,
          openWorldHint: not read_only?
        }
      }
    end)
  end

  @spec lookup(String.t()) :: module() | nil
  def lookup(name), do: Map.get(@tool_map, name)

  defp title(name) do
    name |> String.replace("_", " ") |> String.capitalize()
  end
end
