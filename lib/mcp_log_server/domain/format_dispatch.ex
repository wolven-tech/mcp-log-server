defmodule McpLogServer.Domain.FormatDispatch do
  @moduledoc """
  Eliminates duplicated format-detection case switches by providing
  a single dispatch point that routes to JSON or plain-text callbacks.
  """

  alias McpLogServer.Domain.FormatDetector

  @doc """
  Detect the format of `path` and call the appropriate callback.

  - For `:json_lines` or `:json_array`, calls `json_fn.(format)`.
  - For `:plain`, calls `plain_fn.()`.
  """
  @spec dispatch(String.t(), (FormatDetector.format() -> result), (() -> result)) :: result
        when result: any()
  def dispatch(path, json_fn, plain_fn) do
    case FormatDetector.detect(path) do
      fmt when fmt in [:json_lines, :json_array] -> json_fn.(fmt)
      :plain -> plain_fn.()
    end
  end
end
