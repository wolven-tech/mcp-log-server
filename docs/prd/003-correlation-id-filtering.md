# PRD-003: Session/Correlation ID Filtering for Cross-Service Log Correlation

**GitHub Issue:** #3
**Status:** Draft
**Priority:** P1 — Depends on PRD-001 (JSON field extraction)

---

## Problem Statement

In distributed systems, a single user action (login, API call, video session) generates logs across multiple services. Debugging requires correlating these logs by a shared identifier — session ID, request ID, trace ID, or correlation ID.

Currently, the only way to do this is `search_logs` with a regex pattern, one file at a time, manually. There is no tool to:
- Search across ALL files at once for a correlation ID
- Sort results by timestamp to reconstruct the request timeline
- Understand which services were involved in a given session

This is the highest-value debugging workflow for distributed systems and the primary reason teams export logs to centralized platforms.

## Goals

1. New `correlate` tool that finds all log entries matching a correlation ID across all files
2. Return results sorted by timestamp — unified cross-service timeline
3. Support extracting correlation IDs from JSON fields, key=value pairs, and regex patterns
4. Show which files (services) contributed to the timeline
5. Produce token-efficient TOON output with service/file identification per entry

## Non-Goals

- Automatic correlation ID detection (user must specify the value to search for)
- Distributed tracing visualization (spans, parent-child relationships)
- Real-time streaming correlation
- Modifying log files to inject correlation IDs

## Design

### 1. New Tool: `correlate`

```json
{
  "name": "correlate",
  "description": "Find all log entries matching a correlation ID across ALL log files. Returns a unified timeline sorted by timestamp. Use this to trace a request or session across services.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "value": {
        "type": "string",
        "description": "The correlation ID value to search for (e.g., 'abc-123', '9fa45400b3d78a11')"
      },
      "field": {
        "type": "string",
        "description": "JSON field path to search (e.g., 'sessionId', 'trace', 'data.requestId'). If omitted, searches all fields and plain text."
      },
      "max_results": {
        "type": "integer",
        "description": "Maximum results across all files (default: 200)",
        "default": 200
      },
      "format": {
        "type": "string",
        "enum": ["toon", "json"],
        "description": "Output format (default: toon)"
      }
    },
    "required": ["value"]
  }
}
```

### 2. Correlation Engine

New module: `McpLogServer.Domain.Correlator`

```elixir
@spec correlate(log_dir :: String.t(), value :: String.t(), opts :: keyword()) ::
  {:ok, correlation_result()} | {:error, String.t()}

@type correlation_result :: %{
  value: String.t(),
  field: String.t() | nil,
  total_matches: non_neg_integer(),
  files_matched: [String.t()],
  timeline: [timeline_entry()]
}

@type timeline_entry :: %{
  file: String.t(),
  line_number: pos_integer(),
  timestamp: String.t() | nil,
  severity: String.t() | nil,
  content: String.t()
}
```

**Search strategy** per file:

1. **JSON logs with `field` specified**: Extract the field value, exact match against `value`
2. **JSON logs without `field`**: Deep search all string values in the JSON entry for `value`
3. **Plain text logs**: Regex search for the literal `value` (escaped for regex safety)

**Timeline construction:**
1. Collect matches from all files
2. Extract timestamp from each match (using TimestampParser from PRD-002)
3. Sort by timestamp ascending
4. If no timestamps available, sort by file name then line number

### 3. Deep JSON Value Search

For the "no field specified" case, recursively search all string values in a JSON entry:

```elixir
defp contains_value?(map, value) when is_map(map) do
  Enum.any?(map, fn
    {_k, v} when is_binary(v) -> String.contains?(v, value)
    {_k, v} when is_map(v) -> contains_value?(v, value)
    {_k, v} when is_list(v) -> Enum.any?(v, &contains_value?(&1, value))
    _ -> false
  end)
end
```

### 4. Plain Text Key=Value Extraction

For plain text logs, support common key=value patterns:

```
sessionId=abc-123
session_id="abc-123"
[sessionId: abc-123]
```

When `field` is specified for plain text logs, build a targeted regex:
```elixir
~r/#{field}[=:]\s*"?#{Regex.escape(value)}"?/
```

### 5. TOON Output Format

