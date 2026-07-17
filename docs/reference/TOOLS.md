---
title: Tool Reference
description: Complete API reference for all MCP Log Server tools
status: active
audience: [developers]
difficulty: intermediate
created: 2026-03-18
lastModified: 2026-07-17
tags: [reference, api, tools]
---

# Tool Reference

MCP Log Server exposes 12 tools via the MCP `tools/call` method. All tools return results as MCP text content.

---

## Recommended Workflow

A typical investigation follows this sequence:

0. **`summarize`** -- "What changed in the last 15 minutes?" One call diffs a time window against the window before it: new/gone message templates, error-rate delta, volume delta per source. The highest-leverage first call during an incident.
1. **`all_errors`** -- Health overview across all log files. Start here to see which services have problems.
2. **`log_stats`** or **`time_range`** -- Understand the scope of a specific file (line counts, error counts, time span).
3. **`get_errors`** with `level`/`since` -- Targeted investigation of a single file, filtering by severity and time window.
4. **`search_logs`** with `field`/`context` -- Deep dive into specific patterns, optionally scoped to a JSON field.
5. **`aggregate`** -- Prove structured-field presence/absence or group by a JSON field (`op: exists` / `values` / `count`).
6. **`correlate`** -- Cross-service tracing using a request ID, session ID, or trace ID — or, when you only have a symptom line, an `anchor` regex whose matches become time windows.

Watching something in progress (a deploy, a restart loop)? `tail_log` and `search_logs` return an opaque **`cursor`** — pass it back to receive only lines appended since the last call.

---

## Timestamp Parsing, `since`/`until`, and the Fail-Open Policy

`since`/`until` filters work by extracting a timestamp from each line. Auto-detected formats:

- ISO 8601 / RFC 3339: `2026-03-20T14:00:00.123Z` (also bracketed: `[2026-03-20T14:00:00Z]`)
- Common Log Format: `20/Mar/2026:14:00:00 +0000`
- Date space time: `2026-03-20 14:00:00`
- Syslog: `Mar 20 14:00:00`
- Dev-server time-only formats: `14:00:00` line prefix, `[14:00:00]`, `[vite] 14:00:00` (optional `AM`/`PM`; ANSI color codes are stripped first, so colorized Vite/webpack output works)

Time-only stamps carry no date. The date is resolved from the file's mtime: the time-of-day is placed on the mtime's date, and if that instant would be *later* than the mtime it is shifted back one day. A log line cannot postdate its file's last modification, so this keeps ordering monotonic across midnight for any file spanning under 24 hours.

**Fail-open policy:** a line whose timestamp cannot be parsed is NEVER excluded by `since`/`until` -- it always passes the filter. Silently hiding lines during an incident would be strictly worse than including too many. The degradation is made observable instead:

- Every time-filtered result (`tail_log`, `search_logs`, `get_errors`, `all_errors`) includes **`unparsed_ts`** -- the count of scanned lines whose timestamp could not be parsed while the filter was active. `unparsed_ts: 0` means the filter worked exactly; a large value means the filter was largely a no-op. No time filter, no parsing cost -- the field is omitted.
- `correlate` reports `unparsed_ts` as the number of matched timeline entries that could not be time-ordered (they sort last).
- `log_stats` and `time_range` report **`ts_parse_ratio`** / **`ts_parse_sample`** -- the sampled share of lines with parseable timestamps (`log_stats` samples the first 1000 lines; `time_range` samples the first and last 10). A ratio of `0.0` is the loud version of the formerly silent failure: `since`/`until` on that file filters nothing.

### `LOG_TS_FORMATS`: declaring formats per source

When auto-detection cannot read a file's stamps (or guesses wrong), declare the format explicitly:

```bash
LOG_TS_FORMATS='fly-*.log=%FT%T%.fZ; app*.log=epoch_ms; dev-*.log=%H:%M:%S'
```

- Entries are `glob=format`, separated by `;`. Globs match the log file's basename (`*` and `?` supported); the first matching glob wins.
- Declared formats are tried FIRST for matching files, before auto-detection (which remains the fallback).
- Supported formats: `rfc3339`, `epoch_ms` (13-digit Unix milliseconds), `epoch_s` (10-digit Unix seconds), or a strftime subset: `%Y %m %d %H %M %S %b %f %.f %z %:z %F %T %%`.
- The declaration is parsed and validated ONCE at server startup. An invalid declaration (unknown directive, malformed entry) aborts boot with a descriptive error -- a typo can never degrade into silent 0% parsing at query time.

---

## Omissions: Never Truncate Silently

A truncated result that looks complete is worse than an error: the investigator concludes "line absent" when the truth was "line beyond the buffer". Every tool that bounds its output — match caps, line caps, value caps, the `MAX_LOG_FILE_MB` oversized-file skip — reports any bound it actually hit in ONE uniform place: the **`omissions`** block.

```
omissions: {
  "matches": {"omitted": 240, "showing": "newest 100"},   // count known
  "matches": {"capped_at": 500},                            // count unknown (lazy scan stopped early)
  "lines":   {"omitted": 240, "showing": "newest 100"},    // tail_log
  "values":  {"omitted": 12, "showing": "top 50 by count"}, // trace_ids
  "skipped_files": [{"file": "app.log", "reason": "File too large (142.0 MB). Max is 100 MB. ..."}]
}
```

