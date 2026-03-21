defmodule McpLogServer.Domain.CleanupTest do
  use ExUnit.Case, async: false

  alias McpLogServer.Domain.FileAccess

  @tmp_dir System.tmp_dir!() |> Path.join("cleanup_test")

  setup do
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  defp write_file(name, content) do
    path = Path.join(@tmp_dir, name)
    File.write!(path, content)
    path
  end

  defp make_old(path, days_ago) do
    old_time =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-days_ago * 86400, :second)
      |> NaiveDateTime.to_erl()

    File.touch!(path, old_time)
  end

  describe "cleanup_old_logs/2" do
    test "deletes files older than retention period" do
      path = write_file("old.log", "old data\n")
      make_old(path, 10)

      write_file("new.log", "new data\n")

      FileAccess.cleanup_old_logs(@tmp_dir, 7)

      refute File.exists?(path)
      assert File.exists?(Path.join(@tmp_dir, "new.log"))
    end

    test "preserves files newer than retention period" do
      path = write_file("recent.log", "recent data\n")
      make_old(path, 3)

      FileAccess.cleanup_old_logs(@tmp_dir, 7)

      assert File.exists?(path)
    end

    test "never deletes symlinked files" do
      # Create a target outside tmp_dir so it won't be cleaned up
      external_dir = Path.join(System.tmp_dir!(), "cleanup_external_test")
      File.mkdir_p!(external_dir)
      target = Path.join(external_dir, "target.log")
      File.write!(target, "target data\n")
      make_old(target, 30)

      link_path = Path.join(@tmp_dir, "link.log")
      File.ln_s!(target, link_path)
      make_old(link_path, 30)

      FileAccess.cleanup_old_logs(@tmp_dir, 7)

      # The symlink file itself should NOT be deleted
      {:ok, lstat} = File.lstat(link_path)
      assert lstat.type == :symlink

      File.rm_rf!(external_dir)
    end

    test "does nothing when retention is nil" do
      path = write_file("keep.log", "keep\n")
      make_old(path, 999)

      FileAccess.cleanup_old_logs(@tmp_dir, nil)

      assert File.exists?(path)
    end

    test "does nothing when no files match" do
      write_file("fresh.log", "fresh\n")

      # Should not raise, should log "no files to clean up"
      assert :ok = FileAccess.cleanup_old_logs(@tmp_dir, 7)
    end
  end
end
