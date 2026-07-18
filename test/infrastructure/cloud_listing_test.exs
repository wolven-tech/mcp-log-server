defmodule McpLogServer.Infrastructure.CloudListingTest do
  use ExUnit.Case, async: true

  alias McpLogServer.Infrastructure.CloudListing

  describe "parse_gsutil/1" do
    test "parses object lines and skips the TOTAL summary" do
      output = """
            2276  2026-07-01T10:15:30Z  gs://bucket/logs/api-1.log
             123  2026-07-05T12:00:00Z  gs://bucket/logs/api-2.log
      TOTAL: 2 objects, 2399 bytes (2.34 KiB)
      """

      assert [
               {"gs://bucket/logs/api-1.log", ~U[2026-07-01 10:15:30Z]},
               {"gs://bucket/logs/api-2.log", ~U[2026-07-05 12:00:00Z]}
             ] = CloudListing.parse_gsutil(output)
    end

    test "skips lines without a gs:// url or a parseable timestamp" do
      output = """
      Building synchronization state...
            2276  not-a-timestamp  gs://bucket/logs/api-1.log
             123  2026-07-05T12:00:00Z  gs://bucket/logs/api-2.log
      """

      assert [{"gs://bucket/logs/api-2.log", _}] = CloudListing.parse_gsutil(output)
    end

    test "empty output yields no entries" do
      assert CloudListing.parse_gsutil("") == []
    end
  end

  describe "parse_aws_s3/1" do
    test "parses listing lines, timestamps treated as UTC" do
      output = """
      2026-07-01 10:15:30       2276 logs/api-1.log
      2026-07-05 12:00:00        123 logs/nested/api-2.log
      """

      assert [
               {"logs/api-1.log", ~U[2026-07-01 10:15:30Z]},
               {"logs/nested/api-2.log", ~U[2026-07-05 12:00:00Z]}
             ] = CloudListing.parse_aws_s3(output)
    end

    test "keeps keys containing spaces" do
      output = "2026-07-01 10:15:30       2276 logs/app server.log\n"
      assert [{"logs/app server.log", _}] = CloudListing.parse_aws_s3(output)
    end

    test "skips PRE directory markers and malformed lines" do
      output = """
                                 PRE nested/
      garbage line
      2026-07-05 12:00:00        123 logs/api-2.log
      """

      assert [{"logs/api-2.log", _}] = CloudListing.parse_aws_s3(output)
    end
  end

  describe "parse_az_tsv/1" do
    test "parses name/lastModified tsv lines" do
      output =
        "logs/api-1.log\t2026-07-01T10:15:30+00:00\n" <>
          "logs/api-2.log\t2026-07-05T12:00:00+00:00\n"

      assert [
               {"logs/api-1.log", first},
               {"logs/api-2.log", _second}
             ] = CloudListing.parse_az_tsv(output)

      assert DateTime.compare(first, ~U[2026-07-01 10:15:30Z]) == :eq
    end

    test "skips lines without a tab or with an unparseable timestamp" do
      output = "no-tab-here\nlogs/api.log\tnot-a-date\nlogs/ok.log\t2026-07-05T12:00:00Z\n"
      assert [{"logs/ok.log", _}] = CloudListing.parse_az_tsv(output)
    end
  end
end
