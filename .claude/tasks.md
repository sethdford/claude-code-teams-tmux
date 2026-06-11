# Tasks — Build Loop Real-Time Quality Scoring with Adaptive Model Downshift

## Status: In Progress
Pipeline: standard | Branch: feat/build-loop-real-time-quality-scoring-wit-628

## Checklist
- [ ] Task 1: Add `downshift_model` + dispatch case to `sw-model-router.sh`.
- [ ] Task 2: Create `scripts/lib/loop-model-router.sh` skeleton (guard, VERSION, sourcing-safe).
- [ ] Task 3: Implement `lmr_quality_score` (integer milli-score 0–1000, composite reuse).
- [ ] Task 4: Implement `lmr_decide` with all guard rules + config-chain thresholds.
- [ ] Task 5: Implement `lmr_record_iteration` + `lmr_savings_summary` (atomic JSONL).
- [ ] Task 6: Add `--adaptive-model` flag + `SW_ADAPTIVE_MODEL` env + state vars in `sw-loop.sh`.
- [ ] Task 7: Source the module and wire `lmr_decide` into the main loop after the test gate.
- [ ] Task 8: Apply `MODEL` mutation for next iteration + `emit_event`.
- [ ] Task 9: Add model-mix + savings line to `show_summary`.
- [ ] Task 10: Write `scripts/sw-loop-model-router-test.sh` (unit + integration + e2e).
- [ ] Task 11: Register test in `package.json`; run full suite.
- [ ] Task 12: Update `.claude/CLAUDE.md` (flag + loop config docs).
- [ ] Task 13: Bump `VERSION` in edited scripts; `shipwright version check`.
- [ ] Task 14: Run `npm test`; verify no regressions in `sw-loop-test.sh`, `sw-model-router-test.sh`, `sw-process-reward-test.sh`.
- [ ] `lmr_quality_score` produces a normalized 0–1 (0–1000 milli) score from
- [ ] Opus→Sonnet downshift fires only after 2 consecutive iterations with
- [ ] Sonnet→Opus upshift fires on score <0.5 or a test pass→fail regression.
- [ ] `sw-loop.sh` invokes the scorer after each iteration and the next
- [ ] Per-iteration model + score logged to `model-routing.jsonl`; `show_summary`
- [ ] `scripts/sw-loop-model-router-test.sh` passes (all scoring + routing

## Notes
- Generated from pipeline plan at 2026-06-11T13:43:59Z
- Pipeline will update status as tasks complete
