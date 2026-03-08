# Tasks — Emergency Conservative Pipeline Template for Maximum Reliability

## Status: In Progress
Pipeline: standard | Branch: ci/emergency-conservative-pipeline-template-234

## Checklist
- [ ] Task 1: Create `templates/pipelines/emergency.json` with all conservative settings
- [ ] Task 2: Read `max_restarts` from build stage config in `pipeline-stages-build.sh` and pass `--max-restarts` to loop when no CLI override exists
- [ ] Task 3: Read `verbose` from build stage config in `pipeline-stages-build.sh` and pass `--verbose` to loop
- [ ] Task 4: Read `checkpoint_every_iteration` from build stage config in `pipeline-stages-build.sh` and pass to loop
- [ ] Task 5: Add `--checkpoint-every-iteration` flag parsing to `sw-loop.sh` (variable + arg parsing)
- [ ] Task 6: Update CLAUDE.md Pipeline Templates table with emergency template row
- [ ] Task 7: Create `scripts/sw-emergency-test.sh` test suite validating all template properties and overrides
- [ ] Task 8: Register `sw-emergency-test.sh` in `package.json` scripts
- [ ] Task 9: Run tests to verify everything passes
- [ ] `templates/pipelines/emergency.json` exists and is valid JSON
- [ ] Template has doubled iterations (30 vs standard's 20) and +50% restarts (5)
- [ ] All intelligence/prediction/adaptive features disabled in template
- [ ] Opus model set for all stages
- [ ] checkpoint_every_iteration and verbose flags enabled
- [ ] auto_merge disabled for safety
- [ ] `pipeline-stages-build.sh` reads max_restarts, verbose, checkpoint_every_iteration from config
- [ ] `sw-loop.sh` accepts --checkpoint-every-iteration flag
- [ ] CLAUDE.md Pipeline Templates table includes emergency row
- [ ] Test suite passes with all assertions green
- [ ] Existing test suites still pass (no regressions)

## Notes
- Generated from pipeline plan at 2026-03-08T13:38:44Z
- Pipeline will update status as tasks complete
