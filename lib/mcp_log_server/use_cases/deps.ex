defmodule McpLogServer.UseCases.Deps do
  @moduledoc """
  Resolves the port implementation each use-case talks to.

  Defaults come from application config (`config/config.exs`), so use-cases
  never name an infrastructure module directly. Tests inject fakes by passing
  `:source`, `:config`, or `:sync` in a use-case's `opts`.
  """

  @spec log_source(keyword()) :: module()
  def log_source(opts \\ []),
    do: Keyword.get(opts, :source) || Application.fetch_env!(:mcp_log_server, :log_source)

  @spec config(keyword()) :: module()
  def config(opts \\ []),
    do: Keyword.get(opts, :config) || Application.fetch_env!(:mcp_log_server, :config_impl)

  @spec log_sync(keyword()) :: module()
  def log_sync(opts \\ []),
    do: Keyword.get(opts, :sync) || Application.fetch_env!(:mcp_log_server, :log_sync)
end
