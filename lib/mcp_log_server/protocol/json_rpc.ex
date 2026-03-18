defmodule McpLogServer.Protocol.JsonRpc do
  @moduledoc """
  JSON-RPC 2.0 parsing and response building.
  Pure functions — no state, no I/O.
  """

  @type request :: %{
          method: String.t(),
          id: term() | nil,
          params: map()
        }

  @spec parse(String.t()) :: {:ok, request()} | {:error, :parse_error}
  def parse(json) do
    case Jason.decode(json) do
      {:ok, %{"method" => method} = msg} ->
        {:ok,
         %{
           method: method,
           id: Map.get(msg, "id"),
           params: Map.get(msg, "params", %{})
         }}

      _ ->
        {:error, :parse_error}
    end
  end

  @spec result(term(), term()) :: map()
  def result(id, result) do
    %{jsonrpc: "2.0", id: id, result: result}
  end

  @spec tool_result(term(), String.t()) :: map()
  def tool_result(id, text) do
    result(id, %{content: [%{type: "text", text: text}]})
  end

  @spec tool_error(term(), String.t()) :: map()
  def tool_error(id, message) do
    result(id, %{content: [%{type: "text", text: "Error: #{message}"}], isError: true})
  end

  @spec error(term(), integer(), String.t()) :: map()
  def error(id, code, message) do
    %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}}
  end
end
