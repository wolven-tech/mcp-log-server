defmodule McpLogServer.Tools.SourceManifestTest do
  use ExUnit.Case, async: true

  alias McpLogServer.Tools.Dispatcher

  setup do
    log_dir =
      Path.join(System.tmp_dir!(), "source_manifest_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(log_dir)

    File.write!(Path.join(log_dir, "api.log"), """
    2026-09-03T10:00:00Z INFO started
    2026-09-03T10:01:00Z ERROR failed
    """)

    on_exit(fn -> File.rm_rf!(log_dir) end)
    %{log_dir: log_dir}
  end

  test "reports source freshness and timestamp coverage without paths", %{log_dir: log_dir} do
    assert {:ok, output} = Dispatcher.call("source_manifest", %{}, log_dir)
    manifest = Jason.decode!(output)

    assert manifest["sourceCount"] == 1
    assert manifest["freshThrough"] == "2026-09-03T10:01:00Z"
    assert [source] = manifest["sources"]
    assert source["file"] == "api.log"
    assert source["lines"] == 2
    assert source["timestampParseRatio"] == 1.0
    refute Map.has_key?(source, "path")
  end

  test "rejects unknown source", %{log_dir: log_dir} do
    assert {:error, message} =
             Dispatcher.call("source_manifest", %{"file" => "missing.log"}, log_dir)

    assert message =~ "not found"
  end
end
