defmodule McpLogServer.Domain.WindowDiffTest do
  use ExUnit.Case, async: true

  alias McpLogServer.Domain.WindowDiff

  @w_since ~U[2026-07-17 10:15:00Z]
  @w_until ~U[2026-07-17 10:30:00Z]
  @b_since ~U[2026-07-17 10:00:00Z]

  defp state, do: WindowDiff.new(@w_since, @w_until, @b_since)

  defp info(content, ts, opts \\ []) do
    %{
      content: content,
      instance: Keyword.get(opts, :instance, "app.log"),
      ts: ts,
      error?: Keyword.get(opts, :error?, false)
    }
  end

  describe "classify/2" do
    test "boundaries: w_since belongs to the window, never both" do
      assert WindowDiff.classify(state(), @w_since) == :window
      assert WindowDiff.classify(state(), @w_until) == :window
      assert WindowDiff.classify(state(), @b_since) == :baseline
      assert WindowDiff.classify(state(), ~U[2026-07-17 10:14:59Z]) == :baseline
      assert WindowDiff.classify(state(), ~U[2026-07-17 09:59:59Z]) == :outside
      assert WindowDiff.classify(state(), ~U[2026-07-17 10:30:01Z]) == :outside
      assert WindowDiff.classify(state(), nil) == :unparsed
    end
  end

  describe "template diff" do
    test "new, gone, and common templates" do
      result =
        state()
        |> WindowDiff.add(info("conn 4f9a8bc12 refused", ~U[2026-07-17 10:20:00Z]))
        |> WindowDiff.add(info("conn 77b1deadb refused", ~U[2026-07-17 10:21:00Z]))
        |> WindowDiff.add(info("request 12 handled", ~U[2026-07-17 10:22:00Z]))
        |> WindowDiff.add(info("request 99 handled", ~U[2026-07-17 10:05:00Z]))
        |> WindowDiff.add(info("cron sweep 3 done", ~U[2026-07-17 10:06:00Z]))
        |> WindowDiff.finalize()

      assert [new_row] = result.new_templates
      assert new_row.template =~ "refused"
      assert new_row.count == 2
      assert new_row.first_ts == "2026-07-17T10:20:00Z"
      assert new_row.sample == "conn 4f9a8bc12 refused"

      assert [gone_row] = result.gone_templates
      assert gone_row.template =~ "cron sweep"
      assert gone_row.baseline_count == 1

      # "request N handled" exists in both — in neither list
      refute Enum.any?(result.new_templates, &(&1.template =~ "handled"))
      refute Enum.any?(result.gone_templates, &(&1.template =~ "handled"))
    end

    test "instances_seen counts distinct instances over all seen" do
      result =
        state()
        |> WindowDiff.add(info("boom 1", ~U[2026-07-17 10:20:00Z], instance: "a.log"))
        |> WindowDiff.add(info("boom 2", ~U[2026-07-17 10:21:00Z], instance: "a.log"))
        |> WindowDiff.add(info("fine 3", ~U[2026-07-17 10:05:00Z], instance: "b.log"))
        |> WindowDiff.finalize()

      assert [row] = result.new_templates
      assert row.instances_seen == "1/2"
      assert result.sources_seen == 2
    end

    test "unparsed lines fold into BOTH ranges and never fabricate a diff row" do
      result =
        state()
        |> WindowDiff.add(info("mystery line without timestamp", nil))
        |> WindowDiff.finalize()

      assert result.unparsed_ts == 1
      assert result.new_templates == []
      assert result.gone_templates == []
      # but it IS visible in both volumes
      assert [%{window_lines: 1, baseline_lines: 1}] = result.volume
    end

    test "template caps are reported via omissions" do
      result =
        Enum.reduce(1..5, state(), fn i, st ->
          WindowDiff.add(st, info("unique#{i}alpha#{i}beta event", ~U[2026-07-17 10:20:00Z]))
        end)
        |> WindowDiff.finalize(max_templates: 2)

      assert length(result.new_templates) == 2
      assert result.omissions.new_templates == %{omitted: 3, showing: "top 2 by count"}
    end
  end

  describe "rates" do
    test "error rate per minute with delta" do
      st =
        Enum.reduce(1..3, state(), fn i, st ->
          WindowDiff.add(st, info("ERROR boom #{i}", ~U[2026-07-17 10:20:00Z], error?: true))
        end)

      st = WindowDiff.add(st, info("ERROR old 1", ~U[2026-07-17 10:05:00Z], error?: true))

      result = WindowDiff.finalize(st)

      assert result.error_rate.window_errors == 3
      assert result.error_rate.baseline_errors == 1
      assert result.error_rate.window_per_min == 0.2
      assert result.error_rate.baseline_per_min == 0.07
      assert result.error_rate.delta_per_min == 0.13
    end

    test "volume per source with delta" do
      st =
        Enum.reduce(1..30, state(), fn i, st ->
          WindowDiff.add(st, info("line #{i}", ~U[2026-07-17 10:20:00Z], instance: "web.log"))
        end)

      st = WindowDiff.add(st, info("line b", ~U[2026-07-17 10:05:00Z], instance: "web.log"))

      result = WindowDiff.finalize(st)

      assert [row] = result.volume
      assert row.source == "web.log"
      assert row.window_lines == 30
      assert row.baseline_lines == 1
      assert row.window_per_min == 2.0
      assert row.delta_per_min == 1.93
    end
  end

  describe "parse_duration/1" do
    test "shorthands" do
      assert WindowDiff.parse_duration("15m") == {:ok, 900}
      assert WindowDiff.parse_duration("2h") == {:ok, 7200}
      assert WindowDiff.parse_duration("45s") == {:ok, 45}
      assert WindowDiff.parse_duration("1d") == {:ok, 86_400}
      assert WindowDiff.parse_duration("1w") == {:ok, 604_800}
    end

    test "rejects garbage and zero" do
      assert WindowDiff.parse_duration("") == :error
      assert WindowDiff.parse_duration("15") == :error
      assert WindowDiff.parse_duration("0m") == :error
      assert WindowDiff.parse_duration(nil) == :error
      assert WindowDiff.parse_duration("2026-01-01") == :error
    end
  end
end
