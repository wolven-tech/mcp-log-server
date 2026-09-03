defmodule McpLogServer.Protocol.DiagnosticContext do
  @moduledoc "Machine-readable provenance and tenant/correlation verification for tool results."

  @correlation_keys ~w(request_id trace_id run_id workflow_run_id entity_id conversation_id)

  @spec current(map()) :: map()
  def current(args \\ %{}) do
    configured_tenant = env("MCP_LOG_TENANT_ID")
    requested_tenant = get_in(args, ["diagnostic", "tenant_id"])

    %{
      contractVersion: "1.0",
      tenant: tenant_context(configured_tenant, requested_tenant),
      environment: env("MCP_LOG_ENVIRONMENT") || "local",
      region: env("MCP_LOG_REGION"),
      service: "mcp-log-server",
      serverVersion: server_version(),
      release: env("MCP_LOG_RELEASE"),
      observedAt: DateTime.utc_now() |> DateTime.to_iso8601(),
      freshThrough: nil,
      correlation: correlation(args)
    }
  end

  @spec validate_tenant(map()) :: :ok | {:error, String.t()}
  def validate_tenant(args) do
    configured = env("MCP_LOG_TENANT_ID")
    requested = get_in(args, ["diagnostic", "tenant_id"])

    if configured && requested && configured != requested do
      {:error, "diagnostic.tenant_id does not match this server's configured tenant boundary"}
    else
      :ok
    end
  end

  @spec server_version() :: String.t()
  def server_version do
    case Application.spec(:mcp_log_server, :vsn) do
      nil -> "unknown"
      version -> to_string(version)
    end
  end

  defp tenant_context(configured, requested) when is_binary(configured) do
    %{
      id: configured,
      binding: "server_configuration",
      verified: requested in [nil, configured]
    }
  end

  defp tenant_context(nil, requested) do
    %{id: requested, binding: "unverified", verified: false}
  end

  defp correlation(args) do
    diagnostic = Map.get(args, "diagnostic", %{})

    Map.new(@correlation_keys, fn key ->
      {camelize(key), Map.get(diagnostic, key)}
    end)
  end

  defp camelize(key) do
    [head | tail] = String.split(key, "_")
    head <> Enum.map_join(tail, &String.capitalize/1)
  end

  defp env(name) do
    case System.get_env(name) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end
end
