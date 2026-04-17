# Pipeline Tasks — Fleet Work Conflict Prevention System with File-Level Locking

## Implementation Checklist
- [ ] File conflict detected **before** pipeline spawn (not during git operations)
- [ ] Conflicting issues queued instead of spawned
- [ ] Locks released within 2 seconds of pipeline completion
- [ ] Stale locks cleaned within 2 minutes of pipeline failure
- [ ] All existing daemon tests pass (`npm test`)
- [ ] All existing pipeline tests pass
- [ ] All existing fleet tests pass
- [ ] Lock file at `$DAEMON_DIR/file-locks.json` (daemon-config.json can override)
- [ ] All lock updates atomic (flock-serialized)
- [ ] Files locked in sorted alphabetical order (deadlock prevention)
- [ ] No circular lock dependencies possible
- [ ] Heartbeat integration with existing `~/.shipwright/heartbeats/` pattern
- [ ] Events emitted: `daemon.conflict_detected`, `daemon.lock_acquired`, `daemon.lock_released`
- [ ] Metrics tracked: `conflicts_avoided`, `queue_depth`, `avg_wait_seconds`
- [ ] Dashboard endpoint: `GET /api/fleet/locks` with lock status JSON
- [ ] Stale cleanup logged with PID, issue number, and reason
- [ ] Unit test suite: `sw-file-locks-test.sh` with 12 test cases
- [ ] E2E test: Two-issue conflict scenario in `sw-pipeline-test.sh`
- [ ] Edge cases: stale cleanup, deadlock prevention, queue stalling
- [ ] All tests use mocks (no real git/network calls)

## Context
- Pipeline: standard
- Branch: arch/fleet-work-conflict-prevention-system-wi-401
- Issue: #401
- Generated: 2026-04-17T12:50:02Z
