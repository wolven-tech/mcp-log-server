---
title: Log Structuring Best Practices
description: How to structure your application logs for maximum value with MCP Log Server
status: active
audience: [developers, devops]
difficulty: intermediate
created: 2026-03-20
tags: [logging, json, structured-logs, best-practices]
---

# Log Structuring Best Practices

Get the most out of MCP Log Server by structuring your application logs. This guide covers the ideal log format, stack-specific configurations, and how to thread correlation IDs across services.

---

## 1. Why Log Structure Matters for AI Debugging

MCP Log Server auto-detects JSON log formats and extracts structured fields. When your logs are structured, the tools become dramatically more accurate:

| Tool | Plain Text Behavior | Structured JSON Benefit |
|------|---------------------|------------------------|
| `get_errors` | Regex matching (may false-positive on words like "failed") | Severity field filtering — zero false positives |
| `log_stats` | Regex-based counting | Exact severity-based counts with `fatal_count` |
| `search_logs` | Full-line regex | Field-specific search (`field: "message"`) |
| `correlate` | Substring match on full line | Exact field match on `sessionId`, `traceId`, etc. |
| `trace_ids` | Extracts from `key=value` patterns | Extracts from any JSON field with dot-notation |
| `time_range` | Heuristic timestamp parsing | Reliable ISO 8601 or epoch ms extraction |
| `get_errors` + `since` | Timestamp-aware filtering | Precise time range with ISO 8601 timestamps |

**Bottom line:** Structured JSON logs give you precise filtering, zero false positives, and cross-service correlation that plain text cannot match.

---

## 2. The Ideal Log Entry

The gold standard log entry contains these fields:

```json
{
  "timestamp": "2026-03-20T14:30:00.123Z",
  "level": "error",
  "message": "Failed to connect to database",
  "service": "api-gateway",
  "sessionId": "sess-abc-123",
  "traceId": "trace-xyz-789",
  "requestId": "req-001",
  "error": {
    "type": "ConnectionError",
    "message": "ECONNREFUSED 127.0.0.1:5432",
    "stack": "at Pool.connect (pool.js:42)"
  },
  "duration_ms": 5023,
  "host": "prod-api-01"
}
```

### Field Explanations

| Field | Purpose | MCP Tool Usage |
|-------|---------|----------------|
| `timestamp` | When the event occurred (ISO 8601) | `time_range`, `since`/`until` filtering |
| `level` / `severity` | Severity classification | `get_errors` severity filtering |
| `message` / `msg` | Human-readable description | `search_logs` with `field: "message"` |
| `service` | Which service emitted the log | `trace_ids` with `field: "service"` |
| `sessionId` | User session identifier | `correlate` with `field: "sessionId"` |
| `traceId` | Distributed trace identifier | `correlate` with `field: "traceId"` |
| `requestId` | Individual request identifier | `correlate` with `field: "requestId"` |
| `error` | Structured error details | `search_logs` with `field: "error.type"` |

MCP Log Server checks these field names in priority order:
- **Severity:** `severity`, `level`, `log.level`, `levelname`, `loglevel`
- **Message:** `message`, `msg`, `textPayload`, `@message`
- **Timestamp:** `timestamp`, `time`, `@timestamp`, `receiveTimestamp`

Numeric Pino levels (10=trace, 20=debug, 30=info, 40=warn, 50=error, 60=fatal) are automatically mapped.

---

## 3. Stack-Specific Configurations

### Node.js with Pino

```javascript
const pino = require('pino');

const logger = pino({
  level: 'info',
  timestamp: pino.stdTimeFunctions.isoTime,
  formatters: {
    level(label) {
      return { level: label };
    }
  },
  base: {
    service: 'api-gateway',
    host: os.hostname()
  }
});

// Usage
logger.info({ sessionId: req.sessionId, traceId: req.headers['x-trace-id'] }, 'Request received');
logger.error({ err, sessionId: req.sessionId, duration_ms: Date.now() - start }, 'Request failed');
```

Output:
```json
{"level":"info","time":"2026-03-20T14:30:00.123Z","service":"api-gateway","sessionId":"sess-abc","traceId":"trace-xyz","msg":"Request received"}
```

### Python with structlog

```python
import structlog

structlog.configure(
    processors=[
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.add_log_level,
        structlog.processors.JSONRenderer()
    ]
)

logger = structlog.get_logger(service="user-service")

# Usage
logger.info("request_handled", session_id="sess-abc", trace_id="trace-xyz", duration_ms=42)
logger.error("database_error", session_id="sess-abc", error_type="ConnectionError")
```

Output:
```json
{"timestamp":"2026-03-20T14:30:00.123Z","level":"info","event":"request_handled","service":"user-service","session_id":"sess-abc","trace_id":"trace-xyz","duration_ms":42}
```

### Go with zerolog

