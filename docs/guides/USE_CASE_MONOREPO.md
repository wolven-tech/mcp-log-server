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

The `all_errors` tool is the recommended first call — it scans every log file and returns a summary:

```
Claude> [calls all_errors with lines=10]

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
