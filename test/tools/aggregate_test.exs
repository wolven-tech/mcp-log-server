defmodule McpLogServer.Tools.AggregateTest do
  use ExUnit.Case, async: false

  alias McpLogServer.Tools.Dispatcher

  @tmp_dir System.tmp_dir!() |> Path.join("aggregate_tool_test")

  @app_log """
  {"timestamp":"2026-01-15T10:00:00Z","message":"req 1","fields":{"region":"fra","gated":true}}
  {"timestamp":"2026-01-15T10:00:01Z","message":"req 2","fields":{"region":"ams"}}
  {"timestamp":"2026-01-15T10:00:02Z","message":"req 3","fields":{"region":"fra"}}
  not json at all
  """

  setup do
    File.mkdir_p!(@tmp_dir)
    File.write!(Path.join(@tmp_dir, "app.log"), @app_log)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  test "aggregate is registered and listed" do
    assert McpLogServer.Tools.Registry.lookup("aggregate") == McpLogServer.Tools.Aggregate

    assert Enum.any?(McpLogServer.Tools.Registry.definitions(), &(&1.name == "aggregate"))
  end

  test "op exists returns a JSON proof with sample and non_json" do
    args = %{"file" => "app.log", "field" => "fields.gated", "op" => "exists"}
    {:ok, output} = Dispatcher.call("aggregate", args, @tmp_dir)

    result = Jason.decode!(output)
    assert result["lines_with_field"] == 1
    assert result["lines_without"] == 2
    assert result["non_json"] == 1
    assert result["sample"] =~ "req 1"
  end

  test "op values returns a TOON histogram" do
    args = %{"file" => "app.log", "field" => "fields.region", "op" => "values"}
    {:ok, output} = Dispatcher.call("aggregate", args, @tmp_dir)

    assert output =~ "[count|value]"
    assert output =~ "2|fra"
    assert output =~ "1|ams"
    assert output =~ "distinct_values"
  end

  test "op count returns occurrences" do
    args = %{"file" => "app.log", "field" => "fields.region", "op" => "count"}
    {:ok, output} = Dispatcher.call("aggregate", args, @tmp_dir)

    assert Jason.decode!(output)["occurrences"] == 3
  end

  test "invalid op is an error" do
    args = %{"file" => "app.log", "field" => "x", "op" => "sum"}
    assert {:error, msg} = Dispatcher.call("aggregate", args, @tmp_dir)
    assert msg =~ "Invalid op"
  end
end
