# PRD-006: Setup/Install Script for Easy Onboarding

**GitHub Issue:** #5
**Status:** Draft
**Priority:** P1 — Independent, high adoption impact

---

## Problem Statement

Getting the MCP log server running requires multiple manual steps:
1. Clone the repo (or pull the Docker image)
2. Build the Docker image
3. Create `.mcp.json` config with the correct volume mount
4. Create the log directory
5. Understand how to pipe/dump logs into the directory
6. Restart the editor/MCP client

Each developer on a team must figure this out independently. There's no single command that handles it. This friction is the #1 barrier to adoption.

## Goals

1. Ship a `setup.sh` script that automates the full onboarding flow
2. Auto-detect the MCP client (Claude Code, Cursor, VS Code) and write config to the correct location
3. Pre-flight validation (Docker running, ports available, etc.)
4. Support both Docker-based and source-based installation
5. Provide a `.mcp.json.example` for teams to copy into their projects
6. Make the GHCR Docker image the primary installation path (no clone needed)

## Non-Goals

- Windows support in v1 (Linux and macOS only)
- Auto-updating the server
- Managing log rotation or cleanup
- IDE plugin development

## Design

### 1. Installation Paths

#### Path A: Docker (recommended, no clone)

```bash
# One-liner setup
curl -fsSL https://raw.githubusercontent.com/wolven-tech/mcp-log-server/main/setup.sh | bash
```

Or for those who don't pipe to bash:
```bash
git clone https://github.com/wolven-tech/mcp-log-server.git /tmp/mcp-log-setup
/tmp/mcp-log-setup/setup.sh
```

#### Path B: From source (for contributors)

```bash
git clone https://github.com/wolven-tech/mcp-log-server.git
cd mcp-log-server
./setup.sh --from-source
```

### 2. `setup.sh` Script Flow

```
┌─────────────────────────────┐
│ 1. Pre-flight checks        │
│    - Docker installed?      │
│    - Docker daemon running? │
│    - (source) Elixir 1.17+? │
├─────────────────────────────┤
│ 2. Install server           │
│    Docker: pull from GHCR   │
│    Source: mix deps.get +   │
│           mix compile       │
├─────────────────────────────┤
│ 3. Detect MCP client        │
│    - Claude Code (.claude/)  │
│    - Cursor (.cursor/)      │
│    - VS Code (.vscode/)     │
│    - Manual (prompt user)   │
├─────────────────────────────┤
│ 4. Configure log directory  │
│    - Prompt or use default  │
│    - mkdir -p               │
├─────────────────────────────┤
│ 5. Write MCP config         │
│    - .mcp.json (project) or │
│    - Global settings path   │
├─────────────────────────────┤
│ 6. Verify installation      │
│    - Quick health check     │
│    - Print next steps       │
└─────────────────────────────┘
```

### 3. MCP Client Detection & Config

#### Claude Code

Config location: `.mcp.json` in project root, or `~/.claude/claude_desktop_config.json` for global.

```json
{
  "mcpServers": {
    "log-server": {
      "command": "docker",
      "args": [
        "run", "--rm", "-i",
        "-v", "./tmp/logs:/tmp/mcp-logs:ro",
        "ghcr.io/wolven-tech/mcp-log-server:latest"
      ]
    }
  }
}
```

#### Cursor

Config location: `.cursor/mcp.json` in project root.

Same JSON structure as Claude Code.

#### VS Code (with MCP extension)

Config location: `.vscode/settings.json` under `mcp.servers`.

```json
{
  "mcp.servers": {
    "log-server": {
      "command": "docker",
      "args": [
        "run", "--rm", "-i",
        "-v", "./tmp/logs:/tmp/mcp-logs:ro",
        "ghcr.io/wolven-tech/mcp-log-server:latest"
      ]
    }
  }
}
```

#### From source (non-Docker)

```json
{
  "mcpServers": {
    "log-server": {
      "command": "bash",
      "args": ["-c", "cd /path/to/mcp-log-server && LOG_DIR=/path/to/logs mix run --no-halt"],
      "env": {
        "LOG_DIR": "./tmp/logs"
      }
    }
  }
}
```

### 4. Interactive Prompts

The script should be interactive with sensible defaults:

