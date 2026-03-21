defmodule McpLogServer.Tools.Helpers do
  @moduledoc """
  Shared argument-parsing helpers for tool modules.
  """

  alias McpLogServer.Domain.TimestampParser

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

  @spec parse_time_opt(any()) :: DateTime.t() | nil
  def parse_time_opt(nil), do: nil

  def parse_time_opt(value) when is_binary(value) do
    # Try ISO 8601 first, then relative shorthand
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> TimestampParser.parse_relative(value)
    end
  end

  def parse_time_opt(_), do: nil
end
