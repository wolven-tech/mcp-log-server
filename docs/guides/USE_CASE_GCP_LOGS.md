---
title: "Use Case: GCP Cloud Logging"
description: Using MCP Log Server with Google Cloud Logging exports
status: active
audience: [developers, devops, sre]
difficulty: intermediate
created: 2026-03-20
tags: [use-case, gcp, cloud-logging, json, structured-logs]
---

# Use Case: GCP Cloud Logging

This guide covers how to export logs from Google Cloud Logging and analyze them with MCP Log Server. GCP Cloud Logging JSON is a first-class format -- the server auto-detects it and uses structured field extraction for accurate error detection and time filtering.

---

## Exporting Logs from GCP

### Basic Export

Export recent logs for a Kubernetes workload:

```bash
gcloud logging read 'resource.type="k8s_container"' \
  --format=json \
  --freshness=2h \
  > /tmp/mcp-logs/production.log
```

### Per-Service Export (Recommended)

Export each service to its own file. This gives better results with `log_stats`, `correlate`, and `all_errors` because MCP Log Server can report per-file breakdowns.

```bash
for svc in gateway api worker; do
  gcloud logging read "resource.labels.container_name=\"$svc\"" \
    --format=json \
    --freshness=2h \
    > "/tmp/mcp-logs/${svc}.log"
done
```

### Filtering by Severity

If you only care about errors and warnings, filter at export time to reduce file size:

```bash
gcloud logging read 'resource.type="k8s_container" AND severity>=WARNING' \
  --format=json \
  --freshness=6h \
  > /tmp/mcp-logs/errors-only.log
```

### Filtering by Log Name or Label

```bash
# Specific log name
gcloud logging read 'logName="projects/my-project/logs/stderr"' \
  --format=json --freshness=1h > /tmp/mcp-logs/stderr.log

# Custom label
gcloud logging read 'labels.environment="production"' \
  --format=json --freshness=1h > /tmp/mcp-logs/prod.log
```

---

## How MCP Log Server Handles GCP JSON

The server auto-detects JSON log format on a per-line basis. For GCP Cloud Logging entries, it extracts the following fields:

### Field Mapping

| GCP Field | What MCP Log Server Uses It For |
|-----------|-------------------------------|
| `severity` | Error detection in `get_errors`, `all_errors`, `log_stats`. Uses the actual field value -- no regex guessing. |
| `timestamp` | Time filtering (`since`, `until`), `time_range`, and timestamp sorting in `correlate`. |
| `textPayload` | Primary message for pattern matching in `search_logs`. |
| `jsonPayload.message` | Fallback message field when `textPayload` is absent. |
| `trace` | Cross-service correlation via `correlate`. |
| `labels.*` | Searchable via `field` parameter in `search_logs` and `correlate`. |
| `resource.labels.*` | Searchable via dot-notation field access. |

### Example GCP Log Entry

```json
{
  "insertId": "abc123def456",
  "severity": "ERROR",
  "timestamp": "2026-03-20T14:00:00.123Z",
  "textPayload": "Connection refused to postgres:5432",
  "resource": {
    "type": "k8s_container",
    "labels": {
      "container_name": "api",
      "namespace_name": "production",
      "pod_name": "api-7f8b9c6d4-x2k9m"
    }
  },
  "labels": {
    "requestId": "req-abc-123",
    "userId": "usr-42"
  },
  "trace": "projects/my-project/traces/abc123def456789"
}
```

How each field maps to MCP tools:

- **`severity: "ERROR"`** -- `get_errors(file: "api.log", level: "error")` will include this entry. `log_stats` will count it as an error.
- **`timestamp`** -- `get_errors(file: "api.log", since: "2026-03-20T14:00:00Z")` will include this entry. `time_range(file: "api.log")` will include this timestamp in the range calculation.
- **`textPayload`** -- `search_logs(file: "api.log", pattern: "postgres")` will match this entry.
- **`trace`** -- `correlate(value: "abc123def456789", field: "trace")` will find this entry across all service files.
- **`labels.requestId`** -- `correlate(value: "req-abc-123", field: "labels.requestId")` will find this entry. Also works with `search_logs` using the `field` parameter.

