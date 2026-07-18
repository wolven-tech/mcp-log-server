defmodule McpLogServer.Tools.SyncLogsTest do
  # async: false — swaps the globally configured :log_sync adapter.
  use ExUnit.Case, async: false

  alias McpLogServer.Tools.SyncLogs

  defmodule FakeSync do
    @behaviour McpLogServer.Ports.LogSync

    @impl true
    def sync(source, log_dir, opts) do
      send(self(), {:sync, source, log_dir, opts})
      {:ok, "fake sync ok"}
    end
  end

  setup do
    original = Application.fetch_env!(:mcp_log_server, :log_sync)
    Application.put_env(:mcp_log_server, :log_sync, FakeSync)
    on_exit(fn -> Application.put_env(:mcp_log_server, :log_sync, original) end)
    :ok
  end

  test "since arg reaches the port as a DateTime" do
    args = %{"source" => "gs://bucket/logs/", "since" => "2026-07-01T10:00:00Z"}

    assert {:ok, "fake sync ok"} = SyncLogs.execute(args, "/logs")

    assert_received {:sync, "gs://bucket/logs/", "/logs", opts}
    assert opts[:since] == ~U[2026-07-01 10:00:00Z]
  end

  test "relative since arg is accepted" do
    assert {:ok, _} =
             SyncLogs.execute(%{"source" => "gs://bucket/logs/", "since" => "1d"}, "/logs")

    assert_received {:sync, _, _, opts}
    assert %DateTime{} = opts[:since]
  end

  test "invalid since is a clear error naming the accepted forms" do
    args = %{"source" => "gs://bucket/logs/", "since" => "not-a-time"}

    assert {:error, msg} = SyncLogs.execute(args, "/logs")
    assert msg =~ "Invalid since"
    assert msg =~ "ISO 8601"
    refute_received {:sync, _, _, _}
  end

  test "omitted since threads nil, prefix still applies" do
    args = %{"source" => "s3://bucket/logs/", "prefix" => "api-"}

    assert {:ok, _} = SyncLogs.execute(args, "/logs")

    assert_received {:sync, "s3://bucket/logs/", "/logs", opts}
    assert opts[:since] == nil
    assert opts[:prefix] == "api-"
  end
end
