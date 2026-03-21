# PRD-002: Time-Based Log Filtering

**GitHub Issue:** #2
**Status:** Draft
**Priority:** P1 — Depends on PRD-001 (JSON timestamp extraction)

---

## Problem Statement

All existing tools operate on line position (last N lines, first N matches). There is no way to ask "show me errors from the last 2 hours" or "what happened between 14:00 and 14:30". For incident response — the primary use case — time is the most natural filter dimension.

Additionally, `gcloud logging read --freshness=24h` is known to return entries outside the requested window. Developers need post-hoc time slicing on exported log dumps.

## Goals

1. Add `since` and `until` parameters to `search_logs`, `get_errors`, `tail_log`, and `all_errors`
2. Support both absolute ISO 8601 timestamps and relative shorthands (`1h`, `30m`, `2d`)
3. Auto-detect timestamp formats in both plain text and JSON logs
4. Add a `time_range` tool that returns the earliest and latest timestamps in a file
5. Keep performance acceptable for files up to 100MB

## Non-Goals

- Timezone conversion UI — all times are UTC internally; local time display is the client's job
- Indexing or pre-processing log files for faster time queries
- Sub-second precision (second-level is sufficient for filtering)

## Design

### 1. Timestamp Extraction Module

New module: `McpLogServer.Domain.TimestampParser`

```elixir
@spec extract(line :: String.t()) :: DateTime.t() | nil
@spec extract_from_json(entry :: map()) :: DateTime.t() | nil
@spec parse_relative(shorthand :: String.t()) :: DateTime.t()
```

**Plain text timestamp patterns** (tried in order):

| Pattern | Example | Regex |
|---------|---------|-------|
| ISO 8601 | `2026-03-20T14:00:00.123Z` | `\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}` |
| Bracketed ISO | `[2026-03-20T14:00:00Z]` | `\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[^\]]*)\]` |
| Syslog | `Mar 20 14:00:00` | `[A-Z][a-z]{2}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2}` |
| Common log format | `20/Mar/2026:14:00:00 +0000` | `\d{2}/[A-Z][a-z]{2}/\d{4}:\d{2}:\d{2}:\d{2}` |
| Date-space-time | `2026-03-20 14:00:00` | `\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}` |

**JSON timestamp extraction** — delegates to `JsonLogParser.extract_timestamp/1` from PRD-001.

**Relative shorthand parsing:**
```
"30s"  → now - 30 seconds
"5m"   → now - 5 minutes
"2h"   → now - 2 hours
"1d"   → now - 1 day
"1w"   → now - 7 days
```

Parse via regex `^(\d+)([smhdw])$`.

### 2. Time Filter Integration

Add a generic filter function that wraps existing logic:

```elixir
defmodule McpLogServer.Domain.TimeFilter do
  @spec in_range?(line_or_entry, since :: DateTime.t() | nil, until :: DateTime.t() | nil) :: boolean()
end
```

For plain text: extract timestamp from line, compare.
For JSON: use parsed timestamp field, compare.
If no timestamp can be extracted from a line, **include it** (fail-open to avoid dropping important context).

### 3. Modify Existing Tools

#### `get_errors` — add `since`, `until`

```elixir
get_errors(log_dir, file, max_lines, since: "2h", until: nil)
```

Pipeline becomes:
```
stream lines → filter by time range → filter by severity → take last N → format
```

#### `search_logs` — add `since`, `until`

```elixir
search(log_dir, file, pattern, since: "2026-03-20T14:00:00Z", until: "2026-03-20T14:30:00Z")
```

#### `tail_log` — add `since`

For `tail_log`, `since` means "return lines from this time onward" (still capped by `lines` count). This is more intuitive than `until` for tailing.

#### `all_errors` — add `since`

Filter errors across all files by time. Critical for incident response: "show me all errors in the last 30 minutes across all services".

### 4. New Tool: `time_range`

