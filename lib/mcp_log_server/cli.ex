defmodule McpLogServer.CLI do
  def main(_args) do
    # Application is already started by escript
    # Keep the process alive
    Process.sleep(:infinity)
  end
end