```
# {"value":"abc-123","total_matches":12,"files_matched":["gateway.log","api.log","ws.log"]}
[file|severity|timestamp|content|line_number]
gateway.log|INFO|2026-03-20T14:00:00.100Z|[gateway] Session started sessionId=abc-123|142
api.log|INFO|2026-03-20T14:00:00.150Z|[api] Auth validated for session abc-123|89
ws.log|INFO|2026-03-20T14:00:00.200Z|[ws] WebSocket connected sessionId=abc-123|201
api.log|ERROR|2026-03-20T14:00:01.500Z|[api] Failed to load user profile for abc-123|95
gateway.log|WARN|2026-03-20T14:00:02.000Z|[gateway] Upstream timeout for session abc-123|156
```

This gives a unified timeline view that immediately shows the request flow across services.

### 6. New Tool: `trace_ids`

Bonus tool — helps the LLM discover what correlation IDs exist in a file:

```json
{
  "name": "trace_ids",
  "description": "Extract unique values for a correlation field across log files. Use this to discover available session/request/trace IDs.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "field": {
        "type": "string",
        "description": "JSON field to extract values from (e.g., 'sessionId', 'trace')"
      },
      "file": {
        "type": "string",
        "description": "Specific file to scan. Omit to scan all files."
      },
      "max_values": {
        "type": "integer",
        "description": "Maximum unique values to return (default: 50)",
        "default": 50
      }
    },
    "required": ["field"]
  }
}
```

**Response:**
```
# {"field":"sessionId","unique_count":23,"files_scanned":3}
[value|count|first_seen|last_seen]
abc-123|15|2026-03-20T14:00:00Z|2026-03-20T14:05:00Z
def-456|8|2026-03-20T14:01:00Z|2026-03-20T14:03:00Z
```

This enables the LLM to ask "what sessions are in these logs?" before diving into a specific one.

## User Stories

### US-1: Cross-service session tracing
**As** a developer debugging a user-reported issue,
**I want** to run `correlate(value: "abc-123")` and get a timeline of everything that happened for that session across all services,
**So that** I can understand the full request flow without manually searching each file.

**Acceptance Criteria:**
- Searches all `.log` files in LOG_DIR
- Returns entries sorted by timestamp
- Each entry includes the source file name
- TOON output includes file, severity, timestamp, content columns

### US-2: Field-specific correlation
**As** a developer with structured JSON logs containing a `trace` field,
**I want** to run `correlate(value: "9fa45400b3d78a11", field: "trace")`,
**So that** I get exact matches on the trace field without false positives from the value appearing in unrelated fields.

**Acceptance Criteria:**
- `field` parameter targets a specific JSON field path
- Supports dot-notation for nested fields (e.g., `data.sessionId`)
- Falls back to regex search for plain text files

### US-3: Discover available correlation IDs
**As** an LLM analyzing logs for the first time,
**I want** to call `trace_ids(field: "sessionId")` to see what sessions exist,
**So that** I can ask the user which session to investigate or pick the most error-prone one.

**Acceptance Criteria:**
- Returns unique values with count and time range
- Sorted by count descending (most active sessions first)
- Works across all files or a single file

### US-4: Plain text correlation
**As** a developer whose logs use `sessionId=abc-123` in plain text format,
**I want** correlation to work without JSON,
**So that** I can trace sessions even before we migrate to structured logging.

**Acceptance Criteria:**
- Plain text search matches `value` as a substring
- When `field` is specified, matches `field=value` and `field: value` patterns
- Mixed directories (some JSON, some plain text) work correctly

## Implementation Plan

1. **Correlator module** + tests — core correlation logic
2. **Deep JSON search** — recursive value search in JSON entries
3. **Plain text key=value matching** — regex-based field search
4. **Timeline sorting** — integrate with TimestampParser for cross-file timestamp sorting
5. **trace_ids tool** — unique value extraction
6. **correlate tool** — Registry + Dispatcher wiring
7. **TOON formatting** — multi-file timeline output
8. **Integration tests** — multi-file correlation, JSON + plain text mixed

## Performance Considerations

- **All-file scan**: `correlate` reads every log file. For directories with many large files, this could be slow. Mitigate:
  - Stream files line-by-line (don't load into memory)
  - Short-circuit when `max_results` is reached
  - Consider parallel file scanning with `Task.async_stream`
- **trace_ids**: Must scan entire files to collect unique values. Consider sampling (first/last 1000 lines) for very large files with a `sampled: true` flag in output.

## Dependencies

- PRD-001 (JSON format support) — for JSON field extraction
- PRD-002 (Time-based filtering) — for timestamp extraction and sorting
- Can be partially implemented for plain text without PRD-001/002
