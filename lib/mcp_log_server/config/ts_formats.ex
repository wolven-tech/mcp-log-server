defmodule McpLogServer.Config.TsFormats do
  @moduledoc """
  Config-boundary owner of declared timestamp formats (`LOG_TS_FORMATS`).

  The raw declaration string is read from the environment once (via
  `config/runtime.exs` into the application env) and compiled ONCE at
  application startup by `init!/0` — a typo'd format string fails loudly at
  boot instead of silently producing 0% parse rates at query time. Compiled
  declarations are cached in `:persistent_term` for zero-copy reads.

  Pure parsing/compilation lives in `McpLogServer.Domain.TsFormat`; this
  module only bridges environment to domain data, following the same
  philosophy as `McpLogServer.Config.Patterns`.
  """

  alias McpLogServer.Domain.TsFormat

  @persistent_term_key :mcp_log_server_ts_formats

  @doc """
  Compile the `LOG_TS_FORMATS` declaration from application config.

  Must be called at application startup. Raises `ArgumentError` with a
  descriptive message when the declaration is invalid, so a broken
  declaration aborts boot.
  """
  @spec init!() :: :ok
  def init! do
    raw = Application.get_env(:mcp_log_server, :ts_formats)

    case TsFormat.parse_declarations(raw) do
      {:ok, declarations} ->
        :persistent_term.put(@persistent_term_key, declarations)
        :ok

      {:error, message} ->
        raise ArgumentError,
              "Invalid LOG_TS_FORMATS: #{message}. " <>
                "Expected 'glob=format' entries separated by ';', e.g. " <>
                "LOG_TS_FORMATS='fly-*.log=%FT%T%.fZ; app*.log=epoch_ms; dev-*.log=%H:%M:%S'"
    end
  end

  @doc """
  Return the compiled format declared for `basename`, or `nil` when no glob
  matches (auto-detection applies then).
  """
  @spec for_file(String.t()) :: TsFormat.compiled() | nil
  def for_file(basename) do
    TsFormat.for_file(declarations(), basename)
  end

  @doc "Return all compiled declarations (initializing lazily if needed)."
  @spec declarations() :: [TsFormat.declaration()]
  def declarations do
    :persistent_term.get(@persistent_term_key)
  rescue
    ArgumentError ->
      init!()
      :persistent_term.get(@persistent_term_key)
  end
end