---

## Workflow Examples

### Triage with all_errors

After exporting, start with a broad scan:

```json
{
  "name": "all_errors",
  "arguments": {
    "since": "1h",
    "level": "error"
  }
}
```

Because GCP uses the `severity` field, error detection is exact -- no false positives from log lines that happen to contain the word "error" in a message.

### Search Within a Specific JSON Field

Use the `field` parameter to restrict pattern matching to a specific part of the log entry. This is particularly useful for GCP logs where the message might be in `textPayload` or nested inside `jsonPayload`:

```json
{
  "name": "search_logs",
  "arguments": {
    "file": "api.log",
    "pattern": "connection refused",
    "field": "textPayload",
    "since": "30m"
  }
}
```

For logs that use `jsonPayload` instead of `textPayload`:

```json
{
  "name": "search_logs",
  "arguments": {
    "file": "api.log",
    "pattern": "timeout",
    "field": "jsonPayload.message"
  }
}
```

### Cross-Service Tracing with GCP Trace IDs

GCP automatically propagates trace IDs across services. The `trace` field contains a value like `projects/my-project/traces/abc123def456789`. Use `correlate` to follow a request across service boundaries:

```json
{
  "name": "correlate",
  "arguments": {
    "value": "abc123def456789",
    "field": "trace"
  }
}
```

This searches all files in the log directory and returns a unified timeline showing how the request moved through gateway, API, worker, and any other services.

To discover which trace IDs appear in the logs (useful when you do not have a specific trace ID from an alert):

```json
{
  "name": "trace_ids",
  "arguments": {
    "field": "trace",
    "file": "api.log"
  }
}
```

### Time Range Inspection

Check what time window your exported file actually covers:

```json
{
  "name": "time_range",
  "arguments": {
    "file": "api.log"
  }
}
```

This is important because `gcloud logging read` does not always return entries that fit neatly within the `--freshness` window (see known quirks below).

### Correlate by Custom Labels

If your services attach custom labels (request IDs, user IDs, session IDs), you can correlate on those:

```json
{
  "name": "correlate",
  "arguments": {
    "value": "usr-42",
    "field": "labels.userId"
  }
}
```

---

## Known gcloud CLI Quirks

### `--freshness` Is Approximate

The `--freshness=24h` flag may return entries slightly outside the specified window due to ingestion delay and clock skew. Use the `since` and `until` parameters on MCP tools for precise post-filtering:

```json
{
  "name": "get_errors",
  "arguments": {
    "file": "api.log",
    "level": "error",
    "since": "2026-03-20T14:00:00Z",
    "until": "2026-03-20T15:00:00Z"
  }
}
```

### Output Order

`gcloud logging read` returns entries in reverse chronological order by default (newest first). MCP Log Server reads files top-to-bottom, so the ordering in results may appear reversed compared to what you see with `gcloud logging read` in your terminal. Use `--order=asc` when exporting if you prefer chronological order:

```bash
gcloud logging read 'resource.type="k8s_container"' \
  --format=json \
  --freshness=2h \
  --order=asc \
  > /tmp/mcp-logs/api.log
```

### Large Exports

By default, `gcloud logging read` returns a maximum of 1000 entries. For larger exports, use `--limit`:

```bash
gcloud logging read 'resource.type="k8s_container"' \
  --format=json \
  --freshness=6h \
  --limit=10000 \
  > /tmp/mcp-logs/api.log
```

For very large files, use the `since` parameter on MCP tools to avoid scanning the entire file on every call.

### JSON Array vs. JSON Lines

`gcloud logging read --format=json` outputs a JSON array (`[{...}, {...}]`), not JSON Lines (one object per line). MCP Log Server handles both formats, so no conversion is needed.

---

**[Back to Documentation Index](../README.md)**
