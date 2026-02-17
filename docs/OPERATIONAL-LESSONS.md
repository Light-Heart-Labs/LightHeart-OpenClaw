# Operational Lessons — What We Learned Running Agents 24/7

Hard-won lessons from running persistent LLM agents on local hardware. These
aren't theoretical — they're from real incidents, real failures, and real fixes
discovered by the agents themselves.

If you're running agents that stay up for hours or days, you'll eventually hit
most of these. Might as well learn from our mistakes.

---

## Silent Failures

### Parser Mismatch Is Silent

Using the wrong `--tool-call-parser` doesn't produce an error. The model loads
fine, accepts requests, and returns responses — but tool calls come back as
plain text instead of structured JSON.

**Symptom:** Agent seems to work but never actually executes tools. Content
field contains JSON-looking text instead of proper `tool_calls`.

**Fix:** Match the parser to the model:

| Model Family | Parser |
|---|---|
| Qwen3-Coder-Next | `qwen3_coder` |
| Qwen2.5-Coder | `hermes` |
| Qwen2.5 Instruct | `hermes` |
| Qwen3-8B/32B | `hermes` |

The tool proxy (see [ARCHITECTURE.md](ARCHITECTURE.md)) catches some of these
as a safety net — it extracts tool calls from text content — but native parsing
is always more reliable.

### Compat Flags Fail Silently

vLLM doesn't reject unknown parameters — it silently ignores them. If you're
missing the `compat` block in `openclaw.json`, requests appear to succeed but
produce garbage or empty responses.

See the README for the four critical compat flags.

---

## Session & Memory Management

### Pre-Compaction Memory Flush

Before the session watchdog or Token Spy resets a session (see
[TOKEN-SPY.md](TOKEN-SPY.md)), any durable memories need to be externalized.
Agents should:

1. Write important findings to persistent files (daily logs, project docs)
2. Commit and push to version control
3. Only then allow the session to reset

If your agent operates on a timer (heartbeat or cron), build the flush into
the schedule. Memory Shepherd (see [memory-shepherd/README.md](../memory-shepherd/README.md))
handles the MEMORY.md reset cycle, but agents need to be taught to externalize
*before* the reset fires.

**Tip:** Include a brief explanation of the memory system in your baseline so
the agent knows to externalize important findings. See
[WRITING-BASELINES.md](../memory-shepherd/docs/WRITING-BASELINES.md) for how.

### Three-Tier Memory Persistence

For agents running long enough to accumulate real knowledge, use three tiers:

| Tier | Storage | Lifetime | Example |
|------|---------|----------|---------|
| Scratch notes | Below `---` in MEMORY.md | Until next reset (hours) | "PR #42 waiting on CI" |
| Daily logs | `memory/YYYY-MM-DD.md` | Days to weeks | "Found auth bug, fixed in commit abc123" |
| Permanent knowledge | Project repo, docs, baselines | Permanent | Architecture decisions, lessons learned |

Scratch notes get archived by Memory Shepherd. Daily logs get reviewed and
distilled into permanent knowledge periodically. Nothing important should live
only in scratch notes.

### Text > Brain

Agents don't have persistent memory between sessions — only files persist.
"Mental notes" don't survive restarts.

**Rule:** If it's worth remembering, write it to a file. If someone says
"remember this," write it to today's daily log. If you learn a lesson, write
it to the shared lessons file.

---

## Tool Calling Reliability

### Making Local Models Use Tools

Local models (Qwen, etc.) sometimes answer questions directly instead of using
provided tools. Two-layer fix:

1. **Prompt layer:** Add explicit instructions: `"You MUST use the provided
   tools. Do not answer directly. Always call a tool."`
2. **API layer:** The tool proxy injects stop tokens (`stop_token_ids: [151645]`)
   to prevent runaway generation after tool calls.

**Sampling settings that help:**

```json
{
  "temperature": 0.1,
  "top_p": 0.1
}
```

Lower temperature reduces "creative" responses that skip tool use.

### The Stop Prompt

For sub-agent tasks, always end with a stop prompt:

```
Reply "Done". Do not output JSON. Do not loop.
```

Without this, local models often:
- Output tool calls as raw JSON text instead of structured calls
- Enter infinite loops repeating the same action
- Continue generating after completing the task

The stop prompt is a safety net on top of the proxy's `MAX_TOOL_CALLS` limit
(see README for configuration).

### Atomic Chains for Multi-Step Tasks

Local models struggle with sequential tool chains (read file → transform →
write result). They conflate steps, loop, or skip actions.

**Fix:** Break multi-step tasks into single-action agents:

```
Agent 1 (read file) → output → Agent 2 (write result)
```

Key principles:
1. **One action per agent** — read OR write, never both in sequence
2. **Pass data through spawn results** — not shared state
3. **Verify side effects, not output text** — check the file exists, not what
   the agent said it did
