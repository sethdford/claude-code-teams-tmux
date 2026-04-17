# Tasks — Test Suite Execution Optimizer with Adaptive Fast-Path Sampling

## Status: In Progress
Pipeline: standard | Branch: test/test-suite-execution-optimizer-with-adap-387

## Checklist
- [ ] T1: Scaffold `sw-test-optimizer.sh` (VERSION, usage, dispatch)
- [ ] T2: Atomic read/write helpers with flock + append-log fallback
- [ ] T3: `track` — jq ring buffer, p50/p95, counters
- [ ] T4: `wrap` — monotonic timing
- [ ] T5: `plan` — smoke + full selection + cold-start fallback
- [ ] T6: `smoke`/`full` executors with aggregate summary
- [ ] T7: `stats`/`report`/`reconcile`
- [ ] T8: Register in `scripts/sw` router
- [ ] T9: `sw-loop.sh` integration behind `SW_TEST_OPTIMIZER`
- [ ] T10: Dashboard endpoints + widget
- [ ] T11: `sw-test-optimizer-test.sh` passes end-to-end
- [ ] T12: Benchmark, record in PR body
- [ ] T13: `shipwright doctor` + `version check` pass
- [ ] T14: `npm test` green
- [ ] All 8 subcommands via `--help`
- [ ] `sw-test-optimizer-test.sh` passes
- [ ] Smoke <30s on this repo (reported)
- [ ] Loop integration works under flag
- [ ] Dashboard endpoints valid JSON
- [ ] VERSION synced; `version check` passes

## Notes
- Generated from pipeline plan at 2026-04-17T12:52:42Z
- Pipeline will update status as tasks complete