```json
{
  "name": "time_range",
  "description": "Get the earliest and latest timestamps in a log file. Helps understand what time period a file covers before querying.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "file": {"type": "string", "description": "Log file name"}
    },
    "required": ["file"]
  }
}
```

**Response:**
```json
{
  "file": "api.log",
  "earliest": "2026-03-20T00:00:01Z",
  "latest": "2026-03-20T23:59:58Z",
  "span": "23h 59m 57s",
  "line_count": 14523,
  "format": "json_lines"
}
```

**Implementation**: Read first and last 10 lines, extract timestamps. For JSON arrays, parse first and last entries. This avoids reading the entire file.

### 5. Tool Schema Updates

Add to `search_logs`, `get_errors`, `tail_log`, `all_errors`:

```json
{
  "since": {
    "type": "string",
    "description": "Start time — ISO 8601 (2026-03-20T14:00:00Z) or relative (1h, 30m, 2d)"
  },
  "until": {
    "type": "string",
    "description": "End time — ISO 8601 or relative. Omit for 'up to now'."
  }
}
```

## User Stories

### US-1: Filter errors by relative time
**As** a developer responding to an incident,
**I want** to run `get_errors(file: "api.log", since: "30m")`,
**So that** I see only errors from the last 30 minutes, not the full 24-hour dump.

**Acceptance Criteria:**
- `since: "30m"` resolves to `now - 30 minutes`
- Supports `s`, `m`, `h`, `d`, `w` suffixes
- Lines without parseable timestamps are included (fail-open)

### US-2: Absolute time range search
**As** a developer investigating a specific outage window,
**I want** to search between two absolute timestamps,
**So that** I can isolate exactly what happened between 14:00 and 14:30.

**Acceptance Criteria:**
- `since` and `until` accept ISO 8601 strings
- Both are optional — omit `since` for "from beginning", omit `until` for "up to now"
- Works with both plain text and JSON log formats

### US-3: Understand file time coverage
**As** an LLM analyzing logs,
**I want** to call `time_range` first to know what period a file covers,
**So that** I can construct meaningful time-bounded queries.

**Acceptance Criteria:**
- Returns earliest and latest timestamps without reading the full file
- Includes human-readable span ("23h 59m")
- Returns `null` for timestamps if file has no parseable timestamps

### US-4: Time-filtered all_errors
**As** a developer who just got paged,
**I want** `all_errors(since: "15m")` to show only recent errors across all services,
**So that** I immediately see what's failing right now, not historical noise.

**Acceptance Criteria:**
- `since` parameter filters each file's errors by time before aggregation
- Files with no recent errors are omitted from results
- TOON output includes timestamp column

## Implementation Plan

1. **TimestampParser module** + tests — extract from plain text, parse relative shorthands
2. **TimeFilter module** + tests — `in_range?/3` for both plain text and JSON entries
3. **time_range tool** — new LogReader function + Registry + Dispatcher
4. **Modify get_errors** — add since/until pipeline stage
5. **Modify search_logs** — add since/until pipeline stage
6. **Modify tail_log** — add since parameter
7. **Modify all_errors** — add since parameter, include timestamp in TOON output
8. **Update Registry schemas** — add since/until to all affected tools
9. **Integration tests** — test relative times, absolute times, time_range, no-timestamp fallback

## Performance Considerations

- **Plain text files**: Must scan lines sequentially to extract timestamps. For files > 50MB, the `since` filter should short-circuit: once we've found lines past `until`, stop reading.
- **JSON files**: Timestamp is a parsed field — no regex overhead.
- **time_range**: Only reads first/last 10 lines — O(1) regardless of file size.
- Consider binary search optimization for sorted log files in a future iteration.

## Dependencies

- PRD-001 (JSON format support) — for `JsonLogParser.extract_timestamp/1`
- Can be partially implemented without PRD-001 by supporting plain-text timestamps first
