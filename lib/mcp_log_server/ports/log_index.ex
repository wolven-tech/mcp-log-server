defmodule McpLogServer.Ports.LogIndex do
  @moduledoc """
  Port (behaviour) for the incremental persistent index (issue #7 P7).

  The index is a CACHE over the log files, never a source of truth: every
  callback answers `:miss` on any doubt (index disabled, not yet built,
  stale, corrupt, or the handle is not a local file), and callers MUST
  treat `:miss` as "do the linear scan" — results must be identical either
  way, only slower. Adapters may schedule a background (re)build as a side
  effect of a `:miss`; they must never block the caller to do so.

  Adapters:

    * `McpLogServer.Infrastructure.LogIndex` — ETS + DETS
      (see docs/decisions/001-index-storage.md)
    * `McpLogServer.Infrastructure.NoIndex` — always `:miss`; the disabled
      mode and the test control group for oracle tests.
  """

  @typedoc "A safe scan start position: byte `offset` begins line `lines + 1`."
  @type seek_point :: %{offset: non_neg_integer(), lines: non_neg_integer()}

  @typedoc "Per-file JSON field knowledge (see `McpLogServer.Domain.SparseIndex`)."
  @type field_stats :: %{
          present: MapSet.t(String.t()),
          opaque: MapSet.t(String.t()),
          capped: boolean(),
          json_lines: non_neg_integer(),
          non_json: non_neg_integer()
        }

  @doc """
  Deepest safe seek point for a `since`-bounded scan of the file at `path`,
  in the given timestamp semantics (`:line` or `:entry` — see
  `McpLogServer.Domain.SparseIndex`). `:miss` on any doubt.
  """
  @callback seek(path :: term(), since :: DateTime.t(), mode :: :line | :entry) ::
              {:ok, seek_point()} | :miss

  @doc """
  Field-key knowledge for the file at `path`, valid ONLY when the file is
  byte-identical to what was indexed (absence proofs cover every line).
  """
  @callback field_stats(path :: term()) :: {:ok, field_stats()} | :miss
end
