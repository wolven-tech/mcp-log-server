---
title: Architecture
description: Layered architecture design and module breakdown
status: active
audience: [developers]
difficulty: intermediate
created: 2026-03-18
lastModified: 2026-03-20
tags: [architecture, design, elixir, otp]
---

# Architecture

MCP Log Server follows a layered architecture where each layer has a single responsibility and dependencies flow inward. After a SOLID refactoring pass, the codebase separates tool definitions from domain logic and uses a behaviour-based dispatch pattern that makes adding new tools trivial.

---

## Layers

```
┌───────────────────────────────────────────────────────────┐
│                   Transport (stdio)                       │  I/O boundary
├───────────────────────────────────────────────────────────┤
│                   Protocol (JSON-RPC)                     │  Message parsing & encoding
├───────────────────────────────────────────────────────────┤
│                   Server (routing)                        │  Method dispatch
├───────────────────────────────────────────────────────────┤
│          Tools (behaviour + 9 tool modules)               │  Argument parsing & formatting
│  ┌─────────┬──────────┬────────────┬────────────────┐     │
│  │Registry │Dispatcher│  Helpers   │ Tool behaviour  │     │
│  └─────────┴──────────┴────────────┴────────────────┘     │
├───────────────────────────────────────────────────────────┤
│          Domain (7 focused modules + facade)              │  Pure business logic
│  ┌──────────┬────────┬────────┬───────┬──────────────┐    │
│  │FileAccess│LogTail │LogSearch│Errors │StatsCollector│    │
│  ├──────────┼────────┴────────┼───────┴──────────────┤    │
│  │Correlator│ TimeRangeCalc   │  FormatDispatch       │    │
│  └──────────┴─────────────────┴───────────────────────┘    │
├───────────────────────────────────────────────────────────┤
│                   Config (Patterns)                       │  persistent_term cache
└───────────────────────────────────────────────────────────┘
```

### Transport Layer

**Module**: `McpLogServer.Transport.Stdio`

GenServer that owns the stdin/stdout I/O. Reads JSON lines from stdin, delegates to the Server, and writes responses to stdout. This is the only module that touches I/O streams.

### Protocol Layer

**Modules**: `McpLogServer.Protocol.JsonRpc`, `McpLogServer.Protocol.ToonEncoder`, `McpLogServer.Protocol.ResponseFormatter`

Pure functions for parsing JSON-RPC 2.0 requests and building responses. The TOON encoder converts tabular data into the token-optimized format. `ResponseFormatter` centralises all tool output formatting (shape-based dispatch for entries, tail, search results, stats, correlation timelines, and multi-file errors), keeping that concern out of individual tool modules.

### Server Layer

**Module**: `McpLogServer.Server`

Routes incoming MCP methods (`initialize`, `tools/list`, `tools/call`) to the appropriate handlers. For `tools/call`, it delegates to the Dispatcher with the tool name, arguments, and log directory. Wires transport, protocol, and tools together.

### Tools Layer

**Modules**: `McpLogServer.Tools.Tool` (behaviour), `McpLogServer.Tools.Registry`, `McpLogServer.Tools.Dispatcher`, `McpLogServer.Tools.Helpers`, plus 9 tool modules.

This layer is structured around the `Tool` behaviour, which defines four callbacks:

```elixir
@callback name() :: String.t()
@callback description() :: String.t()
@callback schema() :: map()
@callback execute(args :: map(), log_dir :: String.t()) :: {:ok, String.t()} | {:error, String.t()}
```

Each tool is a standalone module that implements this behaviour. The tool modules are:

| Module | Tool name | Domain module called |
|---|---|---|
| `ListLogs` | `list_logs` | `FileAccess` |
| `TailLog` | `tail_log` | `LogTail` |
| `SearchLogs` | `search_logs` | `LogSearch` |
| `GetErrors` | `get_errors` | `ErrorExtractor` |
| `LogStats` | `log_stats` | `StatsCollector` |
| `TimeRange` | `time_range` | `TimeRangeCalc` |
| `CorrelateTool` | `correlate` | `Correlator` |
| `TraceIds` | `trace_ids` | `Correlator` |
| `AllErrors` | `all_errors` | `ErrorExtractor` + `FileAccess` |

**Registry** derives its tool list and lookup map at compile time from a module attribute list. It builds the `tools/list` response by calling each module's `name/0`, `description/0`, and `schema/0` callbacks. A compile-time `@tool_map` provides O(1) lookup by name.

**Dispatcher** is a 10-line module. It looks up the tool module via `Registry.lookup/1` and calls `mod.execute(args, log_dir)`. No case statement, no conditional logic.

**Helpers** provides shared argument-parsing utilities (`to_pos_int/2`, `maybe_add_time_opts/2`, `parse_time_opt/1`) so that tool modules stay focused on orchestration rather than input coercion.

#### Adding a new tool

1. Create a new module under `lib/mcp_log_server/tools/` that implements the `Tool` behaviour (define `name/0`, `description/0`, `schema/0`, `execute/2`).
2. Add the module to the `@tools` list in `Registry`.

