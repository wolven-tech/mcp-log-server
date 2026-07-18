defmodule McpLogServer.Infrastructure.CloudListing do
  @moduledoc """
  Pure parsers for the listing output of the cloud storage CLIs
  (`gsutil ls -l`, `aws s3 ls --recursive`, `az storage blob list ... -o tsv`).

  Infrastructure-layer knowledge (each format is a vendor CLI contract), but
  kept free of side effects so `McpLogServer.Infrastructure.CloudSync` can be
  tested line-by-line without shelling out.

  Lines that do not match the expected shape (summary/TOTAL lines, directory
  markers, unparseable timestamps) are skipped — the caller reports how many
  entries were listed, so a systematically wrong parse shows up as a
  suspicious listed-count, not a silent no-op.
  """

  @gsutil_line ~r/^\s*(\d+)\s+(\S+)\s+(gs:\/\/\S+)$/
  @aws_line ~r/^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2})\s+\d+\s+(\S.*)$/

  @doc """
  Parse `gsutil ls -l` output into `[{url, modified :: DateTime.t()}]`.

  Expected object lines look like:

      2276  2026-07-01T10:15:30Z  gs://bucket/logs/api.log

  The trailing `TOTAL: ...` summary line and any non-object lines are
  skipped. Objects whose timestamp does not parse as ISO 8601 are skipped.
  """
  @spec parse_gsutil(String.t()) :: [{String.t(), DateTime.t()}]
  def parse_gsutil(output) do
    for line <- String.split(output, "\n"),
        [_, _size, ts, url] <- [Regex.run(@gsutil_line, line)],
        {:ok, dt, _offset} <- [DateTime.from_iso8601(ts)] do
      {url, dt}
    end
  end

  @doc """
  Parse `aws s3 ls <source> --recursive` output into
  `[{key, modified :: DateTime.t()}]`.

  Expected lines look like:

      2026-07-01 10:15:30       2276 logs/api.log

  CAVEAT: the aws CLI prints these timestamps in the local timezone of the
  host running the CLI; there is no offset in the output, so they are
  treated as UTC here.
  """
  @spec parse_aws_s3(String.t()) :: [{String.t(), DateTime.t()}]
  def parse_aws_s3(output) do
    for line <- String.split(output, "\n"),
        [_, date, time, key] <- [Regex.run(@aws_line, line)],
        {:ok, naive} <- [NaiveDateTime.from_iso8601("#{date}T#{time}")] do
      {key, DateTime.from_naive!(naive, "Etc/UTC")}
    end
  end

  @doc """
  Parse `az storage blob list ... --query "[].[name,properties.lastModified]"
  --output tsv` output into `[{name, modified :: DateTime.t()}]`.

  Expected lines are tab-separated: `logs/api.log\t2026-07-01T10:15:30+00:00`.
  """
  @spec parse_az_tsv(String.t()) :: [{String.t(), DateTime.t()}]
  def parse_az_tsv(output) do
    for line <- String.split(output, "\n"),
        [name, ts] <- [String.split(line, "\t", parts: 2)],
        name != "",
        {:ok, dt, _offset} <- [DateTime.from_iso8601(String.trim(ts))] do
      {name, dt}
    end
  end
end
