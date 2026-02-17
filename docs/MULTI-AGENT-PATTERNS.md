# Multi-Agent Patterns — Coordination, Reliability, and Swarms

Patterns for running multiple agents together. Covers coordination protocols,
reliability through redundancy, sub-agent spawning, and the failure modes that
emerge when agents collaborate.

These patterns were developed running 3+ persistent agents on local hardware.
They apply to any multi-agent setup — OpenClaw, cloud APIs, or mixed.

---

## Coordination: The Sync Protocol

When multiple agents share a codebase, you need rules for who changes what and
when. Without them, agents overwrite each other's work, merge conflicts pile
up, and nobody knows what's current.

### Branch-Based Review Pipeline

```
Agent A creates feature branch → builds → pushes
                                            ↓
                                    Agent B reviews branch
                                     ↓              ↓
                                Approved         Needs changes
                                   ↓                  ↓
                           Agent B merges        Agent A fixes, re-pushes
                             to main                  ↓
                                   ↓            Agent B re-reviews
                           Agent C validates
                          (integration test)
```

**Branch naming:** Use agent-identifiable prefixes:
- `agent-1/short-description`
- `agent-2/short-description`
- `reviewer/short-description` (rare — reviewers mostly review)

### What Needs Review vs. What Doesn't

| Needs Branch + Review | Goes Direct to Main |
|---|---|
| All code changes (.py, .js, .ts, .sh, .yaml) | Status updates, project boards |
| New tools or scripts | Research docs, notes |
| Product code | Daily logs, memory files |
| Infrastructure configs | Test results, benchmarks |

The split is: **code and config through branches, docs and status direct to
main.** This keeps the review pipeline focused on changes that can break things.

### Heartbeat Protocol

For always-on agents, run a periodic sync (every 15-60 minutes):

1. Pull latest from main
2. Check the project board for unclaimed work
3. Check for pending reviews from other agents
4. Check for handoffs or messages from siblings
5. Claim work, push results, update status

The heartbeat prevents drift between agents and catches handoffs that would
otherwise sit idle.

---

## Reliability Through Redundancy

### The Math

Single local model agents have inherent reliability limits. From empirical
testing:

| Setup | Pattern | Success Rate |
|---|---|---|
| 1 agent | Single attempt | ~67-77% |
| 2 agents | Any-success (take first) | ~95% |
| 3 agents | 2-of-3 voting | ~93% |
| 5 agents | 3-of-5 voting | ~97% |

**The simplest upgrade:** Spawn 2 agents on the same task, take the first
successful result. This takes reliability from ~70% to ~95% at 2x compute
cost — but on local hardware, compute is free.

### When to Use Redundancy

- **Critical tasks** where failure means manual intervention
- **Tasks with clear success criteria** (file exists, test passes, output matches)
- **Idempotent operations** where running twice causes no harm

Don't use redundancy for:
- Tasks with side effects (sending emails, posting messages)
- Tasks that modify shared state (unless you handle conflicts)
- Exploratory tasks where "different answer" isn't "wrong answer"

---

## Sub-Agent Spawning

### Task Templates That Work

The difference between a 30% and 90% success rate often comes down to how the
task is written.

**High success (~90%):**

```
You are a [ROLE] agent.

Complete ALL of these steps:

1. Run: ssh user@192.168.0.100 "[COMMAND_1]"
2. Run: ssh user@192.168.0.100 "[COMMAND_2]"
3. Run: ssh user@192.168.0.100 "[COMMAND_3]"
4. Write ALL findings to: /absolute/path/to/output.md

Include raw command outputs. Do not summarize or omit.
Do not stop until the file is written.
Reply "Done". Do not output JSON. Do not loop.
```

**What makes it work:**
1. Explicit commands (not "check the system" — actual commands to run)
2. Numbered steps (1, 2, 3 — not prose paragraphs)
3. Absolute file paths (not relative, not "save it somewhere")
4. Reinforcement ("do not stop until the file is written")
5. Stop prompt ("Reply Done. Do not output JSON. Do not loop.")
6. Single focus (one role, one objective)

**Low success (~30-40%):**
- Indirect instructions: "SSH as: user@host" instead of "Run: ssh user@host ..."
- Ambiguous scope: "Document all security configuration"
- Multi-server tasks: "Check both server A and server B"
- Open-ended exploration: "Look around and report what you find"
- Complex conditional logic in a single task

### When to Spawn vs. Do Directly

**Rule of thumb:** If you can write the task as one clear sentence with no
"and then," it's spawn-able.

| Spawn | Do Directly |
|---|---|
| Pure research, multiple independent questions | Needs tool execution with complex chains |
| Repetitive validation across artifacts | Time-sensitive, need it now |
| Document generation from clear templates | Complex multi-step workflows |
| Data gathering, parallel searches | Tasks requiring decisions mid-execution |

### Resource Management

Each sub-agent consumes GPU memory. On a single GPU:

