#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# MCP Log Server — Setup Script
# =============================================================================
# Installs MCP Log Server via Docker (default) or from source (--from-source).
# See: https://github.com/wolven-tech/mcp-log-server
# =============================================================================

DOCKER_IMAGE="ghcr.io/wolven-tech/mcp-log-server:latest"
DEFAULT_LOG_DIR="./tmp/logs"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

info()  { printf '\033[1;34m[info]\033[0m  %s\n' "$1"; }
ok()    { printf '\033[1;32m[ok]\033[0m    %s\n' "$1"; }
warn()  { printf '\033[1;33m[warn]\033[0m  %s\n' "$1"; }
err()   { printf '\033[1;31m[error]\033[0m %s\n' "$1" >&2; }

die() {
  err "$1"
  exit 1
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------

FROM_SOURCE=false
NON_INTERACTIVE=false
LOG_DIR=""
CLIENT=""
SCOPE="project"
CONFIG_FILE_WRITTEN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-source)
      FROM_SOURCE=true
      shift
      ;;
    --non-interactive)
      NON_INTERACTIVE=true
      shift
      ;;
    --log-dir=*)
      LOG_DIR="${1#*=}"
      shift
      ;;
    --log-dir)
      if [[ -z "${2:-}" ]]; then
        die "--log-dir requires a value"
      fi
      LOG_DIR="$2"
      shift 2
      ;;
    --client=*)
      CLIENT="${1#*=}"
      shift
      ;;
    --client)
      if [[ -z "${2:-}" ]]; then
        die "--client requires a value (claude-code|cursor|vscode)"
      fi
      CLIENT="$2"
      shift 2
      ;;
    --scope=*)
      SCOPE="${1#*=}"
      shift
      ;;
    --scope)
      if [[ -z "${2:-}" ]]; then
        die "--scope requires a value (project|global)"
      fi
      SCOPE="$2"
      shift 2
      ;;
    -h|--help)
      cat <<'USAGE'
Usage: ./setup.sh [OPTIONS]

Options:
  --from-source       Build from source (requires Elixir 1.17+) instead of Docker
  --non-interactive   Use defaults without prompting
  --log-dir=PATH      Set the log directory (default: ./tmp/logs)
  --client=CLIENT     MCP client: claude-code, cursor, vscode (auto-detected if omitted)
  --scope=SCOPE       Config scope: project (default) or global
  -h, --help          Show this help message

Examples:
  ./setup.sh                              # Docker setup, interactive
  ./setup.sh --non-interactive            # Docker setup, all defaults
  ./setup.sh --from-source                # Build from Elixir source
  ./setup.sh --log-dir=/var/log/myapp     # Custom log directory
  ./setup.sh --client=cursor              # Force Cursor client config
  ./setup.sh --scope=global               # Write global config
USAGE
      exit 0
      ;;
    *)
      die "Unknown option: $1 (use --help for usage)"
      ;;
  esac
done

# Validate --client and --scope values
if [[ -n "$CLIENT" ]] && [[ "$CLIENT" != "claude-code" ]] && [[ "$CLIENT" != "cursor" ]] && [[ "$CLIENT" != "vscode" ]]; then
  die "Invalid --client value: $CLIENT (must be claude-code, cursor, or vscode)"
fi

if [[ "$SCOPE" != "project" ]] && [[ "$SCOPE" != "global" ]]; then
  die "Invalid --scope value: $SCOPE (must be project or global)"
fi

# -----------------------------------------------------------------------------
# Pre-flight checks
# -----------------------------------------------------------------------------

preflight_docker() {
  info "Checking Docker installation..."

  if ! command -v docker >/dev/null 2>&1; then
    err "Docker is not installed."
    echo ""
    echo "Install Docker:"
    echo "  macOS  — https://docs.docker.com/desktop/install/mac-install/"
    echo "  Linux  — https://docs.docker.com/engine/install/"
    echo ""
    echo "Or run with --from-source to build from Elixir instead."
    exit 1
  fi
  ok "Docker is installed ($(docker --version))"

  info "Checking Docker daemon..."
  if ! docker info >/dev/null 2>&1; then
    err "Docker daemon is not running."
    echo ""
    echo "Start Docker:"
    echo "  macOS  — Open Docker Desktop"
    echo "  Linux  — sudo systemctl start docker"
    exit 1
  fi
  ok "Docker daemon is running"
}

