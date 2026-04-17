## Distributed Lock Recovery & Failure Modes

File-level locking in concurrent fleet execution must survive process crashes, filesystem errors, and malformed lock state. This skill guides building resilient lock recovery.

### Core Failure Modes

1. **Stale Locks**: Pipeline crashes before releasing lock—other pipelines blocked indefinitely
2. **Corrupted State**: Lock file partially written, unreadable JSON, or filesystem error mid-write
3. **Lock Timeout**: Queue depth grows as locks held longer than expected
4. **Permission Denial**: Lock cleanup fails due to process permission mismatch
5. **Clock Skew**: Timestamp-based cleanup unreliable in distributed scenarios

### Recovery Protocol

**Acquisition with TTL**:
- Every lock must include `acquired_at` timestamp and `ttl_seconds` (recommend 3600 = 1 hour for pipeline execution)
- On startup, scan lock file and purge locks older than TTL—prevents indefinite blocking
- Log stale lock cleanup with pipeline ID and age for auditing

**Atomic Writes**:
- Lock file mutations via temp file + `mv` (atomic rename)
- Never partial writes—lock state is either valid or absent
- Track lock format version in lock file for forward compatibility

**Crash Detection**:
- Lock entry includes heartbeat mechanism: pipeline updates mtime every 30s during execution
- If mtime hasn't changed in 2× heartbeat interval, treat lock as stale
- Daemon cleanup task runs every 5 minutes scanning for stale locks by mtime

**Queue Corruption**:
- If queued pipelines file becomes unreadable, restart queue empty (log incident)
- Queue entries must be durable—use append-only log, not in-memory
- Replay log to recover queue state on startup

### State Transitions

```
LOCK_FREE → (acquire with TTL) → LOCK_HELD (heartbeat updates mtime)
          → (release called) → LOCK_FREE
          → (crash, mtime stale) → [cleanup task] → LOCK_FREE
          → (JSON corrupt) → [cleanup task] → LOCK_FREE
```

### Monitoring Signals

- Alert if stale lock cleanup removes >10 locks in 5 min window (suggests systemic crash)
- Alert if queue depth grows monotonically (suggests locks not releasing)
- Alert if lock file mtime hasn't been touched in 10 min (suggests lock system offline)

### Operator Runbook

- **"My pipeline is stuck waiting for files"**: Check `.claude/pipeline-artifacts/lock-state.json` for stale entries older than TTL. If old, run `shipwright fleet unlock --force --file <file>` to manually release.
- **"Queue is huge but no pipelines running"**: Likely lock corruption. Clear queue with `shipwright fleet queue clear` and re-queue blocked issues.
- **"Lock file is corrupted"**: Remove `~/.shipwright/lock-state.json` and restart daemon—fleet will rebuild on next spawn.
