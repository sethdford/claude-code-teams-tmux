# Pipeline Tasks — Adaptive Stage Timeout Engine with P95 Duration-Based Auto-Tuning

## Implementation Checklist
- [ ] Task 1: Add `adaptive_timeouts.stage_timeouts` lookup to `resolve_stage_timeout()` in `scripts/lib/daemon-adaptive.sh` (insert between priority levels 3 and 4, around line 225)
- [ ] Task 2: Add `--auto` flag handling to `cmd_apply()` in `scripts/sw-adaptive-timeout.sh` (add case `--auto) shift ;;`)
- [ ] Task 3: Source `lib/stage-duration-metrics.sh` and `lib/daemon-adaptive.sh` in `scripts/sw-pipeline.sh` (near other library sources)
- [ ] Task 4: Add timeout enforcement to `run_stage_with_retry()` in `scripts/sw-pipeline.sh` — resolve timeout, run stage in background with time limit, record timeout events
- [ ] Task 5: Add test cases to `scripts/sw-adaptive-timeout-test.sh` — `--auto` flag, unified resolution, manual override precedence
- [ ] Task 6: Run `scripts/sw-adaptive-timeout-test.sh` and verify all tests pass
- [ ] Task 7: Run `scripts/sw-pipeline-test.sh` and verify no regressions
- [ ] Task 8: Run full test suite (`npm test`) and fix any failures
- [ ] `resolve_stage_timeout()` returns P95-tuned values from `adaptive_timeouts.stage_timeouts` in daemon-config.json
- [ ] Pipeline stages are enforced with timeouts when `resolve_stage_timeout` is available and returns >0
- [ ] Timeout events are recorded via `record_timeout_event()` for feedback into P95 calculations
- [ ] `sw adaptive-timeout apply --auto` runs without error (daemon patrol integration)
- [ ] Manual overrides always take precedence over P95-tuned values
- [ ] All existing tests in `sw-adaptive-timeout-test.sh` pass (37 tests)
- [ ] All existing tests in `sw-pipeline-test.sh` pass
- [ ] New tests cover: `--auto` flag, unified resolution, manual override precedence
- [ ] Full test suite (`npm test`) passes with no regressions

## Context
- Pipeline: autonomous
- Branch: ci/issue-212
- Issue: none
- Generated: 2026-03-07T22:42:52Z
