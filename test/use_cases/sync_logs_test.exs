defmodule McpLogServer.UseCases.SyncLogsTest do
  use ExUnit.Case, async: true

  alias McpLogServer.UseCases.SyncLogs

  defmodule FakeSync do
    @behaviour McpLogServer.Ports.LogSync

    @impl true
    def sync(source, log_dir, opts) do
      send(self(), {:sync, source, log_dir, opts})
      {:ok, "fake sync ok"}
    end
  end

  test "ISO 8601 since is parsed to a DateTime and threaded to the port" do
    assert {:ok, "fake sync ok"} =
             SyncLogs.run("gs://bucket/logs/", "/logs", "api-",
               sync: FakeSync,
               since: "2026-07-01T10:00:00Z"
             )

    assert_received {:sync, "gs://bucket/logs/", "/logs", opts}
    assert opts[:prefix] == "api-"
    assert opts[:since] == ~U[2026-07-01 10:00:00Z]
  end

  test "relative shorthand since is resolved against now" do
    assert {:ok, _} = SyncLogs.run("s3://bucket/logs/", "/logs", nil, sync: FakeSync, since: "1h")

    assert_received {:sync, _, _, opts}
    expected = DateTime.add(DateTime.utc_now(), -3600, :second)
    assert_in_delta DateTime.to_unix(opts[:since]), DateTime.to_unix(expected), 5
  end

  test "no since threads nil to the port" do
    assert {:ok, _} = SyncLogs.run("gs://bucket/logs/", "/logs", nil, sync: FakeSync)

    assert_received {:sync, _, _, opts}
    assert opts[:since] == nil
    assert opts[:prefix] == nil
  end

  test "invalid since is rejected with the accepted forms, port never called" do
    assert {:error, msg} =
             SyncLogs.run("gs://bucket/logs/", "/logs", nil,
               sync: FakeSync,
               since: "yesterdayish"
             )

    assert msg =~ "Invalid since"
    assert msg =~ "ISO 8601"
    assert msg =~ "relative shorthand"
    refute_received {:sync, _, _, _}
  end
end
