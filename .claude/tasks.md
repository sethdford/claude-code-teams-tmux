# Tasks — Build Loop Stuck Detection and Emergency Abort System

## Status: In Progress
Pipeline: standard | Branch: ci/build-loop-stuck-detection-and-emergency-284

## Checklist
- [ ] Task 1: Add `detect_zero_progress()` function to `scripts/lib/loop-convergence.sh`
- [ ] Task 2: Add `_file_mtime_fingerprint()` and `_file_mtime_monitored()` helpers
- [ ] Task 3: Integrate zero-progress check in `sw-loop.sh` main loop (after ~line 2375)
- [ ] Task 4: Initialize `ZERO_PROGRESS_COUNT` at loop start in `sw-loop.sh`
- [ ] Task 5: Add `--zero-progress-threshold` CLI flag to argument parser
- [ ] Task 6: Add `--zero-progress-threshold` to help text
- [ ] Task 7: Add 7 structural tests to `sw-loop-test.sh`
- [ ] Task 8: Add E2E mock test (zero-progress agent triggers abort) to `sw-loop-test.sh`
- [ ] Task 9: Add counter-reset structural test to `sw-loop-test.sh`
- [ ] Task 10: Create `docs/BUILD-LOOP.md` with stuck detection documentation
- [ ] Task 11: Run `sw-loop-test.sh` and verify all tests pass
- [ ] Task 12: Run `sw-convergence-test.sh` to verify no regressions

## Notes
- Generated from pipeline plan at 2026-03-20T21:43:43Z
- Pipeline will update status as tasks complete
