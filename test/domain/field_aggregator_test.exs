defmodule McpLogServer.Domain.FieldAggregatorTest do
  use ExUnit.Case, async: true

  alias McpLogServer.Domain.FieldAggregator

  describe "get_path/2" do
    test "resolves a top-level key" do
      assert FieldAggregator.get_path(%{"region" => "fra"}, "region") == {:ok, "fra"}
    end

    test "resolves a nested dot-path" do
      entry = %{"fields" => %{"region" => "fra"}}
      assert FieldAggregator.get_path(entry, "fields.region") == {:ok, "fra"}
    end

    test "missing top-level key" do
      assert FieldAggregator.get_path(%{"a" => 1}, "b") == :missing
    end

    test "missing nested key" do
      assert FieldAggregator.get_path(%{"fields" => %{}}, "fields.region") == :missing
    end

    test "path through a non-map value is missing, not a crash" do
      assert FieldAggregator.get_path(%{"fields" => "flat"}, "fields.region") == :missing
      assert FieldAggregator.get_path(%{"fields" => 42}, "fields.region") == :missing
    end

    test "present key holding JSON null counts as present" do
      assert FieldAggregator.get_path(%{"gated" => nil}, "gated") == {:ok, nil}
    end

    test "numeric segments index into nested arrays" do
      entry = %{"items" => [%{"id" => "a"}, %{"id" => "b"}]}
      assert FieldAggregator.get_path(entry, "items.1.id") == {:ok, "b"}
      assert FieldAggregator.get_path(entry, "items.5.id") == :missing
    end

    test "non-numeric segment into an array is missing" do
      assert FieldAggregator.get_path(%{"items" => [1, 2]}, "items.id") == :missing
    end

    test "empty-map entry" do
      assert FieldAggregator.get_path(%{}, "fields.region") == :missing
    end
  end

  describe "accumulation and finalize" do
    defp fold(entries_and_lines, keys) do
      Enum.reduce(entries_and_lines, FieldAggregator.new(), fn
        {:json, entry, line}, acc -> FieldAggregator.add_entry(acc, keys, entry, line)
        {:non_json, _line}, acc -> FieldAggregator.add_non_json(acc)
      end)
    end

    test "exists reports with/without/non_json plus the first sample" do
      acc =
        fold(
          [
            {:json, %{"fields" => %{"gated" => true}}, ~s({"fields":{"gated":true}} LINE1)},
            {:json, %{"fields" => %{}}, "irrelevant"},
            {:json, %{"fields" => %{"gated" => false}}, "LINE3"},
            {:non_json, "plain text line"}
          ],
          ["fields", "gated"]
        )

      {result, om} = FieldAggregator.finalize(acc, :exists, 50)

      assert result.lines_with_field == 2
      assert result.lines_without == 1
      assert result.non_json == 1
      assert result.sample =~ "LINE1"
      assert om == %{}
    end

    test "exists with zero hits carries no sample key" do
      acc = fold([{:json, %{"a" => 1}, "x"}], ["missing"])
      {result, _om} = FieldAggregator.finalize(acc, :exists, 50)

      assert result.lines_with_field == 0
      refute Map.has_key?(result, :sample)
    end

    test "count returns total occurrences" do
      acc =
        fold(
          [
            {:json, %{"region" => "fra"}, "l1"},
            {:json, %{"region" => "ams"}, "l2"},
            {:json, %{"other" => 1}, "l3"}
          ],
          ["region"]
        )

      {result, _om} = FieldAggregator.finalize(acc, :count, 50)
      assert result.occurrences == 2
      assert result.lines_without == 1
    end

    test "values builds a histogram sorted by count desc" do
      acc =
        fold(
          [
            {:json, %{"region" => "fra"}, "l1"},
            {:json, %{"region" => "fra"}, "l2"},
            {:json, %{"region" => "ams"}, "l3"}
          ],
          ["region"]
        )

      {result, om} = FieldAggregator.finalize(acc, :values, 50)

      assert result.distinct_values == 2
      assert result.entries == [%{value: "fra", count: 2}, %{value: "ams", count: 1}]
      assert om == %{}
    end

    test "values caps distinct values and reports the cap in omissions" do
      acc =
        1..10
        |> Enum.map(fn i -> {:json, %{"region" => "r#{i}"}, "l#{i}"} end)
        |> fold(["region"])

      {result, om} = FieldAggregator.finalize(acc, :values, 3)

      assert result.distinct_values == 10
      assert length(result.entries) == 3
      assert om == %{values: %{omitted: 7, showing: "top 3 by count"}}
    end

    test "values normalizes non-string scalars, null, and compound values" do
      acc =
        fold(
          [
            {:json, %{"v" => 42}, "l1"},
            {:json, %{"v" => true}, "l2"},
            {:json, %{"v" => nil}, "l3"},
            {:json, %{"v" => %{"deep" => 1}}, "l4"}
          ],
          ["v"]
        )

      {result, _om} = FieldAggregator.finalize(acc, :values, 50)
      values = Enum.map(result.entries, & &1.value) |> Enum.sort()

      assert values == Enum.sort(["42", "true", "null", ~s({"deep":1})])
    end
  end
end