preflight_source() {
  info "Checking Elixir installation..."

  if ! command -v elixir >/dev/null 2>&1; then
    err "Elixir is not installed."
    echo ""
    echo "Install Elixir 1.17+:"
    echo "  macOS  — brew install elixir"
    echo "  Linux  — https://elixir-lang.org/install.html"
    echo "  asdf   — asdf install elixir 1.17.3-otp-27"
    exit 1
  fi

  local elixir_version
  elixir_version="$(elixir --version | grep -oE 'Elixir [0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+')"

  if [[ -z "$elixir_version" ]]; then
    die "Could not determine Elixir version."
  fi

  local major minor
  major="${elixir_version%%.*}"
  minor="${elixir_version#*.}"

  if [[ "$major" -lt 1 ]] || { [[ "$major" -eq 1 ]] && [[ "$minor" -lt 17 ]]; }; then
    err "Elixir >= 1.17 is required (found $elixir_version)."
    echo ""
    echo "Upgrade Elixir:"
    echo "  macOS  — brew upgrade elixir"
    echo "  asdf   — asdf install elixir 1.17.3-otp-27"
    exit 1
  fi
  ok "Elixir $elixir_version is installed"

  info "Checking Mix availability..."
  if ! command -v mix >/dev/null 2>&1; then
    die "mix command not found. Elixir may not be installed correctly."
  fi
  ok "Mix is available"
}

# -----------------------------------------------------------------------------
# Log directory setup
# -----------------------------------------------------------------------------

setup_log_dir() {
  if [[ -z "$LOG_DIR" ]]; then
    if [[ "$NON_INTERACTIVE" == true ]]; then
      LOG_DIR="$DEFAULT_LOG_DIR"
    else
      printf '\033[1;34m[input]\033[0m Log directory [%s]: ' "$DEFAULT_LOG_DIR"
      read -r user_input
      LOG_DIR="${user_input:-$DEFAULT_LOG_DIR}"
    fi
  fi

  info "Creating log directory: $LOG_DIR"
  mkdir -p "$LOG_DIR"
  ok "Log directory ready: $LOG_DIR"
}

# -----------------------------------------------------------------------------
# Docker setup
# -----------------------------------------------------------------------------

setup_docker() {
  info "Pulling $DOCKER_IMAGE ..."
  docker pull "$DOCKER_IMAGE"
  ok "Docker image pulled"
}

# -----------------------------------------------------------------------------
# Source setup
# -----------------------------------------------------------------------------

setup_source() {
  info "Fetching dependencies..."
  mix deps.get
  ok "Dependencies fetched"

  info "Compiling project..."
  mix compile
  ok "Compilation complete"
}

# -----------------------------------------------------------------------------
# MCP client detection
# -----------------------------------------------------------------------------

detect_client() {
  if [[ -n "$CLIENT" ]]; then
    info "Using specified client: $CLIENT"
    return
  fi

  info "Auto-detecting MCP client..."

  if [[ -d ".claude" ]] || command -v claude >/dev/null 2>&1; then
    CLIENT="claude-code"
    ok "Detected Claude Code"
    return
  fi

  if [[ -d ".cursor" ]]; then
    CLIENT="cursor"
    ok "Detected Cursor"
    return
  fi

  if [[ -d ".vscode" ]]; then
    CLIENT="vscode"
    ok "Detected VS Code"
    return
  fi

  CLIENT="generic"
  info "No specific MCP client detected, using generic .mcp.json"
}

# -----------------------------------------------------------------------------
# Config file path resolution
# -----------------------------------------------------------------------------

resolve_config_path() {
  case "$CLIENT" in
    claude-code)
      if [[ "$SCOPE" == "global" ]]; then
        echo "$HOME/.claude/claude_desktop_config.json"
      else
        echo ".mcp.json"
      fi
      ;;
    cursor)
      if [[ "$SCOPE" == "global" ]]; then
        warn "Cursor does not support global scope; falling back to project scope."
        echo ".cursor/mcp.json"
      else
        echo ".cursor/mcp.json"
      fi
      ;;
    vscode)
      if [[ "$SCOPE" == "global" ]]; then
        warn "VS Code does not support global scope; falling back to project scope."
        echo ".vscode/mcp.json"
      else
        echo ".vscode/mcp.json"
      fi
      ;;
    generic|*)
      if [[ "$SCOPE" == "global" ]]; then
        echo "$HOME/.mcp.json"
      else
        echo ".mcp.json"
      fi
      ;;
  esac
}

# -----------------------------------------------------------------------------
# JSON config generation
# -----------------------------------------------------------------------------

generate_server_block_docker() {
  local abs_log_dir="$1"
  local indent="$2"
  printf '{\n'
  printf '%s  "command": "docker",\n' "$indent"
  printf '%s  "args": ["run", "--rm", "-i", "-v", "%s:/tmp/mcp-logs", "%s"],\n' "$indent" "$abs_log_dir" "$DOCKER_IMAGE"
  printf '%s  "type": "stdio"\n' "$indent"
  printf '%s}' "$indent"
}

