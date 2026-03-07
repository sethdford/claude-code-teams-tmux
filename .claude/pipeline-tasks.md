# Pipeline Tasks — Pipeline Stall and Deadlock Detection with Auto-Abort

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/pipeline-stall-detection.sh` with core detection functions (stall_compute_score, stall_should_abort, stall_build_diagnostics, stall_check_and_abort, stall_save_to_memory, stall_get_statistics)
- [ ] Task 2: Integrate stall detection into `scripts/lib/loop-convergence.sh` — call stall_check_and_abort after stuckness detection
- [ ] Task 3: Add stall_abort status handling to `scripts/sw-loop.sh` — source lib, handle STATUS="stall_abort", show diagnostics in summary
- [ ] Task 4: Add stall_deadlock failure class to `scripts/lib/daemon-failure.sh` — classify, retry strategy (max 1), escalation with different approach
- [ ] Task 5: Add `memory_capture_stall()` to `scripts/sw-memory.sh` — store stall diagnostics for future prevention
- [ ] Task 6: Add stall_risk metric to `scripts/sw-pipeline-vitals.sh` — fifth health signal, influence verdict
- [ ] Task 7: Add stall statistics to `dashboard/server.ts` — parse stall events, include in pipeline status
- [ ] Task 8: Create test suite `scripts/sw-lib-pipeline-stall-detection-test.sh` — comprehensive unit tests
- [ ] Task 9: Register test in `package.json` and run full suite to verify
- [ ] `stall_compute_score()` correctly identifies zero-change (3+) and error-loop (5+) patterns
- [ ] Auto-abort triggers only when score >= 70 AND tests are NOT passing
- [ ] Abort produces JSON diagnostics with stall_type, iterations_stuck, repeated_error, suggested_recovery
- [ ] Diagnostics saved to memory system via `memory_capture_stall()`
- [ ] Daemon classifies stall aborts as `stall_deadlock` with max 1 retry
- [ ] Pipeline vitals include stall_risk in health score
- [ ] Dashboard receives stall statistics via existing event/WebSocket system
- [ ] All tests pass (new test suite + no regressions in existing suites)
- [ ] No false positives: tests-passing state never triggers abort

## Context
- Pipeline: standard
- Branch: feat/pipeline-stall-and-deadlock-detection-wi-198
- Issue: #198
- Generated: 2026-03-07T00:50:21Z
