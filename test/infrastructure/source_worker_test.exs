defmodule McpLogServer.Infrastructure.SourceWorkerTest do
  use ExUnit.Case, async: false

  alias McpLogServer.Infrastructure.SourceStatus
  alias McpLogServer.Infrastructure.SourceWorker

  @tmp_dir System.tmp_dir!() |> Path.join("source_worker_test")

  # Fast timings: all waits are millisecond-scale polls, no long sleeps.
  @fast_backoff [initial_ms: 20, cap_ms: 100, healthy_after_ms: 60_000]

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    SourceStatus.ensure_table()

    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  defp start_worker(name, argv, opts \\ []) do
    spec = %{name: name, cmd: Enum.join(argv, " "), argv: argv}

    {:ok, pid} =
      SourceWorker.start_link(
        [spec: spec, log_dir: @tmp_dir] ++ @fast_backoff ++ opts
      )

    on_exit(fn ->
      # The worker is linked to the (now dead) test process; OTP shuts it
      # down via the parent-exit path. Just wait for it to finish dying.
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        2_000 -> Process.exit(pid, :kill)
      end

      SourceStatus.delete(name)
    end)

    pid
  end

  defp eventually(fun, timeout_ms \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll(fun, deadline)
  end

  defp poll(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline do
        flunk("condition not met within timeout")
      else
        Process.sleep(10)
        poll(fun, deadline)
      end
    end
  end

  defp read(name), do: File.read!(Path.join(@tmp_dir, name))

  # Rotation can move a file between an exists-check and a read; degrade to "".
  defp safe_read(name) do
    case File.read(Path.join(@tmp_dir, name)) do
      {:ok, content} -> content
      _ -> ""
    end
  end

  describe "streaming" do
    test "appends tagged stdout lines to LOG_DIR/<name>.log and reports :running" do
      start_worker("demo", ["sh", "-c", "printf 'one\\ntwo\\n'; sleep 60"])

      eventually(fn ->
        File.exists?(Path.join(@tmp_dir, "demo.log")) and
          read("demo.log") =~ "[src:demo] two"
      end)

      assert read("demo.log") == "[src:demo] one\n[src:demo] two\n"
      assert SourceStatus.get("demo") == :running
    end

    test "creates the ingest file at boot, before any output arrives" do
      start_worker("idle", ["sh", "-c", "sleep 60"])
      eventually(fn -> File.exists?(Path.join(@tmp_dir, "idle.log")) end)
    end
  end

  describe "rotation" do
    test "rotates before the threshold and keeps only N rotations" do
      script = "i=0; while [ $i -lt 20 ]; do echo line-$i; i=$((i+1)); done; sleep 60"

      start_worker("rot", ["sh", "-c", script], rotate_bytes: 60, rotations: 2)

      # Last line must land somewhere (current or rotated file).
      eventually(fn ->
        Enum.any?(["rot.log", "rot.1.log", "rot.2.log"], &(safe_read(&1) =~ "line-19"))
      end)

      assert File.exists?(Path.join(@tmp_dir, "rot.1.log"))
      assert File.exists?(Path.join(@tmp_dir, "rot.2.log"))
      # Keep-count honored: nothing beyond .2 survives 20 lines / ~60B files.
      refute File.exists?(Path.join(@tmp_dir, "rot.3.log"))

      # Disk stays bounded: no file ever exceeds the threshold.
      for file <- ["rot.log", "rot.1.log", "rot.2.log"] do
        assert File.stat!(Path.join(@tmp_dir, file)).size <= 60
      end

      # Rotated lines keep their source tags.
      assert read("rot.1.log") =~ "[src:rot] "
    end
  end

  describe "restart with backoff" do
    test "respawns an exiting command (with growing delays) and reports :backing_off" do
      start_worker("flappy", ["sh", "-c", "echo ping"])

      # >= 3 pings proves at least two supervised respawns happened.
      eventually(fn ->
        File.exists?(Path.join(@tmp_dir, "flappy.log")) and
          (read("flappy.log") |> String.split("\n", trim: true) |> length()) >= 3
      end)

      assert read("flappy.log") =~ "[src:flappy] ping"

      # Between runs the worker publishes :backing_off (delays dominate the
      # short-lived command, so polling reliably observes it).
      eventually(fn -> SourceStatus.get("flappy") == :backing_off end)
    end

    test "a missing executable reports :dead and keeps the worker alive" do
      pid = start_worker("gone", ["mcp-log-server-no-such-exe-xyz"])

      eventually(fn -> SourceStatus.get("gone") == :dead end)
      assert Process.alive?(pid)
      # The ingest file still exists so list_logs can show the dead source.
      assert File.exists?(Path.join(@tmp_dir, "gone.log"))
    end
  end
end
