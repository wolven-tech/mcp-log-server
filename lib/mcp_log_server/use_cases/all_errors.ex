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

  Returns `{:ok, %{results: [...], skipped: [...]}}` where `results` holds
  per-file error maps and `skipped` holds human-readable skip notices.
  Accepts the same filtering options as `McpLogServer.UseCases.GetErrors.run/4`.
  """
  @spec run(String.t(), pos_integer(), keyword()) ::
          {:ok, %{results: [map()], skipped: [String.t()]}}
  def run(log_dir, lines_per_file, opts \\ []) do
    source = Deps.log_source(opts)
    config = Deps.config(opts)

    {:ok, files} = source.list(log_dir)

    {results, skipped} =
      Enum.reduce(files, {[], []}, fn %{name: name} = file_info, {res, skip} ->
        case source.resolve_readable(log_dir, name) do
          {:error, _} ->
            size_mb = Float.round(file_info.size_bytes / 1_048_576, 1)
            max_mb = config.max_log_file_mb()
            {res, skip ++ ["--- skipped: #{name} (#{size_mb} MB exceeds #{max_mb} MB limit) ---"]}

          {:ok, _handle} ->
            case GetErrors.run(log_dir, name, lines_per_file, opts) do
              {:ok, errors} when errors != [] ->
                {res ++ [%{file: name, error_count: length(errors), matches: errors}], skip}

              _ ->
                {res, skip}
            end
        end
      end)

    {:ok, %{results: results, skipped: skipped}}
  end
end