```
MCP Log Server Setup
====================

[1/4] Installation method
  > Docker (recommended) [D]
    From source [S]

[2/4] Log directory
  Where should log files be stored?
  > ./tmp/logs [Enter to accept default]

[3/4] MCP client detected: Claude Code
  Write config to .mcp.json? [Y/n]

[4/4] Scope
  > Project only (this directory) [P]
    Global (all projects) [G]

✓ Docker image pulled: ghcr.io/wolven-tech/mcp-log-server:latest
✓ Log directory created: ./tmp/logs
✓ MCP config written to .mcp.json

Next steps:
  1. Pipe your logs: turbo run dev 2>&1 | tee ./tmp/logs/apps.log
  2. Restart your editor to pick up the MCP config
  3. Ask Claude: "Check my logs for errors"
```

### 5. Non-Interactive Mode

For CI/automation:

```bash
./setup.sh --non-interactive --docker --log-dir=./tmp/logs --client=claude-code --scope=project
```

### 6. `.mcp.json.example`

Ship a ready-to-copy example in the repo root:

```json
{
  "mcpServers": {
    "log-server": {
      "command": "docker",
      "args": [
        "run", "--rm", "-i",
        "-v", "./tmp/logs:/tmp/mcp-logs:ro",
        "ghcr.io/wolven-tech/mcp-log-server:latest"
      ]
    }
  }
}
```

### 7. Makefile Target for Teams

Provide a copy-paste Makefile snippet in the docs for teams to add to their projects:

```makefile
.PHONY: mcp-log-setup mcp-log-start

LOG_DIR ?= tmp/logs

mcp-log-setup:
	@docker pull ghcr.io/wolven-tech/mcp-log-server:latest
	@mkdir -p $(LOG_DIR)
	@test -f .mcp.json || cp .mcp.json.example .mcp.json
	@echo "✓ MCP log server ready. Dump logs to $(LOG_DIR)/"

mcp-log-start:
	@docker run --rm -i -v ./$(LOG_DIR):/tmp/mcp-logs:ro ghcr.io/wolven-tech/mcp-log-server:latest
```

### 8. Health Check / Verification

After setup, run a quick verification:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"setup","version":"1.0"}}}' | \
  docker run --rm -i ghcr.io/wolven-tech/mcp-log-server:latest | \
  head -1 | jq -r '.result.serverInfo.name'
```

Expected: `mcp-log-server` — confirms the server is working.

## User Stories

### US-1: One-command Docker setup
**As** a developer adopting the MCP log server,
**I want** to run a single setup command,
**So that** I'm ready to query logs within 2 minutes without reading documentation.

**Acceptance Criteria:**
- `./setup.sh` pulls Docker image, creates log dir, writes MCP config
- Works on macOS and Linux
- Pre-flight checks: Docker installed and running
- Clear error message if Docker is not available

### US-2: MCP client auto-detection
**As** a developer using Cursor (or Claude Code, or VS Code),
**I want** the setup script to detect my editor and write config to the right place,
**So that** I don't need to know the config file location.

**Acceptance Criteria:**
- Detects Claude Code (.claude/ directory or `claude` in PATH)
- Detects Cursor (.cursor/ directory)
- Detects VS Code (.vscode/ directory)
- Falls back to generic .mcp.json if none detected
- Prompts for confirmation before writing

### US-3: Project-scoped example config
**As** a team lead adding MCP log server to our monorepo,
**I want** a `.mcp.json.example` to commit to the repo,
**So that** new team members can `cp .mcp.json.example .mcp.json` and be set up.

**Acceptance Criteria:**
- `.mcp.json.example` in repo root with Docker config
- Uses relative path `./tmp/logs` for log directory
- `tmp/logs/` added to `.gitignore`
- Setup docs reference the example file

### US-4: Non-interactive mode for CI/automation
**As** a DevOps engineer automating developer environment setup,
**I want** to run setup in non-interactive mode with flags,
**So that** I can include it in our bootstrap scripts.

**Acceptance Criteria:**
- `--non-interactive` flag skips all prompts
- `--docker` / `--from-source` selects install method
- `--log-dir=PATH` sets log directory
- `--client=claude-code|cursor|vscode` sets target client
- `--scope=project|global` sets config scope
- Exits with non-zero code on failure

## Implementation Plan

1. **setup.sh** — main script with pre-flight checks, Docker pull, interactive prompts
2. **MCP client detection** — function to detect Claude Code, Cursor, VS Code
3. **Config generators** — functions to write correct JSON for each client
4. **Non-interactive mode** — flag parsing with getopt
5. **`.mcp.json.example`** — example config in repo root
6. **Health check** — verification step after setup
7. **Update QUICK_START.md** — reference setup.sh as the recommended onboarding path
8. **Update README.md** — add "Quick Install" section at top

## Dependencies

- Docker image published to GHCR (already done via release workflow)
- No code dependencies on other PRDs
