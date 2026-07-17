---
title: Architecture
description: Clean architecture layers, ports, and module breakdown
status: active
audience: [developers]
difficulty: intermediate
created: 2026-03-18
lastModified: 2026-07-17
tags: [architecture, design, elixir, otp, clean-architecture]
---

# Architecture

MCP Log Server follows an explicit clean architecture: a pure domain core,
an application layer of use-cases, infrastructure adapters behind ports
(behaviours), and a thin MCP interface layer.

**The dependency rule: dependencies point inward.**

```
interface (tools, server, protocol, transport)
    │
    ▼
application (use_cases)  ──▶  ports (behaviours)
    │                              ▲
    ▼                              │ implements
domain (pure functions)       infrastructure (adapters)
```

- **Domain** imports nothing outside the domain (plus the compiled-pattern
  data in `Config.Patterns`). No `File.*`, no `System.get_env`, no
  `Application.get_env` — pure functions over values and enumerables.
- **Use-cases** import domain + ports only. Adapters are resolved through
  configuration (`McpLogServer.UseCases.Deps`), never named directly.
- **Tools** import use-cases + protocol only: validate params → call
  use-case → format response.
- **Infrastructure** implements the ports; nothing imports it except the
  composition root (`Application`/`Server`) and the port wiring in
  `config/config.exs`.

---

## Layers

```
┌───────────────────────────────────────────────────────────┐
│                Transport (stdio)                          │  I/O boundary
├───────────────────────────────────────────────────────────┤
│                Protocol (JSON-RPC, TOON)                  │  Message parsing & encoding
├───────────────────────────────────────────────────────────┤
│                Server (routing)                           │  Method dispatch
├───────────────────────────────────────────────────────────┤
│         Tools (behaviour + 10 thin tool modules)          │  Param validation & formatting
├───────────────────────────────────────────────────────────┤
│         Use-cases (application layer)                     │  Orchestration over ports
│  ListLogs · TailLog · SearchLogs · GetErrors ·            │
│  CollectStats · TimeRange · Correlate · TraceIds ·        │
│  AllErrors · SyncLogs · LogReader (facade) · Deps         │
├──────────────────────────┬────────────────────────────────┤
│  Ports (behaviours)      │  Infrastructure (adapters)     │
│  LogSource               │  FileLogSource                 │
│  Config                  │  EnvConfig                     │
│  LogSync                 │  CloudSync · FormatCache       │
├──────────────────────────┴────────────────────────────────┤
│         Domain (pure functions only)                      │
│  TimestampParser · TimeFilter · JsonLogParser ·           │
│  FormatDetector · ErrorExtractor · LogSearch ·            │
│  StatsCollector · TimeRangeCalc · Correlator              │
├───────────────────────────────────────────────────────────┤
│         Config (Patterns — compiled once, read as data)   │
└───────────────────────────────────────────────────────────┘
```

### Transport Layer

**Module**: `McpLogServer.Transport.Stdio`

GenServer that owns the stdin/stdout I/O. Reads JSON lines from stdin,
delegates to the Server, and writes responses to stdout. This is the only
module that touches I/O streams.

### Protocol Layer

**Modules**: `McpLogServer.Protocol.JsonRpc`, `McpLogServer.Protocol.ToonEncoder`, `McpLogServer.Protocol.ResponseFormatter`

Pure functions for parsing JSON-RPC 2.0 requests and building responses. The
TOON encoder converts tabular data into the token-optimized format.
`ResponseFormatter` centralises all tool output formatting, keeping that
concern out of individual tool modules.

### Server Layer

**Module**: `McpLogServer.Server`

Routes incoming MCP methods (`initialize`, `tools/list`, `tools/call`) to the
appropriate handlers. For `tools/call`, it delegates to the Dispatcher with
the tool name, arguments, and log directory.

### Tools Layer (interface)

**Modules**: `McpLogServer.Tools.Tool` (behaviour), `Registry`, `Dispatcher`, `Helpers`, plus 10 tool modules.

