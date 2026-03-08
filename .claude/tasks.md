# Tasks — Emergency Conservative Pipeline Template for Maximum Reliability

## Status: In Progress
Pipeline: standard | Branch: ci/emergency-conservative-pipeline-template-234

## Checklist
- [ ] Task 1: Create `templates/pipelines/emergency.json` with all conservative settings
- [ ] Task 2: Read `checkpoint_every_iteration` from build config in `pipeline-stages-build.sh` and pass `--checkpoint-every-iteration` to loop
- [ ] Task 3: Add `--checkpoint-every-iteration` flag parsing and logic to `sw-loop.sh`
- [ ] Task 4: Read `verbose` from build config in `pipeline-stages-build.sh` and pass `--verbose` to loop
- [ ] Task 5: Read `max_restarts` from template defaults in `pipeline-stages-build.sh` and pass to loop
- [ ] Task 6: Update CLAUDE.md Pipeline Templates table with emergency template
- [ ] Task 7: Create `scripts/sw-emergency-test.sh` test suite
- [ ] Task 8: Register test suite in `package.json`
- [ ] Task 9: Run tests to verify everything passes

## Notes
- Generated from pipeline plan at 2026-03-08T13:13:59Z
- Pipeline will update status as tasks complete
