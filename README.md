<p align="center">
  <h1 align="center">MCP Log Server</h1>
  <p align="center">
    Token-efficient log analysis tools for LLMs via the Model Context Protocol
  </p>
</p>

<p align="center">
  <a href="https://github.com/wolven-tech/mcp-log-server/actions/workflows/ci.yml"><img src="https://github.com/wolven-tech/mcp-log-server/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/wolven-tech/mcp-log-server/actions/workflows/release.yml"><img src="https://github.com/wolven-tech/mcp-log-server/actions/workflows/release.yml/badge.svg" alt="Release"></a>
  <a href="https://github.com/wolven-tech/mcp-log-server/pkgs/container/mcp-log-server"><img src="https://img.shields.io/badge/ghcr.io-mcp--log--server-blue?logo=docker" alt="Docker"></a>
  <a href="https://github.com/wolven-tech/mcp-log-server/releases/latest"><img src="https://img.shields.io/github/v/release/wolven-tech/mcp-log-server?color=green" alt="Latest Release"></a>
  <a href="https://opensource.org/licenses/MIT"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT"></a>
</p>

<p align="center">
  <a href="https://modelcontextprotocol.io/"><img src="https://img.shields.io/badge/MCP-compatible-purple" alt="MCP Compatible"></a>
  <a href="https://elixir-lang.org/"><img src="https://img.shields.io/badge/Elixir-1.17+-4B275F?logo=elixir&logoColor=white" alt="Elixir 1.17+"></a>
  <a href="https://www.erlang.org/"><img src="https://img.shields.io/badge/OTP-27+-A90533?logo=erlang&logoColor=white" alt="OTP 27+"></a>
  <a href="https://hexdocs.pm/jason/"><img src="https://img.shields.io/badge/deps-1%20(jason)-brightgreen" alt="Dependencies: 1"></a>
</p>

<p align="center">
  <a href="#quick-install">Quick Install</a> &middot;
  <a href="examples/README.md">Examples</a> &middot;
  <a href="docs/reference/TOOLS.md">Tool Reference</a> &middot;
  <a href="docs/guides/LOG_STRUCTURING.md">Log Structuring Guide</a> &middot;
  <a href="docs/concepts/ARCHITECTURE.md">Architecture</a>
</p>

---

## The Problem

LLMs waste tokens parsing raw log files. A 10 MB log dump burns thousands of tokens on irrelevant INFO lines before the model even starts reasoning. Developers paste terminal output, Claude reads noise, everyone loses.

**MCP Log Server fixes this.** Instead of dumping logs, Claude calls structured tools that return only what matters — errors, search results, cross-service timelines — in a format that uses ~50% fewer tokens than JSON.

### Before vs After

```
BEFORE: "Here's my terminal output" → paste 500 lines → 2000+ tokens of noise

AFTER:  Claude calls all_errors    → 10 errors across 3 services → ~100 tokens
        Claude calls correlate     → unified timeline for one request → ~80 tokens
        Claude calls get_errors    → filtered by severity + time → ~60 tokens
```

---

## How It Works

```
Your App → writes logs → /tmp/mcp-logs/*.log
                              ↓
                    MCP Log Server (stdio)
                              ↓
                    Claude / Cursor / MCP Client
                    asks questions, gets answers
```

