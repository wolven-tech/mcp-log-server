<div align="center">

# MCP Log Server

**Token-efficient log analysis tools for LLMs via the Model Context Protocol.**<br>
Claude reads structured answers to specific questions instead of raw log dumps, using ~50% fewer tokens.

[![crates.io](https://img.shields.io/badge/ghcr.io-mcp--log--server-blue?logo=docker&logoColor=white)](https://github.com/wolven-tech/mcp-log-server/pkgs/container/mcp-log-server)
[![CI](https://img.shields.io/github/actions/workflow/status/wolven-tech/mcp-log-server/ci.yml?branch=main&logo=githubactions&logoColor=white&label=CI)](https://github.com/wolven-tech/mcp-log-server/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/wolven-tech/mcp-log-server?color=green)](https://github.com/wolven-tech/mcp-log-server/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue)](LICENSE)
[![MCP compatible](https://img.shields.io/badge/MCP-compatible-purple)](https://modelcontextprotocol.io/)
[![Elixir 1.17+](https://img.shields.io/badge/Elixir-1.17%2B-4B275F?logo=elixir&logoColor=white)](#install)
[![OTP 27+](https://img.shields.io/badge/OTP-27%2B-A90533?logo=erlang&logoColor=white)](#install)

[![Elixir, Erlang, Docker](https://skillicons.dev/icons?i=elixir,erlang,docker)](https://skillicons.dev)

[Install](#install) · [Examples](examples/README.md) · [Tools](docs/reference/TOOLS.md) · [Architecture](docs/concepts/ARCHITECTURE.md) · [Log structuring](docs/guides/LOG_STRUCTURING.md)

</div>

---

LLMs waste tokens on raw log files. A 10 MB log dump burns thousands of tokens on irrelevant INFO lines before reasoning starts. Instead of dumping logs, Claude calls structured tools: list errors, find patterns, correlate across services, trace a request. Responses use ~50% fewer tokens than JSON because they're formatted as TOON (Token-Oriented Object Notation) — pipe-delimited rows, not nested objects.

| Scenario | Before | After |
|---|---|---|
| "Here's my 500-line terminal output" | 2000+ tokens, mostly noise | Claude calls `all_errors` → 10 errors across 3 services → ~100 tokens |
| Correlate a request through services | Manually read each service's log | Claude calls `correlate(field="requestId")` → unified timeline → ~80 tokens |
| Filter errors by severity and time | Paste everything, ask Claude to grep | Claude calls `get_errors(level="error", since="30m")` → ~60 tokens |

**13 tools** organized by workflow: discovery (list, stats), analysis (errors, search), correlation (trace requests), maintenance (sync from cloud storage).

| Category | Tools |
|---|---|
| **Discovery** | `list_logs`, `log_stats`, `time_range`, `source_manifest` |
| **Analysis** | `all_errors`, `get_errors`, `search_logs`, `tail_log`, `aggregate`, `summarize` |
| **Correlation** | `correlate`, `trace_ids` |
| **Maintenance** | `sync_logs` (cloud storage) |

## Install

### Docker (recommended)

```sh
docker pull ghcr.io/wolven-tech/mcp-log-server:latest
```

Add to `.mcp.json`:

```json
{
  "mcpServers": {
    "log-server": {
      "command": "docker",
      "args": ["run", "--rm", "-i", "-v", "./tmp/logs:/tmp/mcp-logs:ro", "ghcr.io/wolven-tech/mcp-log-server:latest"]
    }
  }
}
```

### From source

```sh
git clone https://github.com/wolven-tech/mcp-log-server.git
cd mcp-log-server
mix deps.get
LOG_DIR=/path/to/logs mix run --no-halt
```

## What it does

| Capability | Tool | Example |
|---|---|---|
| **Find errors** | `all_errors` | Aggregate errors across all services, best-first |
| **Filter errors** | `get_errors` | Extract errors with severity, exclusion patterns, time range |
| **Search logs** | `search_logs` | Regex search with context, JSON field targeting, template rollup |
| **Correlate** | `correlate` | Trace a request/session across all services in one timeline |
| **Tail** | `tail_log` | Last N lines with optional filtering and polling cursor |
| **Summarize** | `summarize` | "What changed?" — diff two time windows for new/gone patterns |

**Structured format:** Auto-detects JSON logs (Pino, structlog, GCP), extracts severity from standard fields, parses timestamps, and normalizes output to TOON format.

## How it works

```
Your app → logs to /tmp/mcp-logs/*.log
              ↓
        MCP Log Server (stdio)
              ↓
        Claude / Cursor asks questions
        Server returns structured answers
```

The server reads `.log` files and exposes 13 tools via MCP. Auto-detects format (JSON lines, JSON arrays, plain text), extracts severity from standard fields, correlates entries across files.

Output format is **TOON** — pipe-delimited rows:

```
[severity|timestamp|message|line_number]
ERROR|2026-03-20T14:02:15Z|Connection refused to postgres:5432|42
WARN|2026-03-20T14:02:16Z|Retrying in 5s...|43
```

## Examples

See [examples/README.md](examples/README.md) for a step-by-step walkthrough debugging a cascading failure (WebSocket drop → API fallback → DB exhaustion → circuit breaker trip) across 3 services.

Try it:

```sh
LOG_DIR=./examples/logs mix run --no-halt
```

Then ask Claude to call the tools in order:
1. `all_errors` → find the 10 errors
2. `time_range` → measure the incident window
3. `get_errors(level: "error")` → filter warnings
4. `search_logs(context: 2)` → read around errors
5. `correlate(value: "req-006")` → trace the request
6. `trace_ids` → find affected sessions

## Key features

- **Auto-detect JSON logs** — Pino, structlog, GCP Cloud Logging, etc.; extracts severity from standard fields
- **Cross-service correlation** — Trace a request/session across all log files in one call
- **Time-based filtering** — Every tool supports `since`/`until` (absolute or relative)
- **Template rollup** — Group repeated errors; 10,000 repeats become one row with count
- **Polling cursors** — `tail_log` and `search_logs` return opaque cursor; next call returns only new lines
- **Persistent index** — ETS+DETS incremental index accelerates time-window queries; disable with `LOG_INDEX=off`
- **Streamed sources** — Declare Fly/k8s/journald commands; server tees into rotating files and serves them alongside file logs
- **Honest truncation** — Capped lists marked with `omissions` block; nothing dropped silently

## Configuration

| Variable | Default | Description |
|---|---|---|
| `LOG_DIR` | `/tmp/mcp-logs` | Directory containing `.log` files |
| `MAX_LOG_FILE_MB` | `100` | Skip files larger than this |
| `LOG_RETENTION_DAYS` | _(none)_ | Auto-delete logs older than N days on startup |
| `LOG_SOURCES` | _(none)_ | Streamed commands: `name:cmd=command; ...` |
| `LOG_TS_FORMATS` | _(none)_ | Custom timestamp formats: `glob=format; ...` |
| `LOG_INDEX` | `on` | Set `off` to disable persistent index |

See [full reference](docs/reference/TOOLS.md) for all 13 tools and configuration.

## Limits

- Only one MCP server instance per log directory (no concurrent mutations).
- `sync_logs` mutation is opt-in via `MCP_LOG_SYNC_ENABLED=true`.
- Files exceeding `MAX_LOG_FILE_MB` are skipped with a warning.
- Timestamps that cannot be parsed are never dropped (`since`/`until` fail-open); reported in `unparsed_ts` field.

## License

MIT
