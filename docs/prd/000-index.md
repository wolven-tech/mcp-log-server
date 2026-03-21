# MCP Log Server — PRD Index

## Overview

Six PRDs addressing all open GitHub issues (#1–#5) plus a log structuring guide to maximize tool effectiveness.

## Dependency Graph

```
PRD-001 (JSON Structured Logs)     PRD-004 (Configurable Patterns)     PRD-006 (Setup Script)
    │                                   │                                 (independent)
    ├──────────┐                        │ (optional enhancement)
    ▼          ▼                        ▼
PRD-002    PRD-003                  PRD-004 benefits from PRD-001
(Time)     (Correlation)            but works independently
    │          │
    └────┬─────┘
         ▼
    PRD-005 (Log Structuring Guide)
    (documentation, no code deps)
```

## Implementation Order

| Phase | PRD | Issue | Description | Effort |
|-------|-----|-------|-------------|--------|
| 1 | PRD-001 | #1 | JSON structured log format support | L |
| 2 | PRD-004 | #4 | Configurable error patterns & level filtering | M |
| 3 | PRD-002 | #2 | Time-based log filtering | L |
| 4 | PRD-003 | #3 | Correlation ID filtering | L |
| 5 | PRD-005 | — | Log structuring best practices guide | S |
| 1* | PRD-006 | #5 | Setup/install script for easy onboarding | M |

**Rationale**: PRD-001 is the foundation — JSON parsing unlocks accurate severity filtering, timestamp extraction, and field-based correlation. PRD-004 is independent and high-impact (reduces false positives immediately). PRD-002 and PRD-003 build on PRD-001's JSON parsing. PRD-005 is documentation that references all tools. PRD-006 is independent and can be done in parallel with any phase — marked as Phase 1* since it unblocks adoption.

## PRD List

- [PRD-001: JSON Structured Log Format](001-json-structured-logs.md)
- [PRD-002: Time-Based Log Filtering](002-time-based-filtering.md)
- [PRD-003: Correlation ID Filtering](003-correlation-id-filtering.md)
- [PRD-004: Configurable Error Patterns](004-configurable-error-patterns.md)
- [PRD-005: Log Structuring Guide](005-log-structuring-guide.md)
- [PRD-006: Setup/Install Script](006-setup-install-script.md)
