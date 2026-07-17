defmodule McpLogServer.Tools.TailLog do
  @moduledoc "Get the last N lines from a log file."

  @behaviour McpLogServer.Tools.Tool

  alias McpLogServer.Protocol.ResponseFormatter
  alias McpLogServer.UseCases
  import McpLogServer.Tools.Helpers, only: [to_pos_int: 2, maybe_add_time_opts: 2]

  @impl true
  def name, do: "tail_log"

  @impl true
  def description,
    do:
      "Get the last N lines from a log file. Use this to see recent output. " <>
        "Time filtering is fail-open: lines with unparseable timestamps are NOT excluded by since; " <>
        "the unparsed_ts count in the result reveals when filtering was degraded this way."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        file: %{type: "string", description: "Log file name (e.g., api.log)"},
        lines: %{type: "integer", description: "Number of lines (default: 50)", default: 50},
        since: %{type: "string", description: "Only include lines from this time onward. ISO 8601 or relative shorthand (e.g. \"30m\", \"2h\", \"1d\")"},
        format: %{type: "string", enum: ["toon", "json"], description: "Output format (default: toon)"}
      },
      required: ["file"]
    }
  end

  @impl true
  def execute(args, log_dir) do
    file = Map.get(args, "file", "")
    lines = to_pos_int(Map.get(args, "lines"), 50)
    format = Map.get(args, "format")
    opts = maybe_add_time_opts([], args)

    case UseCases.TailLog.run(log_dir, file, lines, opts) do
      {:ok, %{content: content, unparsed_ts: unparsed_ts}} ->
        data = %{file: file, lines: lines, content: content}
        data = if unparsed_ts != nil, do: Map.put(data, :unparsed_ts, unparsed_ts), else: data
        {:ok, ResponseFormatter.format(:tail, data, format)}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
