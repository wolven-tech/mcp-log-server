defmodule McpLogServer.UseCases.AggregateTest do
  use ExUnit.Case, async: false

  alias McpLogServer.UseCases.Aggregate

  @tmp_dir System.tmp_dir!() |> Path.join("aggregate_uc_test")

  setup do
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  defp write!(name, content), do: File.write!(Path.join(@tmp_dir, name), content)

  defp ndjson(entries) do
    Enum.map_join(entries, "", fn map -> Jason.encode!(map) <> "\n" end)
  end

  describe "op: exists — the incident-shaped presence proof" do
    test "finds exactly 2 gated lines out of 500 with a sample" do
      entries =
        for i <- 1..500 do
          base = %{
            "timestamp" => "2026-01-15T10:00:00Z",
            "message" => "request #{i}",
            "fields" => %{"region" => "fra"}
          }

          if i in [137, 342] do
            put_in(base, ["fields", "gated"], true)
          else
            base
          end
        end

      write!("app.log", ndjson(entries))

      {:ok, result} = Aggregate.run(@tmp_dir, "app.log", "fields.gated", "exists")

      assert result.lines_with_field == 2
      assert result.lines_without == 498
      assert result.non_json == 0
      assert result.sample =~ "request 137"
      assert result.op == "exists"
      refute Map.has_key?(result, :omissions)
    end

    test "zero hits proves absence (no sample key)" do
      write!("app.log", ndjson([%{"message" => "hi"}]))

      {:ok, result} = Aggregate.run(@tmp_dir, "app.log", "fields.gated", "exists")

      assert result.lines_with_field == 0
      assert result.lines_without == 1
      refute Map.has_key?(result, :sample)
    end
  end

  describe "op: values" do
    test "returns a histogram of distinct values" do
      write!(
        "app.log",
        ndjson([
          %{"fields" => %{"region" => "fra"}},
          %{"fields" => %{"region" => "fra"}},
          %{"fields" => %{"region" => "ams"}},
          %{"other" => true}
        ])
      )

      {:ok, result} = Aggregate.run(@tmp_dir, "app.log", "fields.region", "values")

      assert result.distinct_values == 2
      assert result.entries == [%{value: "fra", count: 2}, %{value: "ams", count: 1}]
    end

    test "caps distinct values with an omissions marker" do
      write!("app.log", ndjson(for i <- 1..10, do: %{"region" => "r#{i}"}))

      {:ok, result} = Aggregate.run(@tmp_dir, "app.log", "region", "values", max_values: 4)

      assert result.distinct_values == 10
      assert length(result.entries) == 4
      assert result.omissions.values == %{omitted: 6, showing: "top 4 by count"}
    end
  end

  describe "op: count" do
    test "counts total occurrences" do
      write!(
        "app.log",
        ndjson([%{"region" => "fra"}, %{"region" => "ams"}, %{"x" => 1}])
      )

      {:ok, result} = Aggregate.run(@tmp_dir, "app.log", "region", "count")

      assert result.occurrences == 2
      assert result.lines_without == 1
    end
  end

  describe "non-JSON honesty" do
    test "plain lines are counted in non_json, never silently ignored" do
      write!("mixed.log", ~s({"gated":true}\nplain text line\nanother plain line\n))

      {:ok, result} = Aggregate.run(@tmp_dir, "mixed.log", "gated", "exists")

      assert result.lines_with_field == 1
      assert result.non_json == 2
    end

    test "a fully plain-text file reports everything as non_json" do
      write!("plain.log", "2026-01-15 10:00:00 INFO started\n2026-01-15 10:00:01 INFO ready\n")

      {:ok, result} = Aggregate.run(@tmp_dir, "plain.log", "fields.gated", "exists")

      assert result.lines_with_field == 0
      assert result.lines_without == 0
      assert result.non_json == 2
    end
  end

  describe "filters" do
    test "pattern pre-filter restricts aggregation to matching lines" do
      write!(
        "app.log",
        ndjson([
          %{"message" => "checkout ok", "region" => "fra"},
          %{"message" => "checkout ok", "region" => "ams"},
          %{"message" => "healthz", "region" => "fra"}
        ])
      )

      {:ok, result} = Aggregate.run(@tmp_dir, "app.log", "region", "count", pattern: "checkout")

      assert result.occurrences == 2
    end

    test "since/until filter applies with unparsed_ts reported" do
      write!(
        "app.log",
        ndjson([
          %{"timestamp" => "2026-01-15T09:00:00Z", "region" => "fra"},
          %{"timestamp" => "2026-01-15T11:00:00Z", "region" => "ams"},
          %{"region" => "no-ts"}
        ])
      )

      {:ok, result} =
        Aggregate.run(@tmp_dir, "app.log", "region", "values", since: "2026-01-15T10:00:00Z")

      # 09:00 excluded; 11:00 included; the no-timestamp line passes fail-open
      values = Enum.map(result.entries, & &1.value) |> Enum.sort()
      assert values == ["ams", "no-ts"]
      assert result.unparsed_ts == 1
    end
  end

  describe "multi-file scan" do
    test "omitting file scans all logs" do
      write!("a.log", ndjson([%{"region" => "fra"}]))
      write!("b.log", ndjson([%{"region" => "ams"}]))

      {:ok, result} = Aggregate.run(@tmp_dir, nil, "region", "count")

      assert result.occurrences == 2
      assert result.files_scanned == 2
    end
  end

  describe "validation" do
    test "rejects a missing field" do
      assert {:error, msg} = Aggregate.run(@tmp_dir, "a.log", "", "exists")
      assert msg =~ "field is required"
    end

    test "rejects an unknown op" do
      write!("a.log", "x\n")
      assert {:error, msg} = Aggregate.run(@tmp_dir, "a.log", "region", "median")
      assert msg =~ "Invalid op"
    end

    test "unknown file errors" do
      assert {:error, msg} = Aggregate.run(@tmp_dir, "nope.log", "region", "count")
      assert msg =~ "not found"
    end
  end
end
