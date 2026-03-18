defmodule McpLogServer.Tools.Dispatcher do
  @moduledoc """
  Dispatches tool calls to domain logic and formats the response.
  This is the use-case / application layer: orchestrates domain + encoding.
  """

  alias McpLogServer.Domain.LogReader
  alias McpLogServer.Protocol.ToonEncoder

  @spec call(String.t(), map(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def call(tool_name, args, log_dir) do
    dispatch(tool_name, args, log_dir)
  end

  defp to_pos_int(val, _default) when is_integer(val) and val > 0, do: val
  defp to_pos_int(_val, default), do: default

  defp dispatch("list_logs", _args, log_dir) do
    case LogReader.list_files(log_dir) do
      {:ok, files} -> {:ok, ToonEncoder.format_response(%{entries: files})}
    end
  end

  defp dispatch("tail_log", args, log_dir) do
    file = Map.get(args, "file", "")
    lines = to_pos_int(Map.get(args, "lines"), 50)
    format = Map.get(args, "format")

    case LogReader.tail(log_dir, file, lines) do
      {:ok, content} ->
        if format == "json",
          do: {:ok, Jason.encode!(%{file: file, lines: lines, content: content})},
          else: {:ok, "# tail #{file} (last #{lines} lines)\n#{content}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dispatch("search_logs", args, log_dir) do
    file = Map.get(args, "file", "")
    pattern = Map.get(args, "pattern", "")
    max_results = to_pos_int(Map.get(args, "max_results"), 50)
    context = to_pos_int(Map.get(args, "context"), 0)
    format = Map.get(args, "format")

    case LogReader.search(log_dir, file, pattern, max_results: max_results, context: context) do
      {:ok, results} -> {:ok, ToonEncoder.format_response(results, format)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch("get_errors", args, log_dir) do
    file = Map.get(args, "file", "")
    lines = to_pos_int(Map.get(args, "lines"), 100)
    format = Map.get(args, "format")

    case LogReader.get_errors(log_dir, file, lines) do
      {:ok, errors} ->
        {:ok,
         ToonEncoder.format_response(
           %{file: file, error_count: length(errors), matches: errors},
           format
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dispatch("log_stats", args, log_dir) do
    file = Map.get(args, "file", "")

    case LogReader.get_stats(log_dir, file) do
      {:ok, stats} -> {:ok, Jason.encode!(stats)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch("all_errors", args, log_dir) do
    lines_per_file = to_pos_int(Map.get(args, "lines"), 20)

    case LogReader.list_files(log_dir) do
      {:ok, files} ->
        results =
          files
          |> Enum.map(fn %{name: name} ->
            case LogReader.get_errors(log_dir, name, lines_per_file) do
              {:ok, errors} when errors != [] ->
                %{file: name, error_count: length(errors), matches: errors}

              _ ->
                nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        if results == [] do
          {:ok, "No errors found in any log file."}
        else
          output =
            Enum.map_join(results, "\n\n", fn r ->
              "--- #{r.file} (#{r.error_count} errors) ---\n" <>
                ToonEncoder.format_response(%{matches: r.matches})
            end)

          {:ok, output}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dispatch(name, _args, _log_dir), do: {:error, "Unknown tool: #{name}"}
end
