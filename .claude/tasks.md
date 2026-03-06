# Tasks — sw-pipeline.sh Modular Decomposition - Extract Stage Execution Library

## Status: In Progress
Pipeline: autonomous | Branch: ci/issue-189

## Checklist
- [ ] Task 1: Create `scripts/lib/pipeline-orchestrator.sh` with include guard, variable defaults, and extracted functions (`run_pipeline`, `preflight_checks`, `cleanup_on_exit`, heartbeat helpers, CI helpers)
- [ ] Task 2: Update `scripts/sw-pipeline.sh` to source the new library and remove extracted function bodies
- [ ] Task 3: Verify `sw-pipeline.sh` line count is under 400 lines
- [ ] Task 4: Create `scripts/sw-lib-pipeline-orchestrator-test.sh` with unit tests for all extracted functions
- [ ] Task 5: Register the new test in `package.json`
- [ ] Task 6: Run `sw-pipeline-test.sh` to verify no regression in the E2E pipeline tests
- [ ] Task 7: Run the new unit test suite
- [ ] Task 8: Run full test suite (`npm test`) to verify no cross-suite breakage
- [ ] Task 9: Update the Shared Libraries table in `.claude/CLAUDE.md` to document the new library
- [ ] `scripts/lib/pipeline-orchestrator.sh` exists with include guard and all extracted functions
- [ ] `scripts/sw-pipeline.sh` is under 400 lines (from 1075)
- [ ] `scripts/sw-pipeline.sh` sources the new library in the correct dependency order
- [ ] All functions extracted maintain identical signatures and behavior
- [ ] `sw-pipeline-test.sh` passes (0 failures)
- [ ] New `sw-lib-pipeline-orchestrator-test.sh` passes
- [ ] `npm test` passes (no regressions across 102+ suites)
- [ ] CLAUDE.md Shared Libraries table updated

## Notes
- Generated from pipeline plan at 2026-03-06T07:49:09Z
- Pipeline will update status as tasks complete
