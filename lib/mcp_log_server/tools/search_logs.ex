defmodule McpLogServer.Tools.SearchLogs do
  @moduledoc "Search log file for a regex pattern."

  @behaviour McpLogServer.Tools.Tool

  alias McpLogServer.Domain.LogSearch
  alias McpLogServer.Protocol.ResponseFormatter
  import McpLogServer.Tools.Helpers, only: [to_pos_int: 2, maybe_add_time_opts: 2]

  @impl true
  def name, do: "search_logs"

  @impl true
  def description,
    do: "Search log file for a regex pattern. Returns matching lines with line numbers."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        file: %{type: "string", description: "Log file name"},
        pattern: %{type: "string", description: "Regex pattern (case-insensitive)"},
        max_results: %{type: "integer", description: "Max results (default: 50)", default: 50},
        context: %{type: "integer", description: "Context lines around match (default: 0)", default: 0},
        field: %{type: "string", description: "JSON field to search in (dot-notation, e.g. \"jsonPayload.message\"). Only used for JSON log files."},
        since: %{type: "string", description: "Only include lines from this time onward. ISO 8601 or relative shorthand (e.g. \"30m\", \"2h\")"},
        until: %{type: "string", description: "Only include lines up to this time. ISO 8601 or relative shorthand"},
        format: %{type: "string", enum: ["toon", "json"], description: "Output format (default: toon)"}
      },
      required: ["file", "pattern"]
    }
  end

  @impl true
  def execute(args, log_dir) do
    file = Map.get(args, "file", "")
    pattern = Map.get(args, "pattern", "")
    max_results = to_pos_int(Map.get(args, "max_results"), 50)
    context = to_pos_int(Map.get(args, "context"), 0)
    format = Map.get(args, "format")
    field = Map.get(args, "field")

    opts = [max_results: max_results, context: context]
    opts = if field, do: Keyword.put(opts, :field, field), else: opts
    opts = maybe_add_time_opts(opts, args)

    case LogSearch.search(log_dir, file, pattern, opts) do
      {:ok, results} -> {:ok, ResponseFormatter.format(:search_results, results, format)}
      {:error, reason} -> {:error, reason}
    end
  end
end
