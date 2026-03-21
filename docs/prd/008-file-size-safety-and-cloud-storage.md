# PRD-008: File Size Safety and Cloud Storage

**Status:** Proposal
**Priority:** p1
**Depends on:** PRD-007 (tech debt fixes for memory safety)

---

## Problem

The MCP log server has no guardrails for large files and no native cloud storage support. This creates two risks:

### 1. Large files crash the server

Several code paths load entire files into memory:
- `JsonLogParser.parse_entries/2` calls `File.read/1` — a 500MB JSON log file will OOM
- `TimeRangeCalc` reads all lines to get first/last 10
- `Correlator.extract_trace_ids/3` calls `parse_entries` per file across ALL log files

Even after PRD-007 streaming fixes, there is no upper bound. A user pointing `LOG_DIR` at `/var/log` or a runaway application producing multi-GB logs will cause silent failures or crashes.

### 2. No archival or cloud storage story

Logs accumulate in `LOG_DIR` forever. Users must manage cleanup themselves. For production use cases (GCP Cloud Logging exports, centralized log aggregation), users want to:
- Read logs directly from S3/GCS/Azure Blob without local copies
- Auto-archive old logs to cheap storage
- Sync a time window of cloud logs into `LOG_DIR` on demand

---

## Proposed Solution

### Phase 1: File Size Safety (Low effort, high impact)

#### 1a. Max file size guardrail

New environment variable `MAX_LOG_FILE_MB` (default: `100`).

- Tools that process a file check `File.stat!/1` size first
- If file exceeds limit, return `{:error, "File too large (X MB). Max is Y MB. Set MAX_LOG_FILE_MB to increase."}` instead of attempting to read
- `list_logs` adds a `warning: "exceeds max size"` field to oversized files
- `log_stats` always works regardless of size (it already streams)

#### 1b. Large file warnings in `all_errors`

When `all_errors` skips a file due to size, include it in the output:
```
--- skipped: massive.log (2.3 GB exceeds 100 MB limit) ---
```

#### 1c. Streaming JSON parser for NDJSON

Add `JsonLogParser.stream_entries/2` that yields one entry at a time via `File.stream!/1` for `:json_lines` format. This makes all NDJSON operations memory-safe regardless of file size.

`:json_array` format inherently requires full parse — document this limitation and recommend NDJSON for large files.

### Phase 2: Cloud Storage Sync (Medium effort)

#### 2a. `sync_logs` tool

New MCP tool that pulls logs from cloud storage into `LOG_DIR`:

```
sync_logs(source: "gs://bucket/logs/2026-03-20/", prefix: "api-")
sync_logs(source: "s3://bucket/logs/", since: "1h")
```

Implementation: shell out to `gsutil rsync`, `aws s3 sync`, or `az storage blob download-batch` with appropriate filters. No SDK dependency — relies on CLI tools being available.

#### 2b. Auto-cleanup

New environment variable `LOG_RETENTION_DAYS` (default: disabled).

- On server startup, delete `.log` files in `LOG_DIR` with mtime older than N days
- Only applies to `LOG_DIR`, never to mounted volumes or symlinked files
- Log the cleanup action to stderr

### Phase 3: Direct Cloud Read (High effort, future)

Read logs directly from cloud object storage without local copies:
- New `CloudReader` module implementing the same interface as `FileAccess`
- `LOG_SOURCE=gs://bucket/logs/` environment variable
- Caches downloaded files locally with TTL
- Only worth doing if Phase 2 proves insufficient

---

## Non-Goals

- Log rotation management (use logrotate, Docker log driver, or application-level rotation)
- Log ingestion/collection (use Fluentd, Vector, or application logging libraries)
- Long-term log storage (use dedicated log management: Loki, CloudWatch, Datadog)
- Compression support (decompress before placing in LOG_DIR)

---

## User Stories

### US-1: File size guardrail
- [ ] `MAX_LOG_FILE_MB` env var (default 100) controls max processable file size
- [ ] Tools return clear error when file exceeds limit
- [ ] `list_logs` flags oversized files with warning
- [ ] `log_stats` exempt from size limit (streams efficiently)
- [ ] `all_errors` reports skipped files in output

### US-2: Streaming NDJSON parser
- [ ] `JsonLogParser.stream_entries/2` yields entries one at a time for `:json_lines`
- [ ] Correlator, ErrorExtractor, StatsCollector use streaming path for NDJSON
- [ ] `:json_array` documented as requiring full parse

### US-3: Cloud sync tool
- [ ] `sync_logs` tool definition in Registry
- [ ] Supports `gs://`, `s3://`, `az://` URI schemes
- [ ] Delegates to gsutil/aws/az CLI tools
- [ ] `since` parameter for time-windowed sync
- [ ] `prefix` parameter for filtering

### US-4: Auto-cleanup on startup
- [ ] `LOG_RETENTION_DAYS` env var (default: disabled)
- [ ] Deletes old `.log` files on Application.start
- [ ] Logs cleanup to stderr
- [ ] Never deletes symlinked files

---

## Success Metrics

- No OOM crashes on files up to 1GB (after Phase 1)
- Clear error messages for files exceeding configured limit
- Cloud sync completes in under 30 seconds for typical daily log volumes
- Zero data loss from auto-cleanup (retention disabled by default)

---

## Estimated Effort

| Phase | Effort | Impact |
|-------|--------|--------|
| Phase 1 (size safety) | 1-2 days | Prevents crashes, clear error messages |
| Phase 2 (cloud sync) | 2-3 days | Enables cloud workflow |
| Phase 3 (direct read) | 1-2 weeks | Eliminates local copy requirement |
