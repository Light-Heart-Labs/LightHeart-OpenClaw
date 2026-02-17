#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# Lighthouse AI - Installer
# https://github.com/Light-Heart-Labs/Lighthouse-AI
#
# Usage:
#   ./install.sh                      # Interactive install
#   ./install.sh --config my.yaml     # Use custom config
#   ./install.sh --cleanup-only       # Only install session cleanup
#   ./install.sh --proxy-only         # Only install tool proxy
#   ./install.sh --token-spy-only     # Only install Token Spy API monitor
#   ./install.sh --cold-storage-only  # Only install LLM Cold Storage timer
#   ./install.sh --uninstall          # Remove everything
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.yaml"
CLEANUP_ONLY=false
PROXY_ONLY=false
TOKEN_SPY_ONLY=false
COLD_STORAGE_ONLY=false
UNINSTALL=false

# ── Colors ─────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[  OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[FAIL]${NC} $1"; }

# ── Parse args ─────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case $1 in
        --config)       CONFIG_FILE="$2"; shift 2 ;;
        --cleanup-only)   CLEANUP_ONLY=true; shift ;;
        --proxy-only)     PROXY_ONLY=true; shift ;;
        --token-spy-only) TOKEN_SPY_ONLY=true; shift ;;
        --cold-storage-only) COLD_STORAGE_ONLY=true; shift ;;
        --uninstall)      UNINSTALL=true; shift ;;
        -h|--help)
            echo "Usage: ./install.sh [options]"
            echo ""
            echo "Options:"
            echo "  --config FILE       Use custom config file (default: config.yaml)"
            echo "  --cleanup-only      Only install session cleanup"
            echo "  --proxy-only        Only install vLLM tool proxy"
            echo "  --token-spy-only    Only install Token Spy API monitor"
            echo "  --cold-storage-only Only install LLM Cold Storage timer"
            echo "  --uninstall         Remove all installed components"
            echo "  -h, --help          Show this help"
            exit 0
            ;;
        *) err "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Banner ─────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Lighthouse AI - Installer${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo ""

# ── Parse config (section-aware YAML parser — no dependencies needed) ──
# Usage: parse_yaml "section.key" "default"  — reads key within a section
#        parse_yaml "key" "default"           — reads top-level key (legacy)
parse_yaml() {
    local input="$1"
    local default="$2"
    local section="" key="" value=""

    if [[ "$input" == *.* ]]; then
        section="${input%%.*}"
        key="${input#*.}"
    else
        key="$input"
    fi

    if [ -n "$section" ]; then
        # Extract lines between "section:" and the next top-level key (non-indented)
        value=$(sed -n "/^${section}:/,/^[a-zA-Z_]/{/^${section}:/d;/^[a-zA-Z_]/d;p;}" "$CONFIG_FILE" \
            | grep -E "^\s+${key}:" | head -1 \
            | sed 's/.*:\s*//' | sed 's/\s*#.*//' | sed 's/^"//' | sed 's/"$//' | sed "s/^'//" | sed "s/'$//" | xargs)
    else
        value=$(grep -E "^\s*${key}:" "$CONFIG_FILE" 2>/dev/null | head -1 \
            | sed 's/.*:\s*//' | sed 's/\s*#.*//' | sed 's/^"//' | sed 's/"$//' | sed "s/^'//" | sed "s/'$//" | xargs)
    fi

    if [ -z "$value" ] || [ "$value" = '""' ] || [ "$value" = "''" ]; then
        echo "$default"
    else
        echo "$value"
    fi
}

# ── Load config ────────────────────────────────────────────────
if [ ! -f "$CONFIG_FILE" ]; then
    err "Config file not found: $CONFIG_FILE"
    info "Copy config.yaml.example to config.yaml and edit it first"
    exit 1
fi

info "Loading config from $CONFIG_FILE"