- In TOON output the block rides in the `# {...}` metadata line (or a trailing `# omissions: {...}` line for `all_errors` / `tail_log`); in JSON output it is a top-level key.
- **One field to check:** if a result has no `omissions`, you saw everything the tool scanned. If it does, the block names exactly what was withheld and why.
- **Zero noise:** the block is entirely absent when nothing was bounded — never `omitted: 0` — so complete results are unchanged.
- The oversized-file skip appears in the results of every multi-file scan that would have included the file (`all_errors`, rollup-mode `search_logs`). Single-file tools refuse oversized files with an explicit error instead.

Bounds reported per tool: `search_logs` (`max_results`), `get_errors` (`lines`), `tail_log` (`lines`), `all_errors` (per-file `lines` + skipped files), `correlate` (`max_results`; anchor mode also `max_sections`), `trace_ids` (`max_values`), `aggregate` (`max_values` for the histogram + skipped files), `summarize` (`max_templates` per template list + skipped files).

---

## The Persistent Index and `index_used`

Large log directories make `since`-bounded queries and field aggregation linear scans. The server therefore maintains an **incremental persistent index** under `LOG_DIR/.index/` (invisible to `list_logs` and every scan): a sparse timestamp → byte-offset map per file (making `since` seeks skip the proven-excludable prefix) plus per-file JSON field-key knowledge (letting `aggregate` prove field absence without a scan). Storage is ETS + DETS — no native dependencies, works identically in escripts and releases (see `docs/decisions/001-index-storage.md`).

The rules that keep it trustworthy:

- **The index is a cache, never a source of truth.** Indexed and unindexed paths return byte-identical results; the index only changes speed. On any doubt — index missing, stale, corrupt, disabled, file rotated/truncated — the query transparently falls back to the linear scan and reports **`index_used: false`**; a background rebuild is scheduled. A wrong index silently narrowing results would be the exact silent failure the `omissions` block exists to prevent.
- **Fail-open lines block seeks.** A prefix is only skipped when every line in it has a parsed timestamp strictly before `since`. One unparseable timestamp in the prefix (which the fail-open policy would have included) disables the seek — honesty beats speed.
- **Built in the background, never on the request path.** Live `LOG_SOURCES` files are extended incrementally as they grow (batched ingest hook); static files are indexed lazily after their first index-eligible query. Queries always take whatever index state exists.
- **Self-healing.** Corrupt or version-mismatched index storage is dropped and rebuilt automatically; deleting `LOG_DIR/.index/` at any time is safe.
- `LOG_INDEX=off` disables indexing entirely — everything still works, linearly.

`index_used` appears in the results of index-eligible queries: `tail_log`/`search_logs` with `since` (no cursor), every `aggregate`, and every `summarize`.

---

## Cursors: Polling Without Re-Reading

Tailing an in-progress deploy by re-fetching the same window every few seconds is pure token waste for the consuming agent. `tail_log` and `search_logs` therefore return an opaque **`cursor`** string with every (line-oriented) result. Pass it back on the next call to receive **only lines appended since**, plus a fresh cursor.

