defmodule McpLogServer.Config.PatternsTest do
  use ExUnit.Case, async: true

  alias McpLogServer.Config.Patterns

  describe "level hierarchy" do
    test "levels are ordered from lowest to highest" do
      assert Patterns.levels() == [:trace, :debug, :info, :warn, :error, :fatal]
    end

    test "level values increase monotonically" do
      values = Enum.map(Patterns.levels(), &Patterns.level_value/1)
      assert values == Enum.sort(values)
      assert Enum.uniq(values) == values
    end

    test "trace(0) < debug(1) < info(2) < warn(3) < error(4) < fatal(5)" do
      assert Patterns.level_value(:trace) == 0
      assert Patterns.level_value(:debug) == 1
      assert Patterns.level_value(:info) == 2
      assert Patterns.level_value(:warn) == 3
      assert Patterns.level_value(:error) == 4
      assert Patterns.level_value(:fatal) == 5
    end
  end

  describe "default patterns" do
    test "fatal patterns match FATAL, PANIC, OOMKilled, SIGKILL" do
      assert Patterns.detect_level("FATAL: out of memory") == :fatal
      assert Patterns.detect_level("kernel: PANIC - not syncing") == :fatal
      assert Patterns.detect_level("container OOMKilled") == :fatal
      assert Patterns.detect_level("process received SIGKILL") == :fatal
    end

    test "error patterns match ERROR, EXCEPTION, type errors, connection errors" do
      assert Patterns.detect_level("2026-01-01 ERROR something broke") == :error
      assert Patterns.detect_level("EXCEPTION in thread main") == :error
      assert Patterns.detect_level("TypeError: undefined is not a function") == :error
      assert Patterns.detect_level("ReferenceError: x is not defined") == :error
      assert Patterns.detect_level("SyntaxError: unexpected token") == :error
      assert Patterns.detect_level("connect ECONNREFUSED 127.0.0.1:5432") == :error
      assert Patterns.detect_level("getaddrinfo ENOTFOUND example.com") == :error
      assert Patterns.detect_level("UnhandledPromiseRejection: oops") == :error
    end

    test "warn patterns match WARN, WARNING, deprecated, timeout" do
      assert Patterns.detect_level("WARN: disk space low") == :warn
      assert Patterns.detect_level("WARNING: deprecated API") == :warn
      assert Patterns.detect_level("method foo is deprecated") == :warn
      assert Patterns.detect_level("connection timeout after 30s") == :warn
    end

    test "bare 'failed'/'Failed' does NOT match any level (breaking change)" do
      assert Patterns.detect_level(~s("failed": 0)) == nil
      assert Patterns.detect_level("Failed checks: 0") == nil
      assert Patterns.detect_level("tasks failed gracefully") == nil
    end

    test "returns nil for lines with no matching patterns" do
      assert Patterns.detect_level("GET /health 200 OK") == nil
      assert Patterns.detect_level("") == nil
    end

    test "detects info, debug, and trace levels" do
      assert Patterns.detect_level("2026-01-01 INFO Application started") == :info
      assert Patterns.detect_level("DEBUG: checking state") == :debug
      assert Patterns.detect_level("TRACE: entering function") == :trace
    end

    test "patterns are case-insensitive" do
      assert Patterns.detect_level("error: something") == :error
      assert Patterns.detect_level("Error: something") == :error
      assert Patterns.detect_level("fatal crash") == :fatal
      assert Patterns.detect_level("warn: low memory") == :warn
    end

    test "fatal takes precedence over error and warn" do
      # A line containing both FATAL and ERROR should be classified as fatal
      assert Patterns.detect_level("FATAL ERROR: system crash") == :fatal
    end

    test "error takes precedence over warn" do
      # A line containing both ERROR and WARN tokens
      assert Patterns.detect_level("ERROR: WARN threshold exceeded") == :error
    end
  end

  describe "matches_level?/2" do
    test "matches at the exact level" do
      assert Patterns.matches_level?("ERROR: something", :error)
      assert Patterns.matches_level?("WARN: something", :warn)
      assert Patterns.matches_level?("FATAL: something", :fatal)
    end

    test "matches at levels above the threshold" do
      # An error line matches when threshold is warn (error >= warn)
      assert Patterns.matches_level?("ERROR: something", :warn)
      # A fatal line matches when threshold is error
      assert Patterns.matches_level?("FATAL: something", :error)
      # A fatal line matches when threshold is warn
      assert Patterns.matches_level?("FATAL: something", :warn)
    end

    test "does NOT match below the threshold" do
      # A warn line does NOT match when threshold is error
      refute Patterns.matches_level?("WARN: something", :error)
      # A warn line does NOT match when threshold is fatal
      refute Patterns.matches_level?("WARN: something", :fatal)
      # An error line does NOT match when threshold is fatal
      refute Patterns.matches_level?("ERROR: something", :fatal)
    end

    test "returns false for lines with no matching patterns" do
      refute Patterns.matches_level?("INFO: all good", :warn)
      refute Patterns.matches_level?("INFO: all good", :error)
      refute Patterns.matches_level?("INFO: all good", :fatal)
    end
  end

  describe "detect_level/1" do
    test "returns :fatal for fatal-level lines" do
      assert Patterns.detect_level("FATAL: out of memory") == :fatal
    end

    test "returns :error for error-level lines" do
      assert Patterns.detect_level("ERROR: disk full") == :error
    end

    test "returns :warn for warn-level lines" do
      assert Patterns.detect_level("WARNING: high latency") == :warn
    end

    test "returns :info for info-level lines" do
      assert Patterns.detect_level("INFO: healthy") == :info
    end

    test "returns nil for unclassified lines" do
      assert Patterns.detect_level("just some text") == nil
    end
  end

  describe "regex_for/1" do
    test "returns a compiled regex for known levels" do
      assert %Regex{} = Patterns.regex_for(:fatal)
      assert %Regex{} = Patterns.regex_for(:error)
      assert %Regex{} = Patterns.regex_for(:warn)
    end

    test "returns nil for levels without patterns" do
      assert Patterns.regex_for(:trace) == nil
      assert Patterns.regex_for(:debug) == nil
      assert Patterns.regex_for(:info) == nil
    end
  end

  describe "defaults/0" do
    test "returns the built-in default patterns" do
      defaults = Patterns.defaults()
      assert is_map(defaults)
      assert Map.has_key?(defaults, :fatal)
      assert Map.has_key?(defaults, :error)
      assert Map.has_key?(defaults, :warn)
      assert defaults.fatal =~ "FATAL"
      assert defaults.error =~ "ERROR"
      assert defaults.warn =~ "WARN"
    end

    test "default error patterns do NOT contain bare 'failed'" do
      defaults = Patterns.defaults()
      # Split on pipe and check no alternative is just "failed" or "Failed"
      alternatives = String.split(defaults.error, "|")
      refute Enum.any?(alternatives, fn alt -> String.downcase(alt) == "failed" end)
    end
  end

  describe "env var override (compile-time)" do
    # NOTE: Because patterns are compiled at module load time via module attributes,
    # env var overrides cannot be tested dynamically in the same BEAM instance.
    # These tests document the expected behavior and verify the default path works.

    test "pattern_source returns the active source string for each level" do
      assert is_binary(Patterns.pattern_source(:fatal))
      assert is_binary(Patterns.pattern_source(:error))
      assert is_binary(Patterns.pattern_source(:warn))
      assert Patterns.pattern_source(:info) == nil
    end

    test "without env vars, pattern sources match defaults" do
      defaults = Patterns.defaults()
      assert Patterns.pattern_source(:fatal) == defaults.fatal
      # error source may include LOG_EXTRA_PATTERNS; without env var it matches default
      assert Patterns.pattern_source(:error) == defaults.error
      assert Patterns.pattern_source(:warn) == defaults.warn
    end
  end
end
