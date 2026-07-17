defmodule McpLogServer.Domain.Cursor do
  @moduledoc """
  Opaque polling cursor for `tail_log` / `search_logs` (slice 005, P6).

  A cursor encodes (file identity + byte offset + rotation guard) so a
  polling agent re-fetches only lines appended since its last call — never
  the same window twice.

  WHY opaque (base64 of a versioned term): the encoding must be free to
  change without breaking clients — slice 006's index will change it. The
  version is the first tuple element; decoding an unknown version fails,
  which callers treat exactly like rotation: full window + `cursor_reset`.

  Contents are deliberately LOG_DIR-relative: only the file's basename is
  stored, never an absolute path, so a cursor leaks nothing beyond what the
  tools already expose.

  Rotation guard: the cursor stores a hash of the file's first
  `min(#{256}, size)` bytes (`sig` over `sig_len` bytes). If the file was
  rotated, truncated, or replaced, those bytes (or the total size vs.
  offset) no longer agree — the cursor is invalid, and the caller returns a
  flagged full window (`cursor_reset: true`) instead of wrong increments.

  Offsets always land on a line boundary: `state_for/2` advances only to
  the end of the last complete (newline-terminated) line, so a poll that
  races a mid-line append re-delivers the completed line next time instead
  of a fragment.
  """

  @version 1
  @sig_bytes 256

  @type t :: %{
          file: String.t(),
          offset: non_neg_integer(),
          sig_len: non_neg_integer(),
          sig: non_neg_integer()
        }

  @doc "Encode a cursor state into its opaque string form."
  @spec encode(t()) :: String.t()
  def encode(%{file: file, offset: offset, sig_len: sig_len, sig: sig}) do
    {@version, file, offset, sig_len, sig}
    |> :erlang.term_to_binary()
    |> Base.url_encode64(padding: false)
  end

  @doc "Decode an opaque cursor string. Any malformed or unknown-version input is `:error`."
  @spec decode(term()) :: {:ok, t()} | :error
  def decode(str) when is_binary(str) do
    with {:ok, bin} <- Base.url_decode64(str, padding: false),
         {@version, file, offset, sig_len, sig}
         when is_binary(file) and is_integer(offset) and offset >= 0 and
                is_integer(sig_len) and sig_len >= 0 and is_integer(sig) <-
           safe_term(bin) do
      {:ok, %{file: file, offset: offset, sig_len: sig_len, sig: sig}}
    else
      _ -> :error
    end
  end

  def decode(_), do: :error

  @doc """
  Build the cursor state for the current content of `file` (basename).
  The offset is the end of the last complete line (0 when none).
  """
  @spec state_for(String.t(), binary()) :: t()
  def state_for(file, content) do
    sig_len = min(byte_size(content), @sig_bytes)

    %{
      file: file,
      offset: complete_end(content),
      sig_len: sig_len,
      sig: sig(content, sig_len)
    }
  end

  @doc """
  Check a decoded cursor against the file's current content.

  `:invalid` when the file identity changed, the content shrank below the
  cursor's offset or signature region, or the signed prefix bytes differ
  (rotation/truncation/replacement).
  """
  @spec validate(t(), String.t(), binary()) :: :ok | :invalid
  def validate(cursor, file, content) do
    size = byte_size(content)

    cond do
      cursor.file != file -> :invalid
      size < cursor.offset -> :invalid
      size < cursor.sig_len -> :invalid
      sig(content, cursor.sig_len) != cursor.sig -> :invalid
      true -> :ok
    end
  end

  @doc """
  Resolve an incoming cursor string (or `nil`) against current content.

  Returns `{start_offset, reset?}`: a valid cursor yields its offset; no
  cursor starts at 0 without a reset; an invalid/undecodable cursor starts
  at 0 WITH `reset?: true` — the caller must surface `cursor_reset` so the
  full window is never mistaken for an increment.
  """
  @spec resolve(String.t() | nil, String.t(), binary()) :: {non_neg_integer(), boolean()}
  def resolve(nil, _file, _content), do: {0, false}

  def resolve(str, file, content) do
    with {:ok, cursor} <- decode(str),
         :ok <- validate(cursor, file, content) do
      {cursor.offset, false}
    else
      _ -> {0, true}
    end
  end

  @doc """
  Split content from `offset` into trimmed lines plus the 1-based line
  number of the first returned line (derived from newlines before the
  offset). A trailing partial line IS returned (tail semantics) but is not
  covered by `state_for/2`'s offset, so it re-delivers completed.
  """
  @spec slice_lines(binary(), non_neg_integer()) :: {[String.t()], pos_integer()}
  def slice_lines(content, offset) do
    prefix = binary_part(content, 0, offset)
    region = binary_part(content, offset, byte_size(content) - offset)

    lines =
      case String.split(region, "\n") do
        [""] -> []
        parts -> parts |> drop_trailing_empty() |> Enum.map(&String.trim_trailing/1)
      end

    {lines, count_newlines(prefix) + 1}
  end

  @doc "Byte offset just past the last newline in `content` (0 when none)."
  @spec complete_end(binary()) :: non_neg_integer()
  def complete_end(""), do: 0
  def complete_end(content), do: find_last_newline(content, byte_size(content) - 1)

  defp find_last_newline(_content, -1), do: 0

  defp find_last_newline(content, i) do
    if :binary.at(content, i) == ?\n, do: i + 1, else: find_last_newline(content, i - 1)
  end

  defp drop_trailing_empty(parts) do
    case List.last(parts) do
      "" -> Enum.drop(parts, -1)
      _ -> parts
    end
  end

  defp count_newlines(bin), do: length(:binary.matches(bin, "\n"))

  defp sig(_content, 0), do: 0
  defp sig(content, len), do: :erlang.phash2(binary_part(content, 0, len))

  defp safe_term(bin) do
    :erlang.binary_to_term(bin, [:safe])
  rescue
    _ -> :error
  end
end
