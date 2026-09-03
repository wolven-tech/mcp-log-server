defmodule McpLogServer.Protocol.DiagnosticContextTest do
  use ExUnit.Case, async: false

  alias McpLogServer.Protocol.DiagnosticContext

  setup do
    names = ~w(MCP_LOG_TENANT_ID MCP_LOG_ENVIRONMENT MCP_LOG_REGION MCP_LOG_RELEASE)
    previous = Map.new(names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  test "binds tenant and carries typed correlation" do
    System.put_env("MCP_LOG_TENANT_ID", "tenant-a")
    System.put_env("MCP_LOG_ENVIRONMENT", "production")
    System.put_env("MCP_LOG_REGION", "eu-west")
    System.put_env("MCP_LOG_RELEASE", "sha256:abc")

    args = %{
      "diagnostic" => %{
        "tenant_id" => "tenant-a",
        "request_id" => "req-1",
        "run_id" => "run-1"
      }
    }

    context = DiagnosticContext.current(args)

    assert context.tenant == %{id: "tenant-a", binding: "server_configuration", verified: true}
    assert context.environment == "production"
    assert context.region == "eu-west"
    assert context.release == "sha256:abc"
    assert context.freshThrough == nil
    assert context.correlation["requestId"] == "req-1"
    assert context.correlation["runId"] == "run-1"
  end

  test "rejects tenant override" do
    System.put_env("MCP_LOG_TENANT_ID", "tenant-a")

    assert {:error, message} =
             DiagnosticContext.validate_tenant(%{"diagnostic" => %{"tenant_id" => "tenant-b"}})

    assert message =~ "tenant boundary"
  end
end
