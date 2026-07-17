defmodule McpLogServer.Tools.AllErrors do
  @moduledoc "Get errors from all log files at once."

  @behaviour McpLogServer.Tools.Tool

  alias McpLogServer.Domain.Omissions
  alias McpLogServer.Protocol.ResponseFormatter
  alias McpLogServer.UseCases
  import McpLogServer.Tools.Helpers, only: [to_pos_int: 2, maybe_add_time_opts: 2]

  @impl true
  def name, do: "all_errors"

  @impl true
  def description,
    do:
      "Get errors from ALL log files at once. Best first call for health overview. Always returns TOON format. " <>
        "Time filtering is fail-open: lines with unparseable timestamps are NOT excluded by since; " <>
        "the unparsed_ts count in the result reveals when filtering was degraded this way. " <>
        "If any bound was hit (per-file cap, oversized-file skip), the result carries an omissions " <>
        "block naming exactly what was withheld — absent when you saw everything. " <>
        "With rollup: true, errors are collapsed into message templates with count, instances_seen " <>
        "(e.g. \"1/9\"), and first/last timestamps. " <>
        "Tip: Use JSON structured logs with a severity field to eliminate false positives — see docs/guides/LOG_STRUCTURING.md."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        lines: %{type: "integer", description: "Max errors per file (default: 20). Not used in rollup mode", default: 20},
        level: %{type: "string", enum: ["fatal", "error", "warn", "info"], description: "Minimum severity level (default: warn)"},
        exclude: %{type: "string", description: "Regex pattern — lines matching this are excluded from results"},
        rollup: %{type: "boolean", description: "Collapse errors into message templates with count, instances_seen, first/last timestamps (default: false)", default: false},
        since: %{type: "string", description: "Only include errors from this time onward. ISO 8601 or relative shorthand (e.g. \"1h\")"}
      },
      required: []
    }
  end

  @impl true
  def execute(args, log_dir) do
    lines_per_file = to_pos_int(Map.get(args, "lines"), 20)

    opts = []
    opts = case Map.get(args, "level") do
      level when level in ~w(fatal error warn info) ->
        Keyword.put(opts, :level, String.to_existing_atom(level))
      _ -> opts
    end
    opts = case Map.get(args, "exclude") do
      nil -> opts
      exclude when is_binary(exclude) -> Keyword.put(opts, :exclude, exclude)
      _ -> opts
    end
    opts = if Map.get(args, "rollup") == true, do: Keyword.put(opts, :rollup, true), else: opts
    opts = maybe_add_time_opts(opts, args)

    case UseCases.AllErrors.run(log_dir, lines_per_file, opts) do
      {:ok, %{rollup: true} = result} ->
        {:ok, ResponseFormatter.format(:rollup, result, nil)}

      {:ok, %{results: results, unparsed_ts: unparsed_ts, omissions: omissions}} ->
        output = ResponseFormatter.format(:multi_file_errors, results)

        output =
          if unparsed_ts != nil do
            output <> "\n\n# unparsed_ts: #{unparsed_ts}"
          else
            output
          end

        output =
          if Omissions.empty?(omissions) do
            output
          else
            output <> "\n\n# omissions: #{Jason.encode!(omissions)}"
          end

        {:ok, output}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