Each tool implements the `Tool` behaviour (`name/0`, `description/0`,
`schema/0`, `execute/2`) and is deliberately thin: it coerces and validates
MCP arguments, calls exactly one use-case, and formats the result via
`ResponseFormatter`. No business logic lives here.

| Module | Tool name | Use-case called |
|---|---|---|
| `ListLogs` | `list_logs` | `UseCases.ListLogs` |
| `TailLog` | `tail_log` | `UseCases.TailLog` |
| `SearchLogs` | `search_logs` | `UseCases.SearchLogs` |
| `GetErrors` | `get_errors` | `UseCases.GetErrors` |
| `LogStats` | `log_stats` | `UseCases.CollectStats` |
| `TimeRange` | `time_range` | `UseCases.TimeRange` |
| `CorrelateTool` | `correlate` | `UseCases.Correlate` |
| `TraceIds` | `trace_ids` | `UseCases.TraceIds` |
| `AllErrors` | `all_errors` | `UseCases.AllErrors` |
| `SyncLogs` | `sync_logs` | `UseCases.SyncLogs` |

**Registry** derives its tool list and lookup map at compile time.
**Dispatcher** looks up the tool module and calls `mod.execute(args, log_dir)`.

#### Adding a new tool

1. Add a use-case module under `lib/mcp_log_server/use_cases/` that
   orchestrates domain functions over the ports.
2. Create a thin tool module under `lib/mcp_log_server/tools/` implementing
   the `Tool` behaviour.
3. Add the module to the `@tools` list in `Registry`.

### Application Layer (use-cases)

**Modules**: one per tool capability under `lib/mcp_log_server/use_cases/`.

A use-case resolves a log name through the `LogSource` port, obtains line or
entry streams from the adapter, and hands them to pure domain functions.
`UseCases.Deps` resolves the port implementation from application config, so
tests inject fakes by passing `:source`, `:config`, or `:sync` in `opts` —
no mocking library needed.

`UseCases.LogReader` is a delegation facade that preserves the historical
`LogReader` API for existing callers and tests; new code calls the focused
use-cases directly.

### Ports

**Modules**: `McpLogServer.Ports.LogSource`, `McpLogServer.Ports.Config`, `McpLogServer.Ports.LogSync`

