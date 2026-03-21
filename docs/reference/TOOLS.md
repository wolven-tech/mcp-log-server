---
title: Tool Reference
description: Complete API reference for all MCP Log Server tools
status: active
audience: [developers]
difficulty: intermediate
created: 2026-03-18
lastModified: 2026-03-20
tags: [reference, api, tools]
---

# Tool Reference

MCP Log Server exposes 9 tools via the MCP `tools/call` method. All tools return results as MCP text content.

---

## Recommended Workflow

A typical investigation follows this sequence:

1. **`all_errors`** -- Health overview across all log files. Start here to see which services have problems.
2. **`log_stats`** or **`time_range`** -- Understand the scope of a specific file (line counts, error counts, time span).
3. **`get_errors`** with `level`/`since` -- Targeted investigation of a single file, filtering by severity and time window.
4. **`search_logs`** with `field`/`context` -- Deep dive into specific patterns, optionally scoped to a JSON field.
5. **`correlate`** -- Cross-service tracing using a request ID, session ID, or trace ID to build a unified timeline.

---

## Discovery Tools

### list_logs

List all available `.log` files with metadata.

**Parameters:** None

**Example request:**
```json
{
  "name": "list_logs",
  "arguments": {}
}
```

**Example response:**
```
[modified|name|size]
2026-03-20T10:05:00Z|api.log|2.4 MB
2026-03-20T09:30:00Z|worker.log|156 KB
2026-03-20T08:12:00Z|gateway.log|4.1 MB
```

**When to use:** First call to discover what log files are available in the configured log directory.

---

### log_stats

Get file statistics without reading the full content. Auto-detects JSON format and uses the severity field for accurate counting.

**Parameters:**

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `file` | string | Yes | -- | Log file name |

**Example request:**
```json
{
  "name": "log_stats",
  "arguments": {
    "file": "api.log"
  }
}
```

**Example response:**
```json
{
  "file": "api.log",
  "size": "2.4 MB",
  "lines": 14523,
  "errors": 12,
  "warnings": 47,
  "modified": "2026-03-20T10:05:00Z"
}
```

**When to use:** Quick overview of file health -- check error/warning counts before deciding whether to dig deeper.

---

### time_range

Get the earliest and latest timestamps in a log file, plus the time span. Works with both plain-text and JSON-structured logs.

**Parameters:**

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `file` | string | Yes | -- | Log file name |

**Example request:**
```json
{
  "name": "time_range",
  "arguments": {
    "file": "api.log"
  }
}
```

**Example response:**
```json
{
  "file": "api.log",
  "earliest": "2026-03-20T00:00:03Z",
  "latest": "2026-03-20T10:05:00Z",
  "span": "10h 4m 57s"
}
```

**When to use:** Determine what time period a log file covers before using `since`/`until` filters on other tools.

---

## Analysis Tools

### tail_log

Get the last N lines from a log file, optionally filtered to a time window.

**Parameters:**

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `file` | string | Yes | -- | Log file name (e.g., `api.log`) |
| `lines` | integer | No | 50 | Number of lines to return |
| `since` | string | No | -- | Only include lines from this time onward. ISO 8601 or relative shorthand (e.g. `30m`, `2h`, `1d`) |
| `format` | string | No | toon | Output format: `toon` or `json` |

**Example request:**
```json
{
  "name": "tail_log",
  "arguments": {
    "file": "api.log",
    "lines": 20,
    "since": "15m"
  }
}
```

**Example response:**
```
# tail api.log (last 20 lines, since 15m ago)
2026-03-20T10:02:11Z INFO  [Router] GET /api/users 200 12ms
2026-03-20T10:02:14Z WARN  [Pool] Connection pool at 80% capacity
2026-03-20T10:03:01Z ERROR [DB] Query timeout after 30s on users_table
```

**When to use:** See the most recent log output from a specific file, optionally narrowed to a recent time window.

---

### search_logs

