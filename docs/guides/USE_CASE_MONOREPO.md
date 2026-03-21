---
title: "Use Case: Multi-Service Monorepo"
description: How MCP Log Server integrates with a multi-service monorepo for AI-assisted debugging
status: active
audience: [developers]
difficulty: intermediate
created: 2026-03-18
lastModified: 2026-03-18
tags: [use-case, monorepo, docker, claude-code]
---

# Use Case: Multi-Service Monorepo

This guide walks through how MCP Log Server integrates with a multi-service monorepo — a common setup where multiple services generate concurrent log output during development.

---

## The Problem

A typical monorepo runs several services during development:

| Service | Stack | Role |
|---------|-------|------|
| API | NestJS / Rails / etc. | Backend |
| Web | Next.js / Vite | Frontend |
| Worker | Node.js / Python | Background jobs |
| Auth | Go / Elixir | Authentication |

Running all services together (`turbo run dev`, `docker compose up`) produces a flood of interleaved log output. When something breaks, the developer (or Claude Code) has to sift through thousands of lines to find the relevant error.

**Before MCP Log Server**: paste the last 500 lines of terminal output into Claude, burning ~2000 tokens on irrelevant INFO lines.

**After MCP Log Server**: Claude calls `all_errors` and gets a focused, token-efficient summary in ~200 tokens.

## The Setup

### 1. Pipe Dev Logs to a File

In your `package.json`:

```json
{
  "scripts": {
    "dev": "turbo run dev --filter='./apps/*'",
    "dev:logged": "mkdir -p /tmp/mcp-logs && turbo run dev --filter='./apps/*' 2>&1 | tee /tmp/mcp-logs/apps.log"
  }
}
```

`dev:logged` sends all output to both the terminal and `/tmp/mcp-logs/apps.log`. Developers see logs as usual; the MCP server reads them from the file.

### Per-Service Log Files

For better results with `correlate` and `log_stats`, pipe each service to its own file instead of combining them. This lets MCP Log Server report per-service error counts and trace requests across service boundaries.

```json
{
  "scripts": {
    "dev": "turbo run dev --filter='./apps/*'",
    "dev:logged": "mkdir -p /tmp/mcp-logs && npm-run-all --parallel dev:api:logged dev:web:logged dev:worker:logged",
    "dev:api:logged": "cd apps/api && npm run dev 2>&1 | tee /tmp/mcp-logs/api.log",
    "dev:web:logged": "cd apps/web && npm run dev 2>&1 | tee /tmp/mcp-logs/web.log",
    "dev:worker:logged": "cd apps/worker && npm run dev 2>&1 | tee /tmp/mcp-logs/worker.log"
  }
}
```

Alternatively, with Docker Compose, use per-service logging:

```bash
docker compose up api 2>&1 | tee /tmp/mcp-logs/api.log &
docker compose up web 2>&1 | tee /tmp/mcp-logs/web.log &
docker compose up worker 2>&1 | tee /tmp/mcp-logs/worker.log &
```

### 2. Build and Configure the MCP Server

```bash
docker build -t mcp-log-server .
```

### 3. Add MCP Configuration

`.mcp.json` in the monorepo root:

```json
{
  "mcpServers": {
    "log-server": {
      "command": "docker",
      "args": [
        "run", "--rm", "-i",
        "-v", "/tmp/mcp-logs:/tmp/mcp-logs",
        "mcp-log-server:latest"
      ],
      "type": "stdio"
    }
  }
}
```

### 4. Enable in Claude Settings

`.claude/settings.local.json`:

```json
{
  "permissions": {
    "allow": ["mcp__log-server__all_errors"]
  },
  "enableAllProjectMcpServers": true
}
```

Pre-allowing `all_errors` means Claude can check log health without asking for permission each time.

## The Workflow

### Daily Development

1. Start services: `pnpm dev:logged`
2. Work on features with Claude Code
3. When something breaks, Claude uses the log tools:

