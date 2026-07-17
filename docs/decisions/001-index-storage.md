---
title: "ADR 001: Index storage — ETS + DETS over SQLite"
status: accepted
date: 2026-07-17
---

# ADR 001: Index storage — ETS + DETS, not SQLite (`exqlite`)

## Context

Issue #7 P7 calls for an incremental persistent index so `since`/`until`
seeks and JSON field queries stop being linear scans over multi-hundred-MB
log directories. The issue suggests either ETS+DETS or SQLite via
`exqlite`. The index must:

* coexist with live streamed sources (slice 003) appending continuously;
* never block the MCP request path;
* survive restarts (persistent), yet remain a **cache** — stale, missing,
  or corrupt index must transparently fall back to the linear scan;
* work in every distribution mode the project ships: `mix run`, OTP
  release, **and escript**.

## Options considered

### SQLite via `exqlite`

Pros: real B-tree indexes, SQL range queries, single well-understood file,
crash-safe WAL, concurrent readers.

Cons that decided against it:

* **NIF in an escript.** `exqlite` is a NIF. Escripts do not ship dep
  `priv/` directories, so the `.so` cannot be loaded from a plain escript —
  the project's primary distribution today (`mix.exs` builds
  `main_module: McpLogServer.CLI`). We would have to gate indexing on
  release mode and document a degraded escript, i.e. the flagship feature
  would be off in the flagship packaging.
* **First native dependency.** The project is currently pure Elixir
  (`jason` only). A NIF adds per-platform build requirements (cc, make,
  SQLite amalgamation) to every install path, Docker image, and CI matrix.
* **Oversized for the workload.** The index is a *sparse* timestamp →
  byte-offset map (one checkpoint per N lines, ~500 checkpoints for a
  500k-line file) plus per-file field-key sets. That is kilobytes per file
  — nowhere near needing a B-tree engine.

### ETS + DETS (chosen)

* **Zero new dependencies, zero NIFs.** Pure OTP: works identically in
  `mix test`, releases, and escripts. The escript risk named in issue #7
  evaporates instead of being mitigated.
* **Concurrent readers during ingest for free.** Queries read a named ETS
  table (`read_concurrency: true`) directly — no GenServer call, no lock
  shared with the writer. The owning `LogIndex` process is the only writer;
  DETS is only touched by that process for persistence.
* **Crash recovery is acceptable *because the index is a cache*.** DETS
  auto-repairs on unclean shutdown; if repair fails we delete the file and
  rebuild from the logs — the logs are always the source of truth, so
  losing the index costs a rebuild, never data. (This is exactly why
  SQLite's stronger durability buys nothing here.)
* **Size limits are irrelevant at this design.** DETS caps at 2 GB per
  file. The sparse index stores ~100 bytes per checkpoint and one
  field-key set per file: a 1 GB LOG_DIR indexes to well under 1 MB.
  If the index ever grew toward the limit, the schema-version bump +
  rebuild path (already required for corruption healing) is the migration
  path.

## Decision

`McpLogServer.Infrastructure.LogIndex` — a GenServer owning:

* a **named ETS table** (protected, `read_concurrency: true`): the query
  path. `seek/2` and `field_stats/1` read it from the caller's process and
  return `:miss` on any doubt (missing table, missing entry, stat/sig
  mismatch, ref-sensitive timestamps with a changed file).
* a **DETS table** under `LOG_DIR/.index/log_index.dets`: persistence.
  Loaded into ETS at boot (pruning entries for files that no longer
  exist), written through on every (re)build. A stored schema version
  guards format changes: mismatch → `delete_all_objects` and lazy rebuild.
  Unopenable/corrupt file → delete, recreate; if even that fails the index
  runs memory-only. `init/1` cannot crash the server.

Index contents per file (absolute path key):

* sparse checkpoints every N lines: `{byte_offset, lines, max_ts, unparsed}`
  in **two timestamp semantics** (line-regex based for `tail_log`/
  `search_logs`, JSON-entry based for `aggregate`), because the two scan
  paths parse timestamps differently and a seek is only sound when it uses
  the same semantics as the scan it replaces;
* per-file JSON field-key sets (`present` / `opaque` paths, capped) plus
  `json_lines`/`non_json` totals, so `aggregate` can *prove* field absence
  without scanning;
* identity: size, mtime, and signatures over BOTH ends of the indexed
  byte range (the cursor-style head guard alone would validate a rewrite
  whose first bytes coincide with the old file). Rotation/truncation/
  regression → entries dropped, background rebuild, current query
  linear-scans with `index_used: false`.

A seek is only returned when the skipped prefix provably contains **zero
unparsed timestamps** and its max timestamp is strictly before `since` —
otherwise fail-open lines (slice 002's honesty rule) would be silently
dropped, recreating the exact trust failure P0/P3 eliminated. Files whose
timestamps resolve against the file mtime (time-only dev formats) are
marked `ref_sensitive` and only seekable while the file is byte-identical
to what was indexed.

## Consequences

* No new dependency; escript keeps full indexing.
* Query fast path is an ETS lookup + `File.stat` + 256-byte pread —
  microseconds, no writer contention.
* Rebuilds are serialized in one process; a huge build delays other
  *builds*, never queries (they take whatever index state exists).
* DETS 2 GB cap accepted; revisit (schema bump) if per-file metadata ever
  grows beyond sparse checkpoints and key sets.
