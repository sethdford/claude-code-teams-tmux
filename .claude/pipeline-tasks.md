# Pipeline Tasks — Fleet Work Conflict Prevention System with File-Level Locking

## Implementation Checklist
- [ ] Task 1: `_lock_acquire_serializer` (flock+mkdir fallback)
- [ ] Task 2: `lock_acquire_or_queue` + `lock_export_metrics_prometheus`
- [ ] Task 3: Create `conflict-predictor.sh`
- [ ] Task 4: Create `conflict-queue.sh`
- [ ] Task 5: Unit tests for predictor + queue (T3, T4 block T5)
- [ ] Task 6: Wire gate into `daemon-dispatch.sh` spawn + reap (T2, T3, T4 block T6)
- [ ] Task 7: Wire gate into `sw-fleet.sh`
- [ ] Task 8: `lock_cleanup_stale` in daemon patrol
- [ ] Task 9: `/api/locks` endpoint + dashboard widget
- [ ] Task 10: Metrics row in `sw-fleet-viz.sh`
- [ ] Task 11: Extend `sw-file-locks-test.sh` integration scenarios
- [ ] Task 12: Register new test suites in `package.json`
- [ ] Task 13: Run suites, fix regressions
- [ ] Task 14: `shipwright docs sync`
- [ ] Two conflicting pipelines: one acquires, one queues (integration test).
- [ ] Release drains queued item; it starts automatically.
- [ ] Patrol reaps crashed pipeline within 120s; queue drains.
- [ ] `/api/locks` returns holders + metrics; widget renders.
- [ ] `sw-fleet-viz` prints `conflicts_avoided`.
- [ ] `SW_FILE_LOCKS_ENABLED=0` fully bypasses.

## Context
- Pipeline: standard
- Branch: arch/fleet-work-conflict-prevention-system-wi-401
- Issue: #401
- Generated: 2026-04-17T18:46:19Z