generate_server_block_source() {
  local abs_log_dir="$1"
  local indent="$2"
  local project_dir
  project_dir="$(pwd)"
  printf '{\n'
  printf '%s  "command": "bash",\n' "$indent"
  printf '%s  "args": ["-c", "cd %s && LOG_DIR=%s mix run --no-halt"],\n' "$indent" "$project_dir" "$abs_log_dir"
  printf '%s  "type": "stdio"\n' "$indent"
  printf '%s}' "$indent"
}

generate_config_json() {
  local abs_log_dir="$1"
  local server_block

  case "$CLIENT" in
    vscode)
      # VS Code uses .vscode/mcp.json with top-level "servers" key
      # Ref: https://code.visualstudio.com/docs/copilot/customization/mcp-servers
      if [[ "$FROM_SOURCE" == true ]]; then
        server_block="$(generate_server_block_source "$abs_log_dir" "    ")"
      else
        server_block="$(generate_server_block_docker "$abs_log_dir" "    ")"
      fi
      printf '{\n'
      printf '  "servers": {\n'
      printf '    "log-server": %s\n' "$server_block"
      printf '  }\n'
      printf '}\n'
      ;;
    *)
      # Claude Code, Cursor, and generic all use mcpServers
      if [[ "$FROM_SOURCE" == true ]]; then
        server_block="$(generate_server_block_source "$abs_log_dir" "    ")"
      else
        server_block="$(generate_server_block_docker "$abs_log_dir" "    ")"
      fi
      printf '{\n'
      printf '  "mcpServers": {\n'
      printf '    "log-server": %s\n' "$server_block"
      printf '  }\n'
      printf '}\n'
      ;;
  esac
}

# -----------------------------------------------------------------------------
# Merge into existing global Claude config
# -----------------------------------------------------------------------------

merge_claude_global_config() {
  local config_path="$1"
  local abs_log_dir="$2"
  local server_block

  if [[ "$FROM_SOURCE" == true ]]; then
    server_block="$(generate_server_block_source "$abs_log_dir" "    ")"
  else
    server_block="$(generate_server_block_docker "$abs_log_dir" "    ")"
  fi

  if [[ ! -f "$config_path" ]]; then
    # File doesn't exist yet — write full config
    mkdir -p "$(dirname "$config_path")"
    generate_config_json "$abs_log_dir" > "$config_path"
    return
  fi

  # File exists — check if it already has mcpServers
  if grep -q '"mcpServers"' "$config_path" 2>/dev/null; then
    # Check if log-server already defined
    if grep -q '"log-server"' "$config_path" 2>/dev/null; then
      warn "log-server entry already exists in $config_path — skipping merge."
      return 1
    fi
    # Insert log-server into existing mcpServers block
    # Find the line with "mcpServers": { and insert after it
    local tmp_file="${config_path}.tmp.$$"
    local inserted=false
    while IFS= read -r line; do
      printf '%s\n' "$line"
      if [[ "$inserted" == false ]] && printf '%s' "$line" | grep -q '"mcpServers"'; then
        # Print the server entry (indented to match existing format)
        printf '    "log-server": %s,\n' "$server_block"
        inserted=true
      fi
    done < "$config_path" > "$tmp_file"
    mv "$tmp_file" "$config_path"
  else
    # No mcpServers key — write fresh config (overwrite)
    generate_config_json "$abs_log_dir" > "$config_path"
  fi
}

# -----------------------------------------------------------------------------
# Write MCP config file
# -----------------------------------------------------------------------------

