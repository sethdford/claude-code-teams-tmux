# Pipeline Tasks — Per-Stage Reliability Dashboard with Automatic Config Rollback

## Implementation Checklist
- [ ] Task 1: Add `config_snapshots` and `config_rollbacks` tables to `sw-db.sh` `init_schema()`, bump SCHEMA_VERSION to 7, add v6->v7 migration block
- [ ] Task 2: Add `db_stage_health()`, `db_stage_health_all()`, `db_stage_failure_types()`, `db_stage_success_rate_recent()` query functions to `sw-db.sh`
- [ ] Task 3: Add `db_save_config_snapshot()`, `db_get_last_good_config()`, `db_record_rollback()`, `db_recent_rollback_count()` functions to `sw-db.sh`
- [ ] Task 4: Create `scripts/sw-stage-health.sh` with CLI parsing, overview, single-stage detail, trend, and rollback-history views
- [ ] Task 5: Add `daemon_check_stage_rollback()` and `daemon_snapshot_config()` to `scripts/lib/daemon-poll-health.sh`
- [ ] Task 6: Integrate rollback check and config snapshot calls into `scripts/lib/daemon-poll.sh` poll loop
- [ ] Task 7: Add `stage-health` command route to `scripts/sw`
- [ ] Task 8: Create `scripts/sw-stage-health-test.sh` test suite with ~25 tests covering aggregation, snapshots, rollback logic, and CLI output
- [ ] Task 9: Run full test suite (`npm test`) and fix any regressions
- [ ] Task 10: Update CLAUDE.md docs table entries for new files
- [ ] `shipwright stage-health` displays per-stage success_rate, p50_duration, p95_duration, failure types
- [ ] `shipwright stage-health build --days 7` shows 7-day view for specific stage
- [ ] `shipwright stage-health --json` returns machine-readable JSON
- [ ] `shipwright stage-health --days 90` supports 7/30/90 day views
- [ ] Config rollback triggers when any stage success rate drops >10% relative over 5 runs
- [ ] Rollback restores last known-good `daemon-config.json` atomically
- [ ] Rollback has 2-hour cooldown to prevent thrashing
- [ ] Rollback audit log records every trigger (reason, before/after config)
- [ ] Daemon poll loop calls rollback check every 5 cycles
- [ ] Config snapshot saved after each successful self-optimize cycle

## Context
- Pipeline: standard
- Branch: feat/per-stage-reliability-dashboard-with-aut-342
- Issue: #342
- Generated: 2026-04-03T18:41:56Z