That is all. No dispatcher changes, no server changes, no case branches to update.

### Domain Layer

**Modules**: `FileAccess`, `LogTail`, `LogSearch`, `ErrorExtractor`, `StatsCollector`, `TimeRangeCalc`, `Correlator`, `FormatDispatch`, plus `LogReader` (facade).

Each domain module has a single, focused responsibility:

- **FileAccess** -- File-system operations: listing `.log` files, resolving paths with traversal protection, reading files into indexed lines, reading raw lines. Every domain module that needs file access goes through here.
- **FormatDispatch** -- Eliminates duplicated format-detection case switches. Takes a path and two callbacks (one for JSON, one for plain text), detects the format, and routes to the right callback. Used by `ErrorExtractor` and `StatsCollector`.
- **LogTail** -- Returns the last N lines of a log file with optional time filtering.
- **LogSearch** -- Searches log files by regex with support for JSON field-level search, context lines, and time filtering.
- **ErrorExtractor** -- Extracts error/warning/fatal entries from both plain-text and JSON log files. Supports severity filtering, exclusion patterns, and time ranges.
- **StatsCollector** -- Computes per-file statistics (line count, error/warn/fatal counts, file size) for both plain-text and JSON formats.
- **TimeRangeCalc** -- Determines the time span of a log file by sampling the first and last 10 lines.
- **Correlator** -- Cross-service log correlation. Searches for a value (e.g., trace ID, session ID) across all log files and returns a unified timeline sorted by timestamp. Also provides `extract_trace_ids/3` for discovering unique field values.
- **LogReader** -- A thin delegation facade that re-exports the public API of the focused domain modules under a single namespace. Exists for backward compatibility; new code should call the focused modules directly.

Domain modules have no knowledge of MCP, JSON-RPC, or transport concerns. They take paths and parameters and return data structures.

### Config Layer

**Module**: `McpLogServer.Config.Patterns`

Manages compiled regex patterns for log-level detection across the severity hierarchy: `trace(0) < debug(1) < info(2) < warn(3) < error(4) < fatal(5)`.

Configuration flows through three stages:

1. **Environment variables** (`LOG_FATAL_PATTERNS`, `LOG_ERROR_PATTERNS`, `LOG_WARN_PATTERNS`, `LOG_EXTRA_PATTERNS`) are read at startup.
2. **`config/runtime.exs`** maps those env vars into `Application` environment under the `:mcp_log_server` app.
3. **`Patterns.init/0`** (called from `Application.start/2`) compiles the pattern strings into regexes and stores them in `:persistent_term` for zero-copy, zero-overhead reads from any process.

Downstream modules (`ErrorExtractor`, `StatsCollector`, `Correlator`) call `Patterns.detect_level/1` and `Patterns.matches_level?/2` without any runtime cost beyond the regex match itself.

---

## OTP Supervision

```
McpLogServer.Application (supervisor, one_for_one)
├── Patterns.init()          [called eagerly before tree starts]
└── McpLogServer.Transport.Stdio (GenServer)
    └── read loop (linked Task)
```

The application reads `LOG_DIR` from the environment, ensures the directory exists, initialises compiled patterns, and starts the Stdio transport. The transport starts a blocking read loop in a linked Task.

---

## Security Model

- **Path traversal protection**: `FileAccess.resolve/2` validates that file arguments are basenames only -- no `/`, `..`, or absolute paths accepted.
- **Read-only**: No file writes, no command execution.
- **Isolated I/O**: Logger outputs to stderr; MCP protocol uses stdout. This prevents log messages from being interpreted as JSON-RPC responses.

---

## Design Decisions

**Why Elixir?** OTP's supervision tree handles crashes gracefully. If a tool call fails, the server stays alive. The BEAM VM is also excellent for concurrent I/O -- relevant when streaming large log files.

**Why stdio over HTTP?** MCP's primary transport is stdio. It is simpler, requires no port management, and works naturally with Docker containers.

**Why TOON instead of just JSON?** LLM context windows are expensive. For a development workflow with dozens of log queries per session, 50% token savings compounds meaningfully.

**Why a Tool behaviour?** Before the refactoring, the Dispatcher contained a growing case statement that mixed argument parsing, domain calls, and response formatting for every tool. The behaviour pattern inverts this: each tool module is self-contained, and the Dispatcher is reduced to a two-line lookup-and-call. Adding a tool requires zero changes to existing code (Open/Closed Principle). The Registry derives its definitions at compile time from the module list, so there is no duplication between schema declaration and dispatch routing.

**Why persistent_term for Patterns?** Log-level patterns are read on every line of every file during error extraction and stats collection. `Application.get_env` copies the value on each call. `:persistent_term` provides a direct reference with no copying and no ETS lookup, making the hot path as fast as a module attribute while remaining runtime-configurable.

**Why a delegation facade (LogReader)?** The original monolithic `LogReader` module was the public API for the domain layer. After decomposition into focused modules, `LogReader` was retained as a thin delegation facade so that any external consumers (or tests) referencing the old API continue to work. New tool modules call the focused domain modules directly.

---

**[Back to Documentation Index](../README.md)**
