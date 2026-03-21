defmodule McpLogServer.Tools.Dispatcher do
  @moduledoc """
  Dispatches tool calls to the appropriate tool module.
  """

  alias McpLogServer.Tools.Registry

  @spec call(String.t(), map(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def call(tool_name, args, log_dir) do
    case Registry.lookup(tool_name) do
      nil -> {:error, "Unknown tool: #{tool_name}"}
      mod -> mod.execute(args, log_dir)
    end
  end
end
