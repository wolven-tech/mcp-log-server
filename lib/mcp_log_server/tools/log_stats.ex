defmodule McpLogServer.Tools.LogStats do
  @moduledoc "Get stats for a log file."

  @behaviour McpLogServer.Tools.Tool

  alias McpLogServer.Protocol.ResponseFormatter
  alias McpLogServer.UseCases

  @impl true
  def name, do: "log_stats"

  @impl true
  def description,
    do:
      "Get stats: line count, error count, warn count, file size. Auto-detects JSON format and uses severity field for accurate counting. " <>
        "Also reports ts_parse_ratio/ts_parse_sample — the sampled share of lines with parseable timestamps. " <>
        "A low ratio means since/until filters on this file are unreliable (fail-open includes unparseable lines); " <>
        "declare the file's format via LOG_TS_FORMATS to fix it."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        file: %{type: "string", description: "Log file name"}
      },
      required: ["file"]
    }
  end

  @impl true
  def execute(args, log_dir) do
    file = Map.get(args, "file", "")

    case UseCases.CollectStats.run(log_dir, file) do
      {:ok, stats} -> {:ok, ResponseFormatter.format(:stats, stats)}
      {:error, reason} -> {:error, reason}
    end
  end
end
