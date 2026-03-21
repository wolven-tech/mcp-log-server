# Examples: Debugging a Multi-Service Platform

This walkthrough demonstrates every MCP Log Server tool using realistic logs from a multi-service platform. The platform has three services:

| Service | File | Format | Description |
|---------|------|--------|-------------|
| API | `logs/api.log` | Plain text | Backend service — upstream WebSocket feed, PostgreSQL, Redis |
| Recommendation | `logs/recommendation.log` | Plain text | ML pipeline — embeddings, vector database |
| Gateway | `logs/gateway.log` | JSON (structured) | API gateway — routing, JWT auth, circuit breaker |

The logs capture a cascading failure: at 14:02, the upstream WebSocket connection drops, causing the API to fall back to slow polling, which exhausts PostgreSQL connections. The recommendation pipeline loses its vector database connection, and the gateway trips its circuit breaker.

---

## Try It Yourself

```bash
# Point the MCP server at the example logs
LOG_DIR=./examples/logs mix run --no-halt

# Or with Docker
docker run --rm -i -v $(pwd)/examples/logs:/tmp/mcp-logs ghcr.io/wolven-tech/mcp-log-server:latest
```

Then use Claude Code (or any MCP client) to follow the workflow below.

---

## Step 1: Health Overview

**What to ask Claude:** "Check the logs for errors"

Claude calls `all_errors`:

```json
{"name": "all_errors", "arguments": {"lines": 10}}
```

**Response:**
```
--- api.log (5 errors) ---
[content|line_number]
ERROR: Failed to connect to upstream WebSocket: ECONNREFUSED sessionId=sess-7a2f requestId=req-006|14
ERROR: WebSocket max reconnection attempts reached sessionId=sess-7a2f requestId=req-006|19
ERROR: Live feed unavailable - switching to polling fallback sessionId=sess-7a2f requestId=req-007|20
ERROR: PostgreSQL connection timeout after 30s requestId=req-009|23
ERROR: Cannot process event update: database unavailable requestId=req-009|24

--- recommendation.log (2 errors) ---
[content|line_number]
ERROR: Vector database connection lost: ECONNREFUSED 10.0.0.5:6333 sessionId=sess-7a2f requestId=req-006|11
ERROR: All 4690 embeddings failed - vector database unavailable sessionId=sess-7a2f requestId=req-006|12

--- gateway.log (3 errors) ---
[content|line_number]
ERROR|2026-03-20T14:02:15.000Z|POST /api/v1/predictions - 502 Bad Gateway|9
ERROR|2026-03-20T14:02:16.000Z|POST /api/v1/predictions - 502 Bad Gateway|10
ERROR|2026-03-20T14:02:25.000Z|GET /api/v1/events - 503 Service Unavailable (circuit breaker open)|12
```

Immediate insight: 10 errors across 3 services. The upstream WebSocket dropped first, then the vector database, then PostgreSQL. Gateway started returning 502/503.

---

## Step 2: Understand the Timeline

**What to ask Claude:** "When did the errors start? Check the timeline of api.log"

Claude calls `time_range`:

```json
{"name": "time_range", "arguments": {"file": "api.log"}}
```

**Response:**
```json
{
  "file": "api.log",
  "earliest": "2026-03-20T14:00:00Z",
  "latest": "2026-03-20T14:05:00Z",
  "span": "5m",
  "line_count": 29,
  "format": "plain"
}
```

The file covers a 5-minute window. Now Claude knows the exact time range to work with.

---

## Step 3: Errors-Only View with Severity Filtering

**What to ask Claude:** "Show me only the actual errors from the API, not warnings"

Claude calls `get_errors` with level filtering:

```json
{
  "name": "get_errors",
  "arguments": {
    "file": "api.log",
    "level": "error",
    "since": "2026-03-20T14:02:00Z"
  }
}
```

**Response (errors only, no WARN lines):**
```
# {"file":"api.log","error_count":5}
[content|line_number]
ERROR: Failed to connect to upstream WebSocket: ECONNREFUSED ...|14
ERROR: WebSocket max reconnection attempts reached ...|19
ERROR: Live feed unavailable - switching to polling fallback ...|20
ERROR: PostgreSQL connection timeout after 30s ...|23
ERROR: Cannot process event update: database unavailable ...|24
```

Without `level: "error"`, the response would include 6 WARN lines (lock failures, slow queries, reconnect attempts). The level filter cuts noise by 55%.

---

## Step 4: Search with Context

**What to ask Claude:** "Show me what happened around the PostgreSQL timeout"

Claude calls `search_logs` with context lines:

```json
{
  "name": "search_logs",
  "arguments": {
    "file": "api.log",
    "pattern": "PostgreSQL|connection pool",
    "context": 2
  }
}
```

**Response:**
```
# {"file":"api.log","pattern":"PostgreSQL|connection pool","returned_matches":3}
[content|line_number]
[2026-03-20 14:00:01] INFO: Connected to PostgreSQL at db:5432|2
[2026-03-20 14:03:00] ERROR: PostgreSQL connection timeout after 30s requestId=req-009|23
  22: [2026-03-20 14:02:30] INFO: Polling data from REST API ...
  24: [2026-03-20 14:03:01] ERROR: Cannot process event update: database unavailable ...
[2026-03-20 14:03:05] WARN: Connection pool exhausted (10/10 connections in use) requestId=req-010|25
  24: [2026-03-20 14:03:01] ERROR: Cannot process event update: database unavailable ...
  26: [2026-03-20 14:03:10] INFO: PostgreSQL connection recovered requestId=req-011
```

