defmodule McpLogServer.Infrastructure.NoIndex do
  @moduledoc """
  `McpLogServer.Ports.LogIndex` adapter that always misses.

  Two jobs:

    * the explicit DISABLED mode (`LOG_INDEX=off`) — every query takes the
      linear-scan path, results identical, `index_used: false`;
    * the control group for the oracle tests: run the same query with the
      real index and with `NoIndex`, assert byte-identical results.
  """

  @behaviour McpLogServer.Ports.LogIndex

  @impl true
  def seek(_path, _since, _mode), do: :miss

  @impl true
  def field_stats(_path), do: :miss
end
