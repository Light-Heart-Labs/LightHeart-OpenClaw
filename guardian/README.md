# Guardian — Self-Healing Process Watchdog

An auto-healing process watchdog for LLM infrastructure. Monitors services, detects failures, and restores from known-good backups — all without human intervention.

---

## The Problem

Persistent LLM agents break things:

- **Services crash.** Gateways, API proxies, and vector databases go down. The agent can't call LLMs, can't search memory, can't function.
- **Configs get corrupted.** Agents modify their own model settings, break JSON configs, or overwrite critical files.
- **Processes disappear.** Background services get killed by OOM, stale PIDs, or the agent itself.
- **Nobody notices.** By the time you check, the agent has been running degraded for hours.

Guardian fixes all of this automatically.

---

## Design Principles

1. **Agents can't touch it.** Guardian runs as a root systemd service. Agents (unprivileged users) cannot kill, modify, or interfere with it.
2. **It knows what healthy looks like.** Configuration defines the desired state. Generational backups preserve known-good file contents.
3. **It heals automatically.** Soft restart first, then restore from backup and restart. No human intervention needed.
4. **It logs everything.** Every failure, every restart, every restore is logged with timestamps. You always know what broke and when.

---

## Supported Monitoring Types

| Type | Monitors | Restarts via |
|------|----------|-------------|
| `process` | `pgrep -f` pattern match | `start_cmd` (kill + restart) |
| `systemd-user` | `systemctl --user is-active` | `systemctl --user restart` |
| `docker` | `docker inspect` container state | `docker restart` |
| `file-integrity` | File existence, size, JSON validity | Restore from backup |

All types support additional health checks: `required_ports`, `health_url`, `health_port`, `health_cmd`.

---

## Prerequisites

- **Linux with systemd** (Ubuntu, Debian, Fedora, RHEL, etc.)
- **ext4 or xfs filesystem** (for `chattr +i` immutable flags — btrfs/zfs use different mechanisms)
- **python3** (for JSON validation in `file-integrity` checks)
- **curl** (for `health_url` checks)
- **iproute2** (`ss` command, for port checks — installed by default on most distros)
- **e2fsprogs** (`chattr`/`lsattr` commands — installed by default on most distros)
- **psmisc** (`fuser` command, for freeing ports during process restarts)
- **docker** (optional, only needed if monitoring Docker containers)

```bash
# Debian/Ubuntu — install anything missing
sudo apt install python3 curl iproute2 e2fsprogs psmisc

# RHEL/Fedora
sudo dnf install python3 curl iproute e2fsprogs psmisc
```

---

## Quick Start

```bash
# Clone (or copy the guardian/ directory)
git clone https://github.com/Light-Heart-Labs/LightHeart-OpenClaw.git
cd LightHeart-OpenClaw/guardian

# Copy and edit the config
cp guardian.conf.example guardian.conf
nano guardian.conf
# All sections ship as enabled=false — enable the ones you need

# IMPORTANT: Update ReadWritePaths in the systemd service
nano guardian.service
# ProtectSystem=strict blocks ALL writes outside listed paths.
# You MUST add every directory Guardian needs to read/write:
#   ReadWritePaths=/var/log /var/lib/guardian /tmp /home/deploy /opt/myapp
# Without this, Guardian will silently fail to backup, restore, or
# restart anything in unlisted directories.

# Install (requires root)
sudo ./install.sh

# Verify it's running
sudo systemctl status guardian
sudo tail -f /var/log/guardian.log
```

### Editing config after install

```bash
sudo chattr -i /etc/guardian/guardian.conf   # unlock
sudo nano /etc/guardian/guardian.conf         # edit
sudo chattr +i /etc/guardian/guardian.conf    # re-lock
sudo systemctl restart guardian              # apply
```

### Editing ReadWritePaths after install

```bash
sudo chattr -i /etc/systemd/system/guardian.service
sudo nano /etc/systemd/system/guardian.service   # add paths to ReadWritePaths
sudo chattr +i /etc/systemd/system/guardian.service
sudo systemctl daemon-reload
sudo systemctl restart guardian
```

---

## Configuration Reference

Guardian uses INI-style config files. Each section (except `[general]`) defines a monitored resource.

### `[general]` section

| Key | Default | Description |
|-----|---------|-------------|
| `check_interval` | `60` | Seconds between monitoring cycles |
| `log_file` | `/var/log/guardian.log` | Log file path |
| `max_log_size` | `10485760` | Log rotation threshold (bytes, default 10MB) |
| `backup_dir` | `/var/lib/guardian/backups` | Backup storage directory |
| `backup_generations` | `5` | Number of backup generations to keep |

### Resource section keys

