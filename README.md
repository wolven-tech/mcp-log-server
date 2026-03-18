# MCP Log Server

An Elixir-based [Model Context Protocol](https://modelcontextprotocol.io/) (MCP) server that gives LLMs token-efficient tools for reading, searching, and analyzing log files.

Built for Claude Code but compatible with any MCP client.

---

## Why

LLMs waste tokens parsing raw log files. A 10 MB log dumped into a context window is expensive and noisy. MCP Log Server solves this by providing **structured tools** that let the LLM ask specific questions about logs and get back only what matters — in a format optimized for token efficiency.

**TOON (Token-Oriented Object Notation)** delivers ~50% token reduction vs JSON for tabular log data:

```
[line_number|content]
42|ERROR: Connection refused to postgres:5432
43|INFO: Retrying in 5s...
87|ERROR: Max retries exceeded
```

---

## Tools

| Tool | Description |
|------|-------------|
| `list_logs` | List all available log files with size and modification time |
| `tail_log` | Get the last N lines from a log file |
| `search_logs` | Regex search with optional context lines |
| `get_errors` | Extract ERROR, FATAL, WARN, and exception lines |
| `log_stats` | Line count, error count, warn count, file size — without reading content |
| `all_errors` | Aggregate errors across ALL log files at once |

---

## Quick Start

### Docker (Recommended)

```bash
docker build -t mcp-log-server .
```

Add to your project's `.mcp.json`:

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

Requires Elixir 1.17+ and Erlang/OTP 27+.

```bash
mix deps.get
LOG_DIR=/path/to/logs mix run --no-halt
```

### As Escript

```bash
mix escript.build
LOG_DIR=/path/to/logs ./mcp_log_server
```

---

## Configuration

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `LOG_DIR` | `/tmp/mcp-logs` | Directory containing `.log` files to analyze |

The server reads all `.log` files from the configured directory. Point `LOG_DIR` at wherever your application writes logs.

---

## Real-World Use Case: Multi-Service Monorepo

MCP Log Server shines in monorepos with multiple services generating concurrent log output. During development, pipe all service output into a shared log directory:

```bash
# In package.json
"dev:logged": "mkdir -p /tmp/mcp-logs && turbo run dev --filter='./apps/*' 2>&1 | tee /tmp/mcp-logs/apps.log"
```

Claude Code then uses the MCP tools to investigate issues without reading the entire log:

```
Claude> Use all_errors to check the health of the running services
Claude> Search for "ECONNREFUSED" in apps.log with 3 context lines
Claude> Show me the last 20 lines of apps.log
```

This workflow replaces manual `grep` and `tail` with structured, token-efficient tool calls that fit naturally into the LLM conversation.

See the [Use Case Guide](docs/guides/USE_CASE_MONOREPO.md) for the full integration walkthrough.

---

## Architecture

```
stdin/stdout (JSON-RPC 2.0)
        │
   ┌────▼─────┐
   │  Stdio    │  Transport — reads/writes JSON lines
   │ Transport │
   └────┬──────┘
        │
   ┌────▼─────┐
   │  Server   │  Routing — maps methods to handlers
   └────┬──────┘
        │
   ┌────▼──────────┐
   │  Tools         │
   │  Registry +    │  Application — defines & dispatches tools
   │  Dispatcher    │
   └────┬───────────┘
        │
   ┌────▼─────┐
   │ LogReader │  Domain — pure log analysis functions
   └──────────┘
```

Each layer has a single responsibility. The domain layer (`LogReader`) contains pure functions with no side effects beyond file reading. Protocol encoding (JSON-RPC, TOON) is isolated from business logic.

---

## Documentation

| Document | Description |
|----------|-------------|
| [Quick Start](docs/getting-started/QUICK_START.md) | Get running in 5 minutes |
| [Use Case: Monorepo](docs/guides/USE_CASE_MONOREPO.md) | Full integration walkthrough |
| [MCP Client Setup](docs/guides/MCP_CLIENT_SETUP.md) | Configure Claude Code and other MCP clients |
| [Tool Reference](docs/reference/TOOLS.md) | Complete tool API reference |
| [TOON Format](docs/concepts/TOON_FORMAT.md) | Token-Oriented Object Notation specification |
| [Architecture](docs/concepts/ARCHITECTURE.md) | Design decisions and module breakdown |
| [Contributing](docs/CONTRIBUTING.md) | How to contribute |

---

## Security

- **Path traversal protection**: File access is restricted to the configured `LOG_DIR`. Only basenames are accepted — paths like `../../etc/passwd` are rejected.
- **Read-only**: The server only reads log files. No writes, no command execution.
- **No network access**: Communicates exclusively over stdin/stdout.

---

## License

MIT