# Session cleanup settings
CLEANUP_ENABLED=$(parse_yaml "session_cleanup.enabled" "true")
OPENCLAW_DIR=$(parse_yaml "session_cleanup.openclaw_dir" "~/.openclaw")
OPENCLAW_DIR="${OPENCLAW_DIR/#\~/$HOME}"
SESSIONS_PATH=$(parse_yaml "session_cleanup.sessions_path" "agents/main/sessions")
MAX_SESSION_SIZE=$(parse_yaml "session_cleanup.max_session_size" "256000")
INTERVAL_MINUTES=$(parse_yaml "session_cleanup.interval_minutes" "60")
BOOT_DELAY=$(parse_yaml "session_cleanup.boot_delay_minutes" "5")

# Proxy settings
PROXY_ENABLED=$(parse_yaml "tool_proxy.enabled" "true")
PROXY_PORT=$(parse_yaml "tool_proxy.port" "8003")
PROXY_HOST=$(parse_yaml "tool_proxy.host" "0.0.0.0")
VLLM_URL=$(parse_yaml "tool_proxy.vllm_url" "http://localhost:8000")
LOG_FILE=$(parse_yaml "tool_proxy.log_file" "~/vllm-proxy.log")
LOG_FILE="${LOG_FILE/#\~/$HOME}"

# Token Spy settings
TS_ENABLED=$(parse_yaml "token_spy.enabled" "false")
TS_AGENT_NAME=$(parse_yaml "token_spy.agent_name" "my-agent")
TS_PORT=$(parse_yaml "token_spy.port" "9110")
TS_HOST=$(parse_yaml "token_spy.host" "0.0.0.0")
TS_ANTHROPIC_UPSTREAM=$(parse_yaml "token_spy.anthropic_upstream" "https://api.anthropic.com")
TS_OPENAI_UPSTREAM=$(parse_yaml "token_spy.openai_upstream" "")
TS_API_PROVIDER=$(parse_yaml "token_spy.api_provider" "anthropic")
TS_DB_BACKEND=$(parse_yaml "token_spy.db_backend" "sqlite")
TS_SESSION_CHAR_LIMIT=$(parse_yaml "token_spy.session_char_limit" "200000")
TS_AGENT_SESSION_DIRS=$(parse_yaml "token_spy.agent_session_dirs" "")
TS_LOCAL_MODEL_AGENTS=$(parse_yaml "token_spy.local_model_agents" "")

# LLM Cold Storage settings
CS_ENABLED=$(parse_yaml "llm_cold_storage.enabled" "false")
CS_HF_CACHE=$(parse_yaml "llm_cold_storage.hf_cache_dir" "~/.cache/huggingface/hub")
CS_HF_CACHE="${CS_HF_CACHE/#\~/$HOME}"
CS_COLD_DIR=$(parse_yaml "llm_cold_storage.cold_dir" "~/llm-cold-storage")
CS_COLD_DIR="${CS_COLD_DIR/#\~/$HOME}"
CS_MAX_IDLE_DAYS=$(parse_yaml "llm_cold_storage.max_idle_days" "7")

# System user
SYSTEM_USER=$(parse_yaml "system_user" "")
if [ -z "$SYSTEM_USER" ]; then
    SYSTEM_USER="$(whoami)"
fi

echo ""
info "Configuration:"
info "  OpenClaw dir:     $OPENCLAW_DIR"
info "  System user:      $SYSTEM_USER"
info "  Max session size: $MAX_SESSION_SIZE bytes"
info "  Cleanup interval: ${INTERVAL_MINUTES}min"
if [ "$PROXY_ONLY" = false ] && [ "$TOKEN_SPY_ONLY" = false ]; then
    info "  Session cleanup:  $([ "$CLEANUP_ENABLED" = "true" ] && echo "enabled" || echo "disabled")"
fi
if [ "$CLEANUP_ONLY" = false ] && [ "$TOKEN_SPY_ONLY" = false ]; then
    info "  Tool proxy:       $([ "$PROXY_ENABLED" = "true" ] && echo "enabled on :$PROXY_PORT -> $VLLM_URL" || echo "disabled")"
fi
if [ "$CLEANUP_ONLY" = false ] && [ "$PROXY_ONLY" = false ]; then
    info "  Token Spy:        $([ "$TS_ENABLED" = "true" ] && echo "enabled on :$TS_PORT ($TS_AGENT_NAME)" || echo "disabled")"
