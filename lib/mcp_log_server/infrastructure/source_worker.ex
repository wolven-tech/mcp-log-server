defmodule McpLogServer.Infrastructure.SourceWorker do
  @moduledoc """
  Supervised worker that tees ONE declared streaming command (a
  `LOG_SOURCES` entry) into a rotating file under `LOG_DIR`.

  Responsibilities:

    * spawn the command via `Port.open({:spawn_executable, exe}, args: ...)`
      — argv comes pre-tokenized from `McpLogServer.Domain.SourceSpec`; no
      shell ever interprets the declaration
    * append each stdout line to `LOG_DIR/<name>.log`, prefixed with the
      `[src:<name>] ` tag (`McpLogServer.Domain.SourceTag`) so cross-source
      correlation can attribute every line
    * rotate to `<name>.1.log` .. `<name>.N.log` BEFORE the file would
      exceed the rotation threshold — an unattended `-f` stream grows
      unboundedly and would otherwise trip the oversized-file skip, silently
      killing the very source the user declared
    * respawn the command on exit with exponential backoff
      (`McpLogServer.Domain.Backoff`: 1s → 2s → ... cap 60s, reset after a
      healthy run), publishing :running / :backing_off / :dead to
      `McpLogServer.Infrastructure.SourceStatus`

  stdout is sacred: it carries MCP JSON-RPC. The command's stdout is
  captured by the port (never forwarded), its stderr inherits the server's
  stderr, and all worker diagnostics go to stderr via `IO.write/2` —
  bypassing Logger so no level configuration can ever reroute them.

  Test hooks: `:rotate_bytes`, `:rotations`, `:initial_ms`, `:cap_ms`, and
  `:healthy_after_ms` can be injected through `start_link/1` opts so tests
  exercise rotation and the backoff schedule in milliseconds.
  """

  use GenServer

  alias McpLogServer.Domain.Backoff
  alias McpLogServer.Domain.SourceTag
  alias McpLogServer.Infrastructure.EnvConfig
  alias McpLogServer.Infrastructure.SourceStatus

  # Port line-buffer limit; longer lines arrive as :noeol chunks and are
  # reassembled in state.buffer.
  @max_line 65_536

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    spec = Keyword.fetch!(opts, :spec)
    log_dir = Keyword.fetch!(opts, :log_dir)

    rotate_bytes =
      Keyword.get_lazy(opts, :rotate_bytes, fn -> EnvConfig.source_rotate_mb() * 1_048_576 end)

    rotations = Keyword.get_lazy(opts, :rotations, fn -> EnvConfig.source_rotations() end)
    backoff_opts = Keyword.take(opts, [:initial_ms, :cap_ms, :healthy_after_ms])

    File.mkdir_p!(log_dir)
    path = Path.join(log_dir, spec.name <> ".log")
    # Open (and thereby create) the file up front so the source is visible
    # in list_logs from boot, even before the first line arrives.
    {:ok, device} = File.open(path, [:append, :raw, :binary])
    size = current_size(path)

    state = %{
      name: spec.name,
      argv: spec.argv,
      cmd: spec.cmd,
      log_dir: log_dir,
      path: path,
      device: device,
      size: size,
      rotate_bytes: rotate_bytes,
      rotations: max(rotations, 1),
      backoff_opts: backoff_opts,
      backoff_ms: Backoff.initial_ms(backoff_opts),
      port: nil,
      buffer: "",
      spawned_at: nil
    }

    {:ok, state, {:continue, :spawn}}
  end

  @impl true
  def handle_continue(:spawn, state), do: {:noreply, spawn_port(state)}

  @impl true
  def handle_info({port, {:data, {:eol, chunk}}}, %{port: port} = state) do
    state = write_line(%{state | buffer: ""}, state.buffer <> chunk)
    {:noreply, state}
  end

  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    {:noreply, %{state | buffer: state.buffer <> chunk}}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    state = flush_buffer(state)
    uptime = System.monotonic_time(:millisecond) - (state.spawned_at || 0)
    {delay, next} = Backoff.on_exit(state.backoff_ms, uptime, state.backoff_opts)

    log_stderr(state, "command exited with status #{code}; restarting in #{delay}ms")
    SourceStatus.put(state.name, :backing_off)
    Process.send_after(self(), :respawn, delay)

    {:noreply, %{state | port: nil, spawned_at: nil, backoff_ms: next}}
  end

  def handle_info(:respawn, %{port: nil} = state), do: {:noreply, spawn_port(state)}
  def handle_info(:respawn, state), do: {:noreply, state}

  # Port link exits (we trap exits); :exit_status above already handled it.
  def handle_info({:EXIT, _from, _reason}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.port do
      # Port.close/1 only closes the pipe; a command that shrugs off EPIPE
      # (e.g. a shell loop) would linger. Send SIGTERM to the OS process
      # explicitly on clean shutdown.
      kill_os_process(state.port)
      safe_close_port(state.port)
    end

    File.close(state.device)
    SourceStatus.delete(state.name)
    :ok
  end

  # -- Spawning --

  defp spawn_port(state) do
    [exe_name | args] = state.argv

    case System.find_executable(exe_name) do
      nil ->
        # Cannot even start: mark dead (not backing-off) so list_logs shows
        # the truth, but keep retrying — PATH problems can be fixed live.
        {delay, next} = Backoff.on_exit(state.backoff_ms, 0, state.backoff_opts)
        log_stderr(state, "executable not found: #{exe_name}; retrying in #{delay}ms")
        SourceStatus.put(state.name, :dead)
        Process.send_after(self(), :respawn, delay)
        %{state | port: nil, spawned_at: nil, backoff_ms: next}

      exe ->
        try do
          port =
            Port.open(
              {:spawn_executable, exe},
              [:binary, :exit_status, {:args, args}, {:line, @max_line}]
            )

          SourceStatus.put(state.name, :running)
          %{state | port: port, buffer: "", spawned_at: System.monotonic_time(:millisecond)}
        rescue
          e ->
            {delay, next} = Backoff.on_exit(state.backoff_ms, 0, state.backoff_opts)
            log_stderr(state, "spawn failed (#{Exception.message(e)}); retrying in #{delay}ms")
            SourceStatus.put(state.name, :dead)
            Process.send_after(self(), :respawn, delay)
            %{state | port: nil, spawned_at: nil, backoff_ms: next}
        end
    end
  end

  # -- Writing and rotation --

  defp write_line(state, line) do
    data = SourceTag.tag_line(state.name, line) <> "\n"
    state = maybe_rotate(state, byte_size(data))
    IO.binwrite(state.device, data)
    %{state | size: state.size + byte_size(data)}
  end

  defp flush_buffer(%{buffer: ""} = state), do: state
  defp flush_buffer(state), do: write_line(%{state | buffer: ""}, state.buffer)

  # Rotate BEFORE the write that would cross the threshold, so neither the
  # live file nor any rotated file ever exceeds it (rotated files stay
  # readable by every tool).
  defp maybe_rotate(%{size: size, rotate_bytes: max_bytes} = state, incoming)
       when size > 0 and size + incoming > max_bytes do
    rotate(state)
  end

  defp maybe_rotate(state, _incoming), do: state

  defp rotate(state) do
    File.close(state.device)

    File.rm(rotated_path(state, state.rotations))

    if state.rotations > 1 do
      for k <- (state.rotations - 1)..1//-1 do
        File.rename(rotated_path(state, k), rotated_path(state, k + 1))
      end
    end

    File.rename(state.path, rotated_path(state, 1))
    {:ok, device} = File.open(state.path, [:append, :raw, :binary])
    log_stderr(state, "rotated #{Path.basename(state.path)} (keep #{state.rotations})")
    %{state | device: device, size: 0}
  end

  defp rotated_path(state, k), do: Path.join(state.log_dir, "#{state.name}.#{k}.log")

  defp current_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  defp safe_close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  # System.cmd captures kill's output into the return value — nothing can
  # leak onto our stdout.
  defp kill_os_process(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)
        :ok

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  # Diagnostics go straight to stderr — never stdout (the MCP transport),
  # and not through Logger so no runtime level/handler change can reroute them.
  defp log_stderr(state, message) do
    IO.write(:standard_error, "[mcp-log-server] source #{state.name}: #{message}\n")
  end
end
