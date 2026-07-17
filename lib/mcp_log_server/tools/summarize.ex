defmodule McpLogServer.Tools.Summarize do
  @moduledoc "Diff a time window against its baseline: new/gone templates, error rate, volume."

  @behaviour McpLogServer.Tools.Tool

  alias McpLogServer.Protocol.ResponseFormatter
  alias McpLogServer.UseCases
  import McpLogServer.Tools.Helpers, only: [to_pos_int: 2, maybe_add_time_opts: 2]

  @impl true
  def name, do: "summarize"

  @impl true
  def description,
    do:
      "Answer \"what changed?\" in one call: diff a time window against the equal-length window " <>
        "immediately before it (the baseline). Returns new_templates (message templates present " <>
        "in the window but absent in the baseline, with count, instances_seen, first_ts, sample), " <>
        "gone_templates (present before, gone now), error_rate (errors/min window vs baseline " <>
        "with delta), and volume (lines/min per source with delta). Give window (e.g. \"15m\") " <>
        "or explicit since/until; baseline overrides the baseline length. Honesty fields: " <>
        "unparsed_ts counts lines that could not be placed in time (they fold into BOTH ranges, " <>
        "so they can never fabricate a diff row), omissions reports skipped files and capped " <>
        "lists, index_used reports whether the persistent index accelerated the scan (results " <>
        "are identical without it)."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        window: %{type: "string", description: "Window length as relative shorthand (e.g. \"15m\", \"2h\"), ending now (or at until). Alternative: give since/until"},
        since: %{type: "string", description: "Explicit window start (ISO 8601 or relative shorthand). Used when window is omitted"},
        until: %{type: "string", description: "Window end (ISO 8601 or relative shorthand). Default: now"},
        baseline: %{type: "string", description: "Baseline length (e.g. \"1h\"), immediately before the window. Default: same length as the window"},
        file: %{type: "string", description: "Log file name. Omit to scan ALL log files"},
        max_templates: %{type: "integer", description: "Cap per template list (default: 20)", default: 20},
        format: %{type: "string", enum: ["toon", "json"], description: "Output format (default: toon)"}
      }
    }
  end

  @impl true
  def execute(args, log_dir) do
    format = Map.get(args, "format")

    opts = [max_templates: to_pos_int(Map.get(args, "max_templates"), 20)]
    opts = maybe_add_time_opts(opts, args)

    opts =
      Enum.reduce(["window", "baseline", "file"], opts, fn key, opts ->
        case Map.get(args, key) do
          v when is_binary(v) and v != "" -> Keyword.put(opts, String.to_existing_atom(key), v)
          _ -> opts
        end
      end)

    case UseCases.Summarize.run(log_dir, opts) do
      {:ok, result} -> {:ok, ResponseFormatter.format(:summarize, result, format)}
      {:error, reason} -> {:error, reason}
    end
  end
end
