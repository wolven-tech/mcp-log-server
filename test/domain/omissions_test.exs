defmodule McpLogServer.Domain.OmissionsTest do
  use ExUnit.Case, async: true

  alias McpLogServer.Domain.Omissions

  test "cap is a no-op when the bound was not exceeded (zero noise)" do
    om = Omissions.cap(Omissions.new(), :matches, 10, 50, "first 50")
    assert Omissions.empty?(om)
    assert Omissions.attach(%{a: 1}, om) == %{a: 1}
  end

  test "cap records omitted count and what is shown" do
    om = Omissions.cap(Omissions.new(), :matches, 340, 100, "newest 100")
    assert om == %{matches: %{omitted: 240, showing: "newest 100"}}
  end

  test "omitted with 0 is a no-op — never emit omitted: 0" do
    assert Omissions.empty?(Omissions.omitted(Omissions.new(), :matches, 0, "x"))
  end

  test "capped_at marks an unknown remainder" do
    om = Omissions.capped_at(Omissions.new(), :matches, 500)
    assert om == %{matches: %{capped_at: 500}}
  end

  test "skipped files accumulate in order" do
    om =
      Omissions.new()
      |> Omissions.skipped_file("a.log", "too big")
      |> Omissions.skipped_file("b.log", "also too big")

    assert om.skipped_files == [
             %{file: "a.log", reason: "too big"},
             %{file: "b.log", reason: "also too big"}
           ]
  end

  test "attach puts the block only when non-empty" do
    om = Omissions.skipped_file(Omissions.new(), "a.log", "too big")
    assert %{omissions: ^om} = Omissions.attach(%{}, om)
    refute Map.has_key?(Omissions.attach(%{}, Omissions.new()), :omissions)
  end
end
