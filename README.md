# LightHeart OpenClaw

**Keep your AI agents running. No matter what they do to themselves.**

An open source operations toolkit for persistent LLM agents. Built for [OpenClaw](https://openclaw.io) but many components work with any agent framework or service stack.

This toolkit is the infrastructure layer of a proven multi-agent architecture — the [OpenClaw Collective](COLLECTIVE.md) — where 3 AI agents coordinate autonomously on shared projects using local GPU hardware. The companion repository **Android-Labs** (private) is the proof of work: 3,464 commits from 3 agents over 8 days, producing three shipping products and 50+ technical research documents. These tools kept them running.

| Component | What it does | Requires OpenClaw? | Platform |
|-----------|-------------|-------------------|----------|
| [Session Watchdog](#session-watchdog) | Auto-cleans bloated sessions before context overflow | Yes | Linux, Windows |
| [vLLM Tool Call Proxy](#vllm-tool-call-proxy-v4) | Makes local model tool calling work | Yes | Linux |
| [Token Spy](#token-spy--api-cost--usage-monitor) | API cost monitoring with real-time dashboard | No (any OpenAI/Anthropic client) | Linux |
| [Guardian](#guardian) | Self-healing process watchdog with backup restore | No (any Linux services) | Linux (root) |
| [Memory Shepherd](#memory-shepherd) | Periodic memory reset to prevent agent drift | No (any markdown-based agent memory) | Linux |
| [Golden Configs](#golden-configs) | Working config templates for OpenClaw + vLLM | Yes | Any |
| [Workspace Templates](#workspace-templates) | Agent personality/identity starter files | Yes | Any |

---

## What's Inside

### Session Watchdog
A lightweight daemon that monitors `.jsonl` session files and automatically cleans up bloated ones before they hit the context ceiling. Runs on a timer, catches danger-zone sessions, deletes them, and removes their references from `sessions.json` so the gateway seamlessly creates fresh ones.

**The agent doesn't even notice.** It just gets a clean context window mid-conversation. No more `Context overflow: prompt too large for the model` crashes.

### vLLM Tool Call Proxy (v4)
A transparent proxy between OpenClaw and vLLM that makes local model tool calling actually work. Handles SSE re-wrapping, tool call extraction from text, response cleaning, and loop protection.

Without it, you get "No reply from agent" with 0 tokens. With it, your local agents just work.

### Token Spy — API Cost & Usage Monitor
A transparent API proxy that captures per-turn token usage, cost, latency, and session health for cloud model calls (Anthropic, OpenAI, Moonshot). Point your agent's `baseUrl` at Token Spy instead of the upstream API — it logs everything, then forwards requests and responses untouched, including SSE streams.

Includes a real-time dashboard with session health cards, cost charts, token breakdown, and cumulative spend tracking. Can auto-kill sessions that exceed a configurable character limit. Works with any OpenAI-compatible or Anthropic API client.

### Golden Configs
Battle-tested `openclaw.json` and `models.json` templates with the critical `compat` block that prevents OpenClaw from sending parameters vLLM silently rejects. Getting these four flags wrong produces mysterious failures with no error messages — we figured them out so you don't have to.

### Workspace Templates
Starter personality files (`SOUL.md`, `IDENTITY.md`, `TOOLS.md`, `MEMORY.md`) that OpenClaw injects into every agent session. Customize your agent's personality, knowledge, and working memory.

### Memory Shepherd
Periodic memory reset for persistent LLM agents. Agents accumulate scratch notes in `MEMORY.md` during operation — Memory Shepherd archives those notes and restores the file to a curated baseline on a schedule. Keeps agents on-mission by preventing context drift, memory bloat, and self-modification of instructions.

Defines a `---` separator convention: everything above is operator-controlled identity (rules, capabilities, pointers), everything below is agent scratch space that gets archived and cleared. See [memory-shepherd/README.md](memory-shepherd/README.md) for full documentation.

### Guardian
Self-healing process watchdog for LLM infrastructure. Runs as a root systemd service that agents cannot kill or modify. Monitors processes, systemd services, Docker containers, and file integrity — automatically restoring from known-good backups when things break.

Supports tiered health checks (port listening, HTTP endpoints, custom commands, JSON validation), a recovery cascade (soft restart → backup restore → restart), generational backups with immutable flags, and restart delegation chains. Everything is config-driven via an INI file. See [guardian/README.md](guardian/README.md) for full documentation.

### Architecture Docs
Deep-dive documentation on how OpenClaw talks to vLLM, why the proxy exists, how session files work, and the five failure points that kill local setups.

---

## The Bigger Picture

These tools were extracted from a running multi-agent system — the [OpenClaw Collective](COLLECTIVE.md) — where AI agents coordinate autonomously on long-term projects. Here's how each component fits:

```
┌─────────────────────────────────────────────────────────┐
│               Mission Governance (MISSIONS.md)           │
│              Constrains what agents work on               │
├─────────────────────────────────────────────────────────┤
│            Deterministic Supervisor (Android-18)          │
│           Timed pings, session resets, accountability     │
├──────────────┬──────────────┬───────────────────────────┤
│ Session      │ Memory       │ Infrastructure             │
│ Watchdog     │ Shepherd     │ Guardian                   │
│ + Token Spy  │              │                            │
│              │              │                            │
│ Context      │ Identity     │ Process monitoring,        │
│ overflow     │ drift        │ file integrity,            │
│ prevention   │ prevention   │ auto-restore               │
├──────────────┴──────────────┴───────────────────────────┤
│              Workspace Templates (SOUL, IDENTITY,         │
│              TOOLS, MEMORY) — Persistent agent identity   │
├─────────────────────────────────────────────────────────┤
│     vLLM Tool Proxy + Golden Configs — Local inference    │
└─────────────────────────────────────────────────────────┘
```

For the full architecture: **[COLLECTIVE.md](COLLECTIVE.md)**
For transferable patterns applicable to any agent framework: **[docs/PATTERNS.md](docs/PATTERNS.md)**
For the rationale behind every design choice: **[docs/DESIGN-DECISIONS.md](docs/DESIGN-DECISIONS.md)**

---

## Quick Start

### Option 1: Full Install (Session Cleanup + Proxy)

```bash
git clone https://github.com/Light-Heart-Labs/LightHeart-OpenClaw.git
cd LightHeart-OpenClaw

# Edit config for your setup
nano config.yaml

# Install everything
chmod +x install.sh
./install.sh
```

### Option 2: Just the Parts You Need

```bash
# Session cleanup only (works with cloud models too)
./install.sh --cleanup-only

# Tool proxy only (for local vLLM setups)
./install.sh --proxy-only

# Token Spy only (API cost monitoring for cloud models)
./install.sh --token-spy-only

# Windows
.\install.ps1
.\install.ps1 -CleanupOnly
.\install.ps1 -ProxyOnly
.\install.ps1 -TokenSpyOnly
```

### Option 3: Running vLLM from Scratch

If you're setting up a local model from zero, see [docs/SETUP.md](docs/SETUP.md) for the full walkthrough — vLLM, proxy, OpenClaw config, and testing.

```bash
# Start vLLM (needs NVIDIA GPU + Docker)
./scripts/start-vllm.sh

# Start the proxy
pip3 install flask requests
./scripts/start-proxy.sh

# Configure OpenClaw
cp configs/openclaw.json ~/.openclaw/openclaw.json
rm -f ~/.openclaw/agents/main/agent/models.json
export VLLM_API_KEY=vllm-local

# Test
openclaw agent --local --agent main -m 'What is 2+2?'
```

### Option 4: Guardian (Process Watchdog)

Works with any Linux service stack — not OpenClaw-specific. See [guardian/README.md](guardian/README.md) for full docs.

```bash
cd guardian
cp guardian.conf.example guardian.conf
nano guardian.conf          # Define your monitored resources
nano guardian.service       # Add your paths to ReadWritePaths
sudo ./install.sh           # Installs to systemd as root service
```

### Option 5: Memory Shepherd (Memory Reset)

Works with any agent that uses markdown memory files. See [memory-shepherd/README.md](memory-shepherd/README.md) for full docs.

```bash
cd memory-shepherd
cp memory-shepherd.conf.example memory-shepherd.conf
nano memory-shepherd.conf   # Define your agents and baselines
sudo ./install.sh           # Installs as systemd timer
```

---

## Configuration

Edit `config.yaml` before installing:

```yaml
session_cleanup:
  enabled: true
  openclaw_dir: "~/.openclaw"
  sessions_path: "agents/main/sessions"
  max_session_size: 256000    # 250KB — tune for your model
  interval_minutes: 60

tool_proxy:
  enabled: true
  port: 8003
  vllm_url: "http://localhost:8000"
  max_tool_calls: 500         # Safety limit for loop protection

token_spy:
  enabled: false              # Set to true to enable
  agent_name: "my-agent"
  port: 9110
  anthropic_upstream: "https://api.anthropic.com"
  openai_upstream: ""         # e.g., "https://api.moonshot.ai"
  session_char_limit: 200000  # ~50K tokens
```

### Session Size Guide

| Model Context | Recommended max_session_size | Recommended interval |
|---|---|---|
| 8K tokens | 64000 (64KB) | 15 min |
| 16K tokens | 128000 (128KB) | 30 min |
| 32K tokens | 256000 (250KB) | 60 min |
| 64K tokens | 512000 (500KB) | 90 min |
| 128K tokens | 1024000 (1MB) | 120 min |

---

## The Compat Block (Read This)

The most important four lines in the entire repo. Without them, OpenClaw sends parameters that vLLM silently rejects:

```json
"compat": {
  "supportsStore": false,
  "supportsDeveloperRole": false,
  "supportsReasoningEffort": false,
  "maxTokensField": "max_tokens"
}
```

| Flag | What happens without it |
|------|------------------------|
| `supportsStore: false` | OpenClaw sends `store: false` → vLLM rejects the request |
| `supportsDeveloperRole: false` | OpenClaw sends `developer` role → vLLM doesn't understand it |
| `supportsReasoningEffort: false` | OpenClaw sends reasoning params → vLLM rejects them |
| `maxTokensField: "max_tokens"` | OpenClaw sends `max_completion_tokens` → vLLM wants `max_tokens` |

These are already set in `configs/openclaw.json`. Just copy it and go.

### Gateway Config (Security Note)

The golden config includes gateway settings for LAN access:

```json
"gateway": {
  "bind": "lan",
  "controlUi": {
    "allowInsecureAuth": true,
    "dangerouslyDisableDeviceAuth": true
  }
}
```

**`dangerouslyDisableDeviceAuth: true`** — Disables the device authorization flow that normally requires confirming new devices via the OpenClaw UI. Set to `true` here because local/headless setups (SSH, systemd) can't complete the interactive auth prompt. **If you expose your gateway to the internet, set this to `false`.**

**`allowInsecureAuth: true`** — Allows HTTP (non-HTTPS) auth on LAN. Safe for local networks, not for public-facing deployments.

---

## How It Works

### Session Cleanup Flow

```
Every N minutes:
  1. Read sessions.json → get active session IDs
  2. Clean up .deleted.* and .bak* debris files
  3. For each .jsonl session file:
     - Not in active list → delete (orphan cleanup)
     - Active AND > max_session_size → delete + remove from sessions.json
  4. Gateway detects missing session → creates new one automatically
  5. Agent gets clean context. Never notices the swap.
```

### Tool Proxy Flow

```
OpenClaw sends request (stream: true, tools: [...])
  → Proxy forces stream: false (can't extract tools from chunks)
  → Forward to vLLM as non-streaming
  → vLLM responds with JSON
  → Proxy extracts tool calls from content (tags, bare JSON, multi-line)
  → Proxy cleans vLLM-specific fields
  → Proxy re-wraps as SSE stream
  → OpenClaw receives proper streaming response with tool_calls
```

### Token Spy Flow

```
OpenClaw sends request to Token Spy (instead of direct to API)
  → Token Spy logs: model, tokens, cache, cost, latency, session health
  → Token Spy forwards to upstream (Anthropic/OpenAI) untouched
  → Upstream responds (JSON or SSE stream)
  → Token Spy forwards response back untouched
  → Dashboard updates in real-time
  → If session exceeds char limit → auto-kill session file
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full deep dive.

---

## Project Structure

```
LightHeart-OpenClaw/
├── config.yaml                         # Configuration (edit this first)
├── install.sh                          # Linux installer
├── install.ps1                         # Windows installer
├── configs/
│   ├── openclaw.json                   # Golden OpenClaw config template
│   ├── models.json                     # Model definition with compat flags
│   └── openclaw-gateway.service        # systemd service for OpenClaw gateway
├── scripts/
│   ├── session-cleanup.sh              # Session watchdog script
│   ├── vllm-tool-proxy.py             # vLLM tool call proxy (v4)
│   ├── start-vllm.sh                  # Start vLLM via Docker
│   └── start-proxy.sh                 # Start the tool call proxy
├── token-spy/                          # API cost & usage monitor
│   ├── main.py                        # Proxy server + embedded dashboard
│   ├── db.py                          # SQLite storage layer
│   ├── db_postgres.py                 # PostgreSQL/TimescaleDB layer
│   ├── providers/                     # Pluggable cost calculation
│   │   ├── anthropic.py
│   │   └── openai.py
│   ├── .env.example                   # Configuration reference
│   └── requirements.txt               # Python dependencies
├── workspace/
│   ├── SOUL.md                        # Agent personality template
│   ├── IDENTITY.md                    # Agent identity template
│   ├── TOOLS.md                       # Available tools reference
│   └── MEMORY.md                      # Working memory template
├── systemd/
│   ├── openclaw-session-cleanup.service
│   ├── openclaw-session-cleanup.timer
│   ├── vllm-tool-proxy.service
│   └── token-spy@.service             # Token Spy (templated per-agent)
├── memory-shepherd/                    # Periodic memory reset for agents
│   ├── memory-shepherd.sh             # Config-driven reset script
│   ├── memory-shepherd.conf.example   # Example agent config
│   ├── install.sh                     # Systemd timer installer
│   ├── uninstall.sh                   # Systemd timer removal
│   ├── baselines/                     # Baseline MEMORY.md templates
│   └── docs/
│       └── WRITING-BASELINES.md       # Guide to writing effective baselines
├── guardian/                           # Self-healing process watchdog
│   ├── guardian.sh                    # Config-driven watchdog script
│   ├── guardian.conf.example          # Sanitized example config
│   ├── guardian.service               # Systemd unit template
│   ├── install.sh                     # Installer (systemd + immutable flags)
│   ├── uninstall.sh                   # Uninstaller
│   └── docs/
│       └── HEALTH-CHECKS.md           # Health check & recovery reference
├── docs/
│   ├── SETUP.md                       # Full local setup guide
│   ├── ARCHITECTURE.md                # How it all fits together
│   └── TOKEN-SPY.md                   # Token Spy setup & API reference
└── LICENSE
```

---

## Supported Models

The tool proxy works with any vLLM-compatible model. Tested with:

| Model | VRAM | Tool Parser | Notes |
|-------|------|-------------|-------|
| Qwen/Qwen3-Coder-Next-FP8 | ~75GB | `qwen3_coder` | Best for coding agents. 80B MoE. |
| Qwen2.5-Coder (all sizes) | 4-48GB | `hermes` | Outputs `<tools>` tags |
| Qwen2.5 Instruct (all sizes) | 4-48GB | `hermes` | Outputs `<tools>` tags |
| Qwen/Qwen3-8B | ~16GB | `hermes` | Good starter for consumer GPUs |

The proxy handles tool call extraction regardless of format — `<tools>` tags, bare JSON, or multi-line JSON.

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `VLLM_MODEL` | `Qwen/Qwen3-Coder-Next-FP8` | HuggingFace model ID |
| `VLLM_PORT` | `8000` | vLLM API port |
| `VLLM_URL` | `http://localhost:8000` | vLLM base URL (for proxy) |
| `PROXY_PORT` | `8003` | Tool call proxy port |
| `MAX_TOOL_CALLS` | `500` | Safety limit for tool call loops |
| `VLLM_GPU_UTIL` | `0.92` | GPU memory utilization |
| `VLLM_MAX_LEN` | `131072` | Max context length |
| `VLLM_VERSION` | `v0.15.1` | vLLM Docker image tag |
| `VLLM_TOOL_PARSER` | `qwen3_coder` | Tool call parser |
| `VLLM_API_KEY` | — | API key for OpenClaw (can be anything) |

### Token Spy Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `AGENT_NAME` | `unknown` | Agent identifier shown in dashboard |
| `PORT` | `9110` | Token Spy proxy port |
| `ANTHROPIC_UPSTREAM` | `https://api.anthropic.com` | Upstream for `/v1/messages` |
| `OPENAI_UPSTREAM` | *(empty)* | Upstream for `/v1/chat/completions` |
| `DB_BACKEND` | `sqlite` | `sqlite` or `postgres` |
| `SESSION_CHAR_LIMIT` | `200000` | Auto-reset threshold in characters |
| `AGENT_SESSION_DIRS` | *(empty)* | JSON map of agent name to session dir |
| `LOCAL_MODEL_AGENTS` | *(empty)* | Comma-separated agents with $0 cost |

---

## Troubleshooting

See [docs/SETUP.md](docs/SETUP.md) for the full troubleshooting guide. Quick hits:

| Problem | Fix |
|---------|-----|
| "No reply from agent" / 0 tokens | `baseUrl` must point to proxy (:8003), not vLLM (:8000) |
| Config validation errors | Only use the four compat flags listed above |
| Tool calls as plain text | Check proxy is running: `curl localhost:8003/health` |
| Agent stuck in loop | Proxy aborts at 500 calls. Lower `MAX_TOOL_CALLS` if needed |
| vLLM CUDA crash | Add `--compilation_config.cudagraph_mode=PIECEWISE` |
| vLLM assertion error | Don't use `--kv-cache-dtype fp8` with Qwen3-Next |
| Token Spy dashboard empty | Ensure your agent's `baseUrl` points to Token Spy, not the upstream API |
| Token Spy 502 errors | Check `ANTHROPIC_UPSTREAM` or `OPENAI_UPSTREAM` is set correctly in `.env` |

---

## Further Reading

- **[COLLECTIVE.md](COLLECTIVE.md)** — Full architecture of the multi-agent system this toolkit powers
- **[docs/DESIGN-DECISIONS.md](docs/DESIGN-DECISIONS.md)** — Why we made the choices we did: session limits, ping cycles, deterministic supervision, and more
- **[docs/PATTERNS.md](docs/PATTERNS.md)** — Six transferable patterns for autonomous agent systems, applicable to any framework
- **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** — Deep dive on the vLLM Tool Call Proxy internals
- **Android-Labs** (private) — Proof of work: 3,464 commits from 3 AI agents in 8 days

---

## License

Apache 2.0 — see [LICENSE](LICENSE)

---

Built by [Lightheart Labs](https://github.com/Light-Heart-Labs) and the [OpenClaw Collective](COLLECTIVE.md) from real production pain running autonomous AI agents on local hardware.
