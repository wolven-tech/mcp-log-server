defmodule McpLogServer.Domain.TsFormat do
  @moduledoc """
  Pure engine for user-declared timestamp formats (the `LOG_TS_FORMATS`
  environment variable).

  A declaration string maps file-name globs to timestamp formats:

      LOG_TS_FORMATS='fly-*.log=%FT%T%.fZ; app*.log=epoch_ms; dev-*.log=%H:%M:%S'

  Supported format specifiers:

    * `rfc3339` — ISO 8601 / RFC 3339 timestamps
    * `epoch_ms` — 13-digit Unix epoch milliseconds
    * `epoch_s` — 10-digit Unix epoch seconds
    * a strftime subset: `%Y %m %d %H %M %S %b %f %.f %z %:z %F %T %%`

  Declarations are parsed and compiled ONCE at the config boundary
  (`McpLogServer.Config.TsFormats`, called from the application composition
  root) so a typo fails loudly at boot instead of silently at query time.
  This module stays pure: it never reads the environment itself.

  Time-only strftime formats (no `%Y`/`%m`/`%d`/`%b`) resolve their date via
  `McpLogServer.Domain.TimestampParser.resolve_time_only/2` — see that
  function for the midnight-rollover rule.
  """

  alias McpLogServer.Domain.TimestampParser

  @type compiled ::
          %{kind: :rfc3339, source: String.t()}
          | %{kind: :epoch_ms | :epoch_s, regex: Regex.t(), source: String.t()}
          | %{kind: :strftime, regex: Regex.t(), fields: [atom()], source: String.t()}

  @type declaration :: %{glob: String.t(), glob_regex: Regex.t(), format: compiled()}

  @rfc3339_regex ~r/(\d{4}-\d{2}-\d{2}[Tt ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:[Zz]|[+-]\d{2}:?\d{2})?)/
  @epoch_ms_regex ~r/(?<![0-9])(\d{13})(?![0-9])/
  @epoch_s_regex ~r/(?<![0-9])(\d{10})(?![0-9])/

  @months %{
    "jan" => 1, "feb" => 2, "mar" => 3, "apr" => 4,
    "may" => 5, "jun" => 6, "jul" => 7, "aug" => 8,
    "sep" => 9, "oct" => 10, "nov" => 11, "dec" => 12
  }

  # -- Declaration parsing (config-boundary entry point) --

  @doc """
  Parse a `LOG_TS_FORMATS` declaration string into compiled declarations.

  Returns `{:ok, [declaration()]}` or `{:error, message}` describing the
  first invalid entry. `nil` and `""` yield `{:ok, []}`.
  """
  @spec parse_declarations(String.t() | nil) :: {:ok, [declaration()]} | {:error, String.t()}
  def parse_declarations(nil), do: {:ok, []}
  def parse_declarations(""), do: {:ok, []}

  def parse_declarations(raw) when is_binary(raw) do
    raw
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case parse_entry(entry) do
        {:ok, decl} -> {:cont, {:ok, acc ++ [decl]}}
        {:error, msg} -> {:halt, {:error, msg}}
      end
    end)
  end

  @doc """
  Find the compiled format declared for `basename`, or `nil`.
  First matching glob wins.
  """
  @spec for_file([declaration()], String.t()) :: compiled() | nil
  def for_file(declarations, basename) do
    Enum.find_value(declarations, fn %{glob_regex: regex, format: format} ->
      if Regex.match?(regex, basename), do: format
    end)
  end

  # -- Format compilation --

  @doc """
  Compile a single format specifier (`rfc3339`, `epoch_ms`, `epoch_s`, or a
  strftime pattern) into a `t:compiled/0` value.
  """
  @spec compile(String.t()) :: {:ok, compiled()} | {:error, String.t()}
  def compile("rfc3339"), do: {:ok, %{kind: :rfc3339, source: "rfc3339"}}
  def compile("epoch_ms"), do: {:ok, %{kind: :epoch_ms, regex: @epoch_ms_regex, source: "epoch_ms"}}
  def compile("epoch_s"), do: {:ok, %{kind: :epoch_s, regex: @epoch_s_regex, source: "epoch_s"}}

  def compile(format) when is_binary(format) do
    if String.contains?(format, "%") do
      compile_strftime(format)
    else
      {:error,
       "unrecognized timestamp format '#{format}' " <>
         "(expected rfc3339, epoch_ms, epoch_s, or a strftime pattern with %-directives)"}
    end
  end

  # -- Extraction --

  @doc """
  Apply a compiled format to a log line (or raw timestamp value), returning
  a `DateTime` or `nil`. `reference` (the file's mtime) anchors time-only
  formats to a date — see `TimestampParser.resolve_time_only/2`.
  """
  @spec extract(compiled() | nil, String.t(), DateTime.t() | nil) :: DateTime.t() | nil
  def extract(nil, _line, _reference), do: nil

  def extract(%{kind: :rfc3339}, line, _reference) do
    case Regex.run(@rfc3339_regex, line) do
      [_, ts] ->
        ts = ts |> String.replace(" ", "T") |> ensure_zone()

        case DateTime.from_iso8601(ts) do
          {:ok, dt, _} -> dt
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def extract(%{kind: :epoch_ms, regex: regex}, line, _reference) do
    with [_, digits] <- Regex.run(regex, line),
         {:ok, dt} <- DateTime.from_unix(String.to_integer(digits), :millisecond) do
      dt
    else
      _ -> nil
    end
  end

  def extract(%{kind: :epoch_s, regex: regex}, line, _reference) do
    with [_, digits] <- Regex.run(regex, line),
         {:ok, dt} <- DateTime.from_unix(String.to_integer(digits), :second) do
      dt
    else
      _ -> nil
    end
  end

  def extract(%{kind: :strftime, regex: regex}, line, reference) do
    case Regex.named_captures(regex, line) do
      nil -> nil
      captures -> build_datetime(captures, reference)
    end
  end

  # -- Internals: declaration entries --

  defp parse_entry(entry) do
    case String.split(entry, "=", parts: 2) do
      [glob, format] ->
        glob = String.trim(glob)
        format = String.trim(format)

        cond do
          glob == "" ->
            {:error, "empty glob in LOG_TS_FORMATS entry '#{entry}'"}

          format == "" ->
            {:error, "empty format in LOG_TS_FORMATS entry '#{entry}'"}

          true ->
            with {:ok, compiled} <- compile(format) do
              {:ok, %{glob: glob, glob_regex: glob_to_regex(glob), format: compiled}}
            end
        end

      _ ->
        {:error, "expected 'glob=format' in LOG_TS_FORMATS but got '#{entry}'"}
    end
  end

  defp glob_to_regex(glob) do
    source =
      glob
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> String.replace("\\?", ".")

    Regex.compile!("^" <> source <> "$")
  end

  # -- Internals: strftime compilation --

  @simple_directives %{
    "Y" => {"(?<Y>\\d{4})", :year},
    "m" => {"(?<m>\\d{2})", :month},
    "d" => {"(?<d>\\d{2})", :day},
    "H" => {"(?<H>\\d{2})", :hour},
    "M" => {"(?<M>\\d{2})", :minute},
    "S" => {"(?<S>\\d{2})", :second},
    "b" => {"(?<b>[A-Za-z]{3})", :month},
    "f" => {"(?<f>\\d{1,9})", :fraction},
    "z" => {"(?<z>Z|[+-]\\d{2}:?\\d{2})", :offset}
  }

  defp compile_strftime(format) do
    case build_regex_source(String.graphemes(format), format, "", []) do
      {:ok, source, fields} ->
        cond do
          fields == [] ->
            {:error, "strftime format '#{format}' contains no timestamp directives"}

          true ->
            # Digit guards keep e.g. %H:%M:%S from matching inside a longer
            # digit run ("114:00:00" must not yield hour 14).
            source = "(?<![0-9])" <> source <> "(?![0-9])"

            case Regex.compile(source) do
              {:ok, regex} ->
                {:ok, %{kind: :strftime, regex: regex, fields: Enum.uniq(fields), source: format}}

              {:error, {msg, _}} ->
                {:error, "strftime format '#{format}' failed to compile: #{msg}"}
            end
        end

      {:error, _} = error ->
        error
    end
  end

  defp build_regex_source([], _format, acc, fields), do: {:ok, acc, fields}

  defp build_regex_source(["%", "%" | rest], format, acc, fields),
    do: build_regex_source(rest, format, acc <> "%", fields)

  defp build_regex_source(["%", "F" | rest], format, acc, fields),
    do: build_regex_source(["%", "Y", "-", "%", "m", "-", "%", "d" | rest], format, acc, fields)

  defp build_regex_source(["%", "T" | rest], format, acc, fields),
    do: build_regex_source(["%", "H", ":", "%", "M", ":", "%", "S" | rest], format, acc, fields)

  defp build_regex_source(["%", ".", "f" | rest], format, acc, fields),
    do: build_regex_source(rest, format, acc <> "(?:\\.(?<f>\\d{1,9}))?", [:fraction | fields])

  defp build_regex_source(["%", ":", "z" | rest], format, acc, fields),
    do: build_regex_source(["%", "z" | rest], format, acc, fields)

  defp build_regex_source(["%", char | rest], format, acc, fields) do
    case Map.fetch(@simple_directives, char) do
      {:ok, {fragment, field}} ->
        build_regex_source(rest, format, acc <> fragment, [field | fields])

      :error ->
        {:error, "unsupported strftime directive '%#{char}' in format '#{format}'"}
    end
  end

  defp build_regex_source(["%"], format, _acc, _fields),
    do: {:error, "dangling '%' at end of strftime format '#{format}'"}

  defp build_regex_source([char | rest], format, acc, fields),
    do: build_regex_source(rest, format, acc <> Regex.escape(char), fields)

  # -- Internals: building a DateTime from strftime captures --

  defp build_datetime(captures, reference) do
    hour = int_capture(captures, "H", 0)
    minute = int_capture(captures, "M", 0)
    second = int_capture(captures, "S", 0)
    microsecond = fraction_capture(captures)

    with {:ok, time} <- Time.new(hour, minute, second, microsecond) do
      case resolve_date(captures, reference) do
        :time_only ->
          time
          |> TimestampParser.resolve_time_only(reference)
          |> apply_offset(captures)

        {:ok, date} ->
          case DateTime.new(date, time, "Etc/UTC") do
            {:ok, dt} -> apply_offset(dt, captures)
            _ -> nil
          end

        :error ->
          nil
      end
    else
      _ -> nil
    end
  end

  defp resolve_date(captures, reference) do
    year = int_capture(captures, "Y", nil)
    month = int_capture(captures, "m", nil) || month_abbrev(captures)
    day = int_capture(captures, "d", nil)

    cond do
      year == nil and month == nil and day == nil ->
        :time_only

      true ->
        ref = reference || DateTime.utc_now()
        year = year || ref.year

        case Date.new(year, month || 1, day || 1) do
          {:ok, date} -> {:ok, date}
          _ -> :error
        end
    end
  end

  defp month_abbrev(captures) do
    case Map.get(captures, "b", "") do
      "" -> nil
      abbrev -> Map.get(@months, String.downcase(abbrev))
    end
  end

  defp apply_offset(nil, _captures), do: nil

  defp apply_offset(%DateTime{} = dt, captures) do
    case Map.get(captures, "z", "") do
      "" -> dt
      "Z" -> dt
      offset -> DateTime.add(dt, -offset_seconds(offset), :second)
    end
  end

  defp offset_seconds(offset) do
    {sign, rest} = String.split_at(offset, 1)
    digits = String.replace(rest, ":", "")
    hours = digits |> String.slice(0, 2) |> String.to_integer()
    minutes = digits |> String.slice(2, 2) |> String.to_integer()
    seconds = hours * 3600 + minutes * 60
    if sign == "-", do: -seconds, else: seconds
  end

  defp int_capture(captures, key, default) do
    case Map.get(captures, key, "") do
      "" -> default
      value -> String.to_integer(value)
    end
  end

  defp fraction_capture(captures) do
    case Map.get(captures, "f", "") do
      "" ->
        {0, 0}

      digits ->
        digits = String.slice(digits, 0, 6)
        precision = String.length(digits)
        {String.to_integer(digits) * pow10(6 - precision), precision}
    end
  end

  defp pow10(0), do: 1
  defp pow10(n), do: 10 * pow10(n - 1)

  defp ensure_zone(ts) do
    if String.ends_with?(ts, "Z") or String.ends_with?(ts, "z") or
         Regex.match?(~r/[+-]\d{2}:?\d{2}$/, ts) do
      ts
    else
      ts <> "Z"
    end
  end
end
