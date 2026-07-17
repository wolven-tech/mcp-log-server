defmodule McpLogServer.Infrastructure.CloudSyncTest do
  use ExUnit.Case, async: true

  alias McpLogServer.Infrastructure.CloudSync

  @tmp_dir System.tmp_dir!() |> Path.join("cloud_sync_test")

  test "rejects unsupported URI schemes without shelling out" do
    assert {:error, msg} = CloudSync.sync("ftp://bucket/logs/", @tmp_dir, nil)
    assert msg =~ "Unsupported URI scheme"
    assert msg =~ "gs://, s3://, or az://"
  end
end