The server reads `.log` files from a directory and exposes 9 tools via the [Model Context Protocol](https://modelcontextprotocol.io/). It auto-detects JSON structured logs and plain text, extracts severity from standard fields, parses timestamps, and correlates entries across files.

Output uses **TOON (Token-Oriented Object Notation)** — a pipe-delimited tabular format that delivers ~50% token savings over JSON:

```
[severity|timestamp|message|line_number]
ERROR|2026-03-20T14:02:15Z|Connection refused to postgres:5432|42
WARN|2026-03-20T14:02:16Z|Retrying in 5s...|43
ERROR|2026-03-20T14:02:20Z|Max retries exceeded|87
```

---

## Tools

9 tools organized by workflow stage:

### Discovery

| Tool | What it does |
|------|-------------|
| [`list_logs`](docs/reference/TOOLS.md#list_logs) | List available log files with size and modification time |
| [`log_stats`](docs/reference/TOOLS.md#log_stats) | Quick health check — line count, error/warn/fatal counts, file size |
| [`time_range`](docs/reference/TOOLS.md#time_range) | Earliest and latest timestamps in a file with human-readable span |

### Analysis

| Tool | What it does |
|------|-------------|
| [`all_errors`](docs/reference/TOOLS.md#all_errors) | Aggregate errors across ALL log files — best first call |
| [`get_errors`](docs/reference/TOOLS.md#get_errors) | Extract errors with severity filtering (`level`), exclusion patterns, and time range |
| [`search_logs`](docs/reference/TOOLS.md#search_logs) | Regex search with context lines, JSON field targeting, and time range |
| [`tail_log`](docs/reference/TOOLS.md#tail_log) | Last N lines from a file, with optional `since` filtering |

### Correlation

| Tool | What it does |
|------|-------------|
| [`correlate`](docs/reference/TOOLS.md#correlate) | Trace a request/session across ALL log files — unified timeline sorted by timestamp |
| [`trace_ids`](docs/reference/TOOLS.md#trace_ids) | Discover unique session/request/trace IDs with counts and time ranges |

### Recommended Workflow

```
1. all_errors              → "What's broken?"
2. log_stats / time_range  → "How bad? What time window?"
3. get_errors + level      → "Show me only real errors, no warnings"
4. search_logs + context   → "What happened around this error?"
5. correlate               → "Trace this request across services"
```

See the [Tool Reference](docs/reference/TOOLS.md) for complete parameter documentation and examples.

---

## Quick Install

### One-liner (Docker)

```bash
curl -fsSL https://raw.githubusercontent.com/wolven-tech/mcp-log-server/main/setup.sh | bash
```

The setup script pulls the Docker image from GHCR, creates a log directory, auto-detects your MCP client (Cursor, VS Code), and writes the config file.

### Manual (Docker)

```bash
docker pull ghcr.io/wolven-tech/mcp-log-server:latest
```

Add to `.mcp.json` in your project root:

```json
{
  "mcpServers": {
    "log-server": {
      "command": "docker",
      "args": [
        "run", "--rm", "-i",
        "-v", "./tmp/logs:/tmp/mcp-logs:ro",
        "ghcr.io/wolven-tech/mcp-log-server:latest"
      ]
    }
  }
}
```

### From Source

```bash
git clone https://github.com/wolven-tech/mcp-log-server.git
cd mcp-log-server
mix deps.get
LOG_DIR=/path/to/logs mix run --no-halt
```

### For Teams

Copy [`.mcp.json.example`](.mcp.json.example) into your project root so every contributor gets the MCP server pre-configured — no individual setup needed.

```makefile
# Add to your Makefile
mcp-log-setup:
	docker pull ghcr.io/wolven-tech/mcp-log-server:latest
	mkdir -p ./tmp/logs
	test -f .mcp.json || cp .mcp.json.example .mcp.json
```

---

## See It In Action

The [`examples/`](examples/README.md) directory contains sample logs from a multi-service platform (API + recommendation service + gateway) and walks through debugging a cascading failure using every tool.

**The scenario:** An upstream WebSocket connection drops at 14:02. The API falls back to slow polling, exhausting PostgreSQL connections. The recommendation service loses its vector database. The gateway trips its circuit breaker.

**The walkthrough shows:**

```
Step 1: all_errors                          → 10 errors across 3 services
Step 2: time_range                          → incident spans 14:00-14:05
Step 3: get_errors(level: "error", since:)  → 5 real errors, no warning noise
Step 4: search_logs(context: 2)             → polling fallback caused the DB timeout
Step 5: correlate(value: "req-006")         → full cascade across 3 services
Step 6: trace_ids(field: "sessionId")       → 2 affected user sessions
```

Try it yourself:

```bash
LOG_DIR=./examples/logs mix run --no-halt
# or
docker run --rm -i -v $(pwd)/examples/logs:/tmp/mcp-logs ghcr.io/wolven-tech/mcp-log-server:latest
```

---

## Key Features

### Auto-Detect JSON Structured Logs

Drop in JSON log files (from Pino, structlog, GCP Cloud Logging, etc.) and the server automatically:

- Detects the format (JSON Lines, JSON arrays, or plain text)
- Extracts `severity` from standard fields (`severity`, `level`, `log.level`)
- Maps numeric Pino levels (50 = error, 60 = fatal)
- Uses severity for error detection — **zero false positives** vs regex on plain text

```json
{"severity":"ERROR","message":"Connection refused","timestamp":"2026-03-20T14:02:15Z"}
```

### Time-Based Filtering

Every analysis tool supports `since` and `until` parameters — absolute or relative:

```json
{"name": "get_errors", "arguments": {"file": "api.log", "since": "30m"}}
{"name": "search_logs", "arguments": {"file": "api.log", "pattern": "timeout", "since": "2026-03-20T14:00:00Z", "until": "2026-03-20T14:30:00Z"}}
```

### Cross-Service Correlation

Trace a request, session, or trace ID across every log file in one call:

```json
{"name": "correlate", "arguments": {"value": "req-abc-123", "field": "requestId"}}
```

Returns a unified timeline sorted by timestamp, showing the request's path through gateway, API, worker, and any other service.

### Severity Level Filtering

Control what `get_errors` returns with the `level` parameter:

| Level | Returns |
|-------|---------|
| `fatal` | FATAL, PANIC only |
| `error` | ERROR + FATAL |
| `warn` | WARN + ERROR + FATAL (default) |
| `info` | INFO and above |

Combine with `exclude` to remove known noise:

```json
{"name": "get_errors", "arguments": {"file": "api.log", "level": "error", "exclude": "health.check|retry"}}
```

### Configurable Error Patterns

Customize what patterns trigger error detection via environment variables:

| Variable | Effect |
|----------|--------|
| `LOG_EXTRA_PATTERNS` | Add patterns (merged with defaults) |
| `LOG_ERROR_PATTERNS` | Override error patterns entirely |
| `LOG_WARN_PATTERNS` | Override warn patterns entirely |
| `LOG_FATAL_PATTERNS` | Override fatal patterns entirely |

```bash
LOG_EXTRA_PATTERNS="circuit.breaker|deadline.exceeded" docker run ...
```

---

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `LOG_DIR` | `/tmp/mcp-logs` | Directory containing `.log` files |
| `MAX_LOG_FILE_MB` | `100` | Skip files larger than this (prevents memory issues) |
| `LOG_RETENTION_DAYS` | _(none)_ | Auto-delete logs older than N days on startup |
| `LOG_EXTRA_PATTERNS` | _(none)_ | Additional error patterns (pipe-separated regex) |
| `LOG_ERROR_PATTERNS` | _(none)_ | Override default error patterns |
| `LOG_WARN_PATTERNS` | _(none)_ | Override default warn patterns |
| `LOG_FATAL_PATTERNS` | _(none)_ | Override default fatal patterns |

---

## Architecture

```
Transport (stdio)
    ↓
Protocol (JSON-RPC 2.0, TOON)
    ↓
Server (method routing)
    ↓
Tools (behaviour + 9 self-contained modules)
    ↓
Domain (7 focused modules: FileAccess, LogSearch, ErrorExtractor, ...)
    ↓
Config (runtime patterns via persistent_term)
```

**Adding a new tool** = create one module implementing the `Tool` behaviour + add one line to the tool list. No existing code modified.

See the [Architecture docs](docs/concepts/ARCHITECTURE.md) for the full module breakdown, design decisions, and security model.

---

## Documentation

### Getting Started

| | |
|---|---|
| [Quick Start](docs/getting-started/QUICK_START.md) | Get running in 5 minutes |
| [Examples Walkthrough](examples/README.md) | Debug a cascading failure step-by-step |
| [MCP Client Setup](docs/guides/MCP_CLIENT_SETUP.md) | Configure Cursor, VS Code, and other MCP clients |

### Use Cases

| | |
|---|---|
| [Monorepo Development](docs/guides/USE_CASE_MONOREPO.md) | Multi-service monorepo with per-service log files |
| [Incident Response](docs/guides/USE_CASE_INCIDENT_RESPONSE.md) | Production triage: all_errors → correlate → trace_ids |
| [GCP Cloud Logging](docs/guides/USE_CASE_GCP_LOGS.md) | Working with `gcloud logging read` exports |

### Guides

| | |
|---|---|
| [Log Structuring](docs/guides/LOG_STRUCTURING.md) | Structure your logs for maximum tool accuracy — field mapping, stack-specific configs, quality scorecard |

### Reference

| | |
|---|---|
| [Tool Reference](docs/reference/TOOLS.md) | All 9 tools with parameters, examples, and response formats |
| [TOON Format](docs/concepts/TOON_FORMAT.md) | Token-Oriented Object Notation specification |
| [Architecture](docs/concepts/ARCHITECTURE.md) | Layer design, Tool behaviour, SOLID principles |
| [Contributing](docs/CONTRIBUTING.md) | Development standards and how to add tools |

---

## Security

- **Path traversal protection** — file access restricted to `LOG_DIR`; only basenames accepted
- **Read-only** — no file writes, no command execution, no network access
- **Stdio isolation** — MCP protocol on stdout, logger on stderr (no mixing)
- **File size limits** — files exceeding `MAX_LOG_FILE_MB` are skipped with a warning

---

## License

[MIT](LICENSE)