```go
package main

import (
    "os"
    "github.com/rs/zerolog"
    "github.com/rs/zerolog/log"
)

func init() {
    zerolog.TimeFieldFormat = zerolog.TimeFormatUnix
    log.Logger = zerolog.New(os.Stdout).With().
        Timestamp().
        Str("service", "payment-service").
        Logger()
}

// Usage
log.Info().
    Str("sessionId", sessionID).
    Str("traceId", traceID).
    Int("duration_ms", elapsed).
    Msg("Payment processed")
```

Output:
```json
{"level":"info","service":"payment-service","sessionId":"sess-abc","traceId":"trace-xyz","duration_ms":120,"time":1711029000,"message":"Payment processed"}
```

### Elixir with Logger + JSON formatter

```elixir
# config/config.exs
config :logger, :console,
  format: {MyApp.JsonFormatter, :format},
  metadata: [:session_id, :trace_id, :service]

# lib/my_app/json_formatter.ex
defmodule MyApp.JsonFormatter do
  def format(level, message, timestamp, metadata) do
    %{
      timestamp: format_timestamp(timestamp),
      level: level,
      message: IO.chardata_to_string(message),
      service: metadata[:service] || "my-app",
      sessionId: metadata[:session_id],
      traceId: metadata[:trace_id]
    }
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end
end

# Usage
Logger.info("Request handled",
  session_id: "sess-abc",
  trace_id: "trace-xyz"
)
```

### Java with Logback (JSON encoder)

```xml
<!-- logback.xml -->
<configuration>
  <appender name="JSON" class="ch.qos.logback.core.ConsoleAppender">
    <encoder class="net.logstash.logback.encoder.LogstashEncoder">
      <customFields>{"service":"order-service"}</customFields>
    </encoder>
  </appender>

  <root level="INFO">
    <appender-ref ref="JSON" />
  </root>
</configuration>
```

```java
import org.slf4j.MDC;

// Thread correlation IDs through MDC
MDC.put("sessionId", request.getHeader("X-Session-ID"));
MDC.put("traceId", request.getHeader("X-Trace-ID"));

logger.info("Order created");
logger.error("Payment failed", exception);
```

Output:
```json
{"@timestamp":"2026-03-20T14:30:00.123Z","level":"ERROR","message":"Payment failed","service":"order-service","sessionId":"sess-abc","traceId":"trace-xyz","stack_trace":"..."}
```

---

## 4. Correlation ID Threading

For `correlate` and `trace_ids` to work across services, propagate correlation IDs through HTTP headers:

```
Client → API Gateway → Auth Service → Database Service
         X-Session-ID: sess-abc-123
         X-Trace-ID:   trace-xyz-789
```

### Express.js middleware

```javascript
app.use((req, res, next) => {
  req.traceId = req.headers['x-trace-id'] || crypto.randomUUID();
  req.sessionId = req.headers['x-session-id'] || req.session?.id;

  // Propagate to downstream services
  res.setHeader('X-Trace-ID', req.traceId);

  // Attach to logger context
  req.log = logger.child({ traceId: req.traceId, sessionId: req.sessionId });
  next();
});
```

### Downstream HTTP calls

```javascript
const response = await fetch('http://auth-service/verify', {
  headers: {
    'X-Trace-ID': req.traceId,
    'X-Session-ID': req.sessionId
  }
});
```

Then use MCP Log Server to trace the full request path:

```
You> correlate trace-xyz-789
Claude> [calls correlate tool]
Found 8 matches across 3 files:

Timeline:
10:30:00 api-gateway.log  INFO  Request received
10:30:01 auth.log          INFO  Token validated
10:30:02 db.log            INFO  Query executed (42ms)
10:30:02 api.log           INFO  Response sent (200)
```

---

## 5. Log Output for MCP Consumption

MCP Log Server reads `.log` files from a directory. Here are common ways to get logs there.

### Turborepo / monorepo

```bash
# package.json
"dev:logged": "mkdir -p /tmp/mcp-logs && turbo run dev 2>&1 | tee /tmp/mcp-logs/dev.log"
```

Or per-service logs:

```bash
"dev:api": "node api/server.js 2>&1 | tee /tmp/mcp-logs/api.log"
"dev:worker": "node worker/index.js 2>&1 | tee /tmp/mcp-logs/worker.log"
```

### Docker Compose

```yaml
services:
  api:
    image: my-api
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
    volumes:
      - ./logs:/app/logs

  mcp-log-server:
    image: ghcr.io/wolven-tech/mcp-log-server:latest
    volumes:
      - ./logs:/tmp/mcp-logs
    stdin_open: true
```

### GCP Cloud Logging export

Export structured logs to Cloud Storage, then mount locally:

```bash
# Export to GCS bucket
gcloud logging sinks create mcp-export \
  storage.googleapis.com/my-logs-bucket \
  --log-filter='resource.type="cloud_run_revision"'

# Sync locally for MCP analysis
gsutil -m rsync gs://my-logs-bucket/2026/03/20/ /tmp/mcp-logs/
```

