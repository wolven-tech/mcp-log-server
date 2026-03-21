defmodule McpLogServer.Config.Patterns do
  @moduledoc """
  Configurable log-level pattern matching.

  Provides compiled regexes for each severity level that can be used to classify
  plain-text log lines. Patterns are compiled once at application startup via
  `init/0` and cached in `:persistent_term` for zero-copy reads.

  ## Severity hierarchy

      trace(0) < debug(1) < info(2) < warn(3) < error(4) < fatal(5)

  ## Environment variables (read at runtime via config/runtime.exs)

  * `LOG_FATAL_PATTERNS` — override default fatal patterns (pipe-separated)
  * `LOG_ERROR_PATTERNS` — override default error patterns (pipe-separated)
  * `LOG_WARN_PATTERNS`  — override default warn patterns (pipe-separated)
  * `LOG_EXTRA_PATTERNS` — additional patterns merged into the error level

  ## Breaking change

  Bare `failed`/`Failed` has been removed from the default patterns to avoid
  false positives (e.g. `"failed": 0` in JSON health-check responses).
  """

  @levels [:trace, :debug, :info, :warn, :error, :fatal]

  @level_values %{
    trace: 0,
    debug: 1,
    info: 2,
    warn: 3,
    error: 4,
    fatal: 5
  }

  @default_patterns %{
    fatal: "FATAL|PANIC|OOMKilled|SIGKILL",
    error: "ERROR|EXCEPTION|TypeError|ReferenceError|SyntaxError|ECONNREFUSED|ENOTFOUND|UnhandledPromiseRejection",
    warn: "WARN|WARNING|deprecated|timeout"
  }

  # These levels are detected but not configurable via env vars
  @info_regex Regex.compile!("\\bINFO\\b", "i")
  @debug_regex Regex.compile!("\\bDEBUG\\b", "i")
  @trace_regex Regex.compile!("\\bTRACE\\b", "i")

  @persistent_term_key :mcp_log_server_patterns

  @doc """
  Initialize compiled patterns from application config.

  Must be called once at application startup (before any log analysis).
  Reads pattern overrides from `Application.get_env(:mcp_log_server, :patterns)`
  which is populated from environment variables via `config/runtime.exs`.
  """
  @spec init() :: :ok
  def init do
    config = Application.get_env(:mcp_log_server, :patterns, %{})

    fatal_source = config[:fatal] || @default_patterns.fatal
    warn_source = config[:warn] || @default_patterns.warn

    error_base = config[:error] || @default_patterns.error
    extra = config[:extra]
    error_source = if extra, do: "#{error_base}|#{extra}", else: error_base

    compiled = %{
      fatal: %{regex: Regex.compile!("(#{fatal_source})", "i"), source: fatal_source},
      error: %{regex: Regex.compile!("(#{error_source})", "i"), source: error_source},
      warn: %{regex: Regex.compile!("(#{warn_source})", "i"), source: warn_source}
    }

    :persistent_term.put(@persistent_term_key, compiled)
    :ok
  end

  @doc "Returns the ordered list of severity levels from lowest to highest."
  @spec levels() :: [atom()]
  def levels, do: @levels

  @doc "Returns the numeric value for a severity level."
  @spec level_value(atom()) :: non_neg_integer()
  def level_value(level) when is_map_key(@level_values, level) do
    Map.fetch!(@level_values, level)
  end

  @doc """
  Returns `true` if `line` contains a pattern at the given severity level or above.

  For example, `matches_level?(line, :warn)` returns true if the line matches
  warn, error, or fatal patterns.
  """
  @spec matches_level?(String.t(), atom()) :: boolean()
  def matches_level?(line, level) do
    threshold = level_value(level)

    case detect_level(line) do
      nil -> false
      detected -> level_value(detected) >= threshold
    end
  end

  @doc """
  Detects the severity level of a plain-text log line.

  Returns the highest matching severity atom (`:fatal`, `:error`, `:warn`,
  `:info`, `:debug`, `:trace`), or `nil` if no patterns match.

  Fatal, error, and warn patterns are configurable via environment variables.
  Info, debug, and trace use fixed patterns.
  """
  @spec detect_level(String.t()) :: atom() | nil
  def detect_level(line) do
    compiled = get_compiled()

    cond do
      Regex.match?(compiled.fatal.regex, line) -> :fatal
      Regex.match?(compiled.error.regex, line) -> :error
      Regex.match?(compiled.warn.regex, line) -> :warn
      Regex.match?(@info_regex, line) -> :info
      Regex.match?(@debug_regex, line) -> :debug
      Regex.match?(@trace_regex, line) -> :trace
      true -> nil
    end
  end

  @doc "Returns the compiled regex for a given severity level."
  @spec regex_for(atom()) :: Regex.t() | nil
  def regex_for(level) when level in [:fatal, :error, :warn] do
    get_compiled()[level].regex
  end

  def regex_for(_), do: nil

  @doc "Returns the raw pattern source string for a given severity level."
  @spec pattern_source(atom()) :: String.t() | nil
  def pattern_source(level) when level in [:fatal, :error, :warn] do
    get_compiled()[level].source
  end

  def pattern_source(_), do: nil

  @doc "Returns the default (built-in) patterns map before any env var overrides."
  @spec defaults() :: map()
  def defaults, do: @default_patterns

  # Read compiled patterns from persistent_term, initializing lazily if needed.
  defp get_compiled do
    try do
      :persistent_term.get(@persistent_term_key)
    rescue
      ArgumentError ->
        init()
        :persistent_term.get(@persistent_term_key)
    end
  end
end
