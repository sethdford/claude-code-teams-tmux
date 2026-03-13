# Tasks — Minimal Viable Pipeline Test Case for System Health Validation

## Status: In Progress
Pipeline: autonomous | Branch: ci/issue-261

## Checklist
- [ ] Task 1: Create `templates/pipelines/minimal.json` with intake + build stages
- [ ] Task 2: Create `scripts/sw-minimal-test.sh` with template validation tests
- [ ] Task 3: Add template structure validation tests (JSON validity, name, description)
- [ ] Task 4: Add stage configuration tests (exactly 2 enabled, correct IDs)
- [ ] Task 5: Add build config tests (max_iterations, audit, quality_gates)
- [ ] Task 6: Add intelligence config tests (all disabled)
- [ ] Task 7: Add defaults tests (model, agents)
- [ ] Task 8: Add template discoverability test (find_pipeline_config resolves it)
- [ ] Task 9: Register test in `package.json` test chain
- [ ] Task 10: Run `sw-minimal-test.sh` and verify all tests pass
- [ ] Task 11: Run `npm test` to verify no regressions
- [ ] `jq empty templates/pipelines/minimal.json` exits 0
- [ ] `bash scripts/sw-minimal-test.sh` exits 0 with 0 failures
- [ ] Template has exactly 2 enabled stages: `intake` and `build`
- [ ] `max_iterations` is <= 3
- [ ] All intelligence features are disabled
- [ ] Test is registered in `package.json` and `npm test` passes
- [ ] No existing tests are broken by the changes

## Notes
- Generated from pipeline plan at 2026-03-13T22:13:07Z
- Pipeline will update status as tasks complete
