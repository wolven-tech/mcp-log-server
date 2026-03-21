defmodule McpLogServer.Tools.CorrelateTool do
  @moduledoc "Search for a correlation ID across all log files."

  @behaviour McpLogServer.Tools.Tool

  alias McpLogServer.Domain.Correlator
  alias McpLogServer.Protocol.ResponseFormatter
  import McpLogServer.Tools.Helpers, only: [to_pos_int: 2]

  @impl true
  def name, do: "correlate"

  @impl true
  def description,
    do: "Search for a correlation ID (session ID, trace ID, request ID) across ALL log files. Returns a unified timeline sorted by timestamp."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        value: %{type: "string", description: "The correlation value to search for (e.g. a session ID, trace ID)"},
        field: %{type: "string", description: "Restrict search to this field (dot-notation for JSON, field=value for plain text)"},
        max_results: %{type: "integer", description: "Max total results across all files (default: 200)", default: 200},
        format: %{type: "string", enum: ["toon", "json"], description: "Output format (default: toon)"}
      },
      required: ["value"]
    }
  end

  @impl true
  def execute(args, log_dir) do
    value = Map.get(args, "value", "")
    field = Map.get(args, "field")
    max_results = to_pos_int(Map.get(args, "max_results"), 200)
    format = Map.get(args, "format")

    opts = [max_results: max_results]
    opts = if field, do: Keyword.put(opts, :field, field), else: opts

    case Correlator.correlate(log_dir, value, opts) do
      {:ok, result} ->
        {:ok, ResponseFormatter.format(:correlation, result, format)}
    end
  end
end
