---
layout: default
title: Home
---

# MCP Log Server

Token-efficient log analysis tools for LLMs via the [Model Context Protocol](https://modelcontextprotocol.io/).

Built in Elixir. Runs over stdio. Compatible with Claude Code and any MCP client.

---

## What It Does

MCP Log Server gives LLMs structured tools to query log files instead of dumping raw text into the context window. Results are returned in **TOON (Token-Oriented Object Notation)** — a compact format that uses ~50% fewer tokens than JSON for tabular data.

### Available Tools

| Tool | Description |
|------|-------------|
| `list_logs` | List available log files with metadata |
| `tail_log` | Get the last N lines from a file |
| `search_logs` | Regex search with context lines |
| `get_errors` | Extract errors, warnings, and exceptions |
| `log_stats` | File statistics without reading content |
| `all_errors` | Aggregate errors across all files |

---

## Quick Start

```bash
# Build
docker build -t mcp-log-server .

# Configure (.mcp.json in your project root)
{
  "mcpServers": {
    "log-server": {
      "command": "docker",
      "args": ["run", "--rm", "-i", "-v", "/tmp/mcp-logs:/tmp/mcp-logs", "mcp-log-server:latest"],
      "type": "stdio"
    }
  }
}
```

Then open Claude Code — the tools are available immediately.

---

## Documentation

- [Quick Start Guide](getting-started/QUICK_START.md)
- [Tool Reference](reference/TOOLS.md)
- [TOON Format](concepts/TOON_FORMAT.md)
- [Architecture](concepts/ARCHITECTURE.md)
- [MCP Client Setup](guides/MCP_CLIENT_SETUP.md)
- [Use Case: Multi-Service Monorepo](guides/USE_CASE_MONOREPO.md)
- [Contributing](CONTRIBUTING.md)

---

## GitHub

[View on GitHub](https://github.com/decebaldobrica/mcp-log-server)
