defmodule McpLogServer.Protocol.OutputRedactor do
  @moduledoc "Redact common credentials from diagnostic output before it crosses MCP."

  @sensitive_key ~r/((?:authorization|api[_-]?key|cookie|password|private[_-]?key|secret|token)\s*[=:]\s*)[^\s,;]+/i
  @json_sensitive_key ~r/("(?:authorization|api[_-]?key|cookie|password|private[_-]?key|secret|token)"\s*:\s*)"(?:\\.|[^"])*"/i
  @bearer ~r/(bearer\s+)[a-z0-9._~+\/-]+=*/i

  @spec redact(String.t()) :: String.t()
  def redact(text) when is_binary(text) do
    text
    |> replace(@json_sensitive_key, "\\1\"[REDACTED]\"")
    |> replace(@sensitive_key, "\\1[REDACTED]")
    |> replace(@bearer, "\\1[REDACTED]")
  end

  defp replace(text, regex, replacement), do: Regex.replace(regex, text, replacement)
end
