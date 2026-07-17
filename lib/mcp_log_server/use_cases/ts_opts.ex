defmodule McpLogServer.UseCases.TsOpts do
  @moduledoc """
  Builds the timestamp-parsing options every use-case threads into the pure
  domain layer (`TimeFilter.classify/4`, `TimestampParser.extract/2`):

    * `:format` — the format declared for this file via `LOG_TS_FORMATS`
      (compiled once at boot by `McpLogServer.Config.TsFormats`), tried
      before auto-detection
    * `:reference` — the file's mtime as a DateTime, anchoring time-only
      formats to a date (midnight-rollover rule in `TimestampParser`)

  Tests can inject a compiled format directly by passing `:ts_format` in a
  use-case's opts, bypassing global config.
  """

  alias McpLogServer.Config.TsFormats

  @spec build(module(), term(), String.t(), keyword()) :: keyword()
  def build(source, handle, file, opts \\ []) do
    format = Keyword.get(opts, :ts_format) || TsFormats.for_file(Path.basename(file))
    [format: format, reference: mtime_reference(source, handle)]
  end

  # The adapter reports mtime as a naive ISO string; it is treated as UTC.
  # Both the log's wall-clock stamps and the mtime come from the same clock,
  # so comparisons between them stay self-consistent.
  defp mtime_reference(source, handle) do
    with {:ok, %{modified: modified}} <- source.stat(handle),
         {:ok, naive} <- NaiveDateTime.from_iso8601(modified) do
      DateTime.from_naive!(naive, "Etc/UTC")
    else
      _ -> nil
    end
  end
end
