defmodule McpLogServer.Domain.MessageTemplate do
  @moduledoc """
  Pure normalization of log lines into stable message templates.

  With N instances emitting near-identical lines, "did X happen?" is not a
  grep — it's "on how many instances, first/last when?". Collapsing volatile
  tokens (timestamps, UUIDs, IPs, hex ids, numbers, optionally quoted
  strings) into placeholders makes near-identical lines land on the SAME
  template, so a rollup can answer that question in one call:

      2026-07-17T10:00:01Z conn 4f9a lost to 10.0.0.7:5432 after 30s
      2026-07-17T10:02:44Z conn 77b1 lost to 10.0.1.9:5432 after 12s
      → <TS> conn <HEX> lost to <IP> after <N>s

  ## Performance

  Normalization is a SINGLE regex pass per line: one groupless alternation
  (tried in precedence order), and each matched token is classified into
  its placeholder with pure binary matching — no per-token re-matching, no
  capture-group allocation. Benchmarked on 100k-line files this costs
  ~8-15µs/line, on par with one timestamp extraction (which the rollup
  scan pays anyway) — and it runs only on lines the scan already matched,
  so it stays well under the full per-file scan overhead.

  ANSI escapes and `[src:<name>] ` source tags are stripped first (guarded
  by cheap prefix checks): the tag is per-instance attribution — exactly
  what a template must NOT vary on (the instance dimension is aggregated
  separately by `McpLogServer.Domain.Rollup`).

  Deterministic: same line, same options → same template and same hash, on
  any node (`:erlang.phash2/2` is portable across architectures and ERTS
  versions).
  """

  alias McpLogServer.Domain.SourceTag
  alias McpLogServer.Domain.TimestampParser

  @months "(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)"

  # Token sources, in precedence order. Order matters: date-carrying
  # timestamps must win over their embedded bare numbers, UUIDs over generic
  # hex runs, IPs over bare numbers, hex runs over the digit runs they
  # contain.
  @ts_iso "\\d{4}-\\d{2}-\\d{2}[T ]\\d{1,2}:\\d{2}:\\d{2}(?:\\.\\d+)?(?:Z|[+-]\\d{2}:?\\d{2})?"
  @ts_clf "\\d{2}/#{@months}/\\d{4}:\\d{2}:\\d{2}:\\d{2}(?: [+-]\\d{4})?"
  @ts_syslog "#{@months}\\s+\\d{1,2} \\d{1,2}:\\d{2}:\\d{2}"
  @ts_time_only "\\b\\d{1,2}:\\d{2}:\\d{2}(?:\\.\\d+)?(?: ?[AP]M)?\\b"
  @uuid "\\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\\b"
  @ip "\\b\\d{1,3}(?:\\.\\d{1,3}){3}(?::\\d{1,5})?\\b"
  @hex "\\b0[xX][0-9a-fA-F]+\\b|\\b[0-9a-fA-F]{8,}\\b"
  # A digit run starting at a word boundary ("port=5432", "took 34ms",
  # "[123]" are volatile; the "404" in "error404" is glued to an identifier
  # and stays). No trailing boundary, so units normalize correctly
  # ("34ms" → "<N>ms") — only the digits are replaced.
  @number "\\b\\d+(?:\\.\\d+)?"
  @quoted "\"[^\"]*\"|'[^']*'"

  @tokens Enum.join(
            [@ts_iso, @ts_clf, @ts_syslog, @uuid, @ip, @hex, @ts_time_only, @number],
            "|"
          )

  @volatile Regex.compile!(@tokens)
  @volatile_quoted Regex.compile!(@quoted <> "|" <> @tokens)

  @doc """
  Normalize a log line into `%{template: template, hash: hash}`.

  ## Options

    * `:quoted` - when `true`, also collapse `"..."` / `'...'` quoted
      strings into `<STR>` (default `false`)
  """
  @spec normalize(String.t(), keyword()) :: %{template: String.t(), hash: String.t()}
  def normalize(line, opts \\ []) do
    template = template(line, opts)
    %{template: template, hash: hash(template)}
  end

  @doc "Return only the normalized template string. Same options as `normalize/2`."
  @spec template(String.t(), keyword()) :: String.t()
  def template(line, opts \\ []) when is_binary(line) do
    line = if String.contains?(line, "\e"), do: TimestampParser.strip_ansi(line), else: line
    line = if String.starts_with?(line, "[src:"), do: SourceTag.strip(line), else: line

    regex = if Keyword.get(opts, :quoted, false), do: @volatile_quoted, else: @volatile

    regex
    |> Regex.replace(line, &classify/1)
    |> String.trim()
  end

  @doc "Deterministic 8-hex-char hash of a template string (portable phash2)."
  @spec hash(String.t()) :: String.t()
  def hash(template) when is_binary(template) do
    :erlang.phash2(template, 4_294_967_296)
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(8, "0")
  end

  # Classify a matched token into its placeholder with pure binary checks.
  # The alternation already decided the token's extent; its SHAPE tells the
  # class apart cheaply:
  #   * leading quote               → quoted string
  #   * 8-4-4-4-12 dash skeleton    → UUID
  #   * 0x prefix                   → hex literal
  #   * two-plus colons             → any timestamp form (ISO, CLF, syslog,
  #     time-only; an IP:port has exactly one colon)
  #   * one colon or three dots     → IP (with/without port)
  #   * digits with at most one dot → number
  #   * 8+ hex chars with a digit   → hex id; without a digit the (rare)
  #     all-letter word stays intact
  defp classify(<<q, _::binary>> = _token) when q in [?", ?'], do: "<STR>"

  defp classify(
         <<_::binary-size(8), ?-, _::binary-size(4), ?-, _::binary-size(4), ?-,
           _::binary-size(4), ?-, _::binary-size(12)>>
       ),
       do: "<UUID>"

  defp classify(<<?0, x, _::binary>>) when x in [?x, ?X], do: "<HEX>"

  defp classify(token) do
    case scan_shape(token, 0, 0, false, true) do
      {colons, _dots, _digit?, _num?} when colons >= 2 -> "<TS>"
      {1, _dots, _digit?, _num?} -> "<IP>"
      {0, dots, _digit?, true} when dots <= 1 -> "<N>"
      {0, 3, _digit?, _num?} -> "<IP>"
      {_c, _d, true, _num?} -> "<HEX>"
      _ -> token
    end
  end

  # One walk over the (short) token: colon count, dot count, saw-a-digit,
  # and "numeric so far" (only digits and dots).
  defp scan_shape(<<>>, colons, dots, digit?, num?), do: {colons, dots, digit?, num?}

  defp scan_shape(<<c, rest::binary>>, colons, dots, digit?, num?) do
    case c do
      ?: -> scan_shape(rest, colons + 1, dots, digit?, false)
      ?. -> scan_shape(rest, colons, dots + 1, digit?, num?)
      c when c in ?0..?9 -> scan_shape(rest, colons, dots, true, num?)
      _ -> scan_shape(rest, colons, dots, digit?, false)
    end
  end
end
