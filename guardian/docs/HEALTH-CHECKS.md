# Health Checks Reference

How Guardian monitors resources and recovers from failures.

---

## The Tier System

Organize your config sections by dependency criticality. Guardian checks all sections every cycle, but tiers help you reason about what matters most:

| Tier | Purpose | Example |
|------|---------|---------|
| **Tier 1** | Agent lifeline — agent is dead without these | Gateways, core services |
| **Tier 2** | API routing — agent can't think without these | Proxies, API servers |
| **Tier 3** | Memory & context — agent loses state without these | Databases, config files |
| **Tier 4** | Helpers — degraded but alive without these | Monitoring, bots, utilities |

Guardian doesn't enforce tiers — they're an organizational convention. Every enabled section gets checked every cycle regardless of tier.

---

## Monitoring Types

### `process`

Matches a running process by command-line pattern (via `pgrep -f`). If the process isn't found, Guardian restarts it using `start_cmd`.

```ini
[my-api-server]
enabled=true
type=process
description=My API Server
process_match=uvicorn main:app.*8080
start_cmd=start.sh
start_dir=/opt/myapp
start_user=deploy
start_venv=/opt/myapp/venv
required_ports=8080
health_url=http://127.0.0.1:8080/health
protected_files=/opt/myapp/main.py,/opt/myapp/start.sh
max_soft_restarts=3
restart_grace=10
```

**Recovery flow:**
1. Kill existing process (`pkill -f`, then `pkill -9` after 2s)
2. Free required ports (`fuser -k`)
3. Activate virtualenv if `start_venv` is set
4. `cd` to `start_dir` if set
5. Run `start_cmd` as `start_user` via `nohup` (`.py` files use `python3`, others use `bash`)

### `systemd-user`

Monitors a systemd user service via `systemctl --user is-active`. Restarts via `systemctl --user restart`.

```ini
[my-gateway]
enabled=true
type=systemd-user
description=OpenClaw Gateway
service=openclaw-gateway.service
systemd_user=deploy
required_ports=3100
health_port=3100
protected_files=/home/deploy/.openclaw/openclaw.json
protected_service=/home/deploy/.config/systemd/user/openclaw-gateway.service
max_soft_restarts=3
restart_grace=15
skip_immutable=true
```

**Important:** `systemd_user` is required — Guardian needs to know which user's systemd instance to interact with.

### `docker`

Monitors a Docker container via `docker inspect`. Restarts via `docker restart`.

```ini
[my-database]
enabled=true
type=docker
description=Vector Database
container_name=qdrant-prod
required_ports=6333
health_url=http://127.0.0.1:6333/healthz
max_soft_restarts=3
restart_grace=15
```

### `file-integrity`

Validates that files exist, are non-empty, and optionally contain valid JSON with required keys and values. Recovery restores from backup.

```ini
[my-settings]
enabled=true
type=file-integrity
description=Application Settings
protected_files=/opt/myapp/settings.json,/opt/myapp/config.yaml
required_json_keys=session_limit,poll_interval
required_json_values=database.host=localhost
max_soft_restarts=1
restart_grace=5
```

---

## Config Key Reference

### Common Keys (all types)

| Key | Required | Default | Description |
|-----|----------|---------|-------------|
| `enabled` | yes | `false` | Must be `true` to monitor this section |
| `type` | yes | — | `process`, `systemd-user`, `docker`, or `file-integrity` |
| `description` | no | section name | Human-readable description for logs |
| `max_soft_restarts` | no | `3` | Soft restarts before falling back to backup restore |
| `restart_grace` | no | `10` | Seconds to wait after a restart before rechecking |
| `restart_via` | no | — | Delegate restart to another section (by section name) |
| `protected_files` | no | — | Comma-separated file paths to backup and monitor |
| `protected_service` | no | — | Systemd service file path to backup |
| `skip_immutable` | no | `false` | If `true`, don't set immutable flag on restored files |
| `required_ports` | no | — | Comma-separated ports that must be listening |
| `health_url` | no | — | URL that must return HTTP 2xx |
| `health_port` | no | — | Port that must be listening (simpler than `required_ports`) |
| `health_cmd` | no | — | Shell command that must exit 0 |

### Process-Specific Keys

| Key | Required | Default | Description |
|-----|----------|---------|-------------|
| `process_match` | yes | — | Pattern for `pgrep -f` matching |
| `start_cmd` | yes | — | Script/binary to start (`.py` → python3, else bash) |
| `start_dir` | no | — | Working directory for `start_cmd` |
| `start_user` | no | `$(whoami)` | Unix user to run as. **Warning:** defaults to `root` when Guardian runs as a systemd service — always set this explicitly. |
| `start_venv` | no | — | Python virtualenv path to activate before starting |

### Systemd-User Keys

| Key | Required | Default | Description |
|-----|----------|---------|-------------|
| `service` | yes | — | Systemd service unit name |
| `systemd_user` | yes | — | Unix user whose systemd instance to manage |

### Docker Keys

| Key | Required | Default | Description |
|-----|----------|---------|-------------|
| `container_name` | yes | — | Docker container name |

### File-Integrity Keys

| Key | Required | Default | Description |
|-----|----------|---------|-------------|
| `required_json_keys` | no | — | Comma-separated top-level keys that must exist in JSON files |
| `required_json_values` | no | — | Comma-separated `path=value` pairs to validate in JSON files |

---

## The Recovery Cascade

When Guardian detects an unhealthy resource, it follows this sequence:

