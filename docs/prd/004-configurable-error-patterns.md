# PRD-004: Configurable Error Patterns and Log Level Filtering

**GitHub Issue:** #4
**Status:** Draft
**Priority:** P1 — Independent, but benefits from PRD-001

---

## Problem Statement

`get_errors` uses a hardcoded regex pattern:

```elixir
@error_pattern ~r/(ERROR|FATAL|EXCEPTION|WARN|TypeError|ReferenceError|SyntaxError|ECONNREFUSED|ENOTFOUND|failed|Failed)/i
```

This causes two problems:

1. **False positives**: `"failed": 0` in a health check INFO log matches because of the word "failed". `WARN` matches when you only want errors. Every project has different noise.
2. **Missed errors**: Project-specific patterns like `circuit.breaker.open`, `timeout`, `OOMKilled`, `SIGKILL`, `deadline exceeded` are not detected.
3. **No severity filtering**: You cannot ask for "only ERRORs" or "only WARNs" — it's all-or-nothing.

The `log_stats` tool has the same issue — its error/warn counts use separate hardcoded regexes.

## Goals

1. Add a `level` parameter to `get_errors` and `all_errors` for severity-level filtering
2. Allow custom error patterns via environment variable
3. Add `exclude` parameter to filter out known noise
4. Unify pattern definitions so `get_errors`, `all_errors`, and `log_stats` use the same configurable patterns
5. Provide sensible defaults that work out of the box

## Non-Goals

- Per-file pattern configuration (one pattern set per LOG_DIR is sufficient)
- Runtime pattern modification via MCP tool calls (config is set at startup)
- Pattern learning or auto-tuning

## Design

### 1. Severity Level Hierarchy

Define a standard severity hierarchy:

```elixir
@severity_levels %{
  "trace" => 0,
  "debug" => 1,
  "info"  => 2,
  "warn"  => 3,
  "error" => 4,
  "fatal" => 5
}
```

The `level` parameter means "this level and above":
- `level: "error"` → ERROR, FATAL
- `level: "warn"` → WARN, ERROR, FATAL
- `level: "info"` → INFO, WARN, ERROR, FATAL

### 2. Pattern Configuration

#### Default patterns by level

```elixir
@default_patterns %{
  fatal: ~r/FATAL|PANIC|OOMKilled|SIGKILL|kernel\s*panic/i,
  error: ~r/ERROR|EXCEPTION|TypeError|ReferenceError|SyntaxError|ECONNREFUSED|ENOTFOUND|UnhandledPromiseRejection/i,
  warn:  ~r/WARN|WARNING|deprecated|timeout|circuit.breaker|retry/i
}
```

Note: Removed bare `failed`/`Failed` from defaults — this is the #1 source of false positives. Instead, add `failed` to the error pattern only if the user explicitly wants it via custom patterns.

#### Environment variable configuration

```bash
# Additional patterns (merged with defaults)
LOG_EXTRA_PATTERNS="deadline.exceeded|SIGTERM|connection.reset"

# Override default patterns entirely
LOG_ERROR_PATTERNS="ERROR|FATAL|EXCEPTION|my_custom_error"
LOG_WARN_PATTERNS="WARN|WARNING|timeout"
LOG_FATAL_PATTERNS="FATAL|PANIC|OOMKilled"
```

#### Configuration module

New module: `McpLogServer.Config.Patterns`

```elixir
@spec error_pattern(level :: atom()) :: Regex.t()
@spec matches_level?(line :: String.t(), level :: atom()) :: boolean()
@spec detect_level(line :: String.t()) :: atom() | nil
```

Resolution order:
1. If `LOG_ERROR_PATTERNS` is set → use it for error level (override)
2. If `LOG_EXTRA_PATTERNS` is set → merge with defaults
3. Otherwise → use defaults

Patterns are compiled once at application startup and cached in module attribute or application env.

### 3. Exclude Parameter

Add `exclude` to `get_errors` and `all_errors`:

```elixir
get_errors(file: "api.log", level: "error", exclude: "health.check|failed: 0")
```

Implementation: After matching error patterns, apply exclude regex as a reject filter:

```elixir
entries
|> Enum.filter(&matches_level?(&1, level))
|> Enum.reject(&matches_exclude?(&1, exclude_regex))
```

### 4. Modify `get_errors`

```elixir
def get_errors(log_dir, file, max_lines, opts \\ []) do
  level = Keyword.get(opts, :level, :warn)  # default: warn and above
  exclude = Keyword.get(opts, :exclude, nil)

  with {:ok, path} <- resolve(log_dir, file) do
    # For JSON logs (PRD-001): use severity field
    # For plain text: use configurable regex patterns
    errors =
      path
      |> File.stream!()
      |> Stream.map(&String.trim_trailing/1)
      |> Stream.with_index(1)
      |> Stream.filter(fn {line, _} -> Patterns.matches_level?(line, level) end)
      |> maybe_exclude(exclude)
      |> Enum.take(-max_lines)
      |> Enum.map(fn {line, idx} -> %{line_number: idx, content: line} end)

    {:ok, errors}
  end
end
```

