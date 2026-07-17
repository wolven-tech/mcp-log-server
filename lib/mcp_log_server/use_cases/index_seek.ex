defmodule McpLogServer.UseCases.IndexSeek do
  @moduledoc """
  Shared helper applying the persistent index's seek point to a
  content-based scan (`tail_log`, `search_logs`).

  The index (`McpLogServer.Ports.LogIndex`) validates the seek offset
  against the file on disk; this helper re-validates it against the
  CONTENT the use-case actually read (the read and the index check are two
  separate moments — a rotation between them must degrade to the full
  scan, never slice mid-line). Any doubt → offset 0, `index_used: false`.
  """

  @doc """
  Resolve the safe start offset for `content` given an optional `since`
  bound. Returns `{offset, index_used}` where `index_used` is `nil` when
  no `since` bound was given (the query was not index-eligible), otherwise
  `true`/`false`.
  """
  @spec content_offset(module(), term(), DateTime.t() | nil, binary()) ::
          {non_neg_integer(), boolean() | nil}
  def content_offset(_index, _handle, nil, _content), do: {0, nil}

  def content_offset(index, handle, %DateTime{} = since, content) do
    case index.seek(handle, since, :line) do
      {:ok, %{offset: offset}} ->
        if offset <= byte_size(content) and boundary?(content, offset) do
          {offset, true}
        else
          {0, false}
        end

      _ ->
        {0, false}
    end
  end

  defp boundary?(_content, 0), do: true
  defp boundary?(content, offset), do: :binary.at(content, offset - 1) == ?\n
end
