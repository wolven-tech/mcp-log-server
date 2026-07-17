defmodule McpLogServer.Config.TsFormatsTest do
  use ExUnit.Case, async: false

  alias McpLogServer.Config.TsFormats

  setup do
    original = Application.get_env(:mcp_log_server, :ts_formats)

    on_exit(fn ->
      Application.put_env(:mcp_log_server, :ts_formats, original)
      TsFormats.init!()
    end)

    :ok
  end

  test "init! with no declaration yields no declared formats" do
    Application.put_env(:mcp_log_server, :ts_formats, nil)
    assert TsFormats.init!() == :ok
    assert TsFormats.for_file("anything.log") == nil
  end

  test "init! compiles a valid declaration once; for_file resolves globs" do
    Application.put_env(
      :mcp_log_server,
      :ts_formats,
      "fly-*.log=%FT%T%.fZ; app*.log=epoch_ms; dev-*.log=%H:%M:%S"
    )

    assert TsFormats.init!() == :ok

    assert %{kind: :strftime} = TsFormats.for_file("fly-api.log")
    assert %{kind: :epoch_ms} = TsFormats.for_file("app-prod.log")
    assert %{kind: :strftime} = TsFormats.for_file("dev-vite.log")
    assert TsFormats.for_file("unrelated.log") == nil
  end

  test "init! fails loudly at boot on a typo'd format string" do
    Application.put_env(:mcp_log_server, :ts_formats, "app.log=%Q bogus")

    error = assert_raise ArgumentError, fn -> TsFormats.init!() end
    assert error.message =~ "Invalid LOG_TS_FORMATS"
    assert error.message =~ "%Q"
  end

  test "init! fails loudly on a malformed entry" do
    Application.put_env(:mcp_log_server, :ts_formats, "just-a-glob-no-format")

    error = assert_raise ArgumentError, fn -> TsFormats.init!() end
    assert error.message =~ "glob=format"
  end
end
