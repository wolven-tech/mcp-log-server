defmodule McpLogServer.Domain.TimestampParserTest do
  use ExUnit.Case, async: true

  alias McpLogServer.Domain.TimestampParser

  describe "extract/1 - ISO 8601" do
    test "parses full ISO 8601 with Z" do
      dt = TimestampParser.extract("2026-03-20T14:00:00.123Z some log message")
      assert %DateTime{year: 2026, month: 3, day: 20, hour: 14, minute: 0} = dt
    end

    test "parses ISO 8601 without fractional seconds" do
      dt = TimestampParser.extract("2026-03-20T14:00:00Z ERROR something")
      assert %DateTime{year: 2026, month: 3, day: 20} = dt
    end

    test "parses ISO 8601 with timezone offset" do
      dt = TimestampParser.extract("2026-03-20T14:00:00+05:30 log entry")
      assert %DateTime{} = dt
    end
  end

  describe "extract/1 - bracketed ISO" do
    test "parses bracketed ISO 8601" do
      dt = TimestampParser.extract("[2026-03-20T14:00:00.123Z] INFO: started")
      assert %DateTime{year: 2026, month: 3, day: 20, hour: 14} = dt
    end
  end

  describe "extract/1 - syslog" do
    # Syslog format has no year, so TimestampParser uses DateTime.utc_now().year
    test "parses syslog format" do
      dt = TimestampParser.extract("Mar 20 14:00:00 myhost sshd[1234]: accepted")
      assert %DateTime{month: 3, day: 20, hour: 14, minute: 0, second: 0} = dt
    end

    test "parses syslog with single-digit day" do
      dt = TimestampParser.extract("Jan  5 09:30:15 server kernel: message")
      assert %DateTime{month: 1, day: 5, hour: 9, minute: 30, second: 15} = dt
    end

    test "syslog uses current year (not hardcoded)" do
      dt = TimestampParser.extract("Jun 15 12:00:00 host svc: msg")
      assert dt.year == DateTime.utc_now().year
    end
  end

  describe "extract/1 - Common Log Format" do
    test "parses CLF timestamp" do
      dt = TimestampParser.extract(~s|192.168.1.1 - - [20/Mar/2026:14:00:00 +0000] "GET /"|)
      assert %DateTime{year: 2026, month: 3, day: 20, hour: 14} = dt
    end

    test "parses CLF with non-zero offset" do
      dt = TimestampParser.extract(~s|10.0.0.1 - - [20/Mar/2026:14:00:00 +0530] "POST /api"|)
      # +0530 means UTC time is 14:00 - 5:30 = 08:30
      assert %DateTime{hour: 8, minute: 30} = dt
    end
  end

  describe "extract/1 - date space time" do
    test "parses date space time format" do
      dt = TimestampParser.extract("2026-03-20 14:00:00 ERROR Connection refused")
      assert %DateTime{year: 2026, month: 3, day: 20, hour: 14} = dt
    end

    test "parses date space time with fractional seconds" do
      dt = TimestampParser.extract("2026-03-20 14:00:00.456 INFO Started")
      assert %DateTime{year: 2026, month: 3, day: 20} = dt
    end
  end

  describe "extract/1 - edge cases" do
    test "returns nil for non-timestamp text" do
      assert TimestampParser.extract("just some random log text") == nil
    end

    test "returns nil for empty string" do
      assert TimestampParser.extract("") == nil
    end

    test "returns nil for partial date" do
      assert TimestampParser.extract("2026-03-20 some text") == nil
    end
  end

  describe "parse_relative/1" do
    test "parses seconds" do
      dt = TimestampParser.parse_relative("30s")
      diff = DateTime.diff(DateTime.utc_now(), dt, :second)
      assert_in_delta diff, 30, 2
    end

    test "parses minutes" do
      dt = TimestampParser.parse_relative("5m")
      diff = DateTime.diff(DateTime.utc_now(), dt, :second)
      assert_in_delta diff, 300, 2
    end

    test "parses hours" do
      dt = TimestampParser.parse_relative("2h")
      diff = DateTime.diff(DateTime.utc_now(), dt, :second)
      assert_in_delta diff, 7200, 2
    end

    test "parses days" do
      dt = TimestampParser.parse_relative("1d")
      diff = DateTime.diff(DateTime.utc_now(), dt, :second)
      assert_in_delta diff, 86400, 2
    end

    test "parses weeks" do
      dt = TimestampParser.parse_relative("1w")
      diff = DateTime.diff(DateTime.utc_now(), dt, :second)
      assert_in_delta diff, 604_800, 2
    end

    test "returns nil for invalid input" do
      assert TimestampParser.parse_relative("abc") == nil
    end

    test "returns nil for empty string" do
      assert TimestampParser.parse_relative("") == nil
    end

    test "returns nil for unsupported unit" do
      assert TimestampParser.parse_relative("5y") == nil
    end
  end
end