### 5. Update `log_stats`

Use the same `Patterns` module for counting:

```elixir
{line_count, error_count, warn_count, fatal_count} =
  path
  |> File.stream!()
  |> Enum.reduce({0, 0, 0, 0}, fn line, {lines, errors, warns, fatals} ->
    {
      lines + 1,
      if(Patterns.matches_level?(line, :error), do: errors + 1, else: errors),
      if(Patterns.matches_level?(line, :warn), do: warns + 1, else: warns),
      if(Patterns.matches_level?(line, :fatal), do: fatals + 1, else: fatals)
    }
  end)
```

Add `fatal_count` to stats output.

### 6. Tool Schema Updates

#### `get_errors`

```json
{
  "level": {
    "type": "string",
    "enum": ["fatal", "error", "warn", "info"],
    "description": "Minimum severity level (default: warn). 'error' = ERROR+FATAL only. 'warn' = WARN+ERROR+FATAL."
  },
  "exclude": {
    "type": "string",
    "description": "Regex pattern to exclude from results (e.g., 'health.check|failed: 0')"
  }
}
```

#### `all_errors`

Same `level` and `exclude` parameters.

### 7. Integration with PRD-001 (JSON Logs)

When processing JSON logs, severity filtering uses the parsed `severity`/`level` field directly rather than regex patterns. The `exclude` parameter still applies to the message content.

```elixir
def matches_level_json?(entry, level) do
  entry_severity = JsonLogParser.extract_severity(entry)
  severity_rank(entry_severity) >= severity_rank(level)
end
```

For plain text logs, the regex patterns are used. This gives the best of both worlds:
- JSON logs: precise severity filtering via structured field
- Plain text: configurable regex patterns

## User Stories

### US-1: Filter by severity level
**As** a developer who only cares about errors (not warnings),
**I want** to run `get_errors(file: "api.log", level: "error")`,
**So that** I see only ERROR and FATAL lines, not the hundreds of WARN lines.

**Acceptance Criteria:**
- `level: "error"` returns only ERROR and FATAL matches
- `level: "warn"` returns WARN, ERROR, and FATAL (default behavior)
- `level: "fatal"` returns only FATAL/PANIC matches
- Default level is `warn` (backward compatible)

### US-2: Exclude known noise
**As** a developer whose health check logs contain "failed: 0",
**I want** to run `get_errors(file: "api.log", exclude: "health.check|failed: 0")`,
**So that** I don't see false positives from health check responses.

**Acceptance Criteria:**
- `exclude` parameter accepts a regex pattern
- Matched lines are removed from results after severity filtering
- Invalid regex returns a clear error message

### US-3: Add project-specific error patterns
**As** a DevOps engineer whose app uses custom error markers,
**I want** to set `LOG_EXTRA_PATTERNS="deadline.exceeded|circuit.breaker.open"`,
**So that** these are detected as errors without modifying the server code.

**Acceptance Criteria:**
- `LOG_EXTRA_PATTERNS` is merged with default patterns
- `LOG_ERROR_PATTERNS` overrides default error patterns entirely
- Patterns are compiled once at startup (no per-request regex compilation)

### US-4: Accurate log_stats counts
**As** an LLM deciding which file to investigate,
**I want** `log_stats` to report error/warn/fatal counts using the same patterns as `get_errors`,
**So that** the counts are consistent and I can trust the stats.

**Acceptance Criteria:**
- `log_stats` uses `Patterns.matches_level?/2` for counting
- Adds `fatal_count` to the response
- Counts are consistent with what `get_errors` would return

## Implementation Plan

1. **Patterns config module** + tests — load from env, compile, provide `matches_level?/2`
2. **Modify get_errors** — add `level` and `exclude` parameters
3. **Modify all_errors** — add `level` and `exclude` parameters
4. **Modify log_stats** — use Patterns module, add fatal_count
5. **Update Registry** — add level/exclude to schemas
6. **Update Dispatcher** — pass new options through
7. **Remove hardcoded `@error_pattern`** — replace with Patterns module calls
8. **Integration tests** — test level filtering, exclude, custom patterns via env
9. **Update docs** — document env vars in QUICK_START.md

## Migration & Backward Compatibility

- Default `level: "warn"` maintains current behavior (WARN + ERROR + FATAL)
- Removing bare `failed`/`Failed` from defaults is a **breaking change** in detection behavior. Document this in release notes. Users who relied on it can add it back via `LOG_EXTRA_PATTERNS="failed|Failed"`.
- All existing tool calls without `level`/`exclude` parameters continue to work identically.

## Dependencies

- PRD-001 (optional) — enables severity-field-based filtering for JSON logs
- Can be fully implemented for plain text without PRD-001
