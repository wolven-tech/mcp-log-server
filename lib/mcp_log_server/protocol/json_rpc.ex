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

  alias McpLogServer.Protocol.{DiagnosticContext, OutputRedactor}

  @spec tool_result(term(), term(), map()) :: map()
  def tool_result(id, value, args \\ %{}) do
    text =
      case value do
        value when is_binary(value) -> value
        value -> Jason.encode!(value)
      end
      |> OutputRedactor.redact()

    structured =
      case Jason.decode(text) do
        {:ok, decoded} -> decoded
        _ -> %{rendered: text, format: "text"}
      end

    result(id, %{
      content: [%{type: "text", text: text}],
      structuredContent: %{
        context: DiagnosticContext.current(args),
        result: structured
      }
    })
  end

  @spec tool_error(term(), String.t(), map()) :: map()
  def tool_error(id, message, args \\ %{}) do
    message = OutputRedactor.redact(message)
    {code, retryable, action} = classify_error(message)

    result(id, %{
      content: [%{type: "text", text: "Error: #{message}"}],
      structuredContent: %{
        context: DiagnosticContext.current(args),
        error: %{
          code: code,
          message: message,
          retryable: retryable,
          actions: [%{code: action}]
        }
      },
      isError: true
    })
  end

  @spec error(term(), integer(), String.t()) :: map()
  def error(id, code, message) do
    %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}}
  end

  defp classify_error(message) do
    cond do
      String.contains?(message, "tenant") -> {"TENANT_BOUNDARY", false, "CHECK_STORE_ROUTE"}
      String.contains?(message, "not found") -> {"SOURCE_NOT_FOUND", false, "SELECT_SOURCE"}
      String.contains?(message, "required") -> {"INVALID_ARGUMENT", false, "NARROW_QUERY"}
      String.contains?(message, "invalid") -> {"INVALID_ARGUMENT", false, "NARROW_QUERY"}
      true -> {"SOURCE_UNAVAILABLE", true, "RETRY_AFTER"}
    end
  end
end