| GPU Load | Concurrent Agents | Recommendation |
|---|---|---|
| Light | 1-4 | Fast, reliable |
| Medium | 5-8 | Good throughput, optimal sweet spot |
| Heavy | 9-12 | Some queuing expected |
| Overloaded | 13+ | Timeouts likely |

**Pre-spawn health check:**
```bash
# Check VRAM before spawning
curl localhost:9199/status | jq '.nodes[].vram_percent'
# If > 90%, defer spawning or use a lighter approach
```

**Timeouts are mandatory.** Without `runTimeoutSeconds`, local models can loop
indefinitely. Recommended values:

| Task Complexity | Timeout |
|---|---|
| Simple (file write, single command) | 60s |
| Multi-step (3-5 actions) | 120s |
| Complex research | 180s |

### Spawning Patterns

**Pattern 1: Research Fan-Out**

Spawn N agents, each with one focused question. Each writes findings to a
specific file. Coordinator aggregates.

```
Coordinator
  ├── Agent 1: "What are the top 3 embedding models for code search?"
  │                → writes to /tmp/research/embeddings.md
  ├── Agent 2: "What vector databases support hybrid search?"
  │                → writes to /tmp/research/vector-dbs.md
  └── Agent 3: "What's the state of the art in code chunking?"
                   → writes to /tmp/research/chunking.md
```

**Constraint:** Each agent gets ONE question. Don't overload.

**Pattern 2: Validation Sweep**

Define validation criteria. Spawn one agent per artifact. Agents report
pass/fail with specific issues.

Good for: testing multiple configs, validating documentation accuracy,
checking multiple endpoints.

**Pattern 3: Document Generation**

Define a template. Spawn agents with specific content assignments. Works well
for API docs, how-to guides, research summaries.

Fails for: docs requiring tool execution, cross-file coordination, or content
that depends on other agents' output.

### Anti-Patterns

| Anti-Pattern | Why It Fails |
|---|---|
| Tool-heavy sub-agents | Local models output tool calls as plain text JSON |
| Overloaded task scope | Too many objectives = shallow coverage on all of them |
| Cross-agent dependencies | Sub-agents can't read each other's output mid-run |
| Long-running complex chains | Multi-step workflows with decision points derail |

---

## Echo Chamber Prevention

When multiple agents work together, they can amplify each other's assumptions.
This is the most dangerous multi-agent failure mode because it looks like
productive collaboration.

### The Pattern

1. Agent A claims something is working
2. Agent B agrees without independent verification
3. Agent C builds on the claim
4. All three celebrate success
5. Nobody checked if the files actually exist

### The Protocol

**One-Lead Rule:** For debugging sessions, one agent investigates. Others
standby. Multiple agents poking at the same problem simultaneously creates
noise, not signal.

**Verify Before Claiming:** "Works" means:
- File exists on disk (not just "I wrote it")
- End-to-end test passed (not just "it should work")
- Output matches expectations (not just "no errors")

**Red Flag — Rapid Fire:** If 3+ messages fly between agents in quick
succession, everyone pauses. Fast agreement without verification is a signal,
not progress.

**Stop Means Stop:** When told to stop, acknowledge with ONE message, then
silence. Don't negotiate, don't add "one more thing."

**Skepticism > Agreement:** Never "+1" without independent verification.
If Agent A says it works, Agent B should check independently before agreeing.

---

## Division of Labor

If you run both local and cloud models, formalize who does what:

| Task Type | Assign To | Rationale |
|---|---|---|
| Testing, benchmarking, iteration | Local agent | Zero cost, unlimited retries |
| Large file analysis (>32K tokens) | Local agent | Large context at $0 |
| Code generation, boilerplate | Local agent | Volume work, low judgment |
| Integration testing | Cloud agent | Multi-system reasoning |
| Architecture, code review | Cloud agent | Nuance worth the cost |
| Complex debugging | Cloud agent | Error recovery, judgment calls |

**The savings compound.** Each test run a local agent handles saves a cloud API
call. Over a day of development, this adds up to $50-100+ in saved API costs.

For burn rate tracking, see [TOKEN-SPY.md](TOKEN-SPY.md). Token Spy shows
per-agent cost so you can verify the split is working.

---

## Status & Coordination Files

For teams of agents sharing a repo, establish conventions for coordination
files:

| File | Purpose | Update Frequency | Max Size |
|---|---|---|---|
| `STATUS.md` | Who's doing what right now | Every heartbeat | ~100 lines |
| `PROJECTS.md` | Work board with ownership | When work changes | No limit |
| `MISSIONS.md` | North-star priorities | Rarely | Short |
| `memory/YYYY-MM-DD.md` | Daily log of what happened | Continuously | No limit |

**STATUS.md** is ephemeral — it reflects current state only, not history.
**PROJECTS.md** is the work board — agents check it for unclaimed tasks.
**Daily logs** are the audit trail — what happened, when, and by whom.

Keep coordination files small and focused. An agent reading STATUS.md should
know in 10 seconds what's happening and what's blocked.
