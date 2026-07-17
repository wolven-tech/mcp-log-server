defmodule McpLogServer.Tools.AllErrors do
  @moduledoc "Get errors from all log files at once."

  @behaviour McpLogServer.Tools.Tool

  alias McpLogServer.Protocol.ResponseFormatter
  alias McpLogServer.UseCases
  import McpLogServer.Tools.Helpers, only: [to_pos_int: 2, maybe_add_time_opts: 2]

  @impl true
  def name, do: "all_errors"

  @impl true
  def description,
    do: "Get errors from ALL log files at once. Best first call for health overview. Always returns TOON format. Tip: Use JSON structured logs with a severity field to eliminate false positives — see docs/guides/LOG_STRUCTURING.md."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        lines: %{type: "integer", description: "Max errors per file (default: 20)", default: 20},
        level: %{type: "string", enum: ["fatal", "error", "warn", "info"], description: "Minimum severity level (default: warn)"},
        exclude: %{type: "string", description: "Regex pattern — lines matching this are excluded from results"},
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
    opts = maybe_add_time_opts(opts, args)

    {:ok, %{results: results, skipped: skipped}} =
      UseCases.AllErrors.run(log_dir, lines_per_file, opts)

    output = ResponseFormatter.format(:multi_file_errors, results)

    output =
      if skipped != [] do
        output <> "\n\n" <> Enum.join(skipped, "\n")
      else
        output
      end

    {:ok, output}
  end
end
