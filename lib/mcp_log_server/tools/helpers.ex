defmodule McpLogServer.Tools.Helpers do
  @moduledoc """
  Shared argument-parsing helpers for tool modules.
  """

  @spec to_pos_int(any(), pos_integer()) :: pos_integer()
  def to_pos_int(val, _default) when is_integer(val) and val > 0, do: val
  def to_pos_int(_val, default), do: default

  @spec maybe_add_time_opts(keyword(), map()) :: keyword()
  def maybe_add_time_opts(opts, args) do
    opts =
      case Map.get(args, "since") do
        s when is_binary(s) and s != "" -> Keyword.put(opts, :since, s)
        _ -> opts
      end

    case Map.get(args, "until") do
      u when is_binary(u) and u != "" -> Keyword.put(opts, :until, u)
      _ -> opts
    end
  end

end