```
UNHEALTHY detected
  │
  ├─ failure_count <= max_soft_restarts?
  │   └─ YES → Soft restart (just restart the service/process)
  │              Wait restart_grace seconds
  │
  └─ NO (soft restarts exhausted)
      └─ Restore protected_files from backup
         Restart the service/process
         Wait restart_grace seconds
         Reset failure counter to 0
```

**Failure tracking** is persistent across cycles. Each section gets a failure counter file in `/var/lib/guardian/state/`. When a resource recovers (detected healthy after being unhealthy), the counter resets to 0.

### Example timeline for `process` / `systemd-user` / `docker`

With `max_soft_restarts=3`:

| Cycle | Status | Action |
|-------|--------|--------|
| 1 | Unhealthy | Soft restart #1 (just restart the service) |
| 2 | Unhealthy | Soft restart #2 |
| 3 | Unhealthy | Soft restart #3 |
| 4 | Unhealthy | Restore files from backup, then restart service |
| 5 | Healthy | Reset counter, take snapshot |

### How `file-integrity` differs

For `file-integrity` sections, the "restart" action IS a backup restore (there's no process to restart — the recovery is restoring the file). This means the soft restart and the backup-restore fallback both do the same thing: restore from backup.

In practice, use `max_soft_restarts=0` for file-integrity sections. This skips the redundant "soft restart" phase and goes straight to restore:

```ini
[my-config-files]
type=file-integrity
max_soft_restarts=0    # Go straight to restore — no process to "soft restart"
```

If you set `max_soft_restarts=3` on a file-integrity section, Guardian will restore from backup 3 times (one per cycle), then restore again on cycle 4. It's not harmful, but the extra attempts are redundant.

If the file-integrity section has a `restart_via` pointing to a process or service section, the cascade makes more sense — the soft restart phase restores the file and then restarts the delegated service:

```ini
[my-pinned-config]
type=file-integrity
protected_files=/opt/myapp/config.json
required_json_values=model.primary=gpt-4
restart_via=my-api-server    # After restoring the file, restart this service
max_soft_restarts=0
```

---

## File Integrity and JSON Validation

The `file-integrity` type goes beyond checking that files exist. It can validate JSON structure:

### `required_json_keys`

Checks that top-level keys exist in all `.json` files in `protected_files`:

```ini
required_json_keys=session_limit,poll_interval,agents
```

Guardian will flag files that are missing any of these keys.

### `required_json_values`

Pins specific values at dot-notation paths:

```ini
required_json_values=agents.defaults.model.primary=gpt-4,database.port=5432
```

Guardian traverses nested objects using the dot-separated path. If the actual value doesn't match the expected value, the file is considered corrupted and will be restored from backup.

This is useful for preventing agents from changing their own model configuration or other critical settings.

---

## Restart Delegation (`restart_via`)

Sometimes a process is a child of another service. Instead of restarting the child directly, you want to restart the parent:

```ini
[ollama]
enabled=true
type=process
description=Ollama LLM Server
process_match=ollama serve
required_ports=11434
restart_via=my-gateway
```

When `ollama` is unhealthy, Guardian restarts `my-gateway` instead — which will respawn ollama as a child process. The delegation follows the `restart_via` chain (can delegate multiple levels deep).

---

## Custom Health Commands (`health_cmd`)

For checks that don't fit the built-in patterns, use `health_cmd`:

```ini
health_cmd=/opt/myapp/health-check.sh
```

The command runs in bash. **Exit code 0 = healthy**, non-zero = unhealthy. The first 120 characters of stdout/stderr are included in the log message on failure.

Examples:
- Check a database connection: `health_cmd=pg_isready -h localhost`
- Validate a complex config: `health_cmd=python3 /opt/myapp/validate_config.py`
- Check disk space: `health_cmd=test $(df --output=pcent /data | tail -1 | tr -d '% ') -lt 90`

---

## Immutable Flag Management

Guardian uses Linux `chattr +i` (immutable attribute) to prevent agents from modifying critical files. When immutable is set, even root must explicitly clear it before writing.

### Default behavior

- Backup files are always immutable (root-owned, mode 600)
- Restored files get immutable set after restore
- Guardian's own files (`guardian.sh`, config, service file) are kept immutable via `check_self_integrity()`

### `skip_immutable=true`

Some files need to be writable by the application (e.g., config files that agents legitimately update). Set `skip_immutable=true` to prevent Guardian from setting the immutable flag after restore:

```ini
skip_immutable=true
```

The file is still backed up and can be restored — it just won't be locked after restoration.

### Editing protected files

To edit a file Guardian is protecting:

```bash
# 1. Clear the immutable flag
sudo chattr -i /etc/guardian/guardian.conf

# 2. Edit the file
sudo nano /etc/guardian/guardian.conf

# 3. Re-set the flag (or let Guardian do it on next cycle)
sudo chattr +i /etc/guardian/guardian.conf

# 4. Restart guardian to pick up config changes
sudo systemctl restart guardian
```

---

## Backup System

Guardian maintains generational backups of all `protected_files` and `protected_service` files.

### Snapshot behavior

- On each healthy cycle, Guardian compares the live file to the latest backup
- If the file has changed, it rotates existing backups and takes a new snapshot
- Backups are stored in `/var/lib/guardian/backups/<section-name>/`

### Generations

With `backup_generations=5`, backups are named:

```
settings.json      ← current (most recent healthy state)
settings.json.1    ← previous
settings.json.2    ← two versions ago
settings.json.3
settings.json.4
settings.json.5    ← oldest (deleted when a new snapshot is taken)
```

### Restore behavior

When soft restarts are exhausted, Guardian restores all `protected_files` from the most recent backup (the un-numbered copy). File ownership is set to `start_user` or `systemd_user` from the section config.
