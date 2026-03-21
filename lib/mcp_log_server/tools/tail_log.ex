defmodule McpLogServer.Tools.TailLog do
  @moduledoc "Get the last N lines from a log file."

  @behaviour McpLogServer.Tools.Tool

  alias McpLogServer.Domain.LogTail
  alias McpLogServer.Protocol.ResponseFormatter
  import McpLogServer.Tools.Helpers, only: [to_pos_int: 2, maybe_add_time_opts: 2]

  @impl true
  def name, do: "tail_log"

  @impl true
  def description,
    do: "Get the last N lines from a log file. Use this to see recent output."

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

    case LogTail.tail(log_dir, file, lines, opts) do
      {:ok, content} ->
        {:ok, ResponseFormatter.format(:tail, %{file: file, lines: lines, content: content}, format)}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
