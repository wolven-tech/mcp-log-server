defmodule McpLogServer.Server do
  @moduledoc """
  MCP server orchestrator. Wires transport -> protocol -> tools -> domain.

  Receives raw JSON lines from the transport, parses them as JSON-RPC,
  routes to the appropriate MCP handler, and sends responses back.
  """

  alias McpLogServer.Protocol.JsonRpc
  alias McpLogServer.Tools.{Dispatcher, Registry}
  alias McpLogServer.Transport.Stdio

  @server_info %{name: "mcp-log-server", version: "0.1.0"}

  @doc "Handle a raw JSON line from the transport."
  @spec handle_message(String.t()) :: :ok
  def handle_message(json) do
    case JsonRpc.parse(json) do
      {:ok, request} -> route(request)
      {:error, :parse_error} -> Stdio.send_response(JsonRpc.error(nil, -32_700, "Parse error"))
    end

    :ok
  end

  @doc "Return the log directory from application config."
  @spec log_dir() :: String.t()
  def log_dir, do: Application.fetch_env!(:mcp_log_server, :log_dir)

  # -- MCP routing --

  defp route(%{method: "initialize", id: id}) do
    Stdio.send_response(
      JsonRpc.result(id, %{
        protocolVersion: "2024-11-05",
        capabilities: %{tools: %{}},
        serverInfo: @server_info
      })
    )
  end

  defp route(%{method: "notifications/initialized"}), do: :ok

  defp route(%{method: "tools/list", id: id}) do
    Stdio.send_response(JsonRpc.result(id, %{tools: Registry.definitions()}))
  end

  defp route(%{method: "tools/call", id: id, params: params}) do
    tool = Map.get(params, "name")
    args = Map.get(params, "arguments", %{})

    cond do
      not is_binary(tool) ->
        Stdio.send_response(JsonRpc.error(id, -32_602, "Missing or invalid tool name"))

      not is_map(args) ->
        Stdio.send_response(JsonRpc.error(id, -32_602, "Arguments must be an object"))

      true ->
        response =
          case Dispatcher.call(tool, args, log_dir()) do
            {:ok, text} -> JsonRpc.tool_result(id, text)
            {:error, reason} -> JsonRpc.tool_error(id, reason)
          end

        Stdio.send_response(response)
    end
  end

  defp route(%{method: method, id: id}) when is_binary(method) and not is_nil(id) do
    Stdio.send_response(JsonRpc.error(id, -32_601, "Method not found: #{method}"))
  end

  defp route(_), do: :ok
end
