# PRD-005: Log Structuring Best Practices Guide

**GitHub Issue:** N/A — Internal efficiency improvement
**Status:** Draft
**Priority:** P2 — Documentation, no code changes required

---

## Problem Statement

The MCP log server works best when logs are well-structured. But most teams don't think about log structure from the perspective of tool consumption — they think about human readability or compliance. The result:

- Logs without timestamps → time-based filtering is useless
- Logs without correlation IDs → cross-service tracing is impossible
- Inconsistent severity formats → error detection produces false positives
- Unstructured text blobs → field-specific search can't work

We should provide an opinionated guide that helps users structure their logs to get maximum value from the MCP log server tools. This is a force multiplier — better input logs mean better tool output, which means the LLM spends fewer tokens and produces better debugging results.

## Goals

1. Publish a comprehensive guide on structuring logs for AI-assisted debugging
2. Cover the most common stacks (Node.js, Python, Go, Elixir, Java)
3. Explain how each log field maps to a specific MCP tool capability
4. Provide copy-paste configuration snippets
5. Include a "log quality scorecard" that teams can self-assess against

## Document: `docs/guides/LOG_STRUCTURING.md`

### Outline

---

#### 1. Why Log Structure Matters for AI Debugging

Brief explanation of how the MCP log server tools consume logs:

| Tool | What it needs from your logs |
|------|------------------------------|
| `get_errors` / `all_errors` | Severity field (`severity`, `level`) — without it, falls back to regex matching with false positives |
| `search_logs` (field search) | Structured JSON fields — without it, searches full serialised text |
| `time_range` / time filtering | Parseable timestamps — without them, time-based queries are impossible |
| `correlate` | Correlation ID field (`sessionId`, `traceId`, `requestId`) — without it, can only do substring search |
| `trace_ids` | Consistent field naming across services — without it, IDs can't be aggregated |
| `log_stats` | Severity field for accurate counts — without it, uses regex approximation |

**Key insight**: Every minute spent on log structure saves hours of debugging time with AI tools.

---

#### 2. The Ideal Log Entry

The "gold standard" structured log entry for maximum MCP tool compatibility:

```json
{
  "severity": "ERROR",
  "timestamp": "2026-03-20T14:00:00.123Z",
  "message": "Failed to connect to database",
  "service": "api",
  "sessionId": "abc-123",
  "traceId": "9fa45400b3d78a11",
  "requestId": "req-789",
  "error": {
    "type": "ConnectionError",
    "message": "ECONNREFUSED 10.0.0.5:5432",
    "stack": "..."
  },
  "context": {
    "userId": "user-456",
    "endpoint": "POST /api/sessions",
    "duration_ms": 5023
  }
}
```

**Field-by-field explanation:**

| Field | Purpose | MCP Tool Benefit |
|-------|---------|-----------------|
| `severity` | Log level as string | `get_errors` uses this instead of regex — zero false positives |
| `timestamp` | ISO 8601 with timezone | `time_range`, `since`/`until` filtering |
| `message` | Human-readable summary | `search_logs` field search, TOON display |
| `service` | Source service name | Shown in `correlate` timeline |
| `sessionId` | Session correlation ID | `correlate` cross-service tracing |
| `traceId` | Distributed trace ID | `correlate` with field targeting |
| `requestId` | Per-request ID | Fine-grained request tracing |
| `error` | Structured error details | Richer error context in search results |
| `context` | Request metadata | Searchable context for debugging |

---

#### 3. Stack-Specific Configuration

##### Node.js (Pino)

```javascript
const pino = require('pino');

const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  // Use 'severity' instead of numeric 'level' for MCP compatibility
  formatters: {
    level(label) {
      return { severity: label.toUpperCase() };
    }
  },
  // Always include timestamp as ISO string
  timestamp: pino.stdTimeFunctions.isoTime,
  // Base fields included in every log entry
  base: {
    service: process.env.SERVICE_NAME || 'unknown'
  }
});

// Middleware to add correlation IDs to every request log
function correlationMiddleware(req, res, next) {
  req.log = logger.child({
    requestId: req.headers['x-request-id'] || crypto.randomUUID(),
    sessionId: req.session?.id,
    traceId: req.headers['x-trace-id']
  });
  next();
}
```

**Output:**
```json
{"severity":"INFO","time":"2026-03-20T14:00:00.123Z","service":"api","requestId":"req-789","sessionId":"abc-123","msg":"Request started"}
```

##### Python (structlog)