- **Opaque by design:** the cursor encodes file identity + byte offset + a rotation guard (a hash of the file's first bytes). The encoding is versioned and free to change — never parse or construct one.
- **Rotation/truncation safety:** if the file shrank, was rotated, or was replaced, the cursor is invalid. The tool then returns a **flagged full window** with `cursor_reset: true` instead of wrong increments — you always know when your incremental view restarted.
- Cursors never contain absolute paths — only the file's name within `LOG_DIR`.
- A cursor from `tail_log` works in `search_logs` on the same file (and vice versa).
- `search_logs` restrictions: `cursor` cannot be combined with `field` (JSON field search) or `rollup`.
- A trailing line still being written (no newline yet) is returned as-is but not covered by the cursor, so the completed line is re-delivered on the next poll.

**The deploy-watch loop:**

```json
{"name": "tail_log", "arguments": {"file": "deploy.log", "lines": 50}}
```
```
# tail deploy.log (last 50 lines)
# cursor: g2gFYQFtAAAACmRlcGxveS5sb2dhKWEpYgALeg8
release v1 starting
health check pending
```

Next poll — pass the cursor back; only new lines come back:

```json
{"name": "tail_log", "arguments": {"file": "deploy.log", "cursor": "g2gFYQFtAAAACmRlcGxveS5sb2dhKWEpYgALeg8"}}
```
```
# tail deploy.log (last 50 lines)
# cursor: g2gFYQFtAAAACmRlcGxveS5sb2dhT2FPYgUgKwI
instances rolling
health check passed
```

If the deploy rotated the file between polls:

```
# tail deploy.log (last 50 lines)
# cursor_reset: true
# cursor: ...
<full window of the new file>
```

---

## Rollup Mode: "Did X Happen, On How Many Instances, When?"

With N instances emitting near-identical lines, a grep answers the wrong question. A message emitted by 1 of 9 machines is easy to miss entirely in flooded output; `ran on 1/9, first 17:59:21` answers the incident question in one call.

`search_logs` and `all_errors` accept **`rollup: true`** (default `false` — existing behavior untouched). Matching lines are collapsed into **message templates**: volatile tokens are replaced with placeholders so near-identical lines land on the same row.

| Placeholder | Replaces |
|-------------|----------|
| `<TS>` | Timestamps (ISO 8601, CLF, syslog, `HH:MM:SS`) |
| `<UUID>` | UUIDs |
| `<IP>` | IPv4 addresses, with or without `:port` |
| `<HEX>` | `0x...` literals and 8+ char hex ids containing a digit |
| `<N>` | Standalone numbers (including `34ms` → `<N>ms`) |

Each rolled-up row carries:

- `template` — the normalized message
- `count` — how many lines collapsed into it
- `instances_seen` — distinct instances that emitted it, as `1/3` where the denominator is the number of sources scanned. The instance is the line's `[src:<name>]` tag ([streamed sources](#streamed-sources-log_sources)) when present, else the file name; rotated files (`fly.1.log`) collapse into their logical source.
- `first_ts` / `last_ts` — earliest/latest parsed timestamp of the collapsed lines
- `sample` — one raw line, verbatim

```
# {"pattern":"out of memory","rollup":true,"sources_scanned":3}
[count|first_ts|instances_seen|last_ts|sample|template]
2|2026-07-17T17:59:21Z|1/3|2026-07-17T18:03:33Z|[src:web-2] 2026-07-17T17:59:21Z ERROR out of memory: killed worker 4411|<TS> ERROR out of memory: killed worker <N>
```

In rollup mode `search_logs` may omit `file` to scan ALL logs. `since`/`until` apply as usual (fail-open, with `unparsed_ts` reported), and files skipped by the size guardrail appear in `omissions.skipped_files`.

---

## Streamed Sources: `LOG_SOURCES`

The server is not limited to `.log` files that already exist under `LOG_DIR`. Declare streaming commands -- Fly, Kubernetes, journald, Docker, anything that writes logs to stdout -- and the server tees each stream into a rotating file that every tool can search, tail, and correlate with zero special-casing:

```bash
LOG_SOURCES='fly:cmd=flyctl logs -a my-app; k8s:cmd=kubectl logs -f deploy/api'

# More examples
LOG_SOURCES='journal:cmd=journalctl -f -o short-iso'
LOG_SOURCES='web:cmd=docker logs -f web-1'
LOG_SOURCES='demo:cmd=sh -c "while true; do date; sleep 1; done"'
```

- Entries are `name:cmd=command`, separated by `;` (a `;` inside quotes belongs to the command, as in the `demo` example). Names are restricted to `[A-Za-z0-9_-]` so they are always filename-safe.
- The declaration is validated ONCE at boot; a malformed entry aborts startup with a descriptive error instead of silently dropping the stream you asked for.

### How it works

- One supervised worker per source spawns the command and appends its stdout to `LOG_DIR/<name>.log`. The file exists from boot, so `list_logs` shows the source immediately.
- **No shell involved:** the command string is tokenized (quotes honored) and spawned directly via the OS `exec` -- nothing is string-interpolated into a shell. To use shell features (pipes, loops), declare them explicitly: `demo:cmd=sh -c "..."`.
- **Source tagging:** every ingested line is prefixed with `[src:<name>] `. The tag keeps per-line attribution visible when `correlate` merges many files into one timeline (and when the file is opened outside the server). The timestamp parser strips the tag before matching, so tagged lines parse exactly like the originals. Note: a tagged NDJSON line is no longer a bare JSON object, so streamed files are treated as plain text -- use `LOG_TS_FORMATS` if the stream's timestamps are not auto-detected.
- **Rotation:** the file is rotated to `<name>.1.log` ... `<name>.N.log` *before* it would exceed the threshold. An unattended `-f` stream grows without bound and would otherwise trip the `MAX_LOG_FILE_MB` oversized-file skip -- silently killing the very source you declared. Rotated files remain ordinary static logs: searchable, and included in `correlate`.
- **Restart with backoff:** when the command exits, the worker respawns it with exponential backoff (1s → 2s → ... capped at 60s), resetting after a run that stayed healthy for 30s. Restarts are logged to **stderr only** -- stdout carries MCP JSON-RPC and is never touched. A crash-looping source never takes down the server or the other sources.
- `list_logs` marks these files `live: true` with the source name and worker `status` (`running` / `backing_off` / `dead`; `dead` means the executable could not be found -- still retried, in case PATH is fixed live).

| Variable | Default | Description |
|----------|---------|-------------|
| `LOG_SOURCES` | _(none)_ | `name:cmd=command` entries separated by `;` |
| `LOG_SOURCE_ROTATE_MB` | `MAX_LOG_FILE_MB` | Rotate `<name>.log` before it exceeds this size |
| `LOG_SOURCE_ROTATIONS` | `3` | Rotated files kept per source (`<name>.1.log` ... `<name>.N.log`) |

### Security: `LOG_SOURCES` runs arbitrary commands

Each declared command runs **with the server's own privileges**, as a child of the server process. This is the same trust level as the command that launches the server itself -- anyone who can set the server's environment can already run code as the server's user -- but be deliberate about it: treat `LOG_SOURCES` like a startup script, review it in checked-in MCP configs, and never build it from untrusted input.

### Run modes

Streamed sources work in both release and escript mode (spawning needs only the BEAM, not a full release). On clean shutdown the server sends each command SIGTERM; if the server is killed abruptly (SIGKILL), commands are not signalled -- they exit on their own the next time they write to the closed pipe, but a command that ignores broken pipes can linger.

---

## Discovery Tools

### list_logs

List all available `.log` files with metadata.

**Parameters:** None

**Example request:**
```json
{
  "name": "list_logs",
  "arguments": {}
}
```

**Example response:**
```
[live|modified|name|path|size_bytes|source|status]
true|2026-03-20T10:05:00|fly.log|/tmp/mcp-logs/fly.log|2411724|fly|running
false|2026-03-20T09:30:00|worker.log|/tmp/mcp-logs/worker.log|159744||
false|2026-03-20T08:12:00|gateway.log|/tmp/mcp-logs/gateway.log|4291456||
```

`live: true` marks the ingest file of a declared [`LOG_SOURCES`](#streamed-sources-log_sources) stream, with its `source` name and worker `status` (`running` / `backing_off` / `dead`). Static files (including rotated `<name>.1.log` history) carry `live: false`.

**When to use:** First call to discover what log files are available in the configured log directory, and to check the health of declared streamed sources.

---

### log_stats

Get file statistics without reading the full content. Auto-detects JSON format and uses the severity field for accurate counting.

**Parameters:**

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `file` | string | Yes | -- | Log file name |

**Example request:**
```json
{
  "name": "log_stats",
  "arguments": {
    "file": "api.log"
  }
}
```

**Example response:**
```json
{
  "file": "api.log",
  "size": "2.4 MB",
  "lines": 14523,
  "errors": 12,
  "warnings": 47,
  "modified": "2026-03-20T10:05:00Z",
  "ts_parse_ratio": 0.998,
  "ts_parse_sample": 1000
}
```

`ts_parse_ratio` is the share of sampled lines (first `ts_parse_sample` lines, up to 1000) whose timestamp parsed. `0.0` means `since`/`until` filters on this file are effectively disabled (fail-open) -- declare the format via `LOG_TS_FORMATS` to fix it.

**When to use:** Quick overview of file health -- check error/warning counts before deciding whether to dig deeper.

---

### time_range

Get the earliest and latest timestamps in a log file, plus the time span. Works with both plain-text and JSON-structured logs.

**Parameters:**

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `file` | string | Yes | -- | Log file name |

**Example request:**
```json
{
  "name": "time_range",
  "arguments": {
    "file": "api.log"
  }
}
```

**Example response:**
```json
{
  "file": "api.log",
  "earliest": "2026-03-20T00:00:03Z",
  "latest": "2026-03-20T10:05:00Z",
  "span": "10h 4m 57s",
  "ts_parse_ratio": 1.0,
  "ts_parse_sample": 20
}
```

`ts_parse_ratio` / `ts_parse_sample` report timestamp parseability over the sampled first and last lines -- a low ratio warns that `since`/`until` filtering on this file is unreliable (see the fail-open policy above).

**When to use:** Determine what time period a log file covers before using `since`/`until` filters on other tools.

---

## Analysis Tools

### tail_log

Get the last N lines from a log file, optionally filtered to a time window.

**Parameters:**

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `file` | string | Yes | -- | Log file name (e.g., `api.log`) |
| `lines` | integer | No | 50 | Number of lines to return |
| `since` | string | No | -- | Only include lines from this time onward. ISO 8601 or relative shorthand (e.g. `30m`, `2h`, `1d`) |
| `cursor` | string | No | -- | Opaque cursor from a previous call; returns only lines appended since (see [Cursors](#cursors-polling-without-re-reading)) |
| `format` | string | No | toon | Output format: `toon` or `json` |

**Example request:**
```json
{
  "name": "tail_log",
  "arguments": {
    "file": "api.log",
    "lines": 20,
    "since": "15m"
  }
}
```

**Example response:**
```
# tail api.log (last 20 lines)
# unparsed_ts: 0
2026-03-20T10:02:11Z INFO  [Router] GET /api/users 200 12ms
2026-03-20T10:02:14Z WARN  [Pool] Connection pool at 80% capacity
2026-03-20T10:03:01Z ERROR [DB] Query timeout after 30s on users_table
```

When `since` is active, the `# unparsed_ts: N` header line counts scanned lines whose timestamp could not be parsed -- those lines pass the filter (fail-open). Without `since` the line is omitted.

When the file holds more (post-filter) lines than requested, a `# omissions: {"lines":{"omitted":240,"showing":"newest 100"}}` header line reports the withheld older lines -- absent when everything fit. See [Omissions](#omissions-never-truncate-silently).

Every result carries a `# cursor: ...` header line (a `cursor` key in JSON format). Pass it back to receive only lines appended since; after rotation/truncation the result is a full window flagged `# cursor_reset: true`. See [Cursors](#cursors-polling-without-re-reading).

**When to use:** See the most recent log output from a specific file, optionally narrowed to a recent time window. With `cursor`, poll a live deploy without re-reading lines already ingested.

---

### search_logs

Search a log file using a regex pattern. Returns matching lines with line numbers. Supports JSON field scoping and time-range filtering.

**Parameters:**

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `file` | string | Yes* | -- | Log file name. *Optional when `rollup` is true (then ALL log files are scanned) |
| `pattern` | string | Yes | -- | Regex pattern (case-insensitive) |
| `max_results` | integer | No | 50 | Maximum number of matches (not used in rollup mode) |
| `context` | integer | No | 0 | Lines to show before and after each match |
| `field` | string | No | -- | JSON field to search in (dot-notation, e.g. `jsonPayload.message`). Only used for JSON log files |
| `rollup` | boolean | No | false | Collapse matches into [message templates](#rollup-mode-did-x-happen-on-how-many-instances-when) with `count`, `instances_seen`, `first_ts`/`last_ts` |
| `since` | string | No | -- | Only include lines from this time onward. ISO 8601 or relative shorthand (e.g. `30m`, `2h`) |
| `until` | string | No | -- | Only include lines up to this time. ISO 8601 or relative shorthand |
| `cursor` | string | No | -- | Opaque cursor from a previous call; searches only lines appended since. Incompatible with `field` and `rollup` (see [Cursors](#cursors-polling-without-re-reading)) |
| `format` | string | No | toon | Output format: `toon` or `json` |

**Example request:**
```json
{
  "name": "search_logs",
  "arguments": {
    "file": "api.log",
    "pattern": "ECONNREFUSED|timeout",
    "context": 3,
    "max_results": 20,
    "since": "1h"
  }
}
```

**Example response (TOON):**
```
# {"file":"api.log","pattern":"ECONNREFUSED|timeout","returned_matches":2,"unparsed_ts":0}
[content|line_number]
ERROR: ECONNREFUSED to redis:6379|142
ERROR: Request timeout after 30s|287
```

With `since`/`until` active, `unparsed_ts` counts scanned lines whose timestamp could not be parsed -- those lines pass the time filter (fail-open). The field is omitted when no time filter is applied.

When the `max_results` cap was actually hit, the metadata carries an [`omissions`](#omissions-never-truncate-silently) block, e.g. `"omissions":{"matches":{"omitted":240,"showing":"first 50"}}` -- absent when every match was returned.

**Example request with rollup (the multi-instance incident question):**
```json
{
  "name": "search_logs",
  "arguments": {
    "pattern": "out of memory",
    "rollup": true
  }
}
```

**Example rollup response:**
```
# {"pattern":"out of memory","rollup":true,"sources_scanned":3}
[count|first_ts|instances_seen|last_ts|sample|template]
2|2026-07-17T17:59:21Z|1/3|2026-07-17T18:03:33Z|[src:web-2] 2026-07-17T17:59:21Z ERROR out of memory: killed worker 4411|<TS> ERROR out of memory: killed worker <N>
```

**Example request with field scoping (JSON logs):**
```json
{
  "name": "search_logs",
  "arguments": {
    "file": "structured.log",
    "pattern": "payment",
    "field": "jsonPayload.message",
    "max_results": 10
  }
}
```

Line searches also return a `cursor` in the metadata; pass it back to search only lines appended since the previous call — watching for a specific error during a deploy without rescanning the file. `cursor_reset: true` in the metadata flags a full re-window after rotation/truncation. See [Cursors](#cursors-polling-without-re-reading).

**When to use:** Find specific patterns, error messages, or keywords in logs. Use `field` to avoid false matches in JSON logs and `since`/`until` to narrow the time window.

---

### get_errors

Extract lines matching common error patterns from a single log file. Recognizes `ERROR`, `FATAL`, `WARN`, `EXCEPTION`, `TypeError`, `ReferenceError`, `SyntaxError`, `ECONNREFUSED`, `ENOTFOUND`, `failed`, and `Failed`.

**Severity level hierarchy:** The `level` parameter controls the minimum severity threshold. Levels from most to least severe:

- `fatal` -- Only FATAL-level entries
- `error` -- FATAL and ERROR entries
- `warn` -- FATAL, ERROR, and WARN entries (default)
- `info` -- All entries including INFO-level matches

**Parameters:**

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `file` | string | Yes | -- | Log file name |
| `lines` | integer | No | 100 | Maximum number of error lines |
| `level` | string | No | warn | Minimum severity level: `fatal`, `error`, `warn`, or `info` |
| `exclude` | string | No | -- | Regex pattern -- lines matching this are excluded from results |
| `since` | string | No | -- | Only include errors from this time onward. ISO 8601 or relative shorthand (e.g. `1h`, `30m`) |
| `until` | string | No | -- | Only include errors up to this time. ISO 8601 or relative shorthand |
| `format` | string | No | toon | Output format: `toon` or `json` |

**Example request:**
```json
{
  "name": "get_errors",
  "arguments": {
    "file": "api.log",
    "lines": 50,
    "level": "error",
    "exclude": "HealthCheck",
    "since": "2h"
  }
}
```

**Example response (TOON):**
```
# {"file":"api.log","error_count":3,"unparsed_ts":0}
[line_number|content]
1247|ERROR [ExceptionFilter] TypeError: Cannot read properties of undefined
1251|ERROR [ExceptionFilter] ECONNREFUSED 127.0.0.1:6379
1398|FATAL [Process] Out of memory: heap allocation failed
```

With `since`/`until` active, `unparsed_ts` counts scanned lines whose timestamp could not be parsed -- those lines pass the time filter (fail-open). The field is omitted when no time filter is applied.

When the `lines` cap was hit, the metadata carries `"omissions":{"matches":{"omitted":N,"showing":"newest 100"}}` -- absent when every matching entry was returned. See [Omissions](#omissions-never-truncate-silently).

**When to use:** Get a focused view of problems in a specific log file. Use `level` to filter noise and `exclude` to suppress known false positives.

---

### all_errors

Aggregate errors across ALL log files at once. Always returns TOON format. Accepts severity and time filters just like `get_errors`.

**Parameters:**

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `lines` | integer | No | 20 | Maximum errors per file (not used in rollup mode) |
| `level` | string | No | warn | Minimum severity level: `fatal`, `error`, `warn`, or `info` |
| `exclude` | string | No | -- | Regex pattern -- lines matching this are excluded from results |
| `rollup` | boolean | No | false | Collapse errors into [message templates](#rollup-mode-did-x-happen-on-how-many-instances-when) with `count`, `instances_seen`, `first_ts`/`last_ts` |
| `since` | string | No | -- | Only include errors from this time onward. ISO 8601 or relative shorthand (e.g. `1h`) |

**Example request:**
```json
{
  "name": "all_errors",
  "arguments": {
    "level": "error",
    "since": "30m"
  }
}
```

**Example response:**
```
=== api.log (3 errors) ===
[line_number|content]
1247|ERROR [ExceptionFilter] TypeError: Cannot read properties of undefined
1251|ERROR [ExceptionFilter] ECONNREFUSED 127.0.0.1:6379
1398|FATAL [Process] Out of memory: heap allocation failed

=== worker.log (1 error) ===
[line_number|content]
89|ERROR: Job queue stalled — no heartbeat for 60s

# unparsed_ts: 0
```

With `since` active, the trailing `# unparsed_ts: N` line is the total (across all scanned files) of lines whose timestamp could not be parsed -- those lines pass the time filter (fail-open). The line is omitted when no time filter is applied.

When any bound was hit, a trailing `# omissions: {...}` line reports it -- files skipped by the `MAX_LOG_FILE_MB` guardrail appear as `skipped_files` (each with its reason), and entries dropped by the per-file cap as `matches`. See [Omissions](#omissions-never-truncate-silently). The line is absent when the scan was complete:

```
# omissions: {"skipped_files":[{"file":"huge.log","reason":"File too large (142.0 MB). Max is 100 MB. Set MAX_LOG_FILE_MB to increase."}],"matches":{"omitted":37,"showing":"newest 20 per file"}}
```

With `rollup: true`, the per-file listing is replaced by message-template rows (same shape as `search_logs` rollup), severity-filtered by `level`.

**When to use:** Best first call for a health overview. Scans every log file and returns a summary of errors across the entire system.

---

### aggregate

Aggregate/facet on a JSON field (dot-path) across one log file or ALL files. This is the tool for structured-field questions that regex cannot answer cheaply: proving a field's presence or absence, or grouping by its values.

**Ops:**

- `exists` -- "did ANY line emit this field?" Returns `lines_with_field` / `lines_without` plus one `sample` matching line. Turns "did any line emit `gated`?" into one deterministic query — a present key holding JSON `null` still counts as present.
- `values` -- histogram of distinct values with counts, sorted by count. Distinct values are capped (`max_values`); a hit cap is reported in `omissions.values`.
- `count` -- total occurrences of the field.

**Honesty:** lines that are not JSON objects can never prove field absence — they are counted separately as `non_json`, not silently ignored. A fully plain-text file reports everything under `non_json` and zero under `lines_without`. With `since`/`until` active, `unparsed_ts` is reported as usual (fail-open). Files skipped by the size guardrail in an all-files scan appear in `omissions.skipped_files`.

**Parameters:**

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `field` | string | Yes | -- | Dot-path into parsed JSON lines (e.g. `fields.region`). Numeric segments index arrays (`items.0.id`) |
| `op` | string | Yes | -- | `exists`, `values`, or `count` |
| `file` | string | No | -- | Log file name. Omit to scan ALL log files |
| `pattern` | string | No | -- | Regex pre-filter (case-insensitive) — only matching lines are aggregated |
| `max_values` | integer | No | 50 | Cap on distinct values for `op: values` |
| `since` | string | No | -- | Only include lines from this time onward. ISO 8601 or relative shorthand |
| `until` | string | No | -- | Only include lines up to this time. ISO 8601 or relative shorthand |
| `format` | string | No | toon | Output format: `toon` or `json` |

**Example request (the incident question — "did the gate ever fire?"):**
```json
{
  "name": "aggregate",
  "arguments": {
    "file": "app.log",
    "field": "fields.gated",
    "op": "exists"
  }
}
```

**Example response:**
```json
{"op":"exists","field":"fields.gated","files_scanned":1,"non_json":0,"lines_with_field":2,"lines_without":498,"sample":"{\"fields\":{\"gated\":true,\"region\":\"fra\"},\"message\":\"req 42\",\"timestamp\":\"2026-01-15T10:00:00Z\"}"}
```

`lines_with_field: 2` out of 500 — the field fired exactly twice, and `sample` shows one of the lines. `lines_with_field: 0` with `non_json: 0` is a *proof* of absence over everything scanned.

**Example request (group by region):**
```json
{
  "name": "aggregate",
  "arguments": {
    "field": "fields.region",
    "op": "values"
  }
}
```

**Example response (TOON histogram):**
```
# {"op":"values","field":"fields.region","files_scanned":3,"distinct_values":4,"non_json":12}
[count|value]
2113|fra
1874|ams
420|iad
7|null
```

When the distinct-value cap was hit, the metadata carries `"omissions":{"values":{"omitted":N,"showing":"top 50 by count"}}` — a truncated histogram never looks complete.

**When to use:** Prove structured-field presence/absence in one call (`exists`), see the distribution of a field's values (`values`), or count occurrences (`count`) — instead of grepping and hand-counting.

---

### summarize

The incident-triage capstone: **"what's new or unusual in this window vs the prior one?"** in one call. The window (e.g. the last 15 minutes) is diffed against a **baseline** — by default the equal-length window immediately before it — across all logs (or one file):

- **`new_templates`** -- message templates ([the slice-004 normalizer](#rollup-mode-did-x-happen-on-how-many-instances-when): timestamps/UUIDs/IPs/ids collapsed to placeholders) present in the window but ABSENT in the baseline. Each row: `count`, `instances_seen` (e.g. `1/3` sources), `first_ts`, one raw `sample`. This is where a novel failure mode surfaces.
- **`gone_templates`** -- present in the baseline, absent in the window (top K by baseline count) — the heartbeat that stopped.
- **`error_rate`** -- errors/min in window vs baseline with `delta_per_min`.
- **`volume`** -- lines/min per source with delta — the service that went quiet or exploded.

**Honesty:** `unparsed_ts` counts lines that could not be placed in time; they fold into BOTH ranges (fail-open), so they can never fabricate a `new`/`gone` row — the diff degrades conservatively and observably. Capped template lists are reported in `omissions` (`new_templates`/`gone_templates`); files skipped by the size guardrail appear in `omissions.skipped_files`; `index_used` reports whether the [persistent index](#the-persistent-index-and-index_used) accelerated the scan (results are identical without it).

**Parameters:**

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `window` | string | Yes* | -- | Window length as relative shorthand (`"15m"`, `"2h"`), ending now (or at `until`). *Either `window` or `since` is required |
| `since` | string | Yes* | -- | Explicit window start (ISO 8601 or relative shorthand) — alternative to `window` |
| `until` | string | No | now | Window end |
| `baseline` | string | No | window length | Baseline length (e.g. `"1h"`), immediately before the window |
| `file` | string | No | -- | Log file name. Omit to scan ALL log files |
| `max_templates` | integer | No | 20 | Cap per template list |
| `format` | string | No | toon | Output format: `toon` or `json` |

**Example request (the 15-minute incident question):**
```json
{
  "name": "summarize",
  "arguments": {"window": "15m"}
}
```

**Example response:**
```
# {"window":{"since":"2026-07-17T10:15:00Z","until":"2026-07-17T10:30:00Z"},"baseline":{"since":"2026-07-17T10:00:00Z","until":"2026-07-17T10:15:00Z"},"files_scanned":2,"sources_seen":2,"error_rate":{"window_errors":2,"baseline_errors":0,"window_per_min":0.13,"baseline_per_min":0.0,"delta_per_min":0.13},"unparsed_ts":0,"index_used":true}
== new templates (1) ==
[count|first_ts|instances_seen|sample|template]
2|2026-07-17T10:20:00Z|1/2|2026-07-17T10:20:00Z ERROR redis connection refused conn=ab12cd34ef|<TS> ERROR redis connection refused conn=<HEX>

== gone templates (1) ==
[baseline_count|last_ts|template]
5|2026-07-17T10:05:00Z|<TS> INFO request <N> handled

== volume by source (2) ==
[baseline_lines|baseline_per_min|delta_per_min|source|window_lines|window_per_min]
5|0.33|-0.2|api.log|2|0.13
1|0.07|0.0|web.log|1|0.07
```

Read: a redis-refused template appeared (twice, on 1 of 2 sources, first at 10:20), the steady request traffic stopped, and the error rate went from 0 to 0.13/min — the whole incident shape in one response.

**When to use:** First call when something "just started happening". Answers "what changed?" without knowing what to grep for; follow up with `search_logs`/`correlate` on the surfaced template.

---

## Correlation Tools

### correlate

Search for a correlation ID (session ID, trace ID, request ID) across ALL log files. Returns a unified timeline sorted by timestamp, making it easy to trace a request across multiple services.

No id in hand? Pass **`anchor`** instead (see [anchor mode](#anchor-mode-correlate-around-a-symptom-line) below): every match of a symptom regex becomes a time anchor, and the result is the merged cross-source timeline around each hit. `value` and `anchor` are mutually exclusive — pass exactly one.

**Parameters:**

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `value` | string | Yes* | -- | The correlation value to search for (e.g. a session ID, trace ID). *Mutually exclusive with `anchor` |
| `field` | string | No | -- | Restrict search to this field (dot-notation for JSON, `field=value` for plain text). Only with `value` |
| `anchor` | object | Yes* | -- | `{pattern, window}` or `{pattern, before, after}` — correlate around a regex instead of an id. *Mutually exclusive with `value` |
| `max_results` | integer | No | 200 | Maximum total results across all files |
| `max_sections` | integer | No | 5 | Anchor mode: maximum window sections |
| `format` | string | No | toon | Output format: `toon` or `json` |

**Example request:**
```json
{
  "name": "correlate",
  "arguments": {
    "value": "req-abc-123",
    "field": "traceId",
    "max_results": 100
  }
}
```

**Example response (cross-service timeline):**
```
# {"value":"req-abc-123","total_matches":5,"files_matched":["gateway.log","api.log","worker.log"],"unparsed_ts":0}
[timestamp|file|content]
2026-03-20T10:00:01.100Z|gateway.log|INFO  Incoming POST /api/orders traceId=req-abc-123
2026-03-20T10:00:01.150Z|api.log|INFO  [OrderController] Creating order traceId=req-abc-123
2026-03-20T10:00:01.320Z|api.log|INFO  [OrderService] Validating payment traceId=req-abc-123
2026-03-20T10:00:01.800Z|worker.log|INFO  [PaymentJob] Charging card traceId=req-abc-123
2026-03-20T10:00:02.400Z|gateway.log|INFO  Response 201 /api/orders 1300ms traceId=req-abc-123
```

`unparsed_ts` counts matched entries whose timestamp could not be parsed; they are still included (fail-open) but sort last in the timeline.

When the `max_results` cap was hit, the metadata carries `"omissions":{"matches":{"omitted":N,"showing":"first 200 by time"}}` -- absent when the timeline is complete. See [Omissions](#omissions-never-truncate-silently).

**When to use:** Trace a single request, session, or transaction across multiple services to understand the full lifecycle and pinpoint where failures occur.

#### Anchor mode: correlate around a symptom line

During a boot investigation you have a symptom line, not an id. Anchor mode takes a regex; every match becomes a **time anchor**, and the result is the unified source-tagged timeline of ALL lines (across every file) within a window around each anchor — the surrounding cross-source neighbourhood, merged and time-sorted.

- **Window syntax:** symmetric `"±10s"` / `"±2m"` (ASCII `"+-10s"` accepted; units `s`/`m`/`h`/`d`; default ±30s), or asymmetric `before`/`after` durations.
- **Multiple anchor hits → multiple window sections.** Overlapping windows MERGE into one section (its `anchor_count` says how many anchors it absorbed). Sections are capped at `max_sections`, reported in `omissions.sections`; total timeline entries are capped at `max_results`, reported in `omissions.matches`.
- **Timestamp honesty (slice 002 rules, declared `LOG_TS_FORMATS` respected):** an anchor match whose timestamp cannot be parsed cannot place a window — counted in `anchors_unparsed_ts`. A scanned line whose timestamp cannot be parsed cannot be placed in (or proven outside) any window — counted in the result's `unparsed_ts`. Both zero means the windows are exact.

**Example request (symptom line, no id):**
```json
{
  "name": "correlate",
  "arguments": {
    "anchor": {"pattern": "boot loop detected", "window": "±10s"}
  }
}
```

**Example response:**
```
# {"anchor":"boot loop detected","window":"±10s","total_anchors":1,"anchors_unparsed_ts":0,"total_entries":5,"files_matched":["web.log","db.log","gw.log"],"unparsed_ts":0}
== window 2026-01-15T09:59:55Z .. 2026-01-15T10:00:15Z (1 anchor) ==
[content|file|line_number|severity|timestamp]
[src:web-1] 2026-01-15T10:00:02Z INFO warmup|web.log|2|info|2026-01-15T10:00:02Z
2026-01-15 10:00:04 ERROR too many connections|db.log|1|error|2026-01-15T10:00:04Z
[src:web-1] 2026-01-15T10:00:05Z ERROR boot loop detected|web.log|3|error|2026-01-15T10:00:05Z
upstream refused|gw.log|1|error|2026-01-15T10:00:06Z
[src:web-1] 2026-01-15T10:00:08Z INFO retrying|web.log|4|info|2026-01-15T10:00:08Z
```

One window section per (merged) anchor neighbourhood; `[src:...]` tags ([streamed sources](#streamed-sources-log_sources)) keep per-line attribution visible in the merged timeline.

**Asymmetric window** — mostly interested in what happened *after* the symptom:
```json
{
  "name": "correlate",
  "arguments": {
    "anchor": {"pattern": "OOM killed", "before": "5s", "after": "1m"}
  }
}
```

---

### trace_ids

Discover unique values for a correlation field (e.g. `sessionId`, `traceId`) across log files. Returns each unique value with its occurrence count and the time range it spans.

**Parameters:**

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `field` | string | Yes | -- | The field to extract values from (e.g. `sessionId`, `traceId`) |
| `file` | string | No | -- | Scan only this file instead of all files |
| `max_values` | integer | No | 50 | Maximum number of unique values to return |

**Example request:**
```json
{
  "name": "trace_ids",
  "arguments": {
    "field": "traceId",
    "max_values": 10
  }
}
```

**Example response:**
```
[count|first_seen|last_seen|value]
47|2026-03-20T09:58:00Z|2026-03-20T10:05:00Z|req-abc-123
32|2026-03-20T09:59:12Z|2026-03-20T10:03:45Z|req-def-456
18|2026-03-20T10:01:00Z|2026-03-20T10:02:30Z|req-ghi-789
5|2026-03-20T10:04:00Z|2026-03-20T10:04:02Z|req-jkl-012
```

When the `max_values` cap was hit, a `# {...}` metadata line carries `"omissions":{"values":{"omitted":N,"showing":"top 50 by count"}}` -- absent when the value list is exhaustive. See [Omissions](#omissions-never-truncate-silently).

**When to use:** Find active trace or session IDs before using `correlate` to drill into a specific one. Useful for identifying the busiest or most recent transactions.

---

## Error Handling

All tools return MCP error content for common failure cases:

| Error | Cause |
|-------|-------|
| `File not found: {file}` | The specified file does not exist in `LOG_DIR` |
| `Invalid regex: {pattern}` | The search pattern could not be compiled |
| `Unknown tool: {name}` | The tool name does not match any registered tool |
| `value and anchor are mutually exclusive ...` | `correlate` was given both an id and an anchor |
| `Invalid window ...` / `Invalid duration ...` | Anchor window spec did not parse (expected e.g. `±10s`, `±2m`, or `before`/`after` durations) |
| `Invalid op: ...` | `aggregate` op was not `exists`, `values`, or `count` |
| `cursor cannot be combined with field/rollup` | `search_logs` cursor works only on the plain line-scan path |

---

**[Back to Documentation Index](../README.md)**
