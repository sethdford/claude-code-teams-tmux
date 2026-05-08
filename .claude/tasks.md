# Tasks — Intelligent Test Prioritization Engine for Fail-Fast Feedback

## Status: In Progress
Pipeline: standard | Branch: feat/intelligent-test-prioritization-engine-f-459

## Checklist
- [ ] Task 1: Add dependency-map library `scripts/lib/test-dep-map.sh` with cached map file and atomic writes
- [ ] Task 2: Extend `sw-memory.sh` with `memory_record_test_outcome` / `memory_get_test_failure_rate` helpers (with `flock` concurrency guard)
- [ ] Task 3: Extend `scripts/lib/test-optimizer.sh` with memory-backed failure-rate loader and history persister
- [ ] Task 4: Adjust `testopt_prioritize` scoring to combine affected-files (60%) + historical failure rate (40%) and emit per-test scores
- [ ] Task 5: Create orchestration layer `scripts/lib/test-priority.sh` reading daemon-config flags and below-threshold short-circuit
- [ ] Task 6: Wire `tp_run_prioritized` into `sw-loop.sh:run_test_gate` behind `enable_test_prioritization` flag
- [ ] Task 7: Add `test_prioritization` block to `.claude/daemon-config.json` (default disabled)
- [ ] Task 8: Emit `test_priority_run_complete` events with `tests_skipped`, `time_saved_s`, `early_abort` fields
- [ ] Task 9: Extend `dashboard/server.ts` log parser and WebSocket payload with prioritization metrics
- [ ] Task 10: Update `.claude/CLAUDE.md` Build Loop and Intelligence sections with documentation
- [ ] Task 11: Write `scripts/sw-test-priority-test.sh` (12 unit + 3 integration + 1 E2E)
- [ ] Task 12: Register new test suite in `package.json`
- [ ] Task 13: Verify cold-start behavior (no memory history) falls back gracefully
- [ ] Task 14: Run full `npm test`; confirm zero regressions
- [ ] Task 15: Hand-verify by running a real loop with prioritization enabled and a deliberately failing test
- [ ] All acceptance criteria satisfied (dep mapping, memory tracking, smart ordering, fast-fail, config flags, dashboard metrics, CLAUDE.md docs)
- [ ] New test suite passes; full `npm test` green
- [ ] Default config keeps prioritization **disabled** (zero behavior change for existing pipelines)
- [ ] Dashboard live-updates show `time_saved_s` after a real run
- [ ] CLAUDE.md updated under Build Loop Capabilities + Intelligence Layer

## Notes
- Generated from pipeline plan at 2026-05-08T19:38:04Z
- Pipeline will update status as tasks complete