```python
import structlog
import uuid

structlog.configure(
    processors=[
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.add_log_level,
        structlog.processors.JSONRenderer()
    ]
)

logger = structlog.get_logger()

# Bind correlation IDs per request
def create_request_logger(request):
    return logger.bind(
        service="api",
        request_id=request.headers.get("X-Request-ID", str(uuid.uuid4())),
        session_id=request.session.get("id"),
        trace_id=request.headers.get("X-Trace-ID")
    )
```

**Output:**
```json
{"timestamp":"2026-03-20T14:00:00.123Z","level":"error","service":"api","request_id":"req-789","session_id":"abc-123","event":"Database connection failed"}
```

##### Go (zerolog)

```go
package main

import (
    "os"
    "github.com/rs/zerolog"
    "github.com/rs/zerolog/log"
)

func init() {
    zerolog.TimeFieldFormat = zerolog.TimeFormatUnix
    // Use "severity" field name for MCP compatibility
    zerolog.LevelFieldName = "severity"
    zerolog.MessageFieldName = "message"

    log.Logger = zerolog.New(os.Stdout).With().
        Timestamp().
        Str("service", os.Getenv("SERVICE_NAME")).
        Logger()
}

// Per-request logger with correlation IDs
func requestLogger(r *http.Request) zerolog.Logger {
    return log.With().
        Str("requestId", r.Header.Get("X-Request-ID")).
        Str("sessionId", getSessionID(r)).
        Str("traceId", r.Header.Get("X-Trace-ID")).
        Logger()
}
```

##### Elixir (Logger + JSON formatter)

```elixir
# config/config.exs
config :logger, :console,
  format: {MyApp.JsonFormatter, :format},
  metadata: [:request_id, :session_id, :trace_id, :service]

# lib/my_app/json_formatter.ex
defmodule MyApp.JsonFormatter do
  def format(level, message, timestamp, metadata) do
    %{
      severity: level |> Atom.to_string() |> String.upcase(),
      timestamp: format_timestamp(timestamp),
      message: IO.chardata_to_string(message),
      service: metadata[:service] || "unknown",
      requestId: metadata[:request_id],
      sessionId: metadata[:session_id],
      traceId: metadata[:trace_id]
    }
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end
end
```

##### Java (Logback + JSON encoder)

```xml
<!-- logback.xml -->
<configuration>
  <appender name="JSON" class="ch.qos.logback.core.ConsoleAppender">
    <encoder class="net.logstash.logback.encoder.LogstashEncoder">
      <customFields>{"service":"${SERVICE_NAME:-unknown}"}</customFields>
      <fieldNames>
        <timestamp>timestamp</timestamp>
        <level>severity</level>
        <message>message</message>
      </fieldNames>
    </encoder>
  </appender>
  <root level="INFO">
    <appender-ref ref="JSON" />
  </root>
</configuration>
```

With MDC for correlation IDs:
```java
MDC.put("sessionId", session.getId());
MDC.put("traceId", span.getTraceId());
MDC.put("requestId", request.getHeader("X-Request-ID"));
```

---

#### 4. Correlation ID Threading

How to propagate correlation IDs across services:

```
Client → Gateway → API → Database
  │         │        │
  └─ X-Request-ID: req-789 (generated by gateway, propagated to all)
  └─ X-Session-ID: abc-123 (from JWT, propagated to all)
  └─ X-Trace-ID: 9fa45400 (from tracing system, propagated to all)
```

**Rules:**
1. Generate `requestId` at the edge (gateway/load balancer)
2. Extract `sessionId` from JWT/session at auth middleware
3. Propagate all IDs via HTTP headers to downstream services
4. Bind all IDs to the logger at request start — every log line automatically includes them

**Header convention:**
```
X-Request-ID    → requestId in logs
X-Session-ID    → sessionId in logs
X-Trace-ID      → traceId in logs (or use OpenTelemetry)
```

---

#### 5. Log Output for MCP Consumption

How to pipe logs into the MCP log server:

##### Development (turbo/monorepo)
```bash
# All services to one file
turbo run dev 2>&1 | tee /tmp/mcp-logs/apps.log

# Per-service files (recommended for correlate tool)
turbo run dev --filter=gateway 2>&1 | tee /tmp/mcp-logs/gateway.log &
turbo run dev --filter=api 2>&1 | tee /tmp/mcp-logs/api.log &
turbo run dev --filter=ws 2>&1 | tee /tmp/mcp-logs/ws.log &
```

##### GCP Cloud Logging export
```bash
# Export recent logs as JSON
gcloud logging read \
  'resource.type="k8s_container" AND resource.labels.namespace_name="production"' \
  --format=json \
  --freshness=24h \
  > /tmp/mcp-logs/production.log

# Per-service export (recommended)
for svc in gateway api ws; do
  gcloud logging read \
    "resource.labels.container_name=\"$svc\"" \
    --format=json \
    --freshness=24h \
    > "/tmp/mcp-logs/${svc}.log"
done
```

