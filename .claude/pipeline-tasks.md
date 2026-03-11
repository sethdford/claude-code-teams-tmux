# Pipeline Tasks — Strategic Agent Success Rate Feedback Loop - Constrain Complexity When Success Rate is Low

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/success-rate-constraints.sh` with config loading, `compute_rolling_success_rate()`, `get_constraint_level()` with hysteresis
- [ ] Task 2: Implement `should_defer_issue()`, `get_iteration_cap()`, `constrain_template()` in the same file
- [ ] Task 3: Integrate complexity gate and template constraint into `scripts/lib/daemon-dispatch.sh` before pipeline spawn
- [ ] Task 4: Integrate iteration cap into `scripts/sw-pipeline-composer.sh` in `composer_estimate_iterations()`
- [ ] Task 5: Source the new module in `scripts/sw-daemon.sh`
- [ ] Task 6: Create test suite `scripts/sw-success-rate-constraints-test.sh` with 17 test cases
- [ ] Task 7: Register test suite in `package.json`
- [ ] Task 8: Run full test suite to verify no regressions
- [ ] Rolling success rate is computed from last N pipeline.completed events
- [ ] When success rate < 40%, high-complexity issues (>4) are deferred, iterations capped at 10, templates downgraded aggressively
- [ ] When success rate < 60%, moderate-complexity issues (>7) are deferred, iterations capped at 15, templates downgraded conservatively
- [ ] When success rate recovers above 70%, all constraints relax
- [ ] Issues with complexity <= 3 always proceed regardless of success rate
- [ ] Hysteresis prevents rapid constraint oscillation
- [ ] All constraint decisions emit events for observability
- [ ] Feature is off by default (`success_rate_constraints.enabled: false`)
- [ ] 17-test suite passes covering all logic paths
- [ ] Existing test suites pass without regression
- [ ] All bash 3.2 compatibility rules followed (no associative arrays, no readarray, etc.)
- [ ] Atomic file writes for daemon-tuning.json updates

## Context
- Pipeline: autonomous
- Branch: ci/issue-249
- Issue: none
- Generated: 2026-03-11T01:26:38Z
