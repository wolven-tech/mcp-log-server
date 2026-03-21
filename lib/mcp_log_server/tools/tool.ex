defmodule McpLogServer.Tools.Tool do
  @moduledoc """
  Behaviour for MCP tool modules.
  Each tool defines its name, description, schema, and execution logic.
  """

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback schema() :: map()
  @callback execute(args :: map(), log_dir :: String.t()) :: {:ok, String.t()} | {:error, String.t()}
end
