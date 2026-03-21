defmodule McpLogServer.Tools.GetErrors do
  @moduledoc "Extract error/warning lines from a log file."

  @behaviour McpLogServer.Tools.Tool

  alias McpLogServer.Domain.ErrorExtractor
  alias McpLogServer.Protocol.ResponseFormatter
  import McpLogServer.Tools.Helpers, only: [to_pos_int: 2, maybe_add_time_opts: 2]

  @impl true
  def name, do: "get_errors"

  @impl true
  def description,
    do: "Extract error/warning lines from a log file. Use level to control minimum severity."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        file: %{type: "string", description: "Log file name"},
        lines: %{type: "integer", description: "Max error lines (default: 100)", default: 100},
        level: %{type: "string", enum: ["fatal", "error", "warn", "info"], description: "Minimum severity level (default: warn)"},
        exclude: %{type: "string", description: "Regex pattern — lines matching this are excluded from results"},
        since: %{type: "string", description: "Only include errors from this time onward. ISO 8601 or relative shorthand (e.g. \"1h\", \"30m\")"},
        until: %{type: "string", description: "Only include errors up to this time. ISO 8601 or relative shorthand"},
        format: %{type: "string", enum: ["toon", "json"], description: "Output format (default: toon)"}
      },
      required: ["file"]
    }
  end

  @impl true
  def execute(args, log_dir) do
    file = Map.get(args, "file", "")
    lines = to_pos_int(Map.get(args, "lines"), 100)
    format = Map.get(args, "format")

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

    case ErrorExtractor.get_errors(log_dir, file, lines, opts) do
      {:ok, errors} ->
        {:ok,
         ResponseFormatter.format(
           :error_results,
           %{file: file, error_count: length(errors), matches: errors},
           format
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
