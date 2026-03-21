defmodule McpLogServer.Application do
  use Application

  @impl true
  def start(_type, _args) do
    log_dir = Application.fetch_env!(:mcp_log_server, :log_dir)
    File.mkdir_p!(log_dir)

    McpLogServer.Config.Patterns.init()

    retention_days = Application.get_env(:mcp_log_server, :log_retention_days)
    McpLogServer.Domain.FileAccess.cleanup_old_logs(log_dir, retention_days)

    children = [
      {McpLogServer.Transport.Stdio, handler: &McpLogServer.Server.handle_message/1}
    ]

    opts = [strategy: :one_for_one, name: McpLogServer.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
