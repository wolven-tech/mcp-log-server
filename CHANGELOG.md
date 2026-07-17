# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] - 2026-07-17

### Added

- **New tools** (registry now exposes 12): `aggregate` (JSON-field presence
  proof, value histogram, or count across one or all files) and `summarize`
  ("what changed?" — diff a time window against the equal-length window before
  it: new/gone message templates, error-rate delta, volume delta per source).
- **Template rollup**: `rollup: true` on `search_logs` and `all_errors`
  collapses repeated lines into message templates with counts and
  `instances_seen`.
- **Anchor mode on `correlate`**: correlate around a symptom regex instead of
  an id — every match becomes a time anchor with a `±window`
  (symmetric or `before`/`after`), overlapping windows merged into sections.
- **Polling cursors**: `tail_log` and `search_logs` return an opaque `cursor`;
  pass it back to receive only lines appended since the previous call
  (`cursor_reset: true` after rotation/truncation).
- **Persistent index**: incremental ETS+DETS index under `LOG_DIR/.index/`
  accelerating time-window and severity scans. Pure cache — results are
  identical without it, every response reports `index_used`, and
  `LOG_INDEX=off` disables it (see `docs/decisions/001-index-storage.md`).
- **Streamed source ingestion**: `LOG_SOURCES` declares commands
  (`flyctl logs`, `kubectl logs -f`, ...) that are teed into rotating files
  under `LOG_DIR` by supervised workers with exponential-backoff respawn;
  `LOG_SOURCE_ROTATE_MB` and `LOG_SOURCE_ROTATIONS` control rotation.
- **Declared timestamp formats**: `LOG_TS_FORMATS` maps file globs to
  timestamp formats (strftime-style, `epoch_ms`, ...) when auto-detection
  is not enough.
- **Dev-server timestamp parsing**: bare `HH:MM:SS` prefixes, `[vite]`-style
  stamps, `AM`/`PM`, and ANSI color codes are handled; time-only stamps are
  dated from file mtime.
- **Honesty fields**: uniform `omissions` truncation markers on every capped
  list, `unparsed_ts` counters on time-filtered results (fail-open policy:
  unparseable timestamps never exclude a line), and sampled
  `ts_parse_ratio` on `log_stats`/`time_range`.

### Changed

- **Clean architecture refactor**: explicit `ports/` behaviours (`LogSource`,
  `LogIndex`, `LogSync`, `Config`), `use_cases/` orchestration modules (one
  per tool capability), a pure `domain/` layer, `infrastructure/` adapters,
  and thin `tools/` modules that validate arguments and call exactly one
  use-case.
- Documentation synced across README, GitHub Pages landing, quick start,
  architecture, and tool reference (including the previously undocumented
  `sync_logs`).

## [0.3.0] - 2026-03-21

### Added

- Streaming NDJSON parser, `MAX_LOG_FILE_MB` file-size guardrail, and the
  `sync_logs` cloud-sync tool (`gs://`, `s3://`, `az://`).

## [0.2.0] - 2026-03-21

### Added

- 9 analysis tools with JSON structured-log support (severity fields, numeric
  Pino levels), time-based filtering (`since`/`until`, absolute or relative),
  and cross-service correlation by request/session/trace id.
- Configurable error patterns via `LOG_*_PATTERNS`, setup script,
  SOLID refactoring, expanded documentation.

## [0.1.0] - 2026-03-20

### Added

- Initial release: MCP log server over stdio (JSON-RPC 2.0) with TOON
  (Token-Oriented Object Notation) output, ~50% token savings over JSON.
- Docker image (GHCR), CI and release workflows, documentation site.
