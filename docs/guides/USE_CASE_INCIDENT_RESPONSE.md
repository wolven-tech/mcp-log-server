---
title: "Use Case: Incident Response"
description: Using MCP Log Server for production incident triage and root cause analysis
status: active
audience: [developers, sre, devops]
difficulty: intermediate
created: 2026-03-20
tags: [use-case, incident-response, correlation, time-filtering]
---

# Use Case: Incident Response

This guide walks through using MCP Log Server for production incident triage -- the primary use case for the `correlate`, `time_range`, and time-filtering features.

---

## The Scenario

You get paged at 2am. Your monitoring dashboard shows elevated error rates across multiple services. The on-call Slack channel has reports of failed API calls and dropped WebSocket connections.

You export the last hour of logs from your logging platform (GCP Cloud Logging, Datadog, or similar) to `/tmp/mcp-logs/`, one file per service:

```bash
# Example: export from GCP Cloud Logging
for svc in gateway api ws worker; do
  gcloud logging read "resource.labels.container_name=\"$svc\"" \
    --format=json --freshness=1h > "/tmp/mcp-logs/${svc}.log"
done
```

You now have four files:
- `gateway.log` -- API gateway / load balancer logs
- `api.log` -- main backend API service
- `ws.log` -- WebSocket server
- `worker.log` -- background job processor

Each file contains GCP Cloud Logging JSON entries like this:

```json
{
  "severity": "ERROR",
  "timestamp": "2026-03-20T14:23:01.456Z",
  "textPayload": "Connection refused to postgres:5432",
  "resource": {
    "type": "k8s_container",
    "labels": {
      "container_name": "api",
      "namespace_name": "production"
    }
  },
  "labels": {
    "requestId": "req-abc-123"
  },
  "trace": "projects/my-project/traces/abc123"
}
```

---

## Step-by-Step Workflow

### Step 1: Triage (30 seconds)

Start with the broadest view. `all_errors` scans every file and returns a summary of errors across all services.

**Tool call:**

```json
{
  "name": "all_errors",
  "arguments": {
    "since": "1h"
  }
}
```

**Response (TOON format):**

```
=== gateway.log (2 errors) ===
[line_number|content]
1842|ERROR upstream connect error: connection_refused, target=api:3000
2901|ERROR upstream connect error: connection_refused, target=api:3000

=== api.log (14 errors) ===
[line_number|content]
502|ERROR Connection refused to postgres:5432
503|ERROR Connection refused to postgres:5432
619|ERROR Unhandled rejection: ECONNREFUSED 10.0.2.15:5432
620|ERROR Request req-abc-123 failed: database unavailable
738|ERROR Connection refused to postgres:5432
...truncated (9 more)

=== ws.log (5 errors) ===
[line_number|content]
301|ERROR Failed to authenticate session sess-xyz-789: upstream timeout
302|ERROR WebSocket close: code=1011 reason="internal error"
415|ERROR Failed to authenticate session sess-def-456: upstream timeout
...truncated (2 more)

=== worker.log (8 errors) ===
[line_number|content]
112|ERROR Job payment.process failed: PG::ConnectionBad
113|ERROR Job email.send failed: PG::ConnectionBad
...truncated (6 more)
```

**Conclusion after 30 seconds:** The API service has the most errors, and "postgres" and "connection refused" appear repeatedly. This looks like a database connectivity issue rippling through all services.

---

### Step 2: Scope the Blast Radius

Use `log_stats` on each file to understand the scale of impact.

**Tool calls:**

```json
{"name": "log_stats", "arguments": {"file": "gateway.log"}}
{"name": "log_stats", "arguments": {"file": "api.log"}}
{"name": "log_stats", "arguments": {"file": "ws.log"}}
{"name": "log_stats", "arguments": {"file": "worker.log"}}
```

**Example response for api.log:**

```
[file|lines|errors|warnings|size]
api.log|4230|14|23|2.1 MB
```

The API service has 14 errors and 23 warnings in the last hour -- notably higher than the other services.

---

### Step 3: Timeline

Use `time_range` to determine when errors started and establish the incident window.

**Tool call:**

```json
{
  "name": "time_range",
  "arguments": {
    "file": "api.log"
  }
}
```

**Response:**

```
[earliest|latest|span]
2026-03-20T13:30:00.102Z|2026-03-20T14:30:12.887Z|1h 0m 12s
```

The file covers a full hour. Now narrow down when errors actually started by looking at the first errors with time filtering.

---

### Step 4: Targeted Errors

Now focus on just the real errors (not warnings) within the incident window.

**Tool call:**

```json
{
  "name": "get_errors",
  "arguments": {
    "file": "api.log",
    "level": "error",
    "since": "2026-03-20T14:00:00Z"
  }
}
```

**Response:**

```
=== api.log (14 errors since 2026-03-20T14:00:00Z) ===
[line_number|timestamp|content]
502|2026-03-20T14:05:12.331Z|Connection refused to postgres:5432
503|2026-03-20T14:05:12.445Z|Connection refused to postgres:5432
619|2026-03-20T14:05:13.002Z|Unhandled rejection: ECONNREFUSED 10.0.2.15:5432
620|2026-03-20T14:05:13.119Z|Request req-abc-123 failed: database unavailable
738|2026-03-20T14:05:14.556Z|Connection refused to postgres:5432
812|2026-03-20T14:06:01.223Z|Connection pool exhausted, 0/10 available
813|2026-03-20T14:06:01.334Z|Request req-def-456 failed: database unavailable
...truncated (7 more)
```

