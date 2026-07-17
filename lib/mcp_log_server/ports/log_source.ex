defmodule McpLogServer.Ports.LogSource do
  @moduledoc """
  Port (behaviour) for anything that can enumerate logs and hand their
  contents back as lines.

  Why this port exists: the application layer (use-cases) must not care where
  log lines come from. Today the only adapter is
  `McpLogServer.Infrastructure.FileLogSource` (local `.log` files under
  `LOG_DIR`). Future adapters plug in behind this same contract:

    * **remote streamed sources** — logs fetched or streamed from another
      host, where `live?: true` descriptors identify still-growing streams
    * **indexed source** — a persistent index over rotated files that answers
      `list/1` and `stream_lines/1` without re-reading raw files
    * **multi-instance rollup** — one logical source fanning out to N
      instances of the same service

  The `descriptor` deliberately carries metadata (`name`, `path`,
  `size_bytes`, `modified`, `live?`) so those adapters can extend behaviour
  without breaking the contract. Consumers must tolerate additional keys and
  must not assume `path` points at a local file.

  A `handle` is an opaque token returned by `resolve/2`; only the adapter
  that produced it may interpret it (for `FileLogSource` it is an absolute
  path).
  """

  alias McpLogServer.Domain.JsonLogParser

  @type descriptor :: %{
          required(:name) => String.t(),
          required(:path) => String.t(),
          required(:size_bytes) => non_neg_integer(),
          required(:modified) => String.t(),
          required(:live?) => boolean(),
          optional(:warning) => String.t()
        }

  @type handle :: term()
  @type format :: :plain | :json_lines | :json_array

  @doc "Enumerate available logs in the given location (today: LOG_DIR)."
  @callback list(log_dir :: String.t()) :: {:ok, [descriptor()]}

  @doc "Resolve a log name to an opaque handle, rejecting traversal and unknown names."
  @callback resolve(log_dir :: String.t(), name :: String.t()) ::
              {:ok, handle()} | {:error, String.t()}

  @doc "Like `resolve/2`, but also enforces the source's read-size guardrail."
  @callback resolve_readable(log_dir :: String.t(), name :: String.t()) ::
              {:ok, handle()} | {:error, String.t()}

  @doc "Lazily stream the log's lines with trailing whitespace trimmed."
  @callback stream_lines(handle()) :: Enumerable.t()

  @doc "Read the entire raw content of a log."
  @callback read(handle()) :: {:ok, binary()} | {:error, String.t()}

  @doc "Return size and last-modified metadata for a resolved log."
  @callback stat(handle()) ::
              {:ok, %{size_bytes: non_neg_integer(), modified: String.t()}}
              | {:error, String.t()}

  @doc "Detect the log's format. Adapters may cache the result."
  @callback format(handle()) :: format()

  @doc """
  Stream enriched JSON entries as `{entry, index}` tuples from a source,
  composing the adapter's line/content access with the pure domain JSON
  parser. Works for any `LogSource` adapter.
  """
  @spec stream_entries(module(), handle(), :json_lines | :json_array) :: Enumerable.t()
  def stream_entries(source, handle, :json_lines) do
    handle
    |> source.stream_lines()
    |> JsonLogParser.stream_from_lines()
  end

  def stream_entries(source, handle, :json_array) do
    case source.read(handle) do
      {:ok, content} ->
        case JsonLogParser.parse_string(content, :json_array) do
          {:ok, entries} -> entries |> Enum.with_index(1) |> Stream.map(& &1)
          {:error, _} -> Stream.map([], & &1)
        end

      {:error, _} ->
        Stream.map([], & &1)
    end
  end
end
