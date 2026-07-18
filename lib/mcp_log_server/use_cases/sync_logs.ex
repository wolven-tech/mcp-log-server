defmodule McpLogServer.UseCases.SyncLogs do
  @moduledoc """
  Use-case: pull logs from an external store into the local log directory
  through the `McpLogServer.Ports.LogSync` port.

  A user-supplied `:since` string (ISO 8601 or relative shorthand like
  `"1h"`) is parsed here — with the same `TimestampParser.parse_time/1`
  every other time-filtering tool uses — into an absolute `DateTime` before
  it crosses the port. An unparseable since is a hard error, never a
  silently ignored filter.
  """

  alias McpLogServer.Domain.TimestampParser
  alias McpLogServer.UseCases.Deps

  @spec run(String.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def run(source_uri, log_dir, prefix, opts \\ []) do
    case parse_since(Keyword.get(opts, :since)) do
      {:ok, since} ->
        Deps.log_sync(opts).sync(source_uri, log_dir, prefix: prefix, since: since)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_since(nil), do: {:ok, nil}

  defp parse_since(value) do
    case TimestampParser.parse_time(value) do
      nil ->
        {:error,
         "Invalid since: #{inspect(value)}. Expected ISO 8601 " <>
           "(e.g. \"2026-07-01T10:00:00Z\") or relative shorthand (e.g. \"30m\", \"2h\", \"1d\")."}

      %DateTime{} = dt ->
        {:ok, dt}
    end
  end
end
