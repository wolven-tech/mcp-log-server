defmodule McpLogServer.Config.LogSourcesTest do
  use ExUnit.Case, async: false

  alias McpLogServer.Config.LogSources

  setup do
    original = Application.get_env(:mcp_log_server, :log_sources)

    on_exit(fn ->
      Application.put_env(:mcp_log_server, :log_sources, original)
      LogSources.init!()
    end)

    :ok
  end

  test "init! with no declaration yields no sources" do
    Application.put_env(:mcp_log_server, :log_sources, nil)
    assert LogSources.init!() == :ok
    assert LogSources.declared() == []
  end

  test "init! parses a valid declaration once; declared/0 returns the specs" do
    Application.put_env(
      :mcp_log_server,
      :log_sources,
      "fly:cmd=flyctl logs -a my-app; k8s:cmd=kubectl logs -f deploy/api"
    )

    assert LogSources.init!() == :ok

    assert [%{name: "fly"}, %{name: "k8s"}] = LogSources.declared()
    assert Enum.at(LogSources.declared(), 0).argv == ["flyctl", "logs", "-a", "my-app"]
  end

  test "init! fails loudly at boot on a malformed declaration" do
    Application.put_env(:mcp_log_server, :log_sources, "no-command-here")

    error = assert_raise ArgumentError, fn -> LogSources.init!() end
    assert error.message =~ "Invalid LOG_SOURCES"
    assert error.message =~ "name:cmd=command"
  end

  test "init! fails loudly on duplicate source names" do
    Application.put_env(:mcp_log_server, :log_sources, "a:cmd=echo 1; a:cmd=echo 2")

    error = assert_raise ArgumentError, fn -> LogSources.init!() end
    assert error.message =~ "duplicate source name"
  end
end
