# Tasks — Iteration Waste & Stuck Loop Detector with Early Termination

## Status: In Progress
Pipeline: standard | Branch: feat/iteration-waste-stuck-loop-detector-with-460

## Checklist
- [ ] Task 1: Create `scripts/lib/loop-waste-detector.sh` skeleton with module guard, VERSION, init function (depends on: nothing)
- [ ] Task 2: Implement `waste_record_file_edits` + `waste_detect_circular_edits` (depends on: Task 1)
- [ ] Task 3: Implement `waste_detect_semantic_dup` + `waste_detect_zero_progress` (depends on: Task 1)
- [ ] Task 4: Implement `waste_detect` orchestrator + `waste_detected` event emission (depends on: Tasks 2, 3)
- [ ] Task 5: Implement `waste_write_report` (atomic jq write) + `waste_estimate_cost_saved` (depends on: Task 1)
- [ ] Task 6: Wire detector into `scripts/sw-loop.sh` (init, per-iter call, termination path) (depends on: Tasks 4, 5)
- [ ] Task 7: Refactor `loop-convergence.sh` hardcoded thresholds to config reads (preserve defaults) (independent)
- [ ] Task 8: Write `scripts/sw-waste-detector-test.sh` with ≥7 test cases (depends on: Tasks 1–5)
- [ ] Task 9: Add CLAUDE.md "Iteration Waste Detection" subsection + 6 new config keys in the Loop Configuration table (independent)
- [ ] Task 10: Add `/api/waste-metrics` endpoint in `dashboard/server.ts` (independent)
- [ ] Task 11: Add waste-metrics panel to dashboard frontend (depends on: Task 10)
- [ ] Task 12: Register new test in `package.json` (depends on: Task 8)
- [ ] Task 13: Run `npm test` to verify no regressions (depends on: Tasks 6, 7, 8, 12)
- [ ] Task 14: Manually trigger waste scenario (force-failing test cmd); confirm `waste-report.json` and event written (depends on: Task 13)
- [ ] All 14 task checklist items completed.
- [ ] `npm test` passes (no regressions in existing 200+ suites).
- [ ] `scripts/sw-waste-detector-test.sh` passes with ≥7 cases including disabled-flag and graceful-degradation cases.
- [ ] Manual integration test produces valid `waste-report.json` (validates against jq `.version` and `.estimated_cost_saved_usd`).
- [ ] CLAUDE.md updated with "Iteration Waste Detection" section + 6 new config keys in Loop Configuration table.
- [ ] Dashboard surfaces waste metrics via `/api/waste-metrics` and a UI panel.

## Notes
- Generated from pipeline plan at 2026-05-08T19:37:50Z
- Pipeline will update status as tasks complete
