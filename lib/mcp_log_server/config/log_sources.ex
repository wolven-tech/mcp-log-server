defmodule McpLogServer.Config.LogSources do
  @moduledoc """
  Config-boundary owner of declared streamed log sources (`LOG_SOURCES`).

  The raw declaration string is read from the environment once (via
  `config/runtime.exs` into the application env) and parsed ONCE at
  application startup by `init!/0` — a malformed declaration fails boot
  loudly instead of silently dropping the source the operator asked for.
  Parsed specs are cached in `:persistent_term` for zero-copy reads.

  Pure parsing/validation lives in `McpLogServer.Domain.SourceSpec`; this
  module only bridges environment to domain data, following the same
  philosophy as `McpLogServer.Config.TsFormats`.
  """

  alias McpLogServer.Domain.SourceSpec

  @persistent_term_key :mcp_log_server_log_sources

  @doc """
  Parse the `LOG_SOURCES` declaration from application config.

  Must be called at application startup. Raises `ArgumentError` with a
  descriptive message when the declaration is invalid, so a broken
  declaration aborts boot.
  """
  @spec init!() :: :ok
  def init! do
    raw = Application.get_env(:mcp_log_server, :log_sources)

    case SourceSpec.parse_declarations(raw) do
      {:ok, specs} ->
        :persistent_term.put(@persistent_term_key, specs)
        :ok

      {:error, message} ->
        raise ArgumentError,
              "Invalid LOG_SOURCES: #{message}. " <>
                "Expected 'name:cmd=command' entries separated by ';', e.g. " <>
                "LOG_SOURCES='fly:cmd=flyctl logs -a my-app; k8s:cmd=kubectl logs -f deploy/api'"
    end
  end

  @doc "Return all declared source specs (initializing lazily if needed)."
  @spec declared() :: [SourceSpec.t()]
  def declared do
    :persistent_term.get(@persistent_term_key)
  rescue
    ArgumentError ->
      init!()
      :persistent_term.get(@persistent_term_key)
  end
end