| Key | Default | Description |
|-----|---------|-------------|
| `enabled` | `false` | Must be `true` to monitor |
| `type` | — | `process`, `systemd-user`, `docker`, or `file-integrity` |
| `description` | section name | Human-readable label for logs |
| `max_soft_restarts` | `3` | Attempts before falling back to backup restore |
| `restart_grace` | `10` | Seconds to wait after restart |
| `restart_via` | — | Delegate restart to another section |
| `protected_files` | — | Comma-separated paths to backup/monitor |
| `protected_service` | — | Systemd service file to backup |
| `skip_immutable` | `false` | Don't set immutable flag on restored files |
| `required_ports` | — | Ports that must be listening |
| `health_url` | — | URL that must return HTTP 2xx |
| `health_port` | — | Single port that must be listening |
| `health_cmd` | — | Shell command that must exit 0 |
| `process_match` | — | `pgrep -f` pattern (type=process) |
| `start_cmd` | — | Start script (type=process) |
| `start_dir` | — | Working directory (type=process) |
| `start_user` | `$(whoami)` | Unix user to run as (type=process). **See warning below.** |
| `start_venv` | — | Python venv path (type=process) |
| `service` | — | Systemd unit name (type=systemd-user) |
| `systemd_user` | — | Unix user (type=systemd-user, required) |
| `container_name` | — | Docker container (type=docker) |
| `required_json_keys` | — | Required top-level keys in JSON files |
| `required_json_values` | — | Pinned `path=value` pairs in JSON files |

See [docs/HEALTH-CHECKS.md](docs/HEALTH-CHECKS.md) for detailed examples of each type.

### Warning: `start_user` defaults to root in production

`start_user` defaults to `$(whoami)`. When Guardian runs as a systemd service (which runs as root), this means **processes will be started as root** unless you set `start_user` explicitly. Always set it:

```ini
start_user=deploy
```

---

## Recovery Cascade

```
UNHEALTHY detected
  │
  ├─ failure_count <= max_soft_restarts?
  │   └─ YES → Soft restart (kill + restart or systemctl restart)
  │              Wait restart_grace seconds
  │
  └─ NO (exhausted)
      └─ Restore all protected_files from backup
         Restart the service
         Reset failure counter
```

Failure counters are persistent across cycles and reset when a resource recovers.

---

## Backup System

- **Snapshots on health.** Every cycle a resource is healthy, Guardian diffs live files against the latest backup and takes a new snapshot if they changed.
- **Generational rotation.** Up to N generations (default 5). Oldest is deleted when a new snapshot arrives.
- **Immutable backups.** All backup files are root-owned, mode 600, and `chattr +i`. Agents cannot modify or delete them.
- **Service files too.** `protected_service` paths are backed up alongside application files.

```
/var/lib/guardian/backups/
└── my-gateway/
    ├── openclaw.json        ← latest healthy
    ├── openclaw.json.1      ← previous
    ├── openclaw.json.2
    └── ...
```

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                        systemd (PID 1)                          │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │  guardian.service (root)                                  │    │
│  │                                                          │    │
│  │  ┌─────────────┐   every Ns    ┌───────────────────┐    │    │
│  │  │ guardian.sh  │ ────────────→ │ check_section()   │    │    │
│  │  │             │               │                   │    │    │
│  │  │  • INI parse │               │ • process match   │    │    │
│  │  │  • log rotate│               │ • systemd status  │    │    │
│  │  │  • self-check│               │ • docker inspect  │    │    │
│  │  └─────────────┘               │ • file integrity  │    │    │
│  │                                │ • port checks     │    │    │
│  │                                │ • URL checks      │    │    │
│  │                                │ • custom commands  │    │    │
│  │                                └───────┬───────────┘    │    │
│  │                                        │                │    │
│  │                            ┌───────────┴───────────┐    │    │
│  │                            │                       │    │    │
│  │                     ┌──────▼──────┐    ┌───────────▼┐   │    │
│  │                     │   HEALTHY   │    │  UNHEALTHY │   │    │
│  │                     │             │    │            │   │    │
│  │                     │ • snapshot  │    │ • restart  │   │    │
│  │                     │ • reset ctr │    │ • restore  │   │    │
│  │                     └─────────────┘    └────────────┘   │    │
│  │                                                          │    │
│  └──────────────────────────────────────────────────────────┘    │
│                                                                  │
│  ┌──────────────────┐  ┌──────────────────┐                     │
│  │ /var/lib/guardian │  │ /var/log/        │                     │
│  │ └── backups/     │  │ └── guardian.log  │                     │
│  │ └── state/       │  └──────────────────┘                     │
│  └──────────────────┘                                           │
└──────────────────────────────────────────────────────────────────┘
```

---

## Security Model

- **Root ownership.** `guardian.sh`, config, and systemd service are owned by root with immutable flags (`chattr +i`).
- **ProtectSystem=strict.** Systemd sandboxing prevents writes outside explicitly allowed paths.
- **PrivateTmp=true.** Guardian gets its own `/tmp` namespace.
- **Self-integrity checks.** Every cycle, Guardian verifies its own immutable flags are intact and re-sets them if cleared.
- **Immutable backups.** Backup files are root:root, mode 600, chattr +i. Agents cannot read, modify, or delete them.

---

## Extension Points

Guardian is designed to be extended via the config file and by forking the script.

### Custom health checks

Use `health_cmd` to run any validation logic:

```ini
health_cmd=/opt/myapp/deep-health-check.sh
```

### Model pinning

Use `file-integrity` with `required_json_values` to prevent agents from changing their own model config:

```ini
[model-pin]
type=file-integrity
protected_files=/home/deploy/.openclaw/openclaw.json
required_json_values=agents.defaults.model.primary=gpt-4
restart_via=my-gateway
```

### Restart delegation

Chain restarts through parent processes:

```ini
restart_via=parent-section-name
```

### Adding custom sync logic (e.g. model propagation)

If you need Guardian to do more than monitor and restart — for example, querying a vLLM `/v1/models` endpoint and propagating the current model name to downstream config files and databases — add a custom function to the main loop.

The pattern: write a function that reads its own config section, does the sync work, and call it from the `while true` loop in `main()`:

```bash
# In guardian.sh, add your function above main():
sync_my_models() {
    local section="my-model-sync"
    local enabled
    enabled=$(cfg "$section" enabled "false")
    [[ "$enabled" != "true" ]] && return 0

    # Query your model server, update downstream configs, etc.
    # Use cfg() to read config, log() to log, clear_immutable()/set_immutable()
    # to manage protected files, and secure_backup() to update backups.
}

