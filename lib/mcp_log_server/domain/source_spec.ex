defmodule McpLogServer.Domain.SourceSpec do
  @moduledoc """
  Pure parsing/validation of `LOG_SOURCES` declarations.

  A declaration is a `;`-separated list of `name:cmd=command` entries, e.g.

      LOG_SOURCES='fly:cmd=flyctl logs -a my-app; k8s:cmd=kubectl logs -f deploy/api'

  Each entry yields a spec map:

    * `:name` — the source name; becomes the ingest file `<name>.log` under
      `LOG_DIR` and the `[src:<name>]` line tag. Restricted to
      `[A-Za-z0-9][A-Za-z0-9_-]*` so it is always filename- and tag-safe.
    * `:cmd`  — the raw command string as declared (for display/logging)
    * `:argv` — the command tokenized shell-style (single/double quotes and
      backslash escapes honored). The runtime spawns `argv` directly via
      `{:spawn_executable, ...}` — the string is NEVER handed to a shell, so
      there is no injection surface beyond what the operator explicitly
      declared. To use shell features, declare them explicitly:
      `demo:cmd=sh -c "while true; do date; sleep 1; done"`.

  Reading the environment and failing boot on errors is the job of
  `McpLogServer.Config.LogSources`; this module stays pure.
  """

  @name_regex ~r/^[A-Za-z0-9][A-Za-z0-9_-]*$/

  @type t :: %{name: String.t(), cmd: String.t(), argv: [String.t(), ...]}

  @doc """
  Parse a raw `LOG_SOURCES` declaration into a list of source specs.

  `nil` and blank strings mean "no sources declared". Returns
  `{:error, message}` on any malformed entry so the config boundary can fail
  boot loudly.
  """
  @spec parse_declarations(String.t() | nil) :: {:ok, [t()]} | {:error, String.t()}
  def parse_declarations(nil), do: {:ok, []}

  def parse_declarations(raw) when is_binary(raw) do
    with {:ok, entries} <- split_entries(raw),
         {:ok, specs} <- parse_entries(entries, []),
         :ok <- check_duplicates(specs) do
      {:ok, specs}
    end
  end

  # Split on ';' ONLY outside quotes, so shell commands like
  # `sh -c "while true; do date; done"` stay one entry. Quotes and escapes
  # are preserved verbatim for tokenize/1 to interpret.
  defp split_entries(raw) do
    do_split(String.graphemes(raw), nil, "", [])
  end

  defp do_split([], nil, current, acc),
    do: {:ok, Enum.reverse(add_entry(current, acc))}

  defp do_split([], quote_ch, _current, _acc),
    do: {:error, "unterminated #{quote_ch} quote"}

  defp do_split([";" | rest], nil, current, acc),
    do: do_split(rest, nil, "", add_entry(current, acc))

  defp do_split(["\\", c | rest], quote_ch, current, acc) when quote_ch in [nil, "\""],
    do: do_split(rest, quote_ch, current <> "\\" <> c, acc)

  defp do_split([q | rest], nil, current, acc) when q in ["'", "\""],
    do: do_split(rest, q, current <> q, acc)

  defp do_split([q | rest], q, current, acc) when q in ["'", "\""],
    do: do_split(rest, nil, current <> q, acc)

  defp do_split([c | rest], quote_ch, current, acc),
    do: do_split(rest, quote_ch, current <> c, acc)

  defp add_entry(current, acc) do
    case String.trim(current) do
      "" -> acc
      entry -> [entry | acc]
    end
  end

  defp parse_entries([], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_entries([entry | rest], acc) do
    case parse_entry(entry) do
      {:ok, spec} -> parse_entries(rest, [spec | acc])
      {:error, _} = error -> error
    end
  end

  defp parse_entry(entry) do
    case String.split(entry, ":", parts: 2) do
      [name, "cmd=" <> command] ->
        build_spec(String.trim(name), String.trim(command), entry)

      _ ->
        {:error, "malformed entry #{inspect(entry)} (expected 'name:cmd=command')"}
    end
  end

  defp build_spec(name, command, entry) do
    cond do
      not Regex.match?(@name_regex, name) ->
        {:error,
         "invalid source name #{inspect(name)} (allowed: letters, digits, '-', '_'; " <>
           "must start with a letter or digit)"}

      command == "" ->
        {:error, "empty command in entry #{inspect(entry)}"}

      true ->
        case tokenize(command) do
          {:ok, []} -> {:error, "empty command in entry #{inspect(entry)}"}
          {:ok, argv} -> {:ok, %{name: name, cmd: command, argv: argv}}
          {:error, msg} -> {:error, "#{msg} in entry #{inspect(entry)}"}
        end
    end
  end

  defp check_duplicates(specs) do
    duplicates =
      specs
      |> Enum.frequencies_by(& &1.name)
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(fn {name, _count} -> name end)

    case duplicates do
      [] -> :ok
      names -> {:error, "duplicate source name(s): #{Enum.join(names, ", ")}"}
    end
  end

  @doc """
  Tokenize a command string shell-style, WITHOUT invoking a shell.

  Supports: whitespace-separated words, single quotes (literal), double
  quotes (backslash escapes `\\"` and `\\\\`), and backslash escapes outside
  quotes. Errors on unterminated quotes.
  """
  @spec tokenize(String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def tokenize(command) do
    do_tokenize(String.graphemes(command), nil, nil, [])
  end

  # chars, quote (nil | "'" | "\""), current token (nil = between tokens), acc
  defp do_tokenize([], nil, nil, acc), do: {:ok, Enum.reverse(acc)}
  defp do_tokenize([], nil, token, acc), do: {:ok, Enum.reverse([token | acc])}
  defp do_tokenize([], quote_ch, _token, _acc), do: {:error, "unterminated #{quote_ch} quote"}

  defp do_tokenize([c | rest], nil, token, acc) when c in [" ", "\t"] do
    case token do
      nil -> do_tokenize(rest, nil, nil, acc)
      token -> do_tokenize(rest, nil, nil, [token | acc])
    end
  end

  defp do_tokenize(["\\", c | rest], quote_ch, token, acc) when quote_ch in [nil, "\""] do
    if quote_ch == "\"" and c not in ["\"", "\\"] do
      # Inside double quotes, backslash only escapes '"' and '\'
      do_tokenize(rest, quote_ch, (token || "") <> "\\" <> c, acc)
    else
      do_tokenize(rest, quote_ch, (token || "") <> c, acc)
    end
  end

  defp do_tokenize([q | rest], nil, token, acc) when q in ["'", "\""],
    do: do_tokenize(rest, q, token || "", acc)

  defp do_tokenize([q | rest], q, token, acc) when q in ["'", "\""],
    do: do_tokenize(rest, nil, token, acc)

  defp do_tokenize([c | rest], quote_ch, token, acc),
    do: do_tokenize(rest, quote_ch, (token || "") <> c, acc)
end
