---
title: MCP Client Setup
description: Configure MCP Log Server with Claude Code and other MCP clients
status: active
audience: [developers]
difficulty: beginner
created: 2026-03-18
lastModified: 2026-03-18
tags: [setup, claude-code, mcp, configuration]
---

# MCP Client Setup

How to configure MCP Log Server with different MCP clients.

---

## Claude Code

### Project-Level Configuration

Create `.mcp.json` in your project root:

```json
{
  "mcpServers": {
    "log-server": {
      "command": "docker",
      "args": [
        "run", "--rm", "-i",
        "-v", "/path/to/logs:/tmp/mcp-logs",
        "mcp-log-server:latest"
      ],
      "type": "stdio"
    }
  }
}
```

Replace `/path/to/logs` with the directory where your application writes `.log` files.

### Pre-Allowing Tools

To let Claude use log tools without permission prompts, add to `.claude/settings.local.json`:

```json
{
  "permissions": {
    "allow": [
      "mcp__log-server__all_errors",
      "mcp__log-server__tail_log",
      "mcp__log-server__search_logs",
      "mcp__log-server__get_errors",
      "mcp__log-server__log_stats",
      "mcp__log-server__list_logs"
    ]
  },
  "enableAllProjectMcpServers": true
}
```

Or allow all tools from the server at once:

```json
{
  "permissions": {
    "allow": ["mcp__log-server__*"]
  }
}
```

### Custom Log Directory

Override `LOG_DIR` in the Docker command:

```json
{
  "mcpServers": {
    "log-server": {
      "command": "docker",
      "args": [
        "run", "--rm", "-i",
        "-e", "LOG_DIR=/var/logs",
        "-v", "/var/logs:/var/logs",
        "mcp-log-server:latest"
      ],
      "type": "stdio"
    }
  }
}
```

### Running From Source (Without Docker)

```json
{
  "mcpServers": {
    "log-server": {
      "command": "bash",
      "args": [
        "-c",
        "cd /path/to/mcp-log-server && LOG_DIR=/path/to/logs mix run --no-halt"
      ],
      "type": "stdio"
    }
  }
}
```

## Other MCP Clients

MCP Log Server communicates over **stdio** using **JSON-RPC 2.0**. Any MCP client that supports stdio transport can connect.

### Generic Configuration

The server expects:
- **Transport**: stdio (JSON lines on stdin/stdout)
- **Protocol**: JSON-RPC 2.0, MCP protocol version `2024-11-05`
- **Environment**: `LOG_DIR` pointing to the log directory

### Manual Testing

You can test the server directly from the terminal:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}' | \
  LOG_DIR=/tmp/mcp-logs mix run --no-halt
```

---

**[Back to Documentation Index](../README.md)**
