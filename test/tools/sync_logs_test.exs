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
    original_enabled = Application.get_env(:mcp_log_server, :sync_enabled)
    original_allowed = Application.get_env(:mcp_log_server, :sync_allowed_sources)
    Application.put_env(:mcp_log_server, :log_sync, FakeSync)
    Application.put_env(:mcp_log_server, :sync_enabled, true)
    Application.put_env(:mcp_log_server, :sync_allowed_sources, ["gs://bucket/", "s3://bucket/"])

    on_exit(fn ->
      Application.put_env(:mcp_log_server, :log_sync, original)
      restore_env(:sync_enabled, original_enabled)
      restore_env(:sync_allowed_sources, original_allowed)
    end)

    :ok
  end

  test "defaults to a safe dry run" do
    args = %{"source" => "gs://bucket/logs/?signature=secret", "since" => "1d"}

    assert {:ok, result} = SyncLogs.execute(args, "/logs")
    assert result.dryRun
    assert result.source == "gs://bucket/logs/"
    refute_received {:sync, _, _, _}
  end

  test "since arg reaches the port as a DateTime" do
    args = %{
      "source" => "gs://bucket/logs/",
      "since" => "2026-07-01T10:00:00Z",
      "dry_run" => false
    }

    assert {:ok, "fake sync ok"} = SyncLogs.execute(args, "/logs")

    assert_received {:sync, "gs://bucket/logs/", "/logs", opts}
    assert opts[:since] == ~U[2026-07-01 10:00:00Z]
  end

  test "relative since arg is accepted" do
    assert {:ok, _} =
             SyncLogs.execute(
               %{"source" => "gs://bucket/logs/", "since" => "1d", "dry_run" => false},
               "/logs"
             )

    assert_received {:sync, _, _, opts}
    assert %DateTime{} = opts[:since]
  end

  test "invalid since is a clear error naming the accepted forms" do
    args = %{"source" => "gs://bucket/logs/", "since" => "not-a-time", "dry_run" => false}

    assert {:error, msg} = SyncLogs.execute(args, "/logs")
    assert msg =~ "Invalid since"
    assert msg =~ "ISO 8601"
    refute_received {:sync, _, _, _}
  end

  test "omitted since threads nil, prefix still applies" do
    args = %{"source" => "s3://bucket/logs/", "prefix" => "api-", "dry_run" => false}

    assert {:ok, _} = SyncLogs.execute(args, "/logs")

    assert_received {:sync, "s3://bucket/logs/", "/logs", opts}
    assert opts[:since] == nil
    assert opts[:prefix] == "api-"
  end

  test "blocks mutation when source is not allowlisted" do
    args = %{"source" => "gs://other/logs/", "dry_run" => false}

    assert {:error, msg} = SyncLogs.execute(args, "/logs")
    assert msg =~ "not allowed"
    refute_received {:sync, _, _, _}
  end

  test "blocks mutation when server policy is disabled" do
    Application.put_env(:mcp_log_server, :sync_enabled, false)

    assert {:error, msg} =
             SyncLogs.execute(%{"source" => "gs://bucket/logs/", "dry_run" => false}, "/logs")

    assert msg =~ "disabled by server policy"
    refute_received {:sync, _, _, _}
  end

  defp restore_env(key, nil), do: Application.delete_env(:mcp_log_server, key)
  defp restore_env(key, value), do: Application.put_env(:mcp_log_server, key, value)
end
