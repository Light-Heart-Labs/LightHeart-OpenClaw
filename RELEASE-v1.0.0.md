# Dream Server v1.0.0

First public release of Dream Server -- your turnkey local AI stack.

**Your hardware. Your data. Your rules.**

One installer. Bare metal to fully running local AI in 10 minutes -- LLM inference, chat UI, voice agents, workflow automation, RAG, and privacy tools. No subscriptions. No cloud. Runs entirely offline.

## Highlights

- **Full-stack local AI in one command** -- vLLM inference, chat UI, voice agents, workflow automation, RAG, privacy shield, and a real-time dashboard, all wired together and running on your GPU.
- **Automatic hardware detection** -- the installer probes your GPU, selects the optimal model (7B to 72B parameters), and configures VRAM allocation, context windows, and resource limits without manual tuning.
- **Bootstrap mode for instant start** -- a lightweight 1.5B model boots in under a minute so you can start chatting immediately while the full model downloads in the background. Hot-swap with zero downtime when ready.
- **End-to-end voice pipeline** -- Whisper speech-to-text, Kokoro text-to-speech, and LiveKit WebRTC voice agents let you have real-time spoken conversations with your local LLM entirely on-premises.
- **OpenClaw multi-agent support** -- built-in integration with the OpenClaw agent framework, including a vLLM Tool Call Proxy, pre-configured workspace templates, and battle-tested configs for autonomous AI coordination on local hardware.

## What's Included

| Component | Image | Version | Profile |
|-----------|-------|---------|---------|
| **vLLM** (LLM Inference) | `vllm/vllm-openai` | v0.15.1 | core |
| **Open WebUI** (Chat Interface) | `ghcr.io/open-webui/open-webui` | v0.7.2 | core |
| **Dashboard UI** (Control Center) | `dream-dashboard` | local build | core |
| **Dashboard API** (Status Backend) | `dream-dashboard-api` | local build | core |
| **Whisper** (Speech-to-Text) | `onerahmet/openai-whisper-asr-webservice` | v1.4.1 | voice |
| **Kokoro** (Text-to-Speech) | `ghcr.io/remsky/kokoro-fastapi-cpu` | v0.2.4 | voice |
| **LiveKit** (WebRTC Voice) | `dream-livekit` | local build | voice |
| **LiveKit Voice Agent** | `dream-voice-agent` | local build | voice |
| **n8n** (Workflow Automation) | `n8nio/n8n` | 2.6.4 | workflows |
| **Qdrant** (Vector Database) | `qdrant/qdrant` | v1.16.3 | rag |
| **Text Embeddings** | `ghcr.io/huggingface/text-embeddings-inference` | cpu-1.9.1 | rag |
| **LiteLLM** (API Gateway) | `ghcr.io/berriai/litellm` | v1.81.3-stable | monitoring |
| **Token Spy** (Usage Monitoring) | `lightheartlabs/token-spy` | latest | monitoring |
| **TimescaleDB** (Token Spy DB) | `timescale/timescaledb` | latest-pg15 | monitoring |
| **Redis** (Rate Limiting) | `redis` | 7-alpine | monitoring |
| **Privacy Shield** (PII Redaction) | `dream-privacy-shield` | local build | privacy |
| **OpenClaw** (Agent Framework) | `ghcr.io/openclaw/openclaw` | latest | openclaw |
| **vLLM Tool Proxy** | `dream-vllm-tool-proxy` | local build | openclaw |

## Hardware Support

The installer automatically detects your GPU and selects the optimal model:

| Tier | VRAM | Model | Context | Example GPUs |
|------|------|-------|---------|--------------|
| **Entry** | < 12 GB | Qwen2.5-7B | 8K | RTX 3080, RTX 4070 |
| **Prosumer** | 12 -- 20 GB | Qwen2.5-14B-AWQ | 16K | RTX 3090, RTX 4080 |
| **Pro** | 20 -- 40 GB | Qwen2.5-32B-AWQ | 32K | RTX 4090, A6000 |
| **Enterprise** | 40 GB+ | Qwen2.5-72B-AWQ | 32K | A100, H100, multi-GPU |

Override with `./install.sh --tier 3` if you know what you want.

## Install

**One-liner (Linux / WSL):**

```bash
curl -fsSL https://raw.githubusercontent.com/Light-Heart-Labs/Lighthouse-AI/main/dream-server/get-dream-server.sh | bash
```

**Manual clone:**

```bash
git clone https://github.com/Light-Heart-Labs/Lighthouse-AI.git
cd Lighthouse-AI/dream-server
./install.sh
```

**Windows (PowerShell):**

```powershell
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/Light-Heart-Labs/Lighthouse-AI/main/dream-server/install.ps1" -OutFile install.ps1
.\install.ps1
```

The Windows installer handles WSL2 setup, Docker Desktop, and NVIDIA driver configuration automatically.

**Requirements:** Docker with Compose v2+, NVIDIA GPU with 8 GB+ VRAM (16 GB+ recommended), NVIDIA Container Toolkit, 40 GB+ disk space.

## Operations Toolkit

Standalone tools for running persistent AI agents in production, included in the repo:

- **Guardian** -- Self-healing process watchdog that monitors services, restores from backup, and runs as root so agents cannot kill it.
- **Memory Shepherd** -- Periodic memory reset to prevent identity drift in long-running agents.
- **Token Spy** -- API cost monitoring with real-time dashboard and auto-kill for runaway sessions.
- **vLLM Tool Proxy** -- Makes local model tool calling work with OpenClaw via SSE re-wrapping and loop protection.
- **LLM Cold Storage** -- Archives idle HuggingFace models to free disk while keeping them resolvable via symlink.

## Known Limitations

- First release -- expect rough edges.
- LiveKit voice requires manual profile activation (`--profile voice`).
- OpenClaw integration is experimental.
- No ARM / Apple Silicon support yet (planned).
- Models download on first run (20 GB+ for full-size models).
- Token Spy and TimescaleDB images are pinned to `latest` -- consider pinning exact versions in production.

## What's Next

- ARM / Apple Silicon support
- One-click model switching in dashboard
- Automated backup and restore
- Community workflow templates
- Pinned versions for all remaining `latest` tags

## Contributors

Built by [Lightheart Labs](https://github.com/Light-Heart-Labs) and the [OpenClaw Collective](https://github.com/Light-Heart-Labs/Lighthouse-AI/blob/main/COLLECTIVE.md).

---

**License:** Apache 2.0 -- use it, modify it, ship it.
