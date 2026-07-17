defmodule McpLogServer.Tools.SearchLogs do
  @moduledoc "Search log file for a regex pattern."

  @behaviour McpLogServer.Tools.Tool

  alias McpLogServer.Protocol.ResponseFormatter
  alias McpLogServer.UseCases
  import McpLogServer.Tools.Helpers, only: [to_pos_int: 2, maybe_add_time_opts: 2]

  @impl true
  def name, do: "search_logs"

  @impl true
  def description,
    do:
      "Search log file for a regex pattern. Returns matching lines with line numbers. " <>
        "Time filtering is fail-open: lines with unparseable timestamps are NOT excluded by since/until; " <>
        "the unparsed_ts count in the result reveals when filtering was degraded this way. " <>
        "If any bound was hit (max_results cap, oversized-file skip), the result carries an " <>
        "omissions block naming exactly what was withheld — absent when you saw everything. " <>
        "With rollup: true, matches are collapsed into message templates (volatile tokens like " <>
        "timestamps/UUIDs/ids normalized away) with count, instances_seen (e.g. \"1/9\"), and " <>
        "first/last timestamps — omit file to scan ALL logs and answer \"did X happen, on how " <>
        "many instances, when?\" in one call."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        file: %{type: "string", description: "Log file name. Optional when rollup is true (then ALL log files are scanned)"},
        pattern: %{type: "string", description: "Regex pattern (case-insensitive)"},
        max_results: %{type: "integer", description: "Max results (default: 50). Not used in rollup mode", default: 50},
        context: %{type: "integer", description: "Context lines around match (default: 0)", default: 0},
        field: %{type: "string", description: "JSON field to search in (dot-notation, e.g. \"jsonPayload.message\"). Only used for JSON log files."},
        rollup: %{type: "boolean", description: "Collapse matches into message templates with count, instances_seen, first/last timestamps (default: false)", default: false},
        since: %{type: "string", description: "Only include lines from this time onward. ISO 8601 or relative shorthand (e.g. \"30m\", \"2h\")"},
        until: %{type: "string", description: "Only include lines up to this time. ISO 8601 or relative shorthand"},
        format: %{type: "string", enum: ["toon", "json"], description: "Output format (default: toon)"}
      },
      required: ["pattern"]
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
    rollup = Map.get(args, "rollup") == true

    if file == "" and not rollup do
      {:error, "file is required (or set rollup: true to scan all files)"}
    else
      opts = [max_results: max_results, context: context]
      opts = if field, do: Keyword.put(opts, :field, field), else: opts
      opts = if rollup, do: Keyword.put(opts, :rollup, true), else: opts
      opts = maybe_add_time_opts(opts, args)

      case UseCases.SearchLogs.run(log_dir, file, pattern, opts) do
        {:ok, %{rollup: true} = results} -> {:ok, ResponseFormatter.format(:rollup, results, format)}
        {:ok, results} -> {:ok, ResponseFormatter.format(:search_results, results, format)}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
