---
title: Architecture
description: Layered architecture design and module breakdown
status: active
audience: [developers]
difficulty: intermediate
created: 2026-03-18
lastModified: 2026-03-18
tags: [architecture, design, elixir, otp]
---

# Architecture

MCP Log Server follows a layered architecture where each layer has a single responsibility and dependencies flow inward.

---

## Layers

```
┌─────────────────────────────────┐
│         Transport (stdio)       │  I/O boundary
├─────────────────────────────────┤
│         Protocol (JSON-RPC)     │  Message parsing & encoding
├─────────────────────────────────┤
│         Server (routing)        │  Method dispatch
├─────────────────────────────────┤
│    Tools (registry + dispatch)  │  Application logic
├─────────────────────────────────┤
│      Domain (LogReader)         │  Pure business logic
└─────────────────────────────────┘
```

### Transport Layer

**Module**: `McpLogServer.Transport.Stdio`

GenServer that owns the stdin/stdout I/O. Reads JSON lines from stdin, delegates to the Server, and writes responses to stdout. This is the only module that touches I/O streams.

### Protocol Layer

**Modules**: `McpLogServer.Protocol.JsonRpc`, `McpLogServer.Protocol.ToonEncoder`

Pure functions for parsing JSON-RPC 2.0 requests and building responses. The TOON encoder converts tabular data into the token-optimized format. No state, no side effects.

### Server Layer

**Module**: `McpLogServer.Server`

Routes incoming MCP methods (`initialize`, `tools/list`, `tools/call`) to the appropriate handlers. Wires transport, protocol, and tools together.

### Tools Layer

**Modules**: `McpLogServer.Tools.Registry`, `McpLogServer.Tools.Dispatcher`

Registry defines tool schemas (names, descriptions, input schemas). Dispatcher orchestrates tool execution: extracts arguments, calls domain functions, formats responses.

### Domain Layer

**Module**: `McpLogServer.Domain.LogReader`

Pure functions for log file operations: listing, tailing, searching, error extraction, statistics. No knowledge of MCP, JSON-RPC, or transport. Takes paths and parameters, returns data structures.

## OTP Supervision

```
McpLogServer.Application (supervisor)
└── McpLogServer.Transport.Stdio (GenServer)
```

The application reads `LOG_DIR` from the environment and starts the Stdio transport. The transport starts a blocking read loop in a linked Task.

## Security Model

- **Path traversal protection**: `LogReader.resolve/2` validates that file arguments are basenames only — no `/`, `..`, or absolute paths accepted
- **Read-only**: No file writes, no command execution
- **Isolated I/O**: Logger outputs to stderr; MCP protocol uses stdout. This prevents log messages from being interpreted as JSON-RPC responses.

## Design Decisions

**Why Elixir?** OTP's supervision tree handles crashes gracefully. If a tool call fails, the server stays alive. The BEAM VM is also excellent for concurrent I/O — relevant when streaming large log files.

**Why stdio over HTTP?** MCP's primary transport is stdio. It's simpler, requires no port management, and works naturally with Docker containers.

**Why TOON instead of just JSON?** LLM context windows are expensive. For a development workflow with dozens of log queries per session, 50% token savings compounds meaningfully.

---

**[Back to Documentation Index](../README.md)**
