defmodule McpLogServer.Application do
  use Application

  @impl true
  def start(_type, _args) do
    # Composition root: the only place infrastructure adapters are wired
    # together with the runtime environment.
    log_dir = McpLogServer.Infrastructure.EnvConfig.log_dir()
    File.mkdir_p!(log_dir)

    McpLogServer.Config.Patterns.init()

    retention_days = McpLogServer.Infrastructure.EnvConfig.log_retention_days()
    McpLogServer.Infrastructure.FileLogSource.cleanup_old_logs(log_dir, retention_days)

    children = [
      {McpLogServer.Transport.Stdio, handler: &McpLogServer.Server.handle_message/1}
    ]

    opts = [strategy: :one_for_one, name: McpLogServer.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