Search a log file using a regex pattern. Returns matching lines with line numbers. Supports JSON field scoping and time-range filtering.

**Parameters:**

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `file` | string | Yes | -- | Log file name |
| `pattern` | string | Yes | -- | Regex pattern (case-insensitive) |
| `max_results` | integer | No | 50 | Maximum number of matches |
| `context` | integer | No | 0 | Lines to show before and after each match |
| `field` | string | No | -- | JSON field to search in (dot-notation, e.g. `jsonPayload.message`). Only used for JSON log files |
| `since` | string | No | -- | Only include lines from this time onward. ISO 8601 or relative shorthand (e.g. `30m`, `2h`) |
| `until` | string | No | -- | Only include lines up to this time. ISO 8601 or relative shorthand |
| `format` | string | No | toon | Output format: `toon` or `json` |

**Example request:**
```json
{
  "name": "search_logs",
  "arguments": {
    "file": "api.log",
    "pattern": "ECONNREFUSED|timeout",
    "context": 3,
    "max_results": 20,
    "since": "1h"
  }
}
```

**Example response (TOON):**
```
# {"total":2}
[content|line_number]
ERROR: ECONNREFUSED to redis:6379|142
ERROR: Request timeout after 30s|287
```

**Example request with field scoping (JSON logs):**
```json
{
  "name": "search_logs",
  "arguments": {
    "file": "structured.log",
    "pattern": "payment",
    "field": "jsonPayload.message",
    "max_results": 10
  }
}
```

**When to use:** Find specific patterns, error messages, or keywords in logs. Use `field` to avoid false matches in JSON logs and `since`/`until` to narrow the time window.

---

### get_errors

Extract lines matching common error patterns from a single log file. Recognizes `ERROR`, `FATAL`, `WARN`, `EXCEPTION`, `TypeError`, `ReferenceError`, `SyntaxError`, `ECONNREFUSED`, `ENOTFOUND`, `failed`, and `Failed`.

**Severity level hierarchy:** The `level` parameter controls the minimum severity threshold. Levels from most to least severe:

- `fatal` -- Only FATAL-level entries
- `error` -- FATAL and ERROR entries
- `warn` -- FATAL, ERROR, and WARN entries (default)
- `info` -- All entries including INFO-level matches

**Parameters:**

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `file` | string | Yes | -- | Log file name |
| `lines` | integer | No | 100 | Maximum number of error lines |
| `level` | string | No | warn | Minimum severity level: `fatal`, `error`, `warn`, or `info` |
| `exclude` | string | No | -- | Regex pattern -- lines matching this are excluded from results |
| `since` | string | No | -- | Only include errors from this time onward. ISO 8601 or relative shorthand (e.g. `1h`, `30m`) |
| `until` | string | No | -- | Only include errors up to this time. ISO 8601 or relative shorthand |
| `format` | string | No | toon | Output format: `toon` or `json` |

**Example request:**
```json
{
  "name": "get_errors",
  "arguments": {
    "file": "api.log",
    "lines": 50,
    "level": "error",
    "exclude": "HealthCheck",
    "since": "2h"
  }
}
```

**Example response (TOON):**
```
# {"file":"api.log","error_count":3}
[line_number|content]
1247|ERROR [ExceptionFilter] TypeError: Cannot read properties of undefined
1251|ERROR [ExceptionFilter] ECONNREFUSED 127.0.0.1:6379
1398|FATAL [Process] Out of memory: heap allocation failed
```

**When to use:** Get a focused view of problems in a specific log file. Use `level` to filter noise and `exclude` to suppress known false positives.

---

### all_errors

Aggregate errors across ALL log files at once. Always returns TOON format. Accepts severity and time filters just like `get_errors`.

**Parameters:**

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `lines` | integer | No | 20 | Maximum errors per file |
| `level` | string | No | warn | Minimum severity level: `fatal`, `error`, `warn`, or `info` |
| `exclude` | string | No | -- | Regex pattern -- lines matching this are excluded from results |
| `since` | string | No | -- | Only include errors from this time onward. ISO 8601 or relative shorthand (e.g. `1h`) |