write_mcp_config() {
  local abs_log_dir
  if [[ "$LOG_DIR" == /* ]]; then
    abs_log_dir="$LOG_DIR"
  else
    abs_log_dir="$(cd "$LOG_DIR" && pwd)"
  fi

  local config_path
  config_path="$(resolve_config_path)"

  info "Config file target: $config_path"

  # Check if file already exists
  if [[ -f "$config_path" ]]; then
    # Special handling for Claude Code global merge
    if [[ "$CLIENT" == "claude-code" ]] && [[ "$SCOPE" == "global" ]]; then
      if [[ "$NON_INTERACTIVE" == true ]]; then
        info "Merging log-server into existing $config_path"
        if merge_claude_global_config "$config_path" "$abs_log_dir"; then
          ok "Config merged into $config_path"
          CONFIG_FILE_WRITTEN="$config_path"
        else
          warn "Skipped config writing (entry already exists)."
        fi
        return
      else
        printf '\033[1;34m[input]\033[0m %s exists. Merge log-server entry? [Y/n]: ' "$config_path"
        read -r confirm
        if [[ "$confirm" =~ ^[Nn] ]]; then
          warn "Skipped config writing."
          return
        fi
        if merge_claude_global_config "$config_path" "$abs_log_dir"; then
          ok "Config merged into $config_path"
          CONFIG_FILE_WRITTEN="$config_path"
        else
          warn "Skipped config writing (entry already exists)."
        fi
        return
      fi
    fi

    # Non-global or non-claude: ask before overwriting
    if [[ "$NON_INTERACTIVE" == true ]]; then
      warn "Config file $config_path already exists — skipping (non-interactive mode)."
      return
    fi

    printf '\033[1;34m[input]\033[0m %s already exists. Overwrite? [y/N]: ' "$config_path"
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
      warn "Skipped config writing."
      return
    fi
  fi

  # Prompt for confirmation before writing (unless non-interactive)
  if [[ ! -f "$config_path" ]] && [[ "$NON_INTERACTIVE" != true ]]; then
    echo ""
    info "Will write the following config to $config_path:"
    echo ""
    generate_config_json "$abs_log_dir"
    echo ""
    printf '\033[1;34m[input]\033[0m Write this config? [Y/n]: '
    read -r confirm
    if [[ "$confirm" =~ ^[Nn] ]]; then
      warn "Skipped config writing."
      return
    fi
  fi

  # Create parent directory if needed
  local parent_dir
  parent_dir="$(dirname "$config_path")"
  if [[ "$parent_dir" != "." ]] && [[ ! -d "$parent_dir" ]]; then
    mkdir -p "$parent_dir"
  fi

  # Handle Claude Code global merge for new file
  if [[ "$CLIENT" == "claude-code" ]] && [[ "$SCOPE" == "global" ]]; then
    merge_claude_global_config "$config_path" "$abs_log_dir"
  else
    generate_config_json "$abs_log_dir" > "$config_path"
  fi

  ok "Config written to $config_path"
  CONFIG_FILE_WRITTEN="$config_path"
}

# -----------------------------------------------------------------------------
# Health check (Docker only)
# -----------------------------------------------------------------------------

health_check_docker() {
  info "Running health check against Docker image..."

  local init_request='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"setup-health-check","version":"0.1.0"}}}'

  local response
  if response="$(echo "$init_request" | docker run --rm -i "$DOCKER_IMAGE" 2>/dev/null)"; then
    if printf '%s' "$response" | grep -q '"serverInfo"'; then
      ok "Health check passed — server responded with serverInfo"
      return 0
    else
      warn "Health check: server responded but serverInfo not found in response."
      return 1
    fi
  else
    warn "Health check: could not get a response from the server container."
    return 1
  fi
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

print_summary() {
  local abs_log_dir
  # Resolve to absolute path for display
  if [[ "$LOG_DIR" == /* ]]; then
    abs_log_dir="$LOG_DIR"
  else
    abs_log_dir="$(cd "$LOG_DIR" && pwd)"
  fi

  echo ""
  echo "============================================="
  echo " MCP Log Server — Setup Complete"
  echo "============================================="
  echo ""
  echo " Log directory: $abs_log_dir"

  if [[ "$FROM_SOURCE" == true ]]; then
    echo " Mode:          from source"
  else
    echo " Mode:          Docker ($DOCKER_IMAGE)"
  fi

  echo " Client:        $CLIENT"

  if [[ -n "$CONFIG_FILE_WRITTEN" ]]; then
    echo " Config file:   $CONFIG_FILE_WRITTEN"
  fi

  echo ""
  echo " Next steps:"
  echo ""
  echo " 1. Place .log files in: $abs_log_dir"
  echo ""

  if [[ -n "$CONFIG_FILE_WRITTEN" ]]; then
    echo " 2. Your MCP client is configured. Start coding!"
  else
    echo " 2. Add to your project's MCP config manually:"
    echo ""
    generate_config_json "$abs_log_dir"
  fi

  echo ""
  echo " 3. Restart your editor / MCP client to pick up the new config."
  echo ""
  echo " For more details, see: docs/guides/MCP_CLIENT_SETUP.md"
  echo "============================================="
  echo ""
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
  echo ""
  echo "  MCP Log Server Setup"
  echo "  ====================="
  echo ""

  if [[ "$FROM_SOURCE" == true ]]; then
    preflight_source
  else
    preflight_docker
  fi

  setup_log_dir

  if [[ "$FROM_SOURCE" == true ]]; then
    setup_source
  else
    setup_docker
  fi

  # Health check (Docker only — source requires a running server)
  if [[ "$FROM_SOURCE" != true ]]; then
    health_check_docker || true
  fi

  detect_client
  write_mcp_config

  print_summary
}

main
