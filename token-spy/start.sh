#!/bin/bash
# Token Spy — API Monitor — launcher
# Starts proxy instances sharing a single database.
# Pure telemetry — no request modification.
#
# Dual upstream routing:
#   Anthropic Messages API (/v1/messages) → ANTHROPIC_UPSTREAM
#   OpenAI Chat Completions (/v1/chat/completions) → OPENAI_UPSTREAM
#
# Database backend:
#   DB_BACKEND=sqlite (default) — uses SQLite in data/usage.db
#   DB_BACKEND=postgres — uses PostgreSQL/TimescaleDB on DB_HOST:DB_PORT
# ─────────────────────────────────────────────────────────────────────────────

set -e
cd "$(dirname "$0")"
mkdir -p data

# Load env file if exists
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

# Database backend (sqlite or postgres)
export DB_BACKEND="${DB_BACKEND:-sqlite}"

# Upstream API config
export ANTHROPIC_UPSTREAM="${ANTHROPIC_UPSTREAM:-https://api.anthropic.com}"
export OPENAI_UPSTREAM="${OPENAI_UPSTREAM:-}"

# ── Agent Configuration ──────────────────────────────────────────────────────
# Define your agents below. Each agent gets its own proxy port.
# Format: AGENT_NAME=<name> python3 -m uvicorn main:app --host 0.0.0.0 --port <port>
#
# Single agent (simplest setup):
#   AGENT_NAME=my-agent python3 -m uvicorn main:app --host 0.0.0.0 --port 9110
#
# Multiple agents (one process per agent):
#   AGENT_NAME=agent-1 python3 -m uvicorn main:app --host 0.0.0.0 --port 9110 &
#   AGENT_NAME=agent-2 python3 -m uvicorn main:app --host 0.0.0.0 --port 9111 &
#
# Local model agent (routes to a self-hosted model instead of cloud API):
#   AGENT_NAME=local-agent OPENAI_UPSTREAM=http://localhost:8000 API_PROVIDER=local \
#     python3 -m uvicorn main:app --host 0.0.0.0 --port 9112 &
# ─────────────────────────────────────────────────────────────────────────────

AGENT_NAME="${AGENT_NAME:-my-agent}"
PORT="${PORT:-9110}"

echo "Starting Token Spy — API Monitor..."
echo "  Agent     → ${AGENT_NAME}"
echo "  Port      → :${PORT}"
echo "  DB Backend→ ${DB_BACKEND}"
echo "  Anthropic → ${ANTHROPIC_UPSTREAM}"
echo "  OpenAI    → ${OPENAI_UPSTREAM:-<not set>}"

AGENT_NAME="${AGENT_NAME}" python3 -m uvicorn main:app --host 0.0.0.0 --port "${PORT}" --log-level warning

# ── Multi-Agent Example ──────────────────────────────────────────────────────
# Uncomment and customize for multiple agents:
#
# AGENT_NAME=agent-1 python3 -m uvicorn main:app --host 0.0.0.0 --port 9110 --log-level warning &
# PID1=$!
#
# AGENT_NAME=agent-2 python3 -m uvicorn main:app --host 0.0.0.0 --port 9111 --log-level warning &
# PID2=$!
#
# trap "echo 'Stopping...'; kill $PID1 $PID2 2>/dev/null; wait" EXIT INT TERM
# wait