**Example request:**
```json
{
  "name": "all_errors",
  "arguments": {
    "level": "error",
    "since": "30m"
  }
}
```

**Example response:**
```
=== api.log (3 errors) ===
[line_number|content]
1247|ERROR [ExceptionFilter] TypeError: Cannot read properties of undefined
1251|ERROR [ExceptionFilter] ECONNREFUSED 127.0.0.1:6379
1398|FATAL [Process] Out of memory: heap allocation failed

=== worker.log (1 error) ===
[line_number|content]
89|ERROR: Job queue stalled — no heartbeat for 60s
```

**When to use:** Best first call for a health overview. Scans every log file and returns a summary of errors across the entire system.

---

## Correlation Tools

### correlate

Search for a correlation ID (session ID, trace ID, request ID) across ALL log files. Returns a unified timeline sorted by timestamp, making it easy to trace a request across multiple services.

**Parameters:**

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `value` | string | Yes | -- | The correlation value to search for (e.g. a session ID, trace ID) |
| `field` | string | No | -- | Restrict search to this field (dot-notation for JSON, `field=value` for plain text) |
| `max_results` | integer | No | 200 | Maximum total results across all files |
| `format` | string | No | toon | Output format: `toon` or `json` |

**Example request:**
```json
{
  "name": "correlate",
  "arguments": {
    "value": "req-abc-123",
    "field": "traceId",
    "max_results": 100
  }
}
```

**Example response (cross-service timeline):**
```
# Correlation: req-abc-123 (5 entries across 3 files)
[timestamp|file|content]
2026-03-20T10:00:01.100Z|gateway.log|INFO  Incoming POST /api/orders traceId=req-abc-123
2026-03-20T10:00:01.150Z|api.log|INFO  [OrderController] Creating order traceId=req-abc-123
2026-03-20T10:00:01.320Z|api.log|INFO  [OrderService] Validating payment traceId=req-abc-123
2026-03-20T10:00:01.800Z|worker.log|INFO  [PaymentJob] Charging card traceId=req-abc-123
2026-03-20T10:00:02.400Z|gateway.log|INFO  Response 201 /api/orders 1300ms traceId=req-abc-123
```

**When to use:** Trace a single request, session, or transaction across multiple services to understand the full lifecycle and pinpoint where failures occur.

---

### trace_ids

Discover unique values for a correlation field (e.g. `sessionId`, `traceId`) across log files. Returns each unique value with its occurrence count and the time range it spans.

**Parameters:**

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `field` | string | Yes | -- | The field to extract values from (e.g. `sessionId`, `traceId`) |
| `file` | string | No | -- | Scan only this file instead of all files |
| `max_values` | integer | No | 50 | Maximum number of unique values to return |

**Example request:**
```json
{
  "name": "trace_ids",
  "arguments": {
    "field": "traceId",
    "max_values": 10
  }
}
```

**Example response:**
```
[count|first_seen|last_seen|value]
47|2026-03-20T09:58:00Z|2026-03-20T10:05:00Z|req-abc-123
32|2026-03-20T09:59:12Z|2026-03-20T10:03:45Z|req-def-456
18|2026-03-20T10:01:00Z|2026-03-20T10:02:30Z|req-ghi-789
5|2026-03-20T10:04:00Z|2026-03-20T10:04:02Z|req-jkl-012
```

**When to use:** Find active trace or session IDs before using `correlate` to drill into a specific one. Useful for identifying the busiest or most recent transactions.

---

## Error Handling

All tools return MCP error content for common failure cases:

| Error | Cause |
|-------|-------|
| `File not found: {file}` | The specified file does not exist in `LOG_DIR` |
| `Invalid regex: {pattern}` | The search pattern could not be compiled |
| `Unknown tool: {name}` | The tool name does not match any registered tool |

---

**[Back to Documentation Index](../README.md)**
