defmodule McpLogServer.Tools.SummarizeToolTest do
  use ExUnit.Case, async: false

  alias McpLogServer.Tools.Registry
  alias McpLogServer.Tools.Summarize

  @tmp_dir System.tmp_dir!() |> Path.join("summarize_tool_test")

  setup_all do
    McpLogServer.Config.Patterns.init()
    :ok
  end

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  defp fixture! do
    File.write!(Path.join(@tmp_dir, "app.log"), """
    2026-07-17T10:05:00Z INFO request 1 handled
    2026-07-17T10:20:00Z ERROR redis connection refused conn=ab12cd34ef
    2026-07-17T10:21:00Z ERROR redis connection refused conn=99887766aa
    """)
  end

  test "registered in the tool registry" do
    assert Registry.lookup("summarize") == Summarize
    assert Enum.any?(Registry.definitions(), &(&1.name == "summarize"))
  end

  test "TOON output: meta line plus sections" do
    fixture!()

    {:ok, out} =
      Summarize.execute(
        %{"since" => "2026-07-17T10:15:00Z", "until" => "2026-07-17T10:30:00Z"},
        @tmp_dir
      )

    [meta_line | _] = String.split(out, "\n")
    assert String.starts_with?(meta_line, "# ")
    meta = meta_line |> String.trim_leading("# ") |> Jason.decode!()
    assert meta["index_used"] == false
    assert meta["error_rate"]["window_errors"] == 2
    assert meta["window"]["since"] == "2026-07-17T10:15:00Z"

    assert out =~ "== new templates (1) =="
    assert out =~ "redis connection refused"
    assert out =~ "== gone templates (1) =="
    assert out =~ "== volume by source (1) =="
  end

  test "JSON output round-trips" do
    fixture!()

    {:ok, out} =
      Summarize.execute(
        %{
          "window" => "15m",
          "until" => "2026-07-17T10:30:00Z",
          "format" => "json"
        },
        @tmp_dir
      )

    decoded = Jason.decode!(out)
    assert [row] = decoded["new_templates"]
    assert row["count"] == 2
    assert row["instances_seen"] == "1/1"
  end

  test "errors propagate" do
    assert {:error, msg} = Summarize.execute(%{}, @tmp_dir)
    assert msg =~ "window"
  end
end
