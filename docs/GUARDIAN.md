# Infrastructure Protection — Guardians, Autonomy Tiers, and Safety Nets

Agents with filesystem access and shell execution can — and will — break their
own infrastructure. This doc covers patterns for preventing that: immutable
watchdogs, explicit permission tiers, and the self-modification problem.

These patterns complement the session-level protections (session watchdog,
Memory Shepherd) with system-level protections. Session tools keep agents
*running*; these patterns keep agents from *breaking what they run on*.

---

## The Problem

Persistent agents with tool access can:

- Kill their own gateway process while debugging something else
- Modify configs they depend on (proxy, vLLM, systemd services)
- Fill disks with log output or generated files
- Restart services during active sessions, losing state
- Overwrite their own baseline files (the ones Memory Shepherd restores from)

These aren't hypothetical. They happen when agents are resourceful — which is
exactly the behavior you want, applied to the wrong target.

---

## The Guardian Pattern

A guardian is a watchdog process that monitors critical infrastructure and
auto-recovers from failures. The key property: **agents cannot modify or
disable it.**

### Design Principles

1. **Runs as root** (or a privileged user the agent can't impersonate)
2. **Immutable** — `chattr +i` on the script file prevents modification
3. **Self-healing** — re-sets its own immutable flags if cleared
4. **Tiered monitoring** — not everything is equally critical
5. **Conservative recovery** — soft restart first, restore from backup only
   after repeated failures

### What It Monitors

Organize monitored resources into tiers by criticality:

| Tier | Resources | Recovery |
|---|---|---|
| 1 (Critical) | Agent gateway, API proxy | Auto-restart, alert on failure |
| 2 (Important) | vLLM inference, tool proxy | Auto-restart with backoff |
| 3 (Supporting) | Token Spy, monitoring, cron | Auto-restart, no alert |
| 4 (Auxiliary) | Log rotation, cleanup timers | Log warning, skip |

### Recovery Strategy

```
Service fails
  → Soft restart (systemctl restart)
  → Wait 10s, check again
  → If still down: soft restart #2
  → Wait 10s, check again
  → If still down: soft restart #3
  → Wait 10s, check again
  → If still down after 3 attempts: restore config from backup, restart
  → Alert operator
```

Three-strike recovery prevents thrashing while giving transient failures a
chance to self-resolve.

### Snapshot Generations

Keep N generations of known-good configs (default: 5):

```
/var/lib/guardian/backups/
  ├── gen-1/    # Most recent known-good
  ├── gen-2/
  ├── gen-3/
  ├── gen-4/
  └── gen-5/    # Oldest
```

When a service can't recover after 3 restarts, restore from the most recent
generation. If that fails, try the next. This handles the case where the
most recent "good" config was actually the one that broke things.

### Making It Immutable

```bash
# Install the guardian script
sudo cp guardian.sh /usr/local/bin/guardian.sh
sudo chmod 755 /usr/local/bin/guardian.sh

# Make it immutable — even root needs to explicitly remove this flag
sudo chattr +i /usr/local/bin/guardian.sh

# Verify
lsattr /usr/local/bin/guardian.sh
# Should show: ----i--------e-- /usr/local/bin/guardian.sh
```

**Why immutable matters:** An agent with sudo access or root shell can `rm` or
edit any file. `chattr +i` prevents modification even by root — the flag must
be explicitly removed first. The guardian re-sets its own flag on startup,
so even if an agent manages to clear it, the next check cycle restores it.

To update the guardian:
```bash
sudo chattr -i /usr/local/bin/guardian.sh
sudo cp guardian-v2.sh /usr/local/bin/guardian.sh
sudo chattr +i /usr/local/bin/guardian.sh
```

### Systemd Integration

```ini
[Unit]
Description=Infrastructure Guardian
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/guardian.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

`Restart=always` ensures the guardian itself restarts if killed.

---

## Autonomy Tiers

Tell agents explicitly what they can and can't do. The most effective pattern
is a tiered system — not a flat list of rules.

### The Tiers

| Tier | Label | Examples | Rationale |
|---|---|---|---|
| 0 | **Just do it** | Read files, run tests, draft PRs, push to feature branches, research, claim work, update scratch notes | Low risk, high frequency. Asking permission for these wastes cycles. |
| 1 | **Peer review** | Config changes to local services, new tools before deploy, research conclusions before sharing | Medium risk. Another agent or a quick human check prevents mistakes. |
| 2 | **Escalate** | Production systems, external communications, spending money, irreversible actions, OpenClaw/vLLM config changes | High risk. Always requires human approval. |

### Implementing Tiers in Baselines

Add autonomy tiers to your agent's baseline (see
[WRITING-BASELINES.md](../memory-shepherd/docs/WRITING-BASELINES.md)):

```markdown
## Autonomy Tiers

**Tier 0 — Just do it:** Chat, research, experiments, repo pushes,
test runs, claiming work, opinions, scratch notes.

**Tier 1 — Peer review:** Config changes, new tools, research
conclusions. Get a review from [reviewer agent] or a human.

**Tier 2 — Escalate:** Production infrastructure, external comms,
money, anything irreversible. Always ask [human operator].
```

The key is making tiers concrete with examples. "Be careful with production"
is Tier 2 phrased vaguely. "Never touch the production database without
explicit approval from the operator" is Tier 2 phrased usefully.

### The Self-Modification Rule

If an agent's code touches its **own** infrastructure, it must not modify
it directly:

1. Spawn a dev environment (separate machine, container, or branch)
2. Make changes there
3. Test and validate
4. Promote to production only after verification

**Why:** An agent that modifies the gateway it runs on can crash itself
mid-operation. There's no recovery from "I broke the thing that runs me."

This is the production hot-work lesson (see
[OPERATIONAL-LESSONS.md](OPERATIONAL-LESSONS.md)) formalized as a rule.

---

## Baseline Integrity Protection

Memory Shepherd's baseline files are critical — they define who each agent is
after every reset. If baselines get corrupted, agents get bad resets.

### Immutable Baselines

```bash
# Lock baseline files
sudo chattr +i memory-shepherd/baselines/*.md

# To update, temporarily unlock
sudo chattr -i memory-shepherd/baselines/my-agent-MEMORY.md
vim memory-shepherd/baselines/my-agent-MEMORY.md
sudo chattr +i memory-shepherd/baselines/my-agent-MEMORY.md
```

### Checksum Validation

```bash
# Generate checksums after writing baselines
sha256sum memory-shepherd/baselines/*.md > memory-shepherd/baselines/.checksums

# Verify before each reset
sha256sum --check memory-shepherd/baselines/.checksums || echo "TAMPERING DETECTED"
```

Add the checksum verification to the Memory Shepherd workflow or as a
pre-reset hook.

### Version Control

Keep baselines in version control with the rest of the repo. This gives you:
- Full change history (who changed what, when)
- Rollback capability (`git checkout <hash> -- baselines/`)
- Diff visibility (`git diff` shows exactly what changed)
- Branch-based review for baseline updates

---

## Combining Protections

The full protection stack, from session level to system level:

```
Session Level (keeps agents running):
  ├── Session Watchdog     — prevents context overflow crashes
  ├── Token Spy            — monitors cost, auto-resets bloated sessions
  └── Memory Shepherd      — resets memory to baseline, prevents drift

System Level (keeps infrastructure intact):
  ├── Guardian             — monitors services, auto-recovers failures
  ├── Autonomy Tiers       — explicit permission boundaries
  ├── Baseline Integrity   — immutable + checksummed identity files
  └── Self-Modification Rule — never hot-work your own infrastructure
```

Session tools are documented in the main [README](../README.md),
[TOKEN-SPY.md](TOKEN-SPY.md), and [memory-shepherd/README.md](../memory-shepherd/README.md).
This doc covers the system-level complement.

**The goal is defense in depth.** No single protection catches everything.
The session watchdog catches context overflow but not infrastructure damage.
The guardian catches service failures but not identity drift. Together, they
cover the full failure surface of persistent agents.
