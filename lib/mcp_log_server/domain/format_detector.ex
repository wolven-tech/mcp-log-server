defmodule McpLogServer.Domain.FormatDetector do
  @moduledoc """
  Pure classification of log content as plain text, NDJSON, or a JSON array.

  Operates on already-sampled lines/chunks; reading files and caching results
  is the job of `McpLogServer.Infrastructure.FormatCache`.
  """

  @type format :: :plain | :json_lines | :json_array

  @doc "Returns true if a sampled first line suggests a JSON array file."
  @spec array_candidate?(String.t()) :: boolean()
  def array_candidate?(first_line) do
    first_line
    |> String.trim()
    |> String.starts_with?("[")
  end

  @doc """
  Classify a sample of trimmed, non-empty lines as `:json_lines` or `:plain`.

  Returns `:json_lines` only when every sampled line decodes to a JSON object.
  An empty sample is `:plain`.
  """
  @spec classify_lines([String.t()]) :: format()
  def classify_lines([]), do: :plain

  def classify_lines(lines) do
    all_json? =
      Enum.all?(lines, fn line ->
        case Jason.decode(line) do
          {:ok, decoded} when is_map(decoded) -> true
          _ -> false
        end
      end)

    if all_json?, do: :json_lines, else: :plain
  end

  @doc """
  Classify the leading chunk of an array-candidate file.

  Returns `:json_array` when the (possibly truncated) chunk parses as a JSON
  array of objects, `:plain` otherwise.
  """
  @spec classify_array_chunk(binary()) :: format()
  def classify_array_chunk(data) when is_binary(data) do
    trimmed = String.trim(data)

    case Jason.decode(trimmed) do
      {:ok, list} when is_list(list) ->
        if Enum.all?(list, &is_map/1), do: :json_array, else: :plain

      _ ->
        # Possibly truncated — try appending "]"
        case Jason.decode(trimmed <> "]") do
          {:ok, list} when is_list(list) ->
            if Enum.all?(list, &is_map/1), do: :json_array, else: :plain

          _ ->
            :plain
        end
    end
  end
end
