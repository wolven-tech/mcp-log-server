---
title: Tool Reference
description: Complete API reference for all MCP Log Server tools
status: active
audience: [developers]
difficulty: intermediate
created: 2026-03-18
lastModified: 2026-03-18
tags: [reference, api, tools]
---

# Tool Reference

MCP Log Server exposes 6 tools via the MCP `tools/call` method. All tools return results as MCP text content.

---

## list_logs

List all available `.log` files with metadata.

**Parameters**: None

**Returns**: TOON-formatted table with file name, size, and last modified time.

**Example response**:
```
[modified|name|size]
2026-03-18T10:05:00Z|apps.log|2.4 MB
2026-03-18T09:30:00Z|worker.log|156 KB
```

**When to use**: First call to discover what log files are available.

---

## tail_log

Get the last N lines from a log file.

**Parameters**:

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `file` | string | Yes | — | Log file name (e.g., `apps.log`) |
| `lines` | integer | No | 50 | Number of lines to return |
| `format` | string | No | auto | Output format: `toon` or `json` |

**Example request**:
```json
{
  "name": "tail_log",
  "arguments": {
    "file": "apps.log",
    "lines": 20
  }
}
```

**When to use**: See the most recent log output from a specific file.

---

## search_logs

Search a log file using a regex pattern. Returns matching lines with line numbers.

**Parameters**:

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `file` | string | Yes | — | Log file name |
| `pattern` | string | Yes | — | Regex pattern (case-insensitive) |
| `max_results` | integer | No | 50 | Maximum number of matches |
| `context` | integer | No | 0 | Lines to show before and after each match |
| `format` | string | No | auto | Output format: `toon` or `json` |

**Example request**:
```json
{
  "name": "search_logs",
  "arguments": {
    "file": "apps.log",
    "pattern": "ECONNREFUSED|timeout",
    "context": 3,
    "max_results": 20
  }
}
```

**Example response (TOON)**:
```
# {"total":2}
[content|line_number]
ERROR: ECONNREFUSED to redis:6379|142
ERROR: Request timeout after 30s|287
```

**When to use**: Find specific patterns, error messages, or keywords in logs.

---

## get_errors

Extract lines matching common error patterns: `ERROR`, `FATAL`, `WARN`, `EXCEPTION`, `TypeError`, `ReferenceError`, `SyntaxError`, `ECONNREFUSED`, `ENOTFOUND`, `failed`, `Failed`.

**Parameters**:

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `file` | string | Yes | — | Log file name |
| `lines` | integer | No | 100 | Maximum number of error lines |
| `format` | string | No | auto | Output format: `toon` or `json` |

**Example request**:
```json
{
  "name": "get_errors",
  "arguments": {
    "file": "apps.log",
    "lines": 50
  }
}
```

**When to use**: Get a focused view of problems in a specific log file.

---

## log_stats

Get file statistics without reading the full content. Returns JSON.

**Parameters**:

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `file` | string | Yes | — | Log file name |

**Example response**:
```json
{
  "file": "apps.log",
  "size": "2.4 MB",
  "lines": 14523,
  "errors": 12,
  "warnings": 47,
  "modified": "2026-03-18T10:05:00Z"
}
```

**When to use**: Quick overview of file health — check error/warning counts before deciding whether to dig deeper.

---

## all_errors

Aggregate errors across ALL log files. Always returns TOON format.

**Parameters**:

| Name | Type | Required | Default | Description |
|------|------|----------|---------|-------------|
| `lines` | integer | No | 20 | Maximum errors per file |

**Example response**:
```
=== apps.log (3 errors) ===
[line_number|content]
1247|ERROR [ExceptionFilter] TypeError: Cannot read properties of undefined
1251|ERROR [ExceptionFilter] ECONNREFUSED 127.0.0.1:6379
1398|WARN: Memory usage at 85%

=== worker.log (1 error) ===
[line_number|content]
89|ERROR: Job queue stalled
```

**When to use**: Best first call for a health overview. Scans every log file and returns a summary.

---

## Error Handling

All tools return MCP error content for common failure cases:

| Error | Cause |
|-------|-------|
| `File not found: {file}` | The specified file doesn't exist in `LOG_DIR` |
| `Invalid regex: {pattern}` | The search pattern couldn't be compiled |
| `Unknown tool: {name}` | The tool name doesn't match any registered tool |

---

**[Back to Documentation Index](../README.md)**
