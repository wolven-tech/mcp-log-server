defmodule McpLogServer.MixProject do
  use Mix.Project

  def project do
    [
      app: :mcp_log_server,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {McpLogServer.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"}
    ]
  end

  defp escript do
    [main_module: McpLogServer.CLI]
  end

  defp releases do
    [
      mcp_log_server: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent],
        steps: [:assemble]
      ]
    ]
  end
end
