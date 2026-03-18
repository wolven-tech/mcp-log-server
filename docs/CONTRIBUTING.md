---
title: Contributing to MCP Log Server
description: Guidelines for contributing code and documentation
status: active
created: 2026-03-18
lastModified: 2026-03-18
tags: [contributing, guidelines]
---

# Contributing to MCP Log Server

## Development Setup

1. Install Elixir 1.17+ and Erlang/OTP 27+
2. Clone the repository
3. Run `mix deps.get`
4. Run tests: `mix test`

## Running Locally

```bash
LOG_DIR=/tmp/test-logs mix run --no-halt
```

## Architecture

The codebase follows a layered architecture. See [Architecture](concepts/ARCHITECTURE.md) for details.

When adding new tools:
1. Define the schema in `lib/mcp_log_server/tools/registry.ex`
2. Add dispatch logic in `lib/mcp_log_server/tools/dispatcher.ex`
3. Add domain logic in `lib/mcp_log_server/domain/log_reader.ex`
4. Add integration tests in `test/integration_test.exs`

## Code Style

- Pure functions in the domain layer — no side effects beyond file I/O
- Type specs on all public functions
- Pattern matching over conditionals where possible
- Keep modules focused and under 200 lines

## Documentation Standards

Documentation follows the [Diataxis](https://diataxis.fr/) framework:

- **getting-started/**: Tutorials — learning-oriented
- **guides/**: How-to guides — task-oriented
- **concepts/**: Explanations — understanding-oriented
- **reference/**: Technical reference — information-oriented

All documentation files should include YAML frontmatter:

```yaml
---
title: Document Title
description: Brief description (1-2 sentences)
status: active | draft | deprecated
created: YYYY-MM-DD
lastModified: YYYY-MM-DD
tags: [relevant, tags]
---
```

## Pull Requests

- Keep PRs focused on a single change
- Include tests for new tools or features
- Update documentation if adding or changing tool behavior

---

**[Back to Documentation Index](README.md)**
