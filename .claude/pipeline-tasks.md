# Pipeline Tasks — Pipeline Global Timeout and Emergency Cost Circuit Breaker

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/pipeline-limits.sh` skeleton (VERSION, header, helpers, integer-cents arithmetic)
- [ ] Task 2: Implement `limits_init` (env + config + defaults; treat 0 as disabled)
- [ ] Task 3: Implement `limits_pipeline_cost_cents` (SQLite-first, jq fallback, fail-open on parse/missing file)
- [ ] Task 4: Implement `limits_check` (returns 0/124/125; writes `limits-breach.json` atomically)
- [ ] Task 5: Implement `limits_abort` (checkpoint + state + event + notification + resume hint)
- [ ] Task 6: Wire `limits_init`/`limits_check`/`limits_abort` into `pipeline-execution.sh::run_pipeline` (blocked by Tasks 2–5)
- [ ] Task 7: Add the same in-loop check into the build/test self-healing inner loop
- [ ] Task 8: Surface `aborted_timeout`/`aborted_cost` in `pipeline-state.sh::print_pipeline_state`
- [ ] Task 9: Add 124/125 exit footer in `scripts/sw-pipeline.sh`
- [ ] Task 10: Add `limits` block to all 8 templates in `templates/pipelines/`
- [ ] Task 11: Create `scripts/sw-pipeline-limits-test.sh` with 8 unit tests (init defaults/overrides, cost-read happy/missing/corrupt, check under/timeout/cost, abort writes artifacts)
- [ ] Task 12: Add 3 integration tests exercising `run_pipeline` (over-cost → 125, over-time → 124, resume after abort)
- [ ] Task 13: Register the test suite in `package.json`
- [ ] Task 14: Run `npm test -- sw-pipeline-limits-test`, fix failures; run `sw-pipeline-test.sh`, `sw-cost-test.sh`, `sw-checkpoint-test.sh` for regressions
- [ ] Task 15: Local end-to-end with `SW_GLOBAL_TIMEOUT_SECONDS=2` and `SW_MAX_COST_USD=0.01` proving both trips and resume
- [ ] `scripts/lib/pipeline-limits.sh` exists with 4 public functions and `VERSION` matching `package.json`
- [ ] `run_pipeline` invokes `limits_check` between stages and inside the build/test inner loop; honors 124/125
- [ ] Limits configurable via `templates/pipelines/*.json` and env vars `SW_GLOBAL_TIMEOUT_SECONDS`, `SW_MAX_COST_USD`
- [ ] On breach: checkpoint written, state set to `aborted_timeout`/`aborted_cost`, `pipeline.aborted` event emitted, notification printed with elapsed/cost/limits/resume command
- [ ] `shipwright pipeline resume` recovers correctly after an abort

## Context
- Pipeline: standard
- Branch: feat/pipeline-global-timeout-and-emergency-co-479
- Issue: #479
- Generated: 2026-05-15T01:25:48Z