### Kubernetes

```bash
# Stream pod logs to files
kubectl logs -f deployment/api-gateway > /tmp/mcp-logs/api-gateway.log &
kubectl logs -f deployment/auth-service > /tmp/mcp-logs/auth-service.log &
```

Or use a sidecar that writes to a shared volume mounted by MCP Log Server.

---

## 6. Log Quality Scorecard

Rate your logging setup on this 15-point scale. Each criterion is worth 1 point.

| # | Criterion | How to Check |
|---|-----------|-------------|
| 1 | Timestamps present on every line | `time_range` returns non-nil earliest/latest |
| 2 | Timestamps in ISO 8601 format | `time_range` parses without fallback heuristics |
| 3 | Severity/level field present | `log_stats` shows non-zero error + warn counts |
| 4 | Severity uses standard values (info/warn/error/fatal) | `get_errors` returns zero false positives |
| 5 | Structured JSON format (NDJSON) | `log_stats` auto-detects JSON format |
| 6 | Message field present | `search_logs` with `field: "message"` returns results |
| 7 | Service/source identifier | `trace_ids` with `field: "service"` returns unique services |
| 8 | Session/user correlation ID | `trace_ids` with `field: "sessionId"` returns values |
| 9 | Trace/request correlation ID | `correlate` with a known ID returns cross-file matches |
| 10 | Correlation IDs propagated across services | `correlate` returns `files_matched > 1` |
| 11 | Error entries include structured error details | `search_logs` with `field: "error.type"` works |
| 12 | No multi-line log entries (one JSON object per line) | Format detected as `json_lines` not `plain` |
| 13 | Per-service log files (not one giant mixed file) | `list_logs` shows multiple focused files |
| 14 | Log rotation configured (files < 100MB) | `log_stats` shows reasonable `size_bytes` |
| 15 | Duration/latency fields on request logs | `search_logs` with `field: "duration_ms"` works |

### Scoring Tiers

| Score | Tier | What It Means |
|-------|------|--------------|
| 12-15 | Excellent | Full MCP tool suite works perfectly. Cross-service correlation, precise filtering, zero noise. |
| 8-11 | Good | Core tools work well. Some advanced features (correlation, field search) may be limited. |
| 4-7 | Basic | `get_errors` and `search_logs` work but may have false positives. No cross-service correlation. |
| 0-3 | Minimal | Only `tail_log` and basic `search_logs` are useful. Consider migrating. |

---

## 7. Common Anti-Patterns

| Anti-Pattern | Problem | Fix |
|-------------|---------|-----|
| `console.log("Error: " + err)` | No severity field, no structure, no timestamp | Use a structured logger (Pino, structlog, zerolog) |
| Multi-line stack traces | Breaks NDJSON format, confuses line-based tools | Serialize stack trace into a single `error.stack` field |
| `"level": "ERROR"` (uppercase) | Inconsistent casing across services | Normalize to lowercase in your logger config |
| Logging sensitive data (tokens, passwords) | Security risk, noise in search results | Redact or omit sensitive fields before logging |
| Different timestamp formats per service | `time_range` and `since`/`until` may fail to parse | Standardize on ISO 8601 with timezone (`Z` suffix) |
| No correlation IDs | `correlate` tool cannot trace requests across services | Add `traceId`/`sessionId` to every log entry |
| Giant monolithic log file | `get_errors` mixes unrelated services | Split logs per service: `api.log`, `worker.log`, `auth.log` |
| Logging at DEBUG level in production | Noise overwhelms signal, `get_errors` returns too many results | Use INFO as production minimum, DEBUG only in dev |

---

## 8. Migration Path

Adopt structured logging incrementally. Each phase unlocks more MCP tool capabilities.

### Phase 1: Add Timestamps (Effort: Low)

Ensure every log line has a parseable timestamp.

**Enables:** `time_range`, `since`/`until` filtering on all tools.

```bash
# Before
echo "Server started"

# After
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) INFO Server started"
```

### Phase 2: Switch to JSON (Effort: Medium)

Replace `console.log` / print statements with a structured logging library.

**Enables:** Severity-based `get_errors` (zero false positives), `log_stats` with accurate counts, field-specific `search_logs`.

```javascript
// Before
console.log(`Error: ${err.message}`);

// After
logger.error({ err }, 'Request failed');
```

### Phase 3: Add Correlation IDs (Effort: Medium)

Thread `traceId` and `sessionId` through HTTP headers and log them on every entry.

**Enables:** `correlate` tool for cross-service request tracing, `trace_ids` for discovering active sessions.

### Phase 4: Per-Service Log Files (Effort: Low)

Write each service's output to a separate `.log` file instead of mixing everything together.

**Enables:** `all_errors` gives per-service health overview, `list_logs` shows clear service inventory, reduced noise in every tool.

---

**[Back to Documentation Index](../README.md)**
