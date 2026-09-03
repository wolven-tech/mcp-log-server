defmodule McpLogServer.Tools.SyncLogs do
  @moduledoc "Pull logs from cloud storage (S3, GCS, Azure Blob) into LOG_DIR."

  @behaviour McpLogServer.Tools.Tool

  alias McpLogServer.Domain.TimestampParser
  alias McpLogServer.UseCases

  @impl true
  def name, do: "sync_logs"

  @impl true
  def description,
    do:
      "Pull logs from cloud storage into the log directory. Supports gs://, s3://, and az:// URIs. Requires the respective CLI tool (gsutil, aws, az) to be installed."

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        source: %{
          type: "string",
          description:
            "Cloud storage URI (e.g. \"gs://bucket/logs/\", \"s3://bucket/logs/\", \"az://container/logs/\")"
        },
        prefix: %{type: "string", description: "Only sync files matching this name prefix"},
        since: %{
          type: "string",
          description:
            "Only sync files modified after this time. ISO 8601 or relative shorthand (e.g. \"1h\", \"1d\")"
        },
        dry_run: %{
          type: "boolean",
          default: true,
          description:
            "Preview authorized source and filters without copying. Set false only for an explicitly authorized sync."
        }
      },
      required: ["source"]
    }
  end

  @impl true
  def execute(args, log_dir) do
    source = Map.get(args, "source", "")
    prefix = Map.get(args, "prefix")
    dry_run? = Map.get(args, "dry_run", true)

    with :ok <- validate_source(source),
         :ok <- validate_since(Map.get(args, "since")),
         :ok <- authorize_source(source, dry_run?) do
      if dry_run? do
        {:ok,
         %{
           dryRun: true,
           source: safe_source_label(source),
           prefix: prefix,
           since: Map.get(args, "since"),
           action: "Set dry_run=false after explicit authorization to copy matching logs."
         }}
      else
        opts =
          case Map.get(args, "since") do
            s when is_binary(s) and s != "" -> [since: s]
            _ -> []
          end

        UseCases.SyncLogs.run(source, log_dir, prefix, opts)
      end
    end
  end

  defp validate_source(source) do
    uri = URI.parse(source)

    if uri.scheme in ["gs", "s3", "az"] and is_binary(uri.host) and uri.host != "" do
      :ok
    else
      {:error, "source must be a gs://, s3://, or az:// URI with a bucket or container"}
    end
  end

  defp validate_since(nil), do: :ok
  defp validate_since(""), do: :ok

  defp validate_since(value) when is_binary(value) do
    if TimestampParser.parse_time(value) do
      :ok
    else
      {:error,
       "Invalid since: #{inspect(value)}. Expected ISO 8601 or relative shorthand such as 30m, 2h, or 1d."}
    end
  end

  defp validate_since(_), do: {:error, "since must be a string"}

  defp authorize_source(_source, true), do: :ok

  defp authorize_source(source, false) do
    enabled? = Application.get_env(:mcp_log_server, :sync_enabled, false)
    allowed = Application.get_env(:mcp_log_server, :sync_allowed_sources, [])

    cond do
      not enabled? ->
        {:error,
         "log sync is disabled by server policy; ask an operator to enable an allowlisted source"}

      Enum.any?(allowed, &String.starts_with?(source, &1)) ->
        :ok

      true ->
        {:error, "source is not allowed by server policy"}
    end
  end

  defp safe_source_label(source) do
    uri = URI.parse(source)
    path = uri.path || "/"
    "#{uri.scheme}://#{uri.host}#{path}"
  end
end
