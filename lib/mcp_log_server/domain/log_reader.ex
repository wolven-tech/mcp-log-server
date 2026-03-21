defmodule McpLogServer.Domain.LogReader do
  @moduledoc "Delegation facade — routes to focused domain modules."

  alias McpLogServer.Domain.FileAccess
  alias McpLogServer.Domain.LogTail
  alias McpLogServer.Domain.LogSearch
  alias McpLogServer.Domain.ErrorExtractor
  alias McpLogServer.Domain.StatsCollector
  alias McpLogServer.Domain.TimeRangeCalc

  # Re-export types for backward compatibility
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
          fatal_count: non_neg_integer(),
          modified: String.t()
        }

  @doc "List all .log files in the given directory."
  @spec list_files(String.t()) :: {:ok, [file_info()]}
  def list_files(log_dir), do: FileAccess.list_files(log_dir)

  @doc "Return the last `n` lines of a log file."
  @spec tail(String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def tail(log_dir, file, n, opts \\ []), do: LogTail.tail(log_dir, file, n, opts)

  @doc "Search a log file for lines matching a regex pattern."
  @spec search(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, search_result()} | {:error, String.t()}
  def search(log_dir, file, pattern, opts \\ []), do: LogSearch.search(log_dir, file, pattern, opts)

  @doc "Extract error/warning lines from a log file."
  @spec get_errors(String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, [log_entry()]} | {:error, String.t()}
  def get_errors(log_dir, file, max_lines, opts \\ []),
    do: ErrorExtractor.get_errors(log_dir, file, max_lines, opts)

  @doc "Compute stats for a log file without returning its content."
  @spec get_stats(String.t(), String.t()) :: {:ok, file_stats()} | {:error, String.t()}
  def get_stats(log_dir, file), do: StatsCollector.get_stats(log_dir, file)

  @doc "Return the time range of a log file."
  @spec time_range(String.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def time_range(log_dir, file), do: TimeRangeCalc.time_range(log_dir, file)
end
