# Dream Server Quick Start

One command to a fully running local AI stack. No manual config, no dependency hell.

## Prerequisites

**Linux:**
- Docker with Compose v2+ ([Install](https://docs.docker.com/get-docker/))
- NVIDIA GPU with 8GB+ VRAM (16GB+ recommended)
- NVIDIA Container Toolkit ([Install](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html))
- 40GB+ disk space (for models)

**Windows:**
- Windows 10 21H2+ or Windows 11
- NVIDIA GPU with drivers
- Docker Desktop (installer will prompt if missing)
- WSL2 (installer will enable if needed)

For Windows, use `install.ps1` instead — see [README.md](README.md#windows).

## Step 1: Run the Installer

```bash
./install.sh
```

The installer will:
1. **Detect your GPU** and auto-select the right tier:
   - Tier 1 (Entry): <12GB VRAM → Qwen2.5-7B, 8K context
   - Tier 2 (Prosumer): 12-20GB VRAM → Qwen2.5-14B-AWQ, 16K context
   - Tier 3 (Pro): 20-40GB VRAM → Qwen2.5-32B-AWQ, 32K context
   - Tier 4 (Enterprise): 40GB+ VRAM → Qwen2.5-72B-AWQ, 32K context
2. Check Docker and NVIDIA toolkit
3. Ask which optional components to enable (voice, workflows, RAG)
4. Generate secure passwords and configuration
5. Start all services

**Override tier manually:** `./install.sh --tier 3`

**Time Estimate:** 5-10 minutes interactive setup, plus 10-30 minutes for first model download.

## Step 2: Wait for Model Download

First run downloads the LLM (~20GB for 32B AWQ). Watch progress:

```bash
docker compose logs -f vllm
```

When you see `Application startup complete`, you're ready!

## Step 3: Validate Installation

Verify everything is working:

```bash
./scripts/dream-preflight.sh
```

This tests all services and confirms Dream Server is ready. You should see green checkmarks for each test.

**For comprehensive testing:**
```bash
./scripts/dream-test.sh
```

This runs the full validation suite including load tests.

## Step 4: Open Chat UI

Visit: **http://localhost:3000**

1. Create an account (first user becomes admin)
2. Select a model from the dropdown
3. Start chatting!

## Step 5: Test the API

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-32B-Instruct-AWQ",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

---

## Hardware Tiers

The installer auto-detects your GPU and selects the optimal configuration:

| Tier | VRAM | Model | Example GPUs |
|------|------|-------|--------------|
| 1 (Entry) | <12GB | Qwen2.5-7B | RTX 3080, RTX 4070 |
| 2 (Prosumer) | 12-20GB | Qwen2.5-14B-AWQ | RTX 3090, RTX 4080 |
| 3 (Pro) | 20-40GB | Qwen2.5-32B-AWQ | RTX 4090, A6000 |
| 4 (Enterprise) | 40GB+ | Qwen2.5-72B-AWQ | A100, H100 |

To check what tier you'd get without installing:

```bash
./scripts/detect-hardware.sh
```

---

## Common Issues

### "OOM" or "CUDA out of memory"

Reduce context window in `.env`:
```
MAX_CONTEXT=4096  # or even 2048
```

Or switch to a smaller model:
```
LLM_MODEL=Qwen/Qwen2.5-7B-Instruct
```

### Model download fails

1. Check disk space: `df -h`
2. Try again: `docker compose restart vllm`
3. Or pre-download with Hugging Face CLI

### WebUI shows "No models available"

vLLM is still loading. Check: `docker compose logs vllm`

### Port conflicts

Edit `.env` to change ports:
```
WEBUI_PORT=3001
VLLM_PORT=8001
```

---

## Next Steps

- **Enable voice**: `docker compose --profile voice up -d`
- **Try voice-to-voice**: Import `workflows/05-voice-to-voice.json` into n8n — speak, get spoken answers back
- **Add workflows**: `docker compose --profile workflows up -d` (see `workflows/README.md`)
- **Set up RAG**: `docker compose --profile rag up -d`
- **Connect OpenClaw**: Use this as your local inference backend

---

## Stopping

```bash
docker compose down
```

## Updating

```bash
docker compose pull
docker compose up -d
```

---

Built by The Collective • [Lighthouse AI](https://github.com/Light-Heart-Labs/Lighthouse-AI)