**Key finding:** Errors start at 14:05:12Z. The first errors are all "Connection refused to postgres:5432", and the connection pool exhaustion follows shortly after. The incident start time is approximately 14:05 UTC.

---

### Step 5: Find the Root Cause

Search for connection and timeout patterns with surrounding context to understand what happened right before the first error.

**Tool call:**

```json
{
  "name": "search_logs",
  "arguments": {
    "file": "api.log",
    "pattern": "connection|timeout|postgres",
    "since": "2026-03-20T14:04:00Z",
    "until": "2026-03-20T14:06:00Z",
    "context": 3
  }
}
```

**Response:**

```
=== api.log: 8 matches ===
[line_number|content]
--- match 1 (line 498) ---
495|INFO  Healthcheck passed: postgres OK, redis OK
496|INFO  Request req-997-abc completed in 23ms
497|WARN  Postgres connection latency: 1200ms (threshold: 500ms)
498|WARN  Postgres connection latency: 3400ms (threshold: 500ms)
499|ERROR Connection refused to postgres:5432
500|ERROR Connection refused to postgres:5432
501|ERROR Retrying postgres connection (attempt 1/3)
--- match 2 (line 502) ---
...
```

**Root cause identified:** At 14:05, Postgres connection latency spiked from normal levels to 1200ms, then 3400ms, then connections were refused entirely. This is consistent with a database failover, resource exhaustion, or network partition.

---

### Step 6: Cross-Service Tracing

Pick a specific failing request and trace it across all services to understand the full user impact.

**Tool call:**

```json
{
  "name": "correlate",
  "arguments": {
    "value": "req-abc-123",
    "field": "requestId"
  }
}
```

**Response:**

```
=== Correlation: "req-abc-123" (field: requestId) ===
Found in 3 files, 5 entries (sorted by timestamp)

[timestamp|file|content]
2026-03-20T14:05:12.100Z|gateway.log|POST /api/v1/orders received, upstream=api:3000
2026-03-20T14:05:12.105Z|api.log|Processing order creation for user usr-42
2026-03-20T14:05:12.331Z|api.log|Connection refused to postgres:5432
2026-03-20T14:05:13.119Z|api.log|Request req-abc-123 failed: database unavailable
2026-03-20T14:05:13.122Z|gateway.log|POST /api/v1/orders responded 502, latency=1022ms
```

**Full picture:** The request entered through the gateway, reached the API service, failed when the API could not connect to Postgres, and the gateway returned a 502 to the user. Total latency was over 1 second due to connection retry attempts.

---

### Step 7: Discover Affected Sessions

Find which user sessions were impacted during the incident window to scope the customer impact.

**Tool call:**

```json
{
  "name": "trace_ids",
  "arguments": {
    "field": "sessionId",
    "file": "api.log"
  }
}
```

**Response:**

```
=== Unique values for field "sessionId" in api.log ===
[value|count|first_seen|last_seen]
sess-xyz-789|47|2026-03-20T13:30:01Z|2026-03-20T14:28:44Z
sess-abc-111|23|2026-03-20T13:45:12Z|2026-03-20T14:25:33Z
sess-def-456|18|2026-03-20T14:01:00Z|2026-03-20T14:22:11Z
sess-ghi-222|12|2026-03-20T14:03:55Z|2026-03-20T14:15:02Z
...truncated (8 more unique values)
```

You can then correlate individual sessions to see which requests failed for a specific user:

```json
{
  "name": "correlate",
  "arguments": {
    "value": "sess-xyz-789",
    "field": "sessionId"
  }
}
```

---

## Best Practices for Incident Response

### Export Logs Per Service

Export one file per service rather than dumping everything into a single file. This gives you cleaner `log_stats` results and lets `correlate` show you exactly which services a request touched.

```bash
# Good: one file per service
/tmp/mcp-logs/gateway.log
/tmp/mcp-logs/api.log
/tmp/mcp-logs/worker.log

# Bad: everything in one file
/tmp/mcp-logs/all-services.log
```

### Use `since` to Narrow the Window

Do not scan 24 hours of logs when the incident lasted 30 minutes. Time filtering reduces noise and speeds up every tool call.

```json
{"name": "all_errors", "arguments": {"since": "30m"}}
{"name": "get_errors", "arguments": {"file": "api.log", "since": "2026-03-20T14:00:00Z", "until": "2026-03-20T14:30:00Z"}}
```

Relative shorthand (`"30m"`, `"1h"`, `"2h"`) is often the fastest way to set the window. Use ISO 8601 timestamps when you need precision.

### Start Broad, Then Narrow

Follow this investigation funnel:

1. `all_errors` -- see everything that is broken
2. `log_stats` -- quantify the blast radius per service
3. `get_errors` with `level: "error"` and `since` -- filter out warnings and old noise
4. `search_logs` with `context` -- understand the sequence of events around each error
5. `correlate` -- trace individual requests across services

Each step reduces the scope and increases the detail.

### Use `exclude` to Filter Known Noise

If a service produces known benign errors (deprecated API warnings, expected retries), exclude them to focus on the real problem:

```json
{
  "name": "get_errors",
  "arguments": {
    "file": "api.log",
    "level": "error",
    "since": "1h",
    "exclude": "deprecated|DeprecationWarning"
  }
}
```

### Build the Request Timeline Before Jumping to Code

Use `correlate` to understand what happened before looking at the source code. A failing request may have passed through 3 services, and the root cause may be in a different service than the one that returned the error to the user.

---

**[Back to Documentation Index](../README.md)**
