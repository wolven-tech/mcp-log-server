defmodule McpLogServer.Domain.AnchorWindowTest do
  use ExUnit.Case, async: true

  alias McpLogServer.Domain.AnchorWindow

  defp dt(iso) do
    {:ok, dt, _} = DateTime.from_iso8601(iso)
    dt
  end

  describe "parse/1" do
    test "symmetric with unicode plus-minus" do
      assert AnchorWindow.parse("±10s") == {:ok, %{before: 10, after: 10}}
      assert AnchorWindow.parse("±2m") == {:ok, %{before: 120, after: 120}}
    end

    test "symmetric with ASCII spellings" do
      assert AnchorWindow.parse("+-10s") == {:ok, %{before: 10, after: 10}}
      assert AnchorWindow.parse("+/-1h") == {:ok, %{before: 3600, after: 3600}}
    end

    test "asymmetric map with string keys" do
      assert AnchorWindow.parse(%{"before" => "10s", "after" => "30s"}) ==
               {:ok, %{before: 10, after: 30}}
    end

    test "asymmetric map with one side omitted defaults the other to zero" do
      assert AnchorWindow.parse(%{"after" => "30s"}) == {:ok, %{before: 0, after: 30}}
    end

    test "nil gives the default window" do
      assert AnchorWindow.parse(nil) == {:ok, %{before: 30, after: 30}}
    end

    test "invalid specs produce descriptive errors" do
      assert {:error, msg} = AnchorWindow.parse("10s")
      assert msg =~ "Invalid window"

      assert {:error, _} = AnchorWindow.parse("±10 parsecs")
      assert {:error, _} = AnchorWindow.parse(%{})
      assert {:error, _} = AnchorWindow.parse(%{"before" => "soon"})
      assert {:error, _} = AnchorWindow.parse(42)
    end
  end

  describe "sections/2" do
    test "one anchor yields one window around it" do
      [section] = AnchorWindow.sections([dt("2026-01-01T10:00:00Z")], %{before: 10, after: 30})

      assert section.from == dt("2026-01-01T09:59:50Z")
      assert section.to == dt("2026-01-01T10:00:30Z")
      assert section.anchor_count == 1
    end

    test "distant anchors yield separate time-sorted sections" do
      sections =
        AnchorWindow.sections(
          [dt("2026-01-01T12:00:00Z"), dt("2026-01-01T10:00:00Z")],
          %{before: 5, after: 5}
        )

      assert length(sections) == 2
      assert [%{from: f1}, %{from: f2}] = sections
      assert DateTime.compare(f1, f2) == :lt
    end

    test "overlapping windows merge into one section with combined anchor_count" do
      sections =
        AnchorWindow.sections(
          [dt("2026-01-01T10:00:00Z"), dt("2026-01-01T10:00:08Z"), dt("2026-01-01T10:00:12Z")],
          %{before: 10, after: 10}
        )

      assert [section] = sections
      assert section.anchor_count == 3
      assert section.from == dt("2026-01-01T09:59:50Z")
      assert section.to == dt("2026-01-01T10:00:22Z")
    end

    test "touching windows (boundary equal) also merge" do
      sections =
        AnchorWindow.sections(
          [dt("2026-01-01T10:00:00Z"), dt("2026-01-01T10:00:20Z")],
          %{before: 10, after: 10}
        )

      assert [%{anchor_count: 2}] = sections
    end

    test "no anchors, no sections" do
      assert AnchorWindow.sections([], %{before: 10, after: 10}) == []
    end
  end

  describe "section_index/2" do
    test "finds the containing section, inclusive at both bounds" do
      sections = AnchorWindow.sections([dt("2026-01-01T10:00:00Z")], %{before: 10, after: 10})

      assert AnchorWindow.section_index(sections, dt("2026-01-01T09:59:50Z")) == 0
      assert AnchorWindow.section_index(sections, dt("2026-01-01T10:00:10Z")) == 0
      assert AnchorWindow.section_index(sections, dt("2026-01-01T10:00:11Z")) == nil
      assert AnchorWindow.section_index(sections, dt("2026-01-01T09:59:49Z")) == nil
    end
  end
end
