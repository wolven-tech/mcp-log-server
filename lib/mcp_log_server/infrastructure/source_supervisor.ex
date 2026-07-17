defmodule McpLogServer.Infrastructure.SourceSupervisor do
  @moduledoc """
  Supervises one `McpLogServer.Infrastructure.SourceWorker` per declared
  `LOG_SOURCES` entry.

  Command exits are absorbed INSIDE each worker (exponential backoff, see
  `McpLogServer.Domain.Backoff`), so supervisor restarts only happen on
  worker bugs — and `:one_for_one` keeps one source's failure from touching
  the others or the MCP transport. Restart intensity is generous
  (10 in 60s) so even a pathological worker crash-loop backs off through
  supervision rather than escalating into the application supervisor.

  Also owns the `McpLogServer.Infrastructure.SourceStatus` ETS table, so
  status survives individual worker restarts.

  Runs in both release and escript mode: `Port.open/2` with
  `:spawn_executable` needs only the BEAM, not a full release. See
  `docs/reference/TOOLS.md` for the escript shutdown caveat.
  """

  use Supervisor

  alias McpLogServer.Config.LogSources
  alias McpLogServer.Infrastructure.SourceStatus
  alias McpLogServer.Infrastructure.SourceWorker

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    # Owned by this (long-lived) supervisor process — created before any
    # worker starts writing statuses.
    SourceStatus.ensure_table()

    log_dir = Keyword.fetch!(opts, :log_dir)
    specs = Keyword.get_lazy(opts, :sources, fn -> LogSources.declared() end)

    children =
      for spec <- specs do
        Supervisor.child_spec(
          {SourceWorker, spec: spec, log_dir: log_dir},
          id: {:source_worker, spec.name}
        )
      end

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 10, max_seconds: 60)
  end
end
