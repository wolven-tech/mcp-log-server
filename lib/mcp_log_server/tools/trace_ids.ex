defmodule McpLogServer.Tools.TraceIds do
  @moduledoc "Discover unique values for a correlation field across log files."

  @behaviour McpLogServer.Tools.Tool

  alias McpLogServer.Domain.Correlator
  alias McpLogServer.Protocol.ResponseFormatter
  import McpLogServer.Tools.Helpers, only: [to_pos_int: 2]

  @impl true
  def name, do: "trace_ids"

  @impl true
  def description,
    do: "Discover unique values for a correlation field (e.g. sessionId, traceId) across log files. Returns values with count and time range."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        field: %{type: "string", description: "The field to extract values from (e.g. \"sessionId\", \"traceId\")"},
        file: %{type: "string", description: "Optional: scan only this file instead of all files"},
        max_values: %{type: "integer", description: "Max unique values to return (default: 50)", default: 50}
      },
      required: ["field"]
    }
  end

  @impl true
  def execute(args, log_dir) do
    field = Map.get(args, "field", "")
    max_values = to_pos_int(Map.get(args, "max_values"), 50)
    file = Map.get(args, "file")

    opts = [max_values: max_values]
    opts = if file, do: Keyword.put(opts, :file, file), else: opts

    case Correlator.extract_trace_ids(log_dir, field, opts) do
      {:ok, results} ->
        {:ok, ResponseFormatter.format(:entries, results)}
    end
  end
end
