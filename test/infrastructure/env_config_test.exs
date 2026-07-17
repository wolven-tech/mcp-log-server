defmodule McpLogServer.Infrastructure.EnvConfigTest do
  use ExUnit.Case, async: false

  alias McpLogServer.Infrastructure.EnvConfig

  test "log_dir/0 reads the configured log directory" do
    assert EnvConfig.log_dir() == Application.fetch_env!(:mcp_log_server, :log_dir)
  end

  test "max_log_file_mb/0 reads the configured limit at call time" do
    original = Application.get_env(:mcp_log_server, :max_log_file_mb, 100)
    on_exit(fn -> Application.put_env(:mcp_log_server, :max_log_file_mb, original) end)

    Application.put_env(:mcp_log_server, :max_log_file_mb, 7)
    assert EnvConfig.max_log_file_mb() == 7
  end

  test "log_retention_days/0 defaults to nil" do
    original = Application.get_env(:mcp_log_server, :log_retention_days)
    on_exit(fn -> Application.put_env(:mcp_log_server, :log_retention_days, original) end)

    Application.delete_env(:mcp_log_server, :log_retention_days)
    assert EnvConfig.log_retention_days() == nil
  end
end
