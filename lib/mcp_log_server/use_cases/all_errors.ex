defmodule McpLogServer.UseCases.AllErrors do
  @moduledoc """
  Use-case: extract errors from every log at once for a health overview.

  Logs that exceed the read-size guardrail are reported in `:skipped`
  instead of failing the whole call.
  """

  alias McpLogServer.UseCases.Deps
  alias McpLogServer.UseCases.GetErrors

  @doc """
  Collect errors from all logs in `log_dir`, at most `lines_per_file` each.

  Returns `{:ok, %{results: [...], skipped: [...], unparsed_ts: n | nil}}`
  where `results` holds per-file error maps, `skipped` holds human-readable
  skip notices, and `unparsed_ts` is the total count (across all scanned
  files) of lines whose timestamp could not be parsed while a time filter
  was active — those lines pass the filter (fail-open). It is `nil` when no
  time filter was applied.
  Accepts the same filtering options as `McpLogServer.UseCases.GetErrors.run/4`.
  """
  @spec run(String.t(), pos_integer(), keyword()) ::
          {:ok, %{results: [map()], skipped: [String.t()], unparsed_ts: non_neg_integer() | nil}}
  def run(log_dir, lines_per_file, opts \\ []) do
    source = Deps.log_source(opts)
    config = Deps.config(opts)
    filter_active? = Keyword.get(opts, :since) != nil or Keyword.get(opts, :until) != nil

    {:ok, files} = source.list(log_dir)

    {results, skipped, unparsed_total} =
      Enum.reduce(files, {[], [], 0}, fn %{name: name} = file_info, {res, skip, unparsed} ->
        case source.resolve_readable(log_dir, name) do
          {:error, _} ->
            size_mb = Float.round(file_info.size_bytes / 1_048_576, 1)
            max_mb = config.max_log_file_mb()

            {res, skip ++ ["--- skipped: #{name} (#{size_mb} MB exceeds #{max_mb} MB limit) ---"],
             unparsed}

          {:ok, _handle} ->
            case GetErrors.run(log_dir, name, lines_per_file, opts) do
              {:ok, %{entries: errors, unparsed_ts: file_unparsed}} ->
                unparsed = unparsed + (file_unparsed || 0)

                if errors != [] do
                  {res ++ [%{file: name, error_count: length(errors), matches: errors}], skip,
                   unparsed}
                else
                  {res, skip, unparsed}
                end

              _ ->
                {res, skip, unparsed}
            end
        end
      end)

    {:ok,
     %{
       results: results,
       skipped: skipped,
       unparsed_ts: if(filter_active?, do: unparsed_total, else: nil)
     }}
  end
end
