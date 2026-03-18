defmodule McpLogServer.Domain.LogReader do
  @moduledoc """
  Pure domain logic for reading and analysing log files.
  No processes, no side effects beyond file I/O. Stateless.
  """

  @type log_entry :: %{line_number: pos_integer(), content: String.t()}
  @type file_info :: %{
          name: String.t(),
          path: String.t(),
          size_bytes: non_neg_integer(),
          modified: String.t()
        }
  @type search_result :: %{
          file: String.t(),
          pattern: String.t(),
          total_matches: non_neg_integer(),
          matches: [log_entry()]
        }
  @type file_stats :: %{
          file: String.t(),
          size_bytes: non_neg_integer(),
          size_human: String.t(),
          line_count: non_neg_integer(),
          error_count: non_neg_integer(),
          warn_count: non_neg_integer(),
          modified: String.t()
        }

  @error_pattern ~r/(ERROR|FATAL|EXCEPTION|WARN|TypeError|ReferenceError|SyntaxError|ECONNREFUSED|ENOTFOUND|failed|Failed)/i

  @doc "List all .log files in the given directory."
  @spec list_files(String.t()) :: {:ok, [file_info()]}
  def list_files(log_dir) do
    entries =
      log_dir
      |> Path.join("*.log")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.map(&file_info/1)

    {:ok, entries}
  end

  @doc "Return the last `n` lines of a log file."
  @spec tail(String.t(), String.t(), pos_integer()) :: {:ok, String.t()} | {:error, String.t()}
  def tail(log_dir, file, n) do
    with {:ok, path} <- resolve(log_dir, file) do
      content =
        path
        |> File.stream!()
        |> Stream.map(&String.trim_trailing/1)
        |> Enum.to_list()
        |> Enum.take(-n)
        |> Enum.join("\n")

      {:ok, content}
    end
  end

  @doc "Search a log file for lines matching a regex pattern."
  @spec search(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, search_result()} | {:error, String.t()}
  def search(log_dir, file, pattern, opts \\ []) do
    max_results = Keyword.get(opts, :max_results, 50)
    context_lines = Keyword.get(opts, :context, 0)

    with {:ok, path} <- resolve(log_dir, file),
         {:ok, regex} <- compile_pattern(pattern) do
      lines = read_indexed(path)

      matches =
        lines
        |> Enum.filter(fn {line, _idx} -> Regex.match?(regex, line) end)
        |> Enum.take(max_results)
        |> Enum.map(fn {line, idx} ->
          entry = %{line_number: idx, content: line}

          if context_lines > 0 do
            ctx =
              lines
              |> Enum.filter(fn {_l, i} ->
                i >= idx - context_lines and i <= idx + context_lines and i != idx
              end)
              |> Enum.map_join("\n", fn {l, i} -> "  #{i}: #{l}" end)

            Map.put(entry, :context, ctx)
          else
            entry
          end
        end)

      {:ok,
       %{
         file: Path.basename(path),
         pattern: pattern,
         returned_matches: length(matches),
         matches: matches
       }}
    end
  end

  @doc "Extract error/warning lines from a log file."
  @spec get_errors(String.t(), String.t(), pos_integer()) ::
          {:ok, [log_entry()]} | {:error, String.t()}
  def get_errors(log_dir, file, max_lines) do
    with {:ok, path} <- resolve(log_dir, file) do
      errors =
        path
        |> File.stream!()
        |> Stream.map(&String.trim_trailing/1)
        |> Stream.with_index(1)
        |> Stream.filter(fn {line, _idx} -> Regex.match?(@error_pattern, line) end)
        |> Enum.take(-max_lines)
        |> Enum.map(fn {line, idx} -> %{line_number: idx, content: line} end)

      {:ok, errors}
    end
  end

  @doc "Compute stats for a log file without returning its content."
  @spec get_stats(String.t(), String.t()) :: {:ok, file_stats()} | {:error, String.t()}
  def get_stats(log_dir, file) do
    with {:ok, path} <- resolve(log_dir, file) do
      stat = File.stat!(path)

      {line_count, error_count, warn_count} =
        path
        |> File.stream!()
        |> Enum.reduce({0, 0, 0}, fn line, {lines, errors, warns} ->
          {
            lines + 1,
            if(Regex.match?(~r/ERROR|FATAL/i, line), do: errors + 1, else: errors),
            if(Regex.match?(~r/WARN/i, line), do: warns + 1, else: warns)
          }
        end)

      {:ok,
       %{
         file: Path.basename(path),
         size_bytes: stat.size,
         size_human: humanize_bytes(stat.size),
         line_count: line_count,
         error_count: error_count,
         warn_count: warn_count,
         modified: NaiveDateTime.to_iso8601(stat.mtime |> NaiveDateTime.from_erl!())
       }}
    end
  end

  # -- private --

  defp resolve(log_dir, file) do
    basename = Path.basename(file)

    if basename != file do
      {:error, "Invalid file name: path separators not allowed"}
    else
      path = Path.join(log_dir, basename)

      if File.exists?(path),
        do: {:ok, path},
        else: {:error, "File not found: #{file}"}
    end
  end

  defp compile_pattern(pattern) do
    case Regex.compile(pattern, "i") do
      {:ok, regex} -> {:ok, regex}
      {:error, _} -> {:error, "Invalid regex: #{pattern}"}
    end
  end

  defp read_indexed(path) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim_trailing/1)
    |> Stream.with_index(1)
    |> Enum.to_list()
  end

  defp file_info(path) do
    stat = File.stat!(path)

    %{
      name: Path.basename(path),
      path: path,
      size_bytes: stat.size,
      modified: NaiveDateTime.to_iso8601(stat.mtime |> NaiveDateTime.from_erl!())
    }
  end

  defp humanize_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp humanize_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp humanize_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"
end
