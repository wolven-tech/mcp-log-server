defmodule McpLogServer.Protocol.ToonEncoder do
  @moduledoc """
  TOON (Token-Oriented Object Notation) encoder for LLM-optimized log output.
  ~50% token reduction for tabular data vs JSON.

  Format:
  ```
  [line_number|content]
  42|ERROR: Connection failed
  43|INFO: Retrying...
  ```
  """

  def format_response(data, format \\ nil) do
    case format do
      "toon" -> encode_toon(data)
      "json" -> encode_json(data)
      _ -> auto_format(data)
    end
  end

  defp auto_format(data) when is_map(data) do
    cond do
      is_list(Map.get(data, :matches)) -> encode_toon(data)
      is_list(Map.get(data, "matches")) -> encode_toon(data)
      is_list(Map.get(data, :entries)) -> encode_toon(data)
      is_list(Map.get(data, "entries")) -> encode_toon(data)
      true -> encode_json(data)
    end
  end

  defp auto_format(data) when is_list(data) do
    case encode_toon_list(data) do
      {:ok, toon} -> toon
      _ -> encode_json(data)
    end
  end

  defp auto_format(data), do: encode_json(data)

  defp encode_json(data), do: Jason.encode!(data, pretty: false)

  defp encode_toon(data) when is_map(data) do
    items = find_items(data)

    case encode_toon_list(items) do
      {:ok, toon} ->
        meta = Map.drop(data, [:matches, :entries, "matches", "entries"])
        meta_line = if map_size(meta) > 0, do: "# " <> encode_json(meta) <> "\n", else: ""
        meta_line <> toon

      _ ->
        encode_json(data)
    end
  end

  defp encode_toon(data), do: encode_json(data)

  defp encode_toon_list([%{} = first | _] = items) do
    keys = Map.keys(first) |> Enum.sort()
    header = "[" <> Enum.map_join(keys, "|", &to_string/1) <> "]"

    rows =
      Enum.map(items, fn item ->
        Enum.map_join(keys, "|", fn key ->
          item |> Map.get(key, "") |> encode_value()
        end)
      end)

    {:ok, Enum.join([header | rows], "\n")}
  end

  defp encode_toon_list(_), do: :error

  defp find_items(%{matches: m}) when is_list(m), do: m
  defp find_items(%{entries: e}) when is_list(e), do: e
  defp find_items(%{"matches" => m}) when is_list(m), do: m
  defp find_items(%{"entries" => e}) when is_list(e), do: e
  defp find_items(_), do: []

  defp encode_value(nil), do: ""
  defp encode_value(v) when is_binary(v), do: v |> String.replace("|", "\\|") |> String.replace("\n", "\\n")
  defp encode_value(v) when is_number(v), do: to_string(v)
  defp encode_value(v) when is_boolean(v), do: to_string(v)
  defp encode_value(v) when is_atom(v), do: to_string(v)
  defp encode_value(v), do: inspect(v)

end