Behaviours that define what the application layer needs from the outside
world, deliberately shaped for the roadmap (issues #6/#7):

- **LogSource** — enumerate logs and stream their lines behind an opaque
  handle. Descriptors carry `name`, `path`, `size_bytes`, `modified`, and
  `live?` so future adapters (remote streamed sources, a persistent indexed
  source, multi-instance rollup) extend the contract without breaking it.
  `LogSource.stream_entries/3` composes any adapter's line access with the
  pure JSON parser.
- **Config** — the single boundary for env-derived settings (LOG_DIR,
  MAX_LOG_FILE_MB, LOG_RETENTION_DAYS), resolved in one place and passed
  around as data.
- **LogSync** — pulling logs from an external store into the local log
  directory.
- **LogIndex** — the incremental persistent index (issue #7 P7). Two
  queries: `seek/3` (deepest byte offset a `since`-bounded scan may start
  at) and `field_stats/1` (per-file JSON field-key knowledge for absence
  proofs). The contract is honesty-first: `:miss` on ANY doubt, and
  callers must treat `:miss` as "do the linear scan" — indexed and
  unindexed paths return identical results, only speed differs.

### Infrastructure Layer

**Modules**: `FileLogSource`, `EnvConfig`, `FormatCache`, `CloudSync`

- **FileLogSource** — `LogSource` adapter over local files in LOG_DIR:
  listing, path resolution with traversal protection, the MAX_LOG_FILE_MB
  read guardrail, lazy line streaming, and retention cleanup. Its handle is
  an absolute path; local files report `live?: false`.
- **FormatCache** — samples a file's first lines/chunk, delegates
  classification to the pure `Domain.FormatDetector`, and caches results per
  `{path, mtime}` in ETS.
- **EnvConfig** — `Config` adapter reading the application environment
  (populated from OS env vars by `config/runtime.exs`) at call time.
- **CloudSync** — `LogSync` adapter shelling out to gsutil/aws/az.
- **LogIndex** — `Ports.LogIndex` adapter: ETS (the lock-free read path —
  queries never call the GenServer) + DETS under `LOG_DIR/.index/`
  (persistence, schema-versioned, self-healing on corruption). Builds run
  serialized in one background process, triggered lazily by query misses
  and incrementally by the `SourceWorker` ingest hook; append-only growth
  extends an index, anything else (rotation, truncation, signature
  mismatch) drops and rebuilds it. See
  `docs/decisions/001-index-storage.md` for why ETS+DETS beat SQLite
  here (escript-safe, zero NIFs, cache-not-truth semantics).
- **NoIndex** — the always-`:miss` adapter: the `LOG_INDEX=off` mode and
  the control group for the index oracle tests.

Port wiring lives in `config/config.exs`; the composition root
(`McpLogServer.Application`) is the only other place infrastructure modules
are named.

### Domain Layer

**Modules**: `TimestampParser`, `TimeFilter`, `JsonLogParser`, `FormatDetector`, `ErrorExtractor`, `LogSearch`, `StatsCollector`, `TimeRangeCalc`, `Correlator`

Pure functions only — no file access, no environment reads. Modules that
process log content operate on enumerables (`{line, index}` tuples or
`{enriched_json_entry, index}` tuples) supplied by the caller, which keeps
them trivially testable with plain lists and lazily composable with adapter
streams:

- **TimestampParser** — extracts timestamps from plain-text lines
  (ISO 8601, syslog, CLF, ...) and parses relative shorthands (`"2h"`).
- **TimeFilter** — time-range predicate for lines and JSON entries.
  Lines without parseable timestamps are included (fail-open policy).
- **JsonLogParser** — parses/enriches JSON log entries (`_severity`,
  `_message`, `_timestamp`) from strings or line streams.
- **FormatDetector** — pure classification of sampled content as
  `:plain` / `:json_lines` / `:json_array`.
- **ErrorExtractor** — severity/exclusion/time filtering over line or
  entry streams.
- **LogSearch** — regex matching with context lines and JSON field search.
- **StatsCollector** — severity counting over line or entry streams.
- **TimeRangeCalc** — single-pass head/tail sampling and span computation.
- **Correlator** — correlation matching, timeline building/sorting, field
  value extraction and aggregation.
- **SparseIndex** — pure construction/querying of the per-file index:
  sparse checkpoints (`{byte_offset, lines, max_ts, unparsed}` in BOTH
  line-regex and JSON-entry timestamp semantics — a seek is only sound in
  the semantics of the scan it replaces), field-key `present`/`opaque`
  path sets for absence proofs, and the seek soundness rule (skip a
  prefix only when every timestamp in it parsed and lies strictly before
  `since` — one fail-open line disables the seek).
- **WindowDiff** — pure window-vs-baseline aggregation behind `summarize`:
  template diff (new/gone), error rates, per-source volume. Lines without
  a parseable timestamp fold into BOTH ranges so they can never fabricate
  a diff row.

### Config Layer

**Module**: `McpLogServer.Config.Patterns`

Manages compiled regex patterns for log-level detection across the severity
hierarchy: `trace(0) < debug(1) < info(2) < warn(3) < error(4) < fatal(5)`.

Configuration flows through three stages:

1. **Environment variables** (`LOG_FATAL_PATTERNS`, `LOG_ERROR_PATTERNS`,
   `LOG_WARN_PATTERNS`, `LOG_EXTRA_PATTERNS`) are read at startup.
2. **`config/runtime.exs`** maps those env vars into `Application`
   environment under the `:mcp_log_server` app.
3. **`Patterns.init/0`** (called from `Application.start/2`) compiles the
   pattern strings into regexes and stores them in `:persistent_term` for
   zero-copy reads.

Domain modules read the compiled patterns as data via `Patterns.detect_level/1`
and friends; this is the one sanctioned crossing between domain logic and
configuration, because after `init/0` the patterns are immutable values, not
environment reads.

---

## OTP Supervision

```
McpLogServer.Application (supervisor, one_for_one)
├── Patterns.init()          [called eagerly before tree starts]
├── FileLogSource.cleanup_old_logs()  [startup retention sweep]
└── McpLogServer.Transport.Stdio (GenServer)
    └── read loop (linked Task)
```

The application reads `LOG_DIR` through `EnvConfig`, ensures the directory
exists, initialises compiled patterns, runs retention cleanup, and starts the
Stdio transport.

---

## Security Model

- **Path traversal protection**: `FileLogSource.resolve/2` validates that
  file arguments are basenames only — no `/`, `..`, or absolute paths.
- **Read-size guardrail**: `FileLogSource.resolve_readable/2` enforces
  `MAX_LOG_FILE_MB` for content-loading tools; streaming stats are exempt.
- **Read-only**: No file writes (except `sync_logs`, which only writes into
  LOG_DIR), no arbitrary command execution.
- **Isolated I/O**: Logger outputs to stderr; MCP protocol uses stdout.

---

## Design Decisions

**Why explicit ports?** The roadmap (issues #6 and #7) adds remote streamed
sources, multi-instance rollup, cursors, and a persistent index. Each of
those is an adapter or use-case behind the seams defined here: a remote
source implements `LogSource`, an index-backed source implements `LogSource`,
new tool capabilities become use-cases. If the boundaries were implicit,
every one of those slices would need invasive edits; with ports, they plug in.

**Why enumerable-based domain functions?** Passing streams instead of paths
makes the domain pure without sacrificing constant-memory processing: the
adapter's lazy `File.stream!` composes directly with domain `Stream`
pipelines. Tests feed plain lists; production feeds file streams; a future
remote adapter feeds socket-backed streams — same domain code.

**Why resolve adapters via config instead of default arguments?** A default
argument naming `FileLogSource` inside a use-case would make the application
layer depend on infrastructure. `UseCases.Deps` reads the wiring from
application config (set in `config/config.exs`), keeping the dependency rule
intact while letting tests override per call via `opts`.

**Why Elixir?** OTP's supervision tree handles crashes gracefully. If a tool
call fails, the server stays alive. The BEAM VM is also excellent for
concurrent I/O — relevant when streaming large log files.

**Why stdio over HTTP?** MCP's primary transport is stdio. It is simpler,
requires no port management, and works naturally with Docker containers.

**Why TOON instead of just JSON?** LLM context windows are expensive. For a
development workflow with dozens of log queries per session, 50% token
savings compounds meaningfully.

**Why a Tool behaviour?** Each tool module is self-contained and the
Dispatcher is a two-line lookup-and-call. Adding a tool requires zero changes
to existing code (Open/Closed Principle).

**Why ETS+DETS for the index, not SQLite?** The project ships as an escript
and `exqlite` is a NIF — escripts cannot load it, so SQLite would disable
the index in the primary packaging. The index is also a CACHE (sparse
checkpoints + key sets, ~KB per file), so DETS's weaker durability costs
nothing: corruption → delete → rebuild from the logs, which stay the only
source of truth. Full analysis in `docs/decisions/001-index-storage.md`.

**Why does the index never block a query?** Queries read a
`read_concurrency` ETS table directly and take whatever state exists;
builds are casts processed by one background process. A slow build can
delay another build, never a tool call — the request path's worst case is
exactly the pre-index linear scan, flagged `index_used: false`.

**Why persistent_term for Patterns?** Log-level patterns are read on every
line of every file during error extraction and stats collection.
`:persistent_term` provides a direct reference with no copying and no ETS
lookup, making the hot path as fast as a module attribute while remaining
runtime-configurable.

**Why keep a LogReader facade?** The historical `LogReader` module was the
public API of the old domain layer. `UseCases.LogReader` preserves that
surface for existing callers and tests while the focused use-cases are the
API for new code.

---

**[Back to Documentation Index](../README.md)**
