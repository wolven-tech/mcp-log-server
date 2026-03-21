defmodule McpLogServer.Domain.LogTail do
  @moduledoc """
  Retrieves the last N lines of a log file, with optional time filtering.
  """

  alias McpLogServer.Domain.FileAccess
  alias McpLogServer.Domain.TimeFilter
  alias McpLogServer.Domain.TimestampParser

  @doc """
  Return the last `n` lines of a log file.

  ## Options

    * `:since` - only include lines from this time onward (ISO 8601 or relative shorthand)
  """
  @spec tail(String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def tail(log_dir, file, n, opts \\ []) do
    since = parse_time_opt(Keyword.get(opts, :since))

    with {:ok, path} <- FileAccess.resolve(log_dir, file) do
      content =
        path
        |> File.stream!()
        |> Stream.map(&String.trim_trailing/1)
        |> Stream.filter(fn line -> TimeFilter.in_range?(line, since, nil) end)
        |> Enum.to_list()
        |> Enum.take(-n)
        |> Enum.join("\n")

      {:ok, content}
    end
  end

  defp parse_time_opt(nil), do: nil

  defp parse_time_opt(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> TimestampParser.parse_relative(value)
    end
  end

  defp parse_time_opt(_), do: nil
end
