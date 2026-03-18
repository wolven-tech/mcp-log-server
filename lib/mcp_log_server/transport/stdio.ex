defmodule McpLogServer.Transport.Stdio do
  @moduledoc """
  Stdio transport layer. Reads JSON lines from stdin, writes JSON lines to stdout.
  Delegates parsed messages to a callback module.
  """

  use GenServer
  require Logger

  @type handler :: (String.t() -> :ok)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Write a JSON-encoded response line to stdout."
  @spec send_response(map()) :: :ok
  def send_response(response) do
    IO.write(:stdio, Jason.encode!(response) <> "\n")
  end

  # -- GenServer callbacks --

  @impl true
  def init(opts) do
    handler = Keyword.fetch!(opts, :handler)

    :ok = :io.setopts(:standard_error, encoding: :utf8)
    :ok = :io.setopts(:standard_io, encoding: :utf8)

    {:ok, _pid} = Task.start_link(fn -> read_loop() end)
    {:ok, %{handler: handler}}
  end

  @impl true
  def handle_info({:stdin_line, line}, state) do
    case String.trim(line) do
      "" ->
        :ok

      trimmed ->
        try do
          state.handler.(trimmed)
        rescue
          e ->
            Logger.error("Handler crashed: #{Exception.message(e)}")
        end
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:stdin_eof}, _state) do
    System.halt(0)
    {:noreply, %{}}
  end

  defp read_loop do
    case IO.read(:stdio, :line) do
      :eof ->
        send(__MODULE__, {:stdin_eof})

      {:error, _reason} ->
        send(__MODULE__, {:stdin_eof})

      line when is_binary(line) ->
        send(__MODULE__, {:stdin_line, line})
        read_loop()
    end
  end
end
