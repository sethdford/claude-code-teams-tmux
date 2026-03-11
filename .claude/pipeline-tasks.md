# Pipeline Tasks — Meta-Feature Detection Gate with Mandatory Decomposition Requirement

## Implementation Checklist
- [ ] Task 1: Add `detect_meta_feature()` function to `scripts/lib/pipeline-detection.sh`
- [ ] Task 2: Add `check_meta_feature_decomposition()` function to `scripts/lib/pipeline-detection.sh`
- [ ] Task 3: Wire meta-feature gate into `stage_intake()` in `scripts/lib/pipeline-stages-intake.sh`
- [ ] Task 4: Add `--issue N --create-subtasks` CLI flag to `scripts/sw-decompose.sh`
- [ ] Task 5: Add unit tests for `detect_meta_feature()` to `scripts/sw-lib-pipeline-detection-test.sh`
- [ ] Task 6: Add unit tests for `check_meta_feature_decomposition()` to `scripts/sw-lib-pipeline-detection-test.sh`
- [ ] Task 7: Create `scripts/sw-meta-feature-test.sh` E2E test suite
- [ ] Task 8: Register new test in `package.json` scripts
- [ ] Task 9: Run full test suite and fix any regressions
- [ ] `detect_meta_feature()` correctly identifies issues targeting `scripts/`, `dashboard/`, `lib/`, `templates/`, `.claude/`
- [ ] Pipeline blocks at intake when meta-feature detected without decomposition
- [ ] Error message includes exact `shipwright decompose --issue N --create-subtasks` command
- [ ] Issues with "subtask" or "decomposed" labels bypass the gate
- [ ] `shipwright decompose --issue N --create-subtasks` creates 2-3 GitHub subtask issues
- [ ] All new tests pass
- [ ] All existing tests pass (no regressions)
- [ ] `NO_GITHUB=true` mode works for all new code paths

## Context
- Pipeline: standard
- Branch: feat/meta-feature-detection-gate-with-mandato-250
- Issue: #250
- Generated: 2026-03-11T02:10:21Z
