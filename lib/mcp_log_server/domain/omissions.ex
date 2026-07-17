defmodule McpLogServer.Domain.Omissions do
  @moduledoc """
  The single shape every tool uses to say "you did not see everything".

  A truncated result that looks complete is worse than an error: the
  investigator concludes "line absent" when the truth was "line beyond the
  buffer". Whenever a bound is actually hit — a match/line/value cap, or a
  file skipped by the `MAX_LOG_FILE_MB` guardrail — the result carries an
  `omissions` block naming exactly what was withheld and why:

      omissions: %{
        matches: %{omitted: 240, showing: "first 50"},   # count known
        matches: %{capped_at: 500},                       # count unknown (lazy scan stopped early)
        lines:   %{omitted: 240, showing: "newest 100"},
        values:  %{omitted: 12, showing: "top 50 by count"},
        skipped_files: [%{file: "app.log", reason: "File too large (142.0 MB). ..."}]
      }

  WHY one uniform shape: agents consuming these results must be able to
  check ONE field to know whether they saw everything. And ZERO noise when
  nothing was bounded: `attach/2` adds the block only when it is non-empty,
  so complete results stay byte-identical to before (no `omitted: 0`).
  """

  @type t :: map()

  @doc "An empty omissions block."
  @spec new() :: t()
  def new, do: %{}

  @spec empty?(t()) :: boolean()
  def empty?(om), do: om == %{}

  @doc """
  Record that a cap was hit: `total` items existed, `shown` were returned.
  No-op when the cap was not exceeded.
  """
  @spec cap(t(), atom(), non_neg_integer(), non_neg_integer(), String.t()) :: t()
  def cap(om, key, total, shown, showing) when total > shown,
    do: omitted(om, key, total - shown, showing)

  def cap(om, _key, _total, _shown, _showing), do: om

  @doc "Record `n` omitted items directly. No-op when `n` is 0."
  @spec omitted(t(), atom(), non_neg_integer(), String.t()) :: t()
  def omitted(om, _key, 0, _showing), do: om

  def omitted(om, key, n, showing) when n > 0,
    do: Map.put(om, key, %{omitted: n, showing: showing})

  @doc """
  Record that a lazy scan stopped at `cap` without counting the remainder
  (the honest form when the total is unknown).
  """
  @spec capped_at(t(), atom(), pos_integer()) :: t()
  def capped_at(om, key, cap), do: Map.put(om, key, %{capped_at: cap})

  @doc "Record a file the scan skipped entirely, and why."
  @spec skipped_file(t(), String.t(), String.t()) :: t()
  def skipped_file(om, file, reason) do
    entry = %{file: file, reason: reason}
    Map.update(om, :skipped_files, [entry], &(&1 ++ [entry]))
  end

  @doc """
  Put the block into a result map under `:omissions` — ONLY when non-empty,
  so complete results carry no marker at all.
  """
  @spec attach(map(), t()) :: map()
  def attach(result, om) when om == %{}, do: result
  def attach(result, om), do: Map.put(result, :omissions, om)
end