Context shows: the polling fallback (line 22) saturated the connection pool, causing the PostgreSQL timeout. Root cause is the upstream WebSocket drop forcing slow REST polling.

---

## Step 5: JSON Field Search on Gateway

**What to ask Claude:** "Search for 502 errors in the gateway, show me the upstream that failed"

Claude calls `search_logs` with the `field` parameter:

```json
{
  "name": "search_logs",
  "arguments": {
    "file": "gateway.log",
    "pattern": "502|503",
    "field": "message"
  }
}
```

**Response:**
```
# {"file":"gateway.log","pattern":"502|503","returned_matches":3}
[line_number|message|severity|timestamp]
9|POST /api/v1/predictions - 502 Bad Gateway|ERROR|2026-03-20T14:02:15.000Z
10|POST /api/v1/predictions - 502 Bad Gateway|ERROR|2026-03-20T14:02:16.000Z
12|GET /api/v1/events - 503 Service Unavailable (circuit breaker open)|ERROR|2026-03-20T14:02:25.000Z
```

The `field: "message"` parameter searches only the JSON `message` field, not the entire serialized entry. This avoids false matches from metadata fields.

---

## Step 6: Cross-Service Correlation

**What to ask Claude:** "Trace request req-006 across all services to see the full failure path"

Claude calls `correlate`:

```json
{
  "name": "correlate",
  "arguments": {
    "value": "req-006",
    "field": "requestId"
  }
}
```

**Response:**
```
# {"value":"req-006","total_matches":6,"files_matched":["api.log","recommendation.log","gateway.log"]}
[content|file|line_number|severity|timestamp]
Failed to connect to upstream WebSocket: ECONNREFUSED ...|api.log|14|error|2026-03-20T14:02:15
POST /api/v1/predictions - 502 Bad Gateway|gateway.log|9|ERROR|2026-03-20T14:02:15.000Z
WebSocket reconnecting (attempt 1/5) ...|api.log|15|warn|2026-03-20T14:02:16
Vector database connection lost: ECONNREFUSED 10.0.0.5:6333 ...|recommendation.log|11|error|2026-03-20T14:02:15
All 4690 embeddings failed - vector database unavailable ...|recommendation.log|12|error|2026-03-20T14:02:16
WebSocket max reconnection attempts reached ...|api.log|19|error|2026-03-20T14:02:20
```

A single request ID reveals the entire cascade: API lost upstream WebSocket -> gateway returned 502 -> recommendation service lost vector database -> 4690 embeddings failed. All from one connection drop.

---

## Step 7: Discover Affected Users

**What to ask Claude:** "Which user sessions were affected?"

Claude calls `trace_ids`:

```json
{
  "name": "trace_ids",
  "arguments": {
    "field": "sessionId"
  }
}
```

**Response:**
```
[count|first_seen|last_seen|value]
12|2026-03-20T14:00:10.000Z|2026-03-20T14:04:00.000Z|sess-7a2f
8|2026-03-20T14:01:05.000Z|2026-03-20T14:04:00.000Z|sess-9c4d
```

Two sessions were active during the incident. `sess-7a2f` (user-314) was most affected with 12 log entries spanning the entire window. `sess-9c4d` (user-827) had 8 entries.

Claude can then correlate each session to see their specific experience:

```json
{"name": "correlate", "arguments": {"value": "sess-7a2f"}}
```

---

## Step 8: Exclude Known Noise

**What to ask Claude:** "Show errors but exclude health checks and reconnection attempts"

Claude calls `get_errors` with `exclude`:

```json
{
  "name": "get_errors",
  "arguments": {
    "file": "api.log",
    "level": "warn",
    "exclude": "Health check|reconnecting|retry"
  }
}
```

This filters out 5 lines of noise (4 reconnection attempts + retry messages), leaving only actionable errors and warnings.

---

## Step 9: File Statistics

**What to ask Claude:** "Give me a quick overview of each log file"

Claude calls `log_stats` on each file:

```json
{"name": "log_stats", "arguments": {"file": "api.log"}}
```

**Response:**
```json
{
  "file": "api.log",
  "size_bytes": 2847,
  "size_human": "2.8 KB",
  "line_count": 29,
  "error_count": 5,
  "warn_count": 6,
  "fatal_count": 0,
  "modified": "2026-03-20T14:05:00"
}
```

Quick comparison across files tells Claude which service is the healthiest and which has the most problems.

---

## Key Patterns Demonstrated

| Pattern | Tools Used | When |
|---------|-----------|------|
| **Triage** | `all_errors` | First call — what's broken? |
| **Scoping** | `log_stats`, `time_range` | How big is the problem? What time window? |
| **Filtering** | `get_errors` + `level` + `since` | Remove noise, focus on real errors in the incident window |
| **Investigation** | `search_logs` + `context` | Understand what happened around an error |
| **JSON field search** | `search_logs` + `field` | Target specific fields in structured logs |
| **Cross-service tracing** | `correlate` + `field` | Follow a request/session across services |
| **Impact assessment** | `trace_ids` | How many users/sessions were affected? |
| **Noise reduction** | `get_errors` + `exclude` | Filter out health checks, retries, reconnection spam |

## Plain Text vs JSON Logs

Notice how the tools handle both formats in this example:

- **api.log** and **recommendation.log** are plain text (`[timestamp] LEVEL: message`). Error detection uses configurable regex patterns. Correlation uses `key=value` pattern matching.
- **gateway.log** is JSON structured. Error detection uses the `severity` field directly (zero false positives). Correlation uses exact JSON field matching. The `field` parameter on `search_logs` targets specific fields.

Both formats work together seamlessly in `correlate` and `all_errors` — the tools auto-detect the format per file.