```
Developer> The API is returning 500 errors
Claude> [calls all_errors]
Found errors in apps.log:

  Line 1247: ERROR [ExceptionFilter] TypeError: Cannot read properties of undefined
  Line 1248: at UserService.getProfile (/apps/api/src/user/user.service.ts:42)
  Line 1251: ERROR [ExceptionFilter] ECONNREFUSED 127.0.0.1:6379

Two issues: a null reference in UserService.getProfile and Redis is down.
Let me check the Redis connection context...

Claude> [calls search_logs with pattern="redis|6379" context=5]
```

### Health Check Pattern

The `all_errors` tool is the recommended first call -- it scans every log file and returns a summary. Use `level` to filter by severity and `since` to narrow the time window:

```
Claude> [calls all_errors with level="error" since="30m"]

=== apps.log (3 errors) ===
[line_number|content]
1247|ERROR [ExceptionFilter] TypeError: Cannot read properties of undefined
1251|ERROR [ExceptionFilter] ECONNREFUSED 127.0.0.1:6379
1398|WARN: Memory usage at 85%
```

This costs ~50 tokens vs ~2000 for dumping the raw log.

### Targeted Investigation

After identifying the area of concern:

```
Claude> [calls search_logs with file="apps.log" pattern="UserService" context=3]
Claude> [calls tail_log with file="apps.log" lines=20]
Claude> [calls log_stats with file="apps.log"]
```

### Cross-Service Debugging

When you have per-service log files, `correlate` and `trace_ids` let you trace requests across service boundaries -- even during local development.

**Find all log entries for a specific request:**

```
Claude> [calls correlate with value="req-abc-123" field="requestId"]

=== Correlation: "req-abc-123" (field: requestId) ===
Found in 2 files, 4 entries (sorted by timestamp)

[timestamp|file|content]
2026-03-20T10:15:01.100Z|api.log|POST /api/orders received
2026-03-20T10:15:01.200Z|api.log|Dispatching job order.process
2026-03-20T10:15:01.350Z|worker.log|Processing job order.process for req-abc-123
2026-03-20T10:15:02.100Z|worker.log|Job order.process completed
```

**Discover which request or session IDs appear in your logs:**

```
Claude> [calls trace_ids with field="requestId" file="api.log"]

=== Unique values for field "requestId" in api.log ===
[value|count|first_seen|last_seen]
req-abc-123|12|2026-03-20T10:15:01Z|2026-03-20T10:15:02Z
req-def-456|8|2026-03-20T10:16:30Z|2026-03-20T10:16:31Z
...
```

### Time Range and Time Filtering

Use `time_range` to check what window a log file covers, and use `since`/`until` to focus on a specific period:

```
Claude> [calls time_range with file="api.log"]

[earliest|latest|span]
2026-03-20T09:00:00.102Z|2026-03-20T10:30:12.887Z|1h 30m 12s
```

Filter errors to the last 30 minutes only:

```
Claude> [calls all_errors with level="error" since="30m"]
Claude> [calls get_errors with file="api.log" since="30m" until="15m"]
```

## Token Savings

TOON format makes a measurable difference in LLM context usage:

| Format | 50 log lines | 200 error lines |
|--------|-------------|-----------------|
| Raw JSON | ~1,200 tokens | ~4,800 tokens |
| TOON | ~600 tokens | ~2,400 tokens |
| Savings | **~50%** | **~50%** |

For a development session with 20+ tool calls, this compounds significantly.

## Key Takeaways

1. **Pipe logs to files** — `tee` gives you both terminal output and file-based analysis
2. **Pre-allow health check tools** — let Claude run `all_errors` without permission prompts
3. **Start with `all_errors`** — get the overview before diving into specifics
4. **Use context lines** — `search_logs` with `context=3` gives surrounding lines for free
5. **TOON saves tokens** — meaningful savings over raw log dumps or JSON

---

**[Back to Documentation Index](../README.md)**
