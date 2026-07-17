defmodule McpLogServer.Domain.SourceTag do
  @moduledoc """
  The single owner of the source-tag line format for streamed sources.

  Every line ingested from a declared `LOG_SOURCES` stream is prefixed with a
  structured tag before being appended to `LOG_DIR/<name>.log`:

      [src:fly] 2026-07-17T10:00:00Z proxy[abcd] connection reset

  Why tag at the line level when the file name already carries the source:
  cross-source `correlate` merges lines from many files into one timeline —
  the in-line tag keeps attribution visible in every rendered line (and in
  any external tool the file is opened with), not just in file-level
  metadata. Rotated files (`<name>.1.log`) keep their tags too, so history
  stays attributable after rotation.

  The tag survives timestamp parsing because
  `McpLogServer.Domain.TimestampParser.extract/2` strips it (via `strip/1`)
  before matching, exactly like ANSI escapes. Tag names share the
  `[A-Za-z0-9][A-Za-z0-9_-]*` alphabet enforced by
  `McpLogServer.Domain.SourceSpec`, so `strip/1` never eats user content
  that merely looks bracketed (e.g. `[vite] 14:00:00` is not a source tag).
  """

  @tag_regex ~r/^\[src:([A-Za-z0-9][A-Za-z0-9_-]*)\] /

  @doc ~S|Prefix a line with its source tag: `tag_line("fly", "boom")` → `"[src:fly] boom"`.|
  @spec tag_line(String.t(), String.t()) :: String.t()
  def tag_line(name, line), do: "[src:" <> name <> "] " <> line

  @doc "Remove a leading source tag, if present."
  @spec strip(String.t()) :: String.t()
  def strip(line), do: String.replace(line, @tag_regex, "")

  @doc "Extract the source name from a tagged line, or nil."
  @spec source_of(String.t()) :: String.t() | nil
  def source_of(line) do
    case Regex.run(@tag_regex, line) do
      [_, name] -> name
      _ -> nil
    end
  end
end
