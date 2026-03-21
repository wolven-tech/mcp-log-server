# PRD-001: JSON Structured Log Format Support

**GitHub Issue:** #1
**Status:** Draft
**Priority:** P0 — Foundation for issues #2, #3, #4

---

## Problem Statement

The MCP log server treats all logs as plain text lines. When log files contain JSON (GCP Cloud Logging exports, Pino/Fastify structured output), tools produce incorrect results:

- `get_errors` regex-matches `"failed": 0` in INFO logs as an error (false positive)
- `search_logs` cannot target specific JSON fields — it matches across serialised JSON noise
- `all_errors` aggregates these false positives across every file
- The TOON encoder receives raw JSON strings rather than parsed structured data

This is not an edge case — structured JSON logging is the default for most modern stacks (Node.js/Pino, Python/structlog, Go/zerolog, Java/Logback JSON encoder, GCP Cloud Logging exports).

## Goals

1. Auto-detect whether a log file contains JSON-structured entries
2. Extract severity/level from standard JSON fields instead of regex matching
3. Enable field-specific search within JSON log entries
4. Maintain full backward compatibility with plain-text logs
5. Produce cleaner TOON output from structured data (extract only useful fields)

## Non-Goals

- Parsing non-JSON structured formats (logfmt, XML, CSV) — future work
- Writing or modifying log files
- Supporting mixed-format files (some lines JSON, some plain text) in v1

## Design

### 1. Format Detection Module

New module: `McpLogServer.Domain.FormatDetector`

```elixir
@spec detect(path :: String.t()) :: :plain | :json_lines | :json_array
```

**Detection logic:**
1. Read first non-empty line of file
2. If it starts with `[` and the file parses as a JSON array → `:json_array`
3. If first line parses as a JSON object → `:json_lines` (NDJSON)
4. Otherwise → `:plain`

Cache the result per file path + mtime to avoid re-detecting on every tool call. Use a simple ETS table or process dictionary keyed on `{path, mtime}`.

### 2. JSON Log Parser Module

New module: `McpLogServer.Domain.JsonLogParser`

```elixir
@spec parse_entries(path :: String.t(), format :: :json_lines | :json_array) :: [map()]
@spec extract_severity(entry :: map()) :: String.t()
@spec extract_timestamp(entry :: map()) :: DateTime.t() | nil
@spec extract_message(entry :: map()) :: String.t()
```

**Severity field resolution** (checked in order):
1. `severity` — GCP Cloud Logging
2. `level` — Pino, Winston, Bunyan (may be numeric: 10=trace, 20=debug, 30=info, 40=warn, 50=error, 60=fatal)
3. `log.level` — Elastic Common Schema
4. `levelname` — Python logging
5. `loglevel` — misc frameworks

**Numeric level mapping** (Pino convention):
| Value | Level |
|-------|-------|
| 10 | TRACE |
| 20 | DEBUG |
| 30 | INFO |
| 40 | WARN |
| 50 | ERROR |
| 60 | FATAL |

**Message field resolution** (checked in order):
1. `message`
2. `msg` — Pino
3. `textPayload` — GCP Cloud Logging
4. `@message` — some ECS implementations

**Timestamp field resolution:**
1. `timestamp`
2. `time` — Pino (epoch ms or ISO string)
3. `@timestamp` — ECS
4. `receiveTimestamp` — GCP fallback

### 3. Modify Existing Domain Functions

#### `LogReader.get_errors/3` → `LogReader.get_errors/4`

```elixir
def get_errors(log_dir, file, max_lines, opts \\ []) do
  with {:ok, path} <- resolve(log_dir, file) do
    format = FormatDetector.detect(path)

    case format do
      :plain ->
        # existing regex-based logic (unchanged)
      json_format when json_format in [:json_lines, :json_array] ->
        entries = JsonLogParser.parse_entries(path, json_format)
        errors = entries
          |> Enum.filter(&severity_matches?(&1, :error))
          |> Enum.take(-max_lines)
          |> Enum.map(&to_log_entry/1)
    end
  end
end
```

#### `LogReader.search/4` — add `field` option

Add optional `field` parameter. For JSON logs, search only within the specified field path (dot-notation). For plain text, ignore the parameter.

```elixir
search(log_dir, file, pattern, field: "jsonPayload.message", max_results: 50)
```

**Field path resolution** uses `Access`-style nested get:
```elixir
defp get_nested(map, "jsonPayload.message") do
  get_in(map, ["jsonPayload", "message"])
end
```

