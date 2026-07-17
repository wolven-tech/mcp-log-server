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

  describe "extract/2 - time-only dev-server formats (issue #6)" do
    @reference ~U[2026-03-20 15:00:00Z]

    test "parses HH:MM:SS prefix against the reference date" do
      dt = TimestampParser.extract("14:00:00 [vite] hmr update /src/App.tsx", reference: @reference)
      assert dt == ~U[2026-03-20 14:00:00Z]
    end

    test "parses HH:MM:SS prefix with fractional seconds" do
      dt = TimestampParser.extract("14:00:00.123 dev server ready", reference: @reference)
      assert %DateTime{hour: 14, microsecond: {123_000, 3}} = dt
      assert DateTime.to_date(dt) == ~D[2026-03-20]
    end

    test "parses bracketed [HH:MM:SS]" do
      dt = TimestampParser.extract("[14:00:00] page reload src/main.ts", reference: @reference)
      assert dt == ~U[2026-03-20 14:00:00Z]
    end

    test "parses [vite]-style tagged time" do
      dt = TimestampParser.extract("[vite] 14:00:00 hmr update /src/App.tsx", reference: @reference)
      assert dt == ~U[2026-03-20 14:00:00Z]
    end

    test "parses 12-hour clock with AM/PM" do
      pm = TimestampParser.extract("2:00:00 PM [vite] hmr update", reference: @reference)
      assert pm == ~U[2026-03-20 14:00:00Z]

      am = TimestampParser.extract("9:30:00 AM [vite] page reload", reference: @reference)
      assert am == ~U[2026-03-20 09:30:00Z]
    end

    test "strips ANSI color codes before matching" do
      line = "\e[2m14:00:00\e[0m \e[36m[vite]\e[0m \e[32mhmr update\e[0m /src/App.tsx"
      dt = TimestampParser.extract(line, reference: @reference)
      assert dt == ~U[2026-03-20 14:00:00Z]
    end

    test "strips ANSI codes around bracketed dev-server tags" do
      line = "\e[36m[vite]\e[0m \e[2m14:00:00\e[0m hmr update"
      dt = TimestampParser.extract(line, reference: @reference)
      assert dt == ~U[2026-03-20 14:00:00Z]
    end

    test "does not treat a mid-line time as a prefix timestamp" do
      assert TimestampParser.extract("finished at 14:00:00 today", reference: @reference) == nil
    end

    test "midnight rollover: time later than reference shifts back one day" do
      # File last modified 00:30; a 23:50 line must belong to the previous day.
      reference = ~U[2026-03-21 00:30:00Z]

      late = TimestampParser.extract("23:50:00 [vite] hmr update", reference: reference)
      early = TimestampParser.extract("00:20:00 [vite] page reload", reference: reference)

      assert late == ~U[2026-03-20 23:50:00Z]
      assert early == ~U[2026-03-21 00:20:00Z]
      # Ordering stays monotonic across the rollover
      assert DateTime.compare(late, early) == :lt
    end

    test "defaults the reference to now for still-growing logs" do
      one_min_ago = DateTime.add(DateTime.utc_now(), -60, :second)
      clock = Calendar.strftime(one_min_ago, "%H:%M:%S")

      dt = TimestampParser.extract("#{clock} [vite] hmr update")
      assert_in_delta DateTime.diff(DateTime.utc_now(), dt, :second), 60, 3
    end
  end

  describe "extract/2 - declared format precedence" do
    test "declared format is tried before auto-detection" do
      {:ok, epoch_ms} = McpLogServer.Domain.TsFormat.compile("epoch_ms")
      # Auto-detect would pick the ISO stamp; the declared format must win.
      line = "2026-03-20T14:00:00Z evt=1742479200123"

      dt = TimestampParser.extract(line, format: epoch_ms)
      assert DateTime.to_unix(dt, :millisecond) == 1_742_479_200_123
    end

    test "falls back to auto-detection when the declared format does not match" do
      {:ok, epoch_ms} = McpLogServer.Domain.TsFormat.compile("epoch_ms")
      dt = TimestampParser.extract("2026-03-20T14:00:00Z no epoch here", format: epoch_ms)
      assert dt == ~U[2026-03-20 14:00:00Z]
    end
  end

  describe "extract/2 - regression: existing formats unaffected by time-only support" do
    test "full ISO still wins over time-only" do
      dt = TimestampParser.extract("2026-03-20T14:00:00Z 09:00:00 weird trailer")
      assert dt == ~U[2026-03-20 14:00:00Z]
    end

    test "date-space-time still wins over time-only" do
      dt = TimestampParser.extract("2026-03-20 14:00:00 ERROR at 09:00:00")
      assert dt == ~U[2026-03-20 14:00:00Z]
    end

    test "syslog still wins over time-only" do
      dt = TimestampParser.extract("Mar 20 14:00:00 myhost sshd[1234]: accepted")
      assert %DateTime{month: 3, day: 20, hour: 14} = dt
    end
  end

  describe "parse_json_value/2" do
    test "parses ISO strings" do
      assert TimestampParser.parse_json_value("2026-03-20T14:00:00Z") == ~U[2026-03-20 14:00:00Z]
    end

    test "returns nil for unparseable strings and non-timestamps" do
      assert TimestampParser.parse_json_value("not a time") == nil
      assert TimestampParser.parse_json_value(nil) == nil
      assert TimestampParser.parse_json_value(%{}) == nil
    end

    test "parses integer epochs only with a declared epoch format" do
      {:ok, epoch_ms} = McpLogServer.Domain.TsFormat.compile("epoch_ms")
      {:ok, epoch_s} = McpLogServer.Domain.TsFormat.compile("epoch_s")

      assert TimestampParser.parse_json_value(1_742_479_200_123) == nil

      dt = TimestampParser.parse_json_value(1_742_479_200_123, format: epoch_ms)
      assert DateTime.to_unix(dt, :millisecond) == 1_742_479_200_123

      dt = TimestampParser.parse_json_value(1_742_479_200, format: epoch_s)
      assert DateTime.to_unix(dt) == 1_742_479_200
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
