defmodule McpLogServer.Application do
  use Application

  @impl true
  def start(_type, _args) do
    log_dir = System.get_env("LOG_DIR", "/tmp/mcp-logs")
    File.mkdir_p!(log_dir)

    children = [
      {McpLogServer.Transport.Stdio, handler: &McpLogServer.Server.handle_message/1}
    ]

    opts = [strategy: :one_for_one, name: McpLogServer.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