### 4. TOON Encoder Enhancement

When encoding JSON log entries to TOON, extract only the useful columns rather than dumping the entire JSON object:

```
[severity|timestamp|message|line_number]
ERROR|2026-03-20T14:00:00Z|Connection refused to postgres:5432|42
WARN|2026-03-20T14:00:01Z|Retrying in 5s...|43
```

This gives the LLM structured, scannable data at minimal token cost.

### 5. Tool Schema Updates

#### `search_logs` — add `field` parameter

```json
{
  "field": {
    "type": "string",
    "description": "JSON field path to search within (e.g., 'message', 'jsonPayload.error'). Only applies to JSON-formatted logs."
  }
}
```

#### `log_stats` — add format info

Include detected format in stats response:
```json
{
  "format": "json_lines",
  "severity_field": "severity"
}
```

This tells the LLM upfront what kind of log file it's dealing with, so it can adjust its queries.

## User Stories

### US-1: Auto-detection of JSON log format
**As** a developer using GCP Cloud Logging exports,
**I want** the server to automatically detect that my log files are JSON,
**So that** I don't need to configure anything — it just works.

**Acceptance Criteria:**
- `.log` files starting with `{` per line are detected as `:json_lines`
- `.log` files starting with `[` containing a JSON array are detected as `:json_array`
- Plain text logs continue to work identically
- Detection result is cached per file path + mtime

### US-2: Severity-based error extraction
**As** a developer with Pino structured logs,
**I want** `get_errors` to use the `level` field instead of regex,
**So that** `"failed": 0` in an INFO entry is not flagged as an error.

**Acceptance Criteria:**
- `get_errors` checks `severity`, `level`, `log.level`, `levelname` fields (in order)
- Numeric Pino levels are correctly mapped (50=error, 60=fatal)
- For JSON logs, the regex fallback is NOT used
- False positive rate drops to zero for well-structured JSON logs

### US-3: Field-specific search
**As** a developer debugging a GCP-exported log,
**I want** to search within `jsonPayload.message` only,
**So that** I don't get matches from metadata fields like `resource.labels`.

**Acceptance Criteria:**
- `search_logs` accepts optional `field` parameter
- Dot-notation paths resolve nested JSON fields
- Invalid field paths return empty results (not errors)
- Plain text logs ignore the `field` parameter gracefully

### US-4: Clean TOON output for JSON logs
**As** an LLM consuming log data,
**I want** TOON output from JSON logs to show `severity|timestamp|message`,
**So that** I spend fewer tokens parsing and more tokens reasoning.

**Acceptance Criteria:**
- JSON log entries produce columnar TOON with severity, timestamp, message, line_number
- Extra fields are omitted from default TOON output
- JSON output format (`format: "json"`) still returns full entries

## Implementation Plan

1. **FormatDetector module** + tests — detect :plain, :json_lines, :json_array
2. **JsonLogParser module** + tests — parse entries, extract severity/timestamp/message
3. **Modify LogReader.get_errors** — use severity field for JSON logs
4. **Modify LogReader.search** — add `field` parameter for JSON field search
5. **Modify LogReader.get_stats** — use severity for counting errors/warns in JSON
6. **Update ToonEncoder** — produce clean columnar output for JSON entries
7. **Update Registry** — add `field` to search_logs schema, format to log_stats output
8. **Update Dispatcher** — pass new options through
9. **Integration tests** — test with GCP Cloud Logging sample, Pino sample, mixed directory

## Test Data

Create test fixtures:

**`test/fixtures/gcp_export.log`** — JSON array format:
```json
[
  {"severity":"ERROR","timestamp":"2026-03-20T14:00:00Z","textPayload":"Connection refused"},
  {"severity":"INFO","timestamp":"2026-03-20T14:00:01Z","textPayload":"Health check: failed: 0"}
]
```

**`test/fixtures/pino.log`** — NDJSON format:
```json
{"level":50,"time":1742475600000,"msg":"ECONNREFUSED","data":{"host":"postgres"}}
{"level":30,"time":1742475601000,"msg":"Retry succeeded","data":{"attempt":2}}
```

## Dependencies

- None (Jason already handles JSON parsing)

## Risks

- **Mixed-format files**: Some setups mix plain text and JSON (e.g., startup banner followed by JSON). v1 will not handle this — document the limitation.
- **Very large JSON arrays**: A single JSON array file must be fully parsed into memory. Mitigate by streaming NDJSON where possible and warning on files > 100MB.
