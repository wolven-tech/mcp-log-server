defmodule McpLogServer.Application do
  use Application

  @impl true
  def start(_type, _args) do
    # Composition root: the only place infrastructure adapters are wired
    # together with the runtime environment.
    log_dir = McpLogServer.Infrastructure.EnvConfig.log_dir()
    File.mkdir_p!(log_dir)

    McpLogServer.Config.Patterns.init()
    # Fails loudly at boot on an invalid LOG_TS_FORMATS declaration —
    # a typo must never degrade into silent 0% timestamp parsing.
    McpLogServer.Config.TsFormats.init!()
    # Same philosophy for LOG_SOURCES: a malformed source declaration must
    # abort boot, never silently drop the stream the operator asked for.
    McpLogServer.Config.LogSources.init!()

    retention_days = McpLogServer.Infrastructure.EnvConfig.log_retention_days()
    McpLogServer.Infrastructure.FileLogSource.cleanup_old_logs(log_dir, retention_days)

    children = [
      # Streamed LOG_SOURCES ingestion (one worker per declared source).
      # Started before the transport so live files exist by the time the
      # first tools/call arrives; isolated one_for_one so a source crash
      # can never take the MCP session down.
      {McpLogServer.Infrastructure.SourceSupervisor, log_dir: log_dir},
      {McpLogServer.Transport.Stdio, handler: &McpLogServer.Server.handle_message/1}
    ]

    opts = [strategy: :one_for_one, name: McpLogServer.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
