defmodule McpLogServer.Tools.CorrelateTool do
  @moduledoc "Search for a correlation ID across all log files, or correlate around a regex anchor."

  @behaviour McpLogServer.Tools.Tool

  alias McpLogServer.Protocol.ResponseFormatter
  alias McpLogServer.UseCases
  import McpLogServer.Tools.Helpers, only: [to_pos_int: 2]

  @impl true
  def name, do: "correlate"

  @impl true
  def description,
    do:
      "Search for a correlation ID (session ID, trace ID, request ID) across ALL log files. " <>
        "Returns a unified timeline sorted by timestamp. Matches whose timestamps cannot be parsed " <>
        "are still included (fail-open) but sort last; the unparsed_ts count in the result reveals how many. " <>
        "No id in hand? Pass anchor: {pattern, window} instead — every regex match becomes a time anchor " <>
        "and the result is the merged cross-source timeline of ALL lines within the window around each hit " <>
        "(overlapping windows merge into one section). value and anchor are mutually exclusive. " <>
        "If any cap was hit (max_results, max window sections), the result carries an omissions block " <>
        "saying how many matches/sections were withheld — absent when the timeline is complete."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        value: %{type: "string", description: "The correlation value to search for (e.g. a session ID, trace ID). Mutually exclusive with anchor"},
        field: %{type: "string", description: "Restrict search to this field (dot-notation for JSON, field=value for plain text). Only with value"},
        anchor: %{
          type: "object",
          description: "Correlate around a symptom regex instead of an id: every match becomes a time anchor. Mutually exclusive with value",
          properties: %{
            pattern: %{type: "string", description: "Regex (case-insensitive) whose matches become anchors"},
            window: %{type: "string", description: "Symmetric window around each anchor, e.g. \"±10s\", \"±2m\" (default ±30s)"},
            before: %{type: "string", description: "Asymmetric window: duration before each anchor, e.g. \"10s\""},
            after: %{type: "string", description: "Asymmetric window: duration after each anchor, e.g. \"30s\""}
          },
          required: ["pattern"]
        },
        max_results: %{type: "integer", description: "Max total results across all files (default: 200)", default: 200},
        max_sections: %{type: "integer", description: "Anchor mode: max window sections (default: 5)", default: 5},
        format: %{type: "string", enum: ["toon", "json"], description: "Output format (default: toon)"}
      }
    }
  end

  @impl true
  def execute(args, log_dir) do
    value = Map.get(args, "value")
    anchor = Map.get(args, "anchor")

    cond do
      is_binary(value) and value != "" and is_map(anchor) ->
        {:error, "value and anchor are mutually exclusive — pass exactly one"}

      is_map(anchor) ->
        execute_anchor(anchor, args, log_dir)

      is_binary(value) and value != "" ->
        execute_value(value, args, log_dir)

      true ->
        {:error, "either value (id mode) or anchor (regex mode) is required"}
    end
  end

  defp execute_value(value, args, log_dir) do
    field = Map.get(args, "field")
    max_results = to_pos_int(Map.get(args, "max_results"), 200)
    format = Map.get(args, "format")

    opts = [max_results: max_results]
    opts = if field, do: Keyword.put(opts, :field, field), else: opts

    case UseCases.Correlate.run(log_dir, value, opts) do
      {:ok, result} ->
        {:ok, ResponseFormatter.format(:correlation, result, format)}
    end
  end

  defp execute_anchor(anchor, args, log_dir) do
    pattern = Map.get(anchor, "pattern")
    format = Map.get(args, "format")

    if not is_binary(pattern) or pattern == "" do
      {:error, "anchor.pattern is required"}
    else
      opts = [
        max_results: to_pos_int(Map.get(args, "max_results"), 200),
        max_sections: to_pos_int(Map.get(args, "max_sections"), 5)
      ]

      opts =
        case window_spec(anchor) do
          nil -> opts
          window -> Keyword.put(opts, :window, window)
        end

      case UseCases.Correlate.run_anchor(log_dir, pattern, opts) do
        {:ok, result} -> {:ok, ResponseFormatter.format(:anchor_correlation, result, format)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Asymmetric before/after beats the symmetric window string when both
  # appear; AnchorWindow validates the contents either way.
  defp window_spec(anchor) do
    before_spec = Map.get(anchor, "before")
    after_spec = Map.get(anchor, "after")

    cond do
      before_spec != nil or after_spec != nil -> %{"before" => before_spec, "after" => after_spec}
      is_binary(Map.get(anchor, "window")) -> Map.get(anchor, "window")
      true -> nil
    end
  end
end
