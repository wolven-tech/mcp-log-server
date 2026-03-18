---
title: Quick Start
description: Get MCP Log Server running in 5 minutes
status: active
audience: [developers]
difficulty: beginner
created: 2026-03-18
lastModified: 2026-03-18
tags: [getting-started, setup, docker]
---

# Quick Start

Get MCP Log Server running and connected to Claude Code in 5 minutes.

---

## Prerequisites

- Docker (recommended) **or** Elixir 1.17+ with Erlang/OTP 27+
- An MCP-compatible client (Claude Code, Cursor, etc.)

## Step 1: Build the Server

### Option A: Docker

```bash
git clone https://github.com/your-org/mcp-log-server.git
cd mcp-log-server
docker build -t mcp-log-server .
```

### Option B: From Source

```bash
git clone https://github.com/your-org/mcp-log-server.git
cd mcp-log-server
mix deps.get
mix compile
```

## Step 2: Prepare Log Files

The server reads `.log` files from a directory you specify. Create a test log:

```bash
mkdir -p /tmp/mcp-logs
echo "2026-03-18 10:00:00 INFO: Server started on port 3000
2026-03-18 10:00:05 INFO: Connected to database
2026-03-18 10:01:12 ERROR: Failed to fetch user profile - timeout
2026-03-18 10:01:13 WARN: Retrying request (attempt 2/3)
2026-03-18 10:01:14 INFO: Request succeeded on retry
2026-03-18 10:05:00 ERROR: ECONNREFUSED to redis:6379" > /tmp/mcp-logs/app.log
```

## Step 3: Configure Your MCP Client

Create `.mcp.json` in your project root:

### Docker

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

### From Source

```json
{
  "mcpServers": {
    "log-server": {
      "command": "bash",
      "args": ["-c", "cd /path/to/mcp-log-server && LOG_DIR=/tmp/mcp-logs mix run --no-halt"],
      "type": "stdio"
    }
  }
}
```

## Step 4: Use It

Open Claude Code in your project directory. The MCP tools are now available:

```
You> Check the logs for errors
Claude> [calls all_errors tool]
Found 2 errors across 1 file:

app.log:
  Line 3: ERROR: Failed to fetch user profile - timeout
  Line 6: ERROR: ECONNREFUSED to redis:6379
```

```
You> Search for redis connection issues with context
Claude> [calls search_logs with pattern="redis" context=2]
```

## What's Next

- [Tool Reference](../reference/TOOLS.md) — see all available tools and their parameters
- [MCP Client Setup](../guides/MCP_CLIENT_SETUP.md) — detailed configuration for different clients
- [Use Case: Monorepo](../guides/USE_CASE_MONOREPO.md) — real-world integration example

---

**[Back to Documentation Index](../README.md)**