fi
if [ "$COLD_STORAGE_ONLY" = true ] || ([ "$CLEANUP_ONLY" = false ] && [ "$PROXY_ONLY" = false ] && [ "$TOKEN_SPY_ONLY" = false ]); then
    info "  Cold Storage:     $([ "$CS_ENABLED" = "true" ] && echo "enabled (idle >${CS_MAX_IDLE_DAYS}d → $CS_COLD_DIR)" || echo "disabled")"
fi
echo ""

# ── Uninstall ──────────────────────────────────────────────────
if [ "$UNINSTALL" = true ]; then
    info "Uninstalling Lighthouse AI..."

    if systemctl is-active --quiet openclaw-session-cleanup.timer 2>/dev/null; then
        sudo systemctl stop openclaw-session-cleanup.timer
        sudo systemctl disable openclaw-session-cleanup.timer
        ok "Stopped session cleanup timer"
    fi
    sudo rm -f /etc/systemd/system/openclaw-session-cleanup.service
    sudo rm -f /etc/systemd/system/openclaw-session-cleanup.timer

    if systemctl is-active --quiet vllm-tool-proxy 2>/dev/null; then
        sudo systemctl stop vllm-tool-proxy
        sudo systemctl disable vllm-tool-proxy
        ok "Stopped tool proxy service"
    fi
    sudo rm -f /etc/systemd/system/vllm-tool-proxy.service

    # Token Spy (check for any token-spy@ instances)
    for svc in $(systemctl list-units --type=service --all 2>/dev/null | grep -oP 'token-spy@[^.]+\.service' || true); do
        sudo systemctl stop "$svc" 2>/dev/null || true
        sudo systemctl disable "$svc" 2>/dev/null || true
        ok "Stopped $svc"
    done
    sudo rm -f /etc/systemd/system/token-spy@.service

    # LLM Cold Storage
    if systemctl --user is-active --quiet llm-cold-storage.timer 2>/dev/null; then
        systemctl --user stop llm-cold-storage.timer
        systemctl --user disable llm-cold-storage.timer
        ok "Stopped cold storage timer"
    fi
    rm -f "$HOME/.config/systemd/user/llm-cold-storage.service"
    rm -f "$HOME/.config/systemd/user/llm-cold-storage.timer"
    systemctl --user daemon-reload 2>/dev/null || true

    sudo systemctl daemon-reload
    rm -f "$OPENCLAW_DIR/session-cleanup.sh"

    ok "Uninstall complete"
    exit 0
fi

# ── Preflight checks ──────────────────────────────────────────
info "Running preflight checks..."

# Check for OpenClaw (not needed for cold-storage-only)
if [ "$COLD_STORAGE_ONLY" = false ]; then
    if [ ! -d "$OPENCLAW_DIR" ]; then
        err "OpenClaw directory not found: $OPENCLAW_DIR"
        err "Is OpenClaw installed? Edit openclaw_dir in config.yaml"
        exit 1
    fi
    ok "OpenClaw directory found: $OPENCLAW_DIR"
fi

# Check for python3 (not needed for cold-storage-only)
if [ "$COLD_STORAGE_ONLY" = false ]; then
    if ! command -v python3 &>/dev/null; then
        err "python3 not found. Install Python 3 first."
        exit 1
    fi
    ok "Python 3 found: $(python3 --version 2>&1)"
fi

# Check for systemd
if ! command -v systemctl &>/dev/null; then
    warn "systemd not found — will install scripts but not services"
    warn "You'll need to run them manually or set up your own scheduler"
    HAS_SYSTEMD=false
else
    ok "systemd found"
    HAS_SYSTEMD=true
fi

# Check for sudo
if [ "$HAS_SYSTEMD" = true ] && ! sudo -n true 2>/dev/null; then
    warn "sudo access required for systemd services (you'll be prompted)"
fi