# In the main loop, call it alongside check_section:
while true; do
    rotate_log
    check_self_integrity
    sync_my_models          # <-- your custom sync
    for section in "${SECTIONS[@]}"; do
        # ...
    done
    sleep "$interval"
done
```

This is how the production version handles vLLM model sync — a ~200 line function that queries `/v1/models`, updates agent config files, and patches workflow databases. It was too infrastructure-specific to include here, but the pattern is straightforward: read config, do work, update backups.

---

## Troubleshooting

### Check the log first

```bash
sudo tail -50 /var/log/guardian.log
```

### What healthy looks like

```
[2025-07-15 14:30:00] [INFO] ==========================================
[2025-07-15 14:30:00] [INFO] Guardian starting
[2025-07-15 14:30:00] [INFO]   Config: /etc/guardian/guardian.conf
[2025-07-15 14:30:00] [INFO]   Monitoring: 4 resources
[2025-07-15 14:30:00] [INFO]   Interval: 60s
[2025-07-15 14:30:00] [INFO]   Backups: /var/lib/guardian/backups (5 generations)
[2025-07-15 14:30:00] [INFO] ==========================================
[2025-07-15 14:30:00] [INFO] Taking initial snapshots of all protected resources...
[2025-07-15 14:30:01] [INFO] [my-gateway] Snapshot updated: openclaw.json
[2025-07-15 14:30:01] [INFO] Initial snapshots complete.
```

### What a failure + recovery looks like

```
[2025-07-15 15:31:00] [WARN] [my-api-server] API Server UNHEALTHY: process not found (match: uvicorn main:app.*8080) (failure #1)
[2025-07-15 15:31:00] [INFO] [my-api-server] Soft restart (1/3)
[2025-07-15 15:31:00] [INFO] [my-api-server] Starting: start.sh (user=deploy)
[2025-07-15 15:32:00] [INFO] [my-api-server] API Server RECOVERED. Resetting failure counter.
[2025-07-15 15:32:00] [INFO] [my-api-server] Snapshot updated: main.py
```

### What backup restore looks like

```
[2025-07-15 16:35:00] [WARN] [my-settings] Application Settings UNHEALTHY: file integrity check failed (failure #4)
[2025-07-15 16:35:00] [WARN] [my-settings] Soft restarts exhausted. RESTORING FROM BACKUP.
[2025-07-15 16:35:00] [WARN] [my-settings] RESTORED: settings.json
[2025-07-15 16:35:00] [INFO] [my-settings] Backup restored. Restarting...
```

### Common problems

| Problem | Cause | Fix |
|---------|-------|-----|
| Guardian can't read/write monitored files | `ProtectSystem=strict` blocks unlisted paths | Add directories to `ReadWritePaths` in `guardian.service`, run `systemctl daemon-reload && systemctl restart guardian` |
| Process starts as root | `start_user` defaults to `$(whoami)` = root in systemd | Set `start_user=youruser` explicitly in config |
| "FATAL: Config not found" | Config not at expected path | Set `GUARDIAN_CONF=/path/to/guardian.conf` in the systemd service `Environment=` line |
| `chattr` errors on btrfs/zfs | Immutable flags are ext4/xfs-specific | Guardian still works but immutable protection is unavailable; files can be modified by agents |
| JSON validation fails but file looks correct | Trailing commas or comments in JSON | Python's `json.load()` is strict — no trailing commas, no comments |
| "No systemd_user defined" | `systemd_user` is required for `systemd-user` type | Add `systemd_user=youruser` to the section |
| Log fills up with failures for example services | Example config has services that don't exist on your system | Set `enabled=false` on sections you haven't configured (the example config ships this way) |

---

## Uninstall

```bash
sudo ./uninstall.sh
```

Stops the service, removes the systemd unit, clears immutable flags, and removes installed files. Backups and logs are preserved (instructions to remove them are printed).
