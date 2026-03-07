# Pipeline Tasks — Adaptive Stage Timeout Engine with P95 Duration-Based Auto-Tuning

## Implementation Checklist
- [ ] **Task 1**: Create database schema migration (stage_durations, timeout_recommendations, timeout_adjustments tables)
- [ ] **Task 2**: Implement `db_save_stage_duration()` and related accessor functions in `sw-db.sh`
- [ ] **Task 3**: Create `scripts/lib/stage-duration-metrics.sh` with recording functions
- [ ] **Task 4**: Integrate `record_stage_duration()` hook in `pipeline-state.sh::mark_stage_complete()`
- [ ] **Task 5**: Create `scripts/lib/timeout-recommendation-engine.sh` with stats calculations
- [ ] **Task 6**: Implement percentile calculation and 30-day rolling window logic
- [ ] **Task 7**: Create `scripts/sw-adaptive-timeout.sh` CLI with `analyze` subcommand
- [ ] **Task 8**: Implement `apply` subcommand with config update and dry-run support
- [ ] **Task 9**: Extend `daemon-config.json` with `adaptive_timeouts` configuration section
- [ ] **Task 10**: Add daemon patrol hook for periodic timeout analysis
- [ ] **Task 11**: Update pipeline templates with adaptive timeout fields
- [ ] **Task 12**: Implement timeout avoidance metrics tracking functions
- [ ] **Task 13**: Add timeout-related events for audit trail
- [ ] **Task 14**: Add timeout recommendations API endpoint to dashboard server
- [ ] **Task 15**: Add timeout metrics visualization to DORA dashboard
- [ ] **Task 16**: Create comprehensive test suite `sw-adaptive-timeout-test.sh`
- [ ] **Task 17**: Write documentation and add to CLAUDE.md AUTO:core-scripts
- [ ] **Task 18**: Integration test: Run pipeline with metrics collection → analysis → apply cycle
- [ ] **Task 19**: Performance test: Verify percentile calculations scale to 1000+ records
- [ ] **Task 20**: Manual testing: Verify manual_timeout override is respected

## Context
- Pipeline: standard
- Branch: feat/adaptive-stage-timeout-engine-with-p95-d-212
- Issue: #212
- Generated: 2026-03-07T19:31:03Z