4. **Include the stop prompt** in every sub-agent task

**When to use atomic chains:**
- Multi-step file operations
- Read → transform → write pipelines
- Any task where local models loop on sequential tools

---

## Production Safety

### Never Hot-Work Production

If your agent runs on the same server as its infrastructure (gateway, proxy,
vLLM), never modify that infrastructure while the agent is live.

**What happens:** Multiple gateway processes competing for the same port.
Connection drops. "Pairing required" errors. Silent failures that look like
model problems but are actually process conflicts.

**Rule:** Use a separate machine or container for testing changes. Promote to
production only after validation. If you only have one machine, stop the agent
before making infrastructure changes.

This applies to:
- Gateway config changes
- Proxy updates
- vLLM restarts
- systemd service modifications

### Docker Container → Host Networking

If OpenClaw runs in Docker and needs to reach services on the host (vLLM,
proxy, Token Spy):

- Use `172.17.0.1` (Docker bridge IP) instead of `127.0.0.1` in URLs
- Add firewall rules: `ufw allow from 172.17.0.0/16 to any port <PORT>`
- `localhost` inside a container refers to the container, not the host

### Verify Before Claiming

Status updates are not proof of completion. Agents sometimes report "done"
before verifying the work actually happened.

**Rule:** Working tree state > status reports.

Before declaring a task complete:
- Check `git status` — are files actually committed?
- Check `git log` — does the commit exist?
- Test the implementation — does it actually work?
- Check file existence — does the output file exist on disk?

Premature completion claims waste time because the next agent in the chain
assumes the work is done.

---

## Versioning & Rollback

### Snapshot Before Experimenting

Before any experiment on production infrastructure:

1. **Map** everything that might be touched (be thorough)
2. **Capture state** to version control with a tag
3. **Push before changing** — no baseline = no rollback
4. When something breaks → `git diff` between versions to find the change

```bash
git add -A && git commit -m "pre-experiment snapshot"
git tag -a v1.2.0 -m "Before proxy v5 experiment"
git push && git push --tags
```

Compare: `git diff v1.1.0 v1.2.0`
Rollback: `git checkout v1.1.0 -- path/to/file`

The effort of tagging before changes is trivial. The cost of not having a
rollback point is hours of debugging.

---

## Local Model Quirks

### Sub-Agent Announcements Are Normal

Local Qwen agents running under OpenClaw will sometimes announce "Research
complete" or similar status messages multiple times. This is normal OpenClaw
chaining behavior, not a bug.

### Bash Syntax in Scripts

When copying code between languages, watch for Python-isms in Bash:

- **Wrong:** `"""` for docstrings in Bash (causes syntax errors)
- **Right:** `#` comments in Bash

This seems obvious but catches agents that are primarily trained on Python.

---

## Cost-Aware Task Allocation

If you run both local and cloud models, allocate work by cost sensitivity:

| Task Type | Best For | Why |
|---|---|---|
| Testing, benchmarking, iteration | Local model | Zero cost, unlimited retries |
| Large file analysis | Local model | 128K context at $0 |
| Code generation, boilerplate | Local model | High volume, low judgment |
| Architecture decisions | Cloud model | Complex reasoning worth the cost |
| Code review | Cloud model | Nuance and quality matter |
| Customer-facing output | Cloud model | Reliability and polish |

Every testing task a local model handles saves cloud API credits. The savings
compound — a single day of local testing can save $50-100+ in API calls.

For a more detailed division of labor in multi-agent setups, see
[MULTI-AGENT-PATTERNS.md](MULTI-AGENT-PATTERNS.md).

### Burn Rate Awareness

With Token Spy tracking costs (see [TOKEN-SPY.md](TOKEN-SPY.md)), establish a
baseline burn rate for your workload. Know what "normal" looks like so you can
spot anomalies:

- Sudden cost spikes often mean an agent entered a retry loop
- Flat-zero cost on a cloud agent means it stopped working (not that it's efficient)
- Sub-agent spawns multiply cost — 10 parallel cloud sub-agents at $0.05 each = $0.50 per round

---

## Monitoring: Two Different Questions

If you run both Token Spy and a vLLM monitor (Prometheus/Grafana), understand
that they answer different questions:

| Monitor | Question It Answers | Key Metrics |
|---|---|---|
| Token Spy (:9110) | How much did we spend? | Tokens, cost, session health |
| vLLM Monitor (:9115) | Is the GPU overloaded? | VRAM, queue depth, tokens/sec |

**Why they diverge:**
- Local model runs: Token Spy shows $0, vLLM shows lots of tokens processed
- Cache hits: Token Spy shows reduced cost, vLLM shows no request at all
- Failed retries: Token Spy shows the cost of attempts, vLLM shows the load

Both are useful. Neither replaces the other.
