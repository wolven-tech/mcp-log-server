---
title: TOON Format
description: Token-Oriented Object Notation — a compact format for LLM-optimized data
status: active
audience: [developers]
difficulty: intermediate
created: 2026-03-18
lastModified: 2026-03-18
tags: [toon, format, tokens, optimization]
---

# TOON Format

TOON (Token-Oriented Object Notation) is a pipe-delimited tabular format designed to minimize token usage when sending structured data to LLMs.

---

## Why Not JSON?

JSON is verbose for tabular data. Keys are repeated for every row, quotes add overhead, and nested structures inflate token counts. For log data — which is inherently tabular (line number + content) — this overhead is wasteful.

**JSON** (~24 tokens):
```json
[{"line_number":42,"content":"ERROR: Connection failed"},{"line_number":43,"content":"INFO: Retrying..."}]
```

**TOON** (~12 tokens):
```
[content|line_number]
ERROR: Connection failed|42
INFO: Retrying...|43
```

TOON achieves approximately **50% token reduction** for typical log data.

## Format Specification

### Structure

```
[column1|column2|column3]
value1|value2|value3
value4|value5|value6
```

1. **Header row**: Column names wrapped in `[]`, separated by `|`
2. **Data rows**: Values separated by `|`, in the same order as headers
3. **Columns are sorted alphabetically** by key name

### Metadata

Optional metadata can be included as a JSON comment line:

```
# {"total":142,"file":"apps.log"}
[content|line_number]
ERROR: Connection failed|42
```

### Escaping

| Character | Escaped As |
|-----------|------------|
| `\|` (pipe) | `\\|` |
| `\n` (newline) | `\\n` |

### Auto-Detection

The encoder automatically selects TOON when the data contains `:matches` or `:entries` keys (common patterns for search results and log entries). You can override this by specifying `format: "json"` in tool arguments.

## When TOON Is Used

| Tool | Default Format |
|------|---------------|
| `list_logs` | TOON |
| `tail_log` | TOON |
| `search_logs` | TOON |
| `get_errors` | TOON |
| `log_stats` | JSON (single object, not tabular) |
| `all_errors` | TOON (always) |

## Implementation

The encoder lives in `lib/mcp_log_server/protocol/toon_encoder.ex`. It's a pure module with no dependencies beyond Jason for JSON fallback.

Key design decisions:
- **Alphabetical column sort**: Ensures deterministic output across Elixir map iterations
- **Auto-detection over explicit config**: Reduces tool argument complexity
- **JSON fallback**: Non-tabular data (like `log_stats`) gracefully falls back to JSON

---

**[Back to Documentation Index](../README.md)**
