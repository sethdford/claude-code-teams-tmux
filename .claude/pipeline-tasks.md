# Pipeline Tasks — Stage Duration Profiler with Performance Regression Detection and Bottleneck Alerts

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/stage-profiler.sh` — Core library with percentile computation, regression detection, bottleneck analysis, and adaptive export functions
- [ ] Task 2: Create `scripts/sw-stage-profiler.sh` — CLI script with all subcommands (profile, check, bottlenecks, budget, report, export, widget, trends, reset, help)
- [ ] Task 3: Create `scripts/sw-stage-profiler-test.sh` — Test suite with ~25 test cases covering all library and CLI functions
- [ ] Task 4: Modify `scripts/lib/pipeline-execution.sh` — Source the profiler library and add profiler hooks after stage completion (success + failure paths)
- [ ] Task 5: Modify `scripts/sw` — Add `stage-profiler|profiler` route to CLI router and help text
- [ ] Task 6: Modify `package.json` — Register test suite in npm test script
- [ ] Task 7: Run test suite and verify all tests pass
- [ ] Task 8: Run existing pipeline tests to verify no regressions
- [ ] `shipwright profiler profile` shows P50/P95/mean/samples for all stages
- [ ] `shipwright profiler check` detects regressions >20% above P95 and exits 1
- [ ] `shipwright profiler bottlenecks` ranks top 5 slowest stages over last 7 days
- [ ] `shipwright profiler budget` identifies stages exceeding timeout budget
- [ ] `shipwright profiler report --json` produces valid JSON with all analysis sections
- [ ] `shipwright profiler widget` produces dashboard-compatible JSON
- [ ] `shipwright profiler export` writes data consumable by adaptive timeout engine
- [ ] Pipeline execution calls `profiler_analyze_stage` after each stage (success + failure)
- [ ] `profiler.regression` events emitted when regressions detected
- [ ] All ~25 tests in `sw-stage-profiler-test.sh` pass
- [ ] Existing `sw-pipeline-test.sh` still passes (no regressions)
- [ ] Works without SQLite (JSONL fallback)

## Context
- Pipeline: standard
- Branch: ci/stage-duration-profiler-with-performance-347
- Issue: #347
- Generated: 2026-04-04T10:30:30Z
