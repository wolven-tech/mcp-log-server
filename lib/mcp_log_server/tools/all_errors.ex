defmodule McpLogServer.Tools.AllErrors do
  @moduledoc "Get errors from all log files at once."

  @behaviour McpLogServer.Tools.Tool

  alias McpLogServer.Domain.FileAccess
  alias McpLogServer.Domain.ErrorExtractor
  alias McpLogServer.Protocol.ResponseFormatter
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

    {:ok, files} = FileAccess.list_files(log_dir)

    {results, skipped} =
      Enum.reduce(files, {[], []}, fn %{name: name} = file_info, {res, skip} ->
        case FileAccess.check_size(file_info.path) do
          {:error, _} ->
            size_mb = Float.round(file_info.size_bytes / 1_048_576, 1)
            max_mb = Application.get_env(:mcp_log_server, :max_log_file_mb, 100)
            {res, skip ++ ["--- skipped: #{name} (#{size_mb} MB exceeds #{max_mb} MB limit) ---"]}

          {:ok, _} ->
            case ErrorExtractor.get_errors(log_dir, name, lines_per_file, opts) do
              {:ok, errors} when errors != [] ->
                {res ++ [%{file: name, error_count: length(errors), matches: errors}], skip}

              _ ->
                {res, skip}
            end
        end
      end)

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