# Check Python deps for proxy
if [ "$CLEANUP_ONLY" = false ] && [ "$TOKEN_SPY_ONLY" = false ] && [ "$PROXY_ENABLED" = "true" ]; then
    MISSING_DEPS=()
    python3 -c "import flask" 2>/dev/null || MISSING_DEPS+=("flask")
    python3 -c "import requests" 2>/dev/null || MISSING_DEPS+=("requests")

    if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
        warn "Missing Python packages: ${MISSING_DEPS[*]}"
        info "Installing: pip3 install ${MISSING_DEPS[*]}"
        pip3 install "${MISSING_DEPS[@]}" --quiet 2>/dev/null || {
            err "Failed to install Python dependencies"
            err "Run manually: pip3 install flask requests"
            exit 1
        }
        ok "Python dependencies installed"
    else
        ok "Python dependencies satisfied (flask, requests)"
    fi
fi

# Check Python deps for Token Spy
if ([ "$TOKEN_SPY_ONLY" = true ] || ([ "$CLEANUP_ONLY" = false ] && [ "$PROXY_ONLY" = false ])) && [ "$TS_ENABLED" = "true" ]; then
    TS_MISSING_DEPS=()
    python3 -c "import fastapi" 2>/dev/null || TS_MISSING_DEPS+=("fastapi")
    python3 -c "import httpx" 2>/dev/null || TS_MISSING_DEPS+=("httpx")
    python3 -c "import uvicorn" 2>/dev/null || TS_MISSING_DEPS+=("uvicorn")

    if [ ${#TS_MISSING_DEPS[@]} -gt 0 ]; then
        warn "Missing Token Spy packages: ${TS_MISSING_DEPS[*]}"
        info "Installing from token-spy/requirements.txt"
        pip3 install -r "$SCRIPT_DIR/token-spy/requirements.txt" --quiet 2>/dev/null || {
            err "Failed to install Token Spy dependencies"
            err "Run manually: pip3 install -r token-spy/requirements.txt"
            exit 1
        }
        ok "Token Spy dependencies installed"
    else
        ok "Token Spy dependencies satisfied (fastapi, httpx, uvicorn)"
    fi
fi

echo ""

# ── Install Session Cleanup ───────────────────────────────────
if [ "$PROXY_ONLY" = false ] && [ "$TOKEN_SPY_ONLY" = false ] && [ "$CLEANUP_ENABLED" = "true" ]; then
    info "Installing session cleanup..."

    SESSIONS_DIR="$OPENCLAW_DIR/$SESSIONS_PATH"

    # Copy script to openclaw dir
    cp "$SCRIPT_DIR/scripts/session-cleanup.sh" "$OPENCLAW_DIR/session-cleanup.sh"
    chmod +x "$OPENCLAW_DIR/session-cleanup.sh"

    # Patch in config values
    sed -i "s|OPENCLAW_DIR=\"\${OPENCLAW_DIR:-\$HOME/.openclaw}\"|OPENCLAW_DIR=\"$OPENCLAW_DIR\"|" "$OPENCLAW_DIR/session-cleanup.sh"
    sed -i "s|SESSIONS_DIR=\"\${SESSIONS_DIR:-\$OPENCLAW_DIR/agents/main/sessions}\"|SESSIONS_DIR=\"$SESSIONS_DIR\"|" "$OPENCLAW_DIR/session-cleanup.sh"
    sed -i "s|MAX_SIZE=\"\${MAX_SIZE:-256000}\"|MAX_SIZE=\"$MAX_SESSION_SIZE\"|" "$OPENCLAW_DIR/session-cleanup.sh"

    ok "Session cleanup script installed: $OPENCLAW_DIR/session-cleanup.sh"

    # Install systemd units
    if [ "$HAS_SYSTEMD" = true ]; then
        # Service
        sudo cp "$SCRIPT_DIR/systemd/openclaw-session-cleanup.service" /etc/systemd/system/
        sudo sed -i "s|__USER__|$SYSTEM_USER|g" /etc/systemd/system/openclaw-session-cleanup.service
        sudo sed -i "s|__OPENCLAW_DIR__|$OPENCLAW_DIR|g" /etc/systemd/system/openclaw-session-cleanup.service

        # Timer
        sudo cp "$SCRIPT_DIR/systemd/openclaw-session-cleanup.timer" /etc/systemd/system/
        sudo sed -i "s|__INTERVAL__|$INTERVAL_MINUTES|g" /etc/systemd/system/openclaw-session-cleanup.timer
        sudo sed -i "s|__BOOT_DELAY__|$BOOT_DELAY|g" /etc/systemd/system/openclaw-session-cleanup.timer

        sudo systemctl daemon-reload
        sudo systemctl enable openclaw-session-cleanup.timer
        sudo systemctl start openclaw-session-cleanup.timer

        ok "Session cleanup timer enabled (every ${INTERVAL_MINUTES}min)"
    fi
fi

# ── Install Tool Proxy ────────────────────────────────────────
if [ "$CLEANUP_ONLY" = false ] && [ "$TOKEN_SPY_ONLY" = false ] && [ "$PROXY_ENABLED" = "true" ]; then
    info "Installing vLLM tool proxy..."

    # Determine install location
    INSTALL_DIR="$OPENCLAW_DIR"
    cp "$SCRIPT_DIR/scripts/vllm-tool-proxy.py" "$INSTALL_DIR/vllm-tool-proxy.py"
    chmod +x "$INSTALL_DIR/vllm-tool-proxy.py"

    ok "Tool proxy installed: $INSTALL_DIR/vllm-tool-proxy.py"

    # Install systemd service
    if [ "$HAS_SYSTEMD" = true ]; then
        # Stop existing if running
        if systemctl is-active --quiet vllm-tool-proxy 2>/dev/null; then
            sudo systemctl stop vllm-tool-proxy
        fi

        sudo cp "$SCRIPT_DIR/systemd/vllm-tool-proxy.service" /etc/systemd/system/
        sudo sed -i "s|__USER__|$SYSTEM_USER|g" /etc/systemd/system/vllm-tool-proxy.service
        sudo sed -i "s|__INSTALL_DIR__|$INSTALL_DIR|g" /etc/systemd/system/vllm-tool-proxy.service
        sudo sed -i "s|__PROXY_PORT__|$PROXY_PORT|g" /etc/systemd/system/vllm-tool-proxy.service
        sudo sed -i "s|__VLLM_URL__|$VLLM_URL|g" /etc/systemd/system/vllm-tool-proxy.service

        sudo systemctl daemon-reload
        sudo systemctl enable vllm-tool-proxy
        sudo systemctl start vllm-tool-proxy

        sleep 2
        if systemctl is-active --quiet vllm-tool-proxy; then
            ok "Tool proxy service running on :$PROXY_PORT -> $VLLM_URL"
        else
            err "Tool proxy failed to start. Check: journalctl -u vllm-tool-proxy"
        fi
    else
        info "No systemd. Start manually:"
        info "  python3 $INSTALL_DIR/vllm-tool-proxy.py --port $PROXY_PORT --vllm-url $VLLM_URL"
    fi
fi

# ── Install Token Spy ─────────────────────────────────────────
if ([ "$TOKEN_SPY_ONLY" = true ] || ([ "$CLEANUP_ONLY" = false ] && [ "$PROXY_ONLY" = false ])) && [ "$TS_ENABLED" = "true" ]; then
    info "Installing Token Spy API monitor..."

    TS_INSTALL_DIR="$OPENCLAW_DIR/token-spy"
    mkdir -p "$TS_INSTALL_DIR/providers"

    # Copy Token Spy source
    cp "$SCRIPT_DIR/token-spy/main.py" "$TS_INSTALL_DIR/"
    cp "$SCRIPT_DIR/token-spy/db.py" "$TS_INSTALL_DIR/"
    cp "$SCRIPT_DIR/token-spy/db_postgres.py" "$TS_INSTALL_DIR/"
    cp "$SCRIPT_DIR/token-spy/requirements.txt" "$TS_INSTALL_DIR/"
    cp "$SCRIPT_DIR/token-spy/providers/"*.py "$TS_INSTALL_DIR/providers/"

    # Generate .env from config values
    cat > "$TS_INSTALL_DIR/.env" << TSENV
# Token Spy — generated by install.sh
AGENT_NAME=$TS_AGENT_NAME
PORT=$TS_PORT
ANTHROPIC_UPSTREAM=$TS_ANTHROPIC_UPSTREAM
OPENAI_UPSTREAM=$TS_OPENAI_UPSTREAM
API_PROVIDER=$TS_API_PROVIDER
DB_BACKEND=$TS_DB_BACKEND
SESSION_CHAR_LIMIT=$TS_SESSION_CHAR_LIMIT
AGENT_SESSION_DIRS=$TS_AGENT_SESSION_DIRS
LOCAL_MODEL_AGENTS=$TS_LOCAL_MODEL_AGENTS
TSENV

    ok "Token Spy installed: $TS_INSTALL_DIR"

    # Install systemd service
    if [ "$HAS_SYSTEMD" = true ]; then
        # Stop existing if running
        if systemctl is-active --quiet "token-spy@${TS_AGENT_NAME}" 2>/dev/null; then
            sudo systemctl stop "token-spy@${TS_AGENT_NAME}"
        fi

        sudo cp "$SCRIPT_DIR/systemd/token-spy@.service" /etc/systemd/system/
        sudo sed -i "s|__USER__|$SYSTEM_USER|g" /etc/systemd/system/token-spy@.service
        sudo sed -i "s|__INSTALL_DIR__|$TS_INSTALL_DIR|g" /etc/systemd/system/token-spy@.service
        sudo sed -i "s|__HOST__|$TS_HOST|g" /etc/systemd/system/token-spy@.service
        sudo sed -i "s|__PORT__|$TS_PORT|g" /etc/systemd/system/token-spy@.service

        sudo systemctl daemon-reload
        sudo systemctl enable "token-spy@${TS_AGENT_NAME}"
        sudo systemctl start "token-spy@${TS_AGENT_NAME}"

        sleep 2
        if systemctl is-active --quiet "token-spy@${TS_AGENT_NAME}"; then
            ok "Token Spy running on :$TS_PORT (agent: $TS_AGENT_NAME)"
        else
            err "Token Spy failed to start. Check: journalctl -u token-spy@${TS_AGENT_NAME}"
        fi
    else
        info "No systemd. Start manually:"
        info "  cd $TS_INSTALL_DIR && AGENT_NAME=$TS_AGENT_NAME python3 -m uvicorn main:app --host $TS_HOST --port $TS_PORT"
    fi
fi

# ── Install LLM Cold Storage ────────────────────────────────
if ([ "$COLD_STORAGE_ONLY" = true ] || ([ "$CLEANUP_ONLY" = false ] && [ "$PROXY_ONLY" = false ] && [ "$TOKEN_SPY_ONLY" = false ])) && [ "$CS_ENABLED" = "true" ]; then
    info "Installing LLM Cold Storage..."

    if [ ! -f "$SCRIPT_DIR/scripts/llm-cold-storage.sh" ]; then
        err "scripts/llm-cold-storage.sh not found"
        exit 1
    fi

    chmod +x "$SCRIPT_DIR/scripts/llm-cold-storage.sh"
    ok "Cold storage script: $SCRIPT_DIR/scripts/llm-cold-storage.sh"

    # Install systemd user timer
    if [ "$HAS_SYSTEMD" = true ]; then
        mkdir -p "$HOME/.config/systemd/user"

        # Service — patch in config values
        cp "$SCRIPT_DIR/systemd/llm-cold-storage.service" "$HOME/.config/systemd/user/"
        sed -i "s|%h/Lighthouse-AI/scripts|$SCRIPT_DIR/scripts|g" "$HOME/.config/systemd/user/llm-cold-storage.service"
        sed -i "s|%h/.cache/huggingface/hub|$CS_HF_CACHE|g" "$HOME/.config/systemd/user/llm-cold-storage.service"
        sed -i "s|%h/llm-cold-storage|$CS_COLD_DIR|g" "$HOME/.config/systemd/user/llm-cold-storage.service"
        # Remove User=%i (not needed for user services)
        sed -i '/^User=%i/d' "$HOME/.config/systemd/user/llm-cold-storage.service"

        # Timer
        cp "$SCRIPT_DIR/systemd/llm-cold-storage.timer" "$HOME/.config/systemd/user/"

        systemctl --user daemon-reload
        systemctl --user enable llm-cold-storage.timer
        systemctl --user start llm-cold-storage.timer

        ok "Cold storage timer enabled (daily at 2am)"
        info "  Dry-run first: $SCRIPT_DIR/scripts/llm-cold-storage.sh"
        info "  Execute:       $SCRIPT_DIR/scripts/llm-cold-storage.sh --execute"
    else
        info "No systemd. Run manually:"
        info "  HF_CACHE=$CS_HF_CACHE COLD_DIR=$CS_COLD_DIR $SCRIPT_DIR/scripts/llm-cold-storage.sh --execute"
    fi
fi

# ── OpenClaw Config Reminder ──────────────────────────────────
echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Installation complete!${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo ""

if [ "$CLEANUP_ONLY" = false ] && [ "$TOKEN_SPY_ONLY" = false ] && [ "$PROXY_ENABLED" = "true" ]; then
    info "IMPORTANT: Update your openclaw.json model providers to use the proxy:"
    echo ""
    echo "  Change your provider baseUrl from:"
    echo "    \"baseUrl\": \"http://localhost:8000/v1\""
    echo ""
    echo "  To:"
    echo "    \"baseUrl\": \"http://localhost:${PROXY_PORT}/v1\""
    echo ""
fi

if [ "$TS_ENABLED" = "true" ] && ([ "$TOKEN_SPY_ONLY" = true ] || ([ "$CLEANUP_ONLY" = false ] && [ "$PROXY_ONLY" = false ])); then
    info "IMPORTANT: Update your openclaw.json cloud providers to route through Token Spy:"
    echo ""
    echo "  Change your Anthropic baseUrl to:"
    echo "    \"baseUrl\": \"http://localhost:${TS_PORT}\""
    echo ""
    echo "  Change your OpenAI-compatible baseUrl to:"
    echo "    \"baseUrl\": \"http://localhost:${TS_PORT}/v1\""
    echo ""
    echo "  Dashboard: http://localhost:${TS_PORT}/dashboard"
    echo ""
fi

info "Useful commands:"
if [ "$HAS_SYSTEMD" = true ]; then
    if [ "$PROXY_ONLY" = false ] && [ "$TOKEN_SPY_ONLY" = false ]; then
        echo "  systemctl status openclaw-session-cleanup.timer   # Check timer"
        echo "  journalctl -u openclaw-session-cleanup -f         # Watch cleanup logs"
    fi
    if [ "$CLEANUP_ONLY" = false ] && [ "$TOKEN_SPY_ONLY" = false ]; then
        echo "  systemctl status vllm-tool-proxy                  # Check proxy"
        echo "  journalctl -u vllm-tool-proxy -f                  # Watch proxy logs"
        echo "  curl http://localhost:${PROXY_PORT}/health                    # Test proxy health"
    fi
    if [ "$TS_ENABLED" = "true" ] && ([ "$TOKEN_SPY_ONLY" = true ] || ([ "$CLEANUP_ONLY" = false ] && [ "$PROXY_ONLY" = false ])); then
        echo "  systemctl status token-spy@${TS_AGENT_NAME}                 # Check Token Spy"
        echo "  journalctl -u token-spy@${TS_AGENT_NAME} -f                 # Watch Token Spy logs"
        echo "  curl http://localhost:${TS_PORT}/health                     # Test Token Spy health"
    fi
    if [ "$CS_ENABLED" = "true" ] && ([ "$COLD_STORAGE_ONLY" = true ] || ([ "$CLEANUP_ONLY" = false ] && [ "$PROXY_ONLY" = false ] && [ "$TOKEN_SPY_ONLY" = false ])); then
        echo "  systemctl --user status llm-cold-storage.timer              # Check cold storage timer"
        echo "  systemctl --user list-timers llm-cold-storage.timer         # Next run time"
    fi
fi
echo ""
