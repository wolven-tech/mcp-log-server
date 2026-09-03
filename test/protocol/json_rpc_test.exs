defmodule McpLogServer.Protocol.JsonRpcTest do
  use ExUnit.Case, async: true

  alias McpLogServer.Protocol.JsonRpc

  test "returns structured content while retaining text" do
    response = JsonRpc.tool_result(7, ~s({"count":2}), %{})

    assert get_in(response, [:result, :content]) == [%{type: "text", text: ~s({"count":2})}]
    assert get_in(response, [:result, :structuredContent, :result]) == %{"count" => 2}
    assert get_in(response, [:result, :structuredContent, :context, :contractVersion]) == "1.0"
  end

  test "serializes structured tool values without losing fields" do
    response = JsonRpc.tool_result(1, %{dryRun: true, source: "gs://bucket/logs/"})

    assert get_in(response, [:result, :structuredContent, :result]) == %{
             "dryRun" => true,
             "source" => "gs://bucket/logs/"
           }

    assert Jason.decode!(hd(response.result.content).text)["dryRun"]
  end

  test "redacts credentials from text and structured content" do
    response = JsonRpc.tool_result(7, ~s({"token":"secret-value","message":"ok"}), %{})

    refute inspect(response) =~ "secret-value"
    assert get_in(response, [:result, :structuredContent, :result, "token"]) == "[REDACTED]"
  end

  test "returns actionable structured errors" do
    response = JsonRpc.tool_error(8, "log source not found: api.log", %{})

    assert get_in(response, [:result, :isError])
    assert get_in(response, [:result, :structuredContent, :error, :code]) == "SOURCE_NOT_FOUND"
    assert get_in(response, [:result, :structuredContent, :error, :retryable]) == false

    assert get_in(response, [:result, :structuredContent, :error, :actions]) == [
             %{code: "SELECT_SOURCE"}
           ]
  end

  test "redacts credentials from errors" do
    response = JsonRpc.tool_error(8, "authorization=secret-value invalid", %{})

    refute inspect(response) =~ "secret-value"
    assert get_in(response, [:result, :structuredContent, :error, :message]) =~ "[REDACTED]"
  end
end