##### Docker Compose
```bash
# Per-service log files
docker compose logs gateway --no-color > /tmp/mcp-logs/gateway.log
docker compose logs api --no-color > /tmp/mcp-logs/api.log

# Or use Docker JSON log driver and symlink
ln -s /var/lib/docker/containers/CONTAINER_ID/*-json.log /tmp/mcp-logs/api.log
```

##### Kubernetes
```bash
# stern for multi-pod streaming
stern "api-.*" --output json > /tmp/mcp-logs/api.log

# kubectl for quick export
kubectl logs deployment/api --since=2h > /tmp/mcp-logs/api.log
```

---

#### 6. Log Quality Scorecard

Rate your logging setup:

| Criteria | Points | How to Check |
|----------|--------|-------------|
| All entries have a `severity`/`level` field | +3 | `get_errors` works without false positives |
| All entries have ISO 8601 timestamps | +3 | `time_range` returns valid earliest/latest |
| All entries include a correlation ID (session/request/trace) | +3 | `correlate` returns cross-service timeline |
| Logs are JSON structured (not plain text) | +2 | `log_stats` shows `format: "json_lines"` |
| Each service writes to a separate log file | +2 | `list_logs` shows one file per service |
| Error entries include structured error objects | +1 | `search_logs` can target `error.type` field |
| Message field is human-readable (not just error codes) | +1 | TOON output is immediately understandable |
| **Total** | **/15** | |

**Scoring:**
- **12-15**: Excellent — full MCP tool compatibility, maximum AI debugging efficiency
- **8-11**: Good — most tools work well, some manual searching needed
- **4-7**: Basic — time filtering and correlation won't work, regex-based error detection
- **0-3**: Minimal — raw text logs, AI spends most tokens parsing instead of reasoning

---

#### 7. Common Anti-Patterns

| Anti-Pattern | Problem | Fix |
|-------------|---------|-----|
| `console.log("Error: " + err)` | No severity field, no structure | Use structured logger with severity |
| Numeric log levels (`level: 50`) | Non-obvious, varies by framework | Map to string severity in formatter |
| Timestamps in local timezone | Ambiguous, breaks cross-service sorting | Always use UTC ISO 8601 |
| Correlation ID only in first log line | Other lines can't be correlated | Bind to logger context, include in every entry |
| `JSON.stringify(bigObject)` in message | Bloats message, hard to search | Put objects in dedicated fields |
| Different field names per service | `sessionId` vs `session_id` vs `sid` | Standardize naming across all services |
| Logging to stdout without persistence | Logs disappear when terminal closes | Always `tee` to a file or use log driver |
| Multi-line stack traces as separate entries | Breaks line-based tools | Include stack trace in structured `error.stack` field |

---

#### 8. Migration Path

For teams with existing plain text logs:

**Phase 1: Add timestamps** (1 hour)
- Configure your logger to include ISO 8601 timestamps
- Enables: `time_range`, `since`/`until` filtering

**Phase 2: Switch to JSON output** (2-4 hours)
- Add JSON formatter to your logging library
- Include `severity`, `timestamp`, `message` fields
- Enables: accurate `get_errors`, field-specific `search_logs`

**Phase 3: Add correlation IDs** (half day)
- Generate request ID at edge, propagate via headers
- Bind session/request/trace IDs to logger context
- Enables: `correlate` cross-service tracing, `trace_ids`

**Phase 4: Per-service log files** (1 hour)
- Split monolithic log file into one file per service
- Enables: targeted tool calls, cleaner `all_errors` output

Each phase independently improves your debugging experience.

## User Stories

### US-1: Developer adopts structured logging
**As** a developer setting up a new service,
**I want** a copy-paste logging configuration for my stack,
**So that** my logs work optimally with the MCP log server from day one.

### US-2: Team migrates from plain text to structured
**As** a team lead migrating an existing monorepo,
**I want** a phased migration path,
**So that** we can improve incrementally without a big-bang rewrite.

### US-3: LLM understands log quality
**As** an LLM analyzing a team's logs,
**I want** to reference the scorecard to suggest improvements,
**So that** I can recommend specific changes that will improve debugging efficiency.

## Implementation Plan

1. Write the guide as `docs/guides/LOG_STRUCTURING.md`
2. Test all code snippets (at minimum: Node.js/Pino, Python/structlog)
3. Add link from main README and QUICK_START
4. Add link from `all_errors` tool description: "Tip: See LOG_STRUCTURING guide to reduce false positives"
5. Create sample log files in `examples/` directory demonstrating each format
