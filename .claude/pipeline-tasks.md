# Pipeline Tasks — Test Infrastructure Pre-Flight Validation Gate

## Implementation Checklist
- [ ] Task 1: Add `--skip-test-validation` flag to `parse_args()` in `pipeline-cli.sh`
- [ ] Task 2: Add `SKIP_TEST_VALIDATION` default variable in `pipeline-cli.sh` and `pipeline-stages.sh`
- [ ] Task 3: Create `scripts/lib/pipeline-test-validation.sh` with module guard, defaults, helpers loaded
- [ ] Task 4: Implement `_vtf_find_test_files()` — language-aware test file discovery
- [ ] Task 5: Implement `_vtf_check_bash_harness()` — checks for required boilerplate patterns
- [ ] Task 6: Implement `_vtf_check_shellcheck()` — shellcheck validation with graceful fallback
- [ ] Task 7: Implement `_vtf_check_mock_structure()` — mock directory pattern validation
- [ ] Task 8: Implement `validate_test_infrastructure()` — orchestrator that writes `test-validation.json` and returns actionable errors
- [ ] Task 9: Source the new module in `pipeline-stages.sh`
- [ ] Task 10: Call `validate_test_infrastructure()` in `stage_intake()` after test command detection
- [ ] Task 11: Create `scripts/sw-pipeline-test-validation-test.sh` test suite with positive cases (valid harness)
- [ ] Task 12: Add negative test cases (missing file, not executable, missing boilerplate, shellcheck errors)
- [ ] Task 13: Add edge case tests (skip flag, no test files, non-bash project)
- [ ] Task 14: Register test suite in `package.json`

## Context
- Pipeline: standard
- Branch: ci/test-infrastructure-pre-flight-validatio-232
- Issue: #232
- Generated: 2026-03-08T12:22:08Z
