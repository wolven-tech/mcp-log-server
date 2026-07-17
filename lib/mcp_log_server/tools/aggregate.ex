defmodule McpLogServer.Tools.Aggregate do
  @moduledoc "Aggregate/facet on a JSON field across log lines."

  @behaviour McpLogServer.Tools.Tool

  alias McpLogServer.Protocol.ResponseFormatter
  alias McpLogServer.UseCases
  import McpLogServer.Tools.Helpers, only: [to_pos_int: 2, maybe_add_time_opts: 2]

  @impl true
  def name, do: "aggregate"

  @impl true
  def description,
    do:
      "Aggregate on a JSON field (dot-path) across a log file or ALL files. " <>
        "op: \"exists\" answers \"did any line emit this field?\" with lines_with_field/lines_without " <>
        "and one sample line; \"values\" returns a histogram of distinct values with counts; " <>
        "\"count\" returns total occurrences. Lines that are not JSON objects are counted separately " <>
        "(non_json) — a plain-text line can never prove field absence. The values histogram caps " <>
        "distinct values and reports a hit cap in an omissions block; files skipped by the size " <>
        "guardrail appear in omissions.skipped_files."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        field: %{type: "string", description: "Dot-path into parsed JSON lines (e.g. \"fields.region\", \"jsonPayload.gated\")"},
        op: %{type: "string", enum: ["exists", "values", "count"], description: "Aggregation: exists (presence proof + sample), values (histogram), count (total occurrences)"},
        file: %{type: "string", description: "Log file name. Omit to scan ALL log files"},
        pattern: %{type: "string", description: "Regex pre-filter (case-insensitive) — only lines matching it are aggregated"},
        max_values: %{type: "integer", description: "Cap on distinct values for op: values (default: 50)", default: 50},
        since: %{type: "string", description: "Only include lines from this time onward. ISO 8601 or relative shorthand (e.g. \"30m\", \"2h\")"},
        until: %{type: "string", description: "Only include lines up to this time. ISO 8601 or relative shorthand"},
        format: %{type: "string", enum: ["toon", "json"], description: "Output format (default: toon)"}
      },
      required: ["field", "op"]
    }
  end

  @impl true
  def execute(args, log_dir) do
    field = Map.get(args, "field", "")
    op = Map.get(args, "op", "")
    file = Map.get(args, "file")
    format = Map.get(args, "format")

    opts = [max_values: to_pos_int(Map.get(args, "max_values"), 50)]

    opts =
      case Map.get(args, "pattern") do
        p when is_binary(p) and p != "" -> Keyword.put(opts, :pattern, p)
        _ -> opts
      end

    opts = maybe_add_time_opts(opts, args)

    case UseCases.Aggregate.run(log_dir, file, field, op, opts) do
      {:ok, result} -> {:ok, ResponseFormatter.format(:aggregate, result, format)}
      {:error, reason} -> {:error, reason}
    end
  end
end
