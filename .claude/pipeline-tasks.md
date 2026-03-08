# Pipeline Tasks — Test Infrastructure Pre-Flight Validation Gate

## Implementation Checklist
- [ ] Task 1: Create `scripts/lib/pipeline-test-validation.sh` with module guard and `find_test_files()`
- [ ] Task 2: Implement `validate_test_file()` — existence, executable, harness pattern checks
- [ ] Task 3: Implement `validate_test_shellcheck()` — shellcheck integration with graceful fallback
- [ ] Task 4: Implement `validate_mock_structure()` — mock dir pattern validation
- [ ] Task 5: Implement `validate_test_infrastructure()` orchestrator with JSON report writing
- [ ] Task 6: Add `--skip-test-validation` flag to `pipeline-cli.sh` parse_args
- [ ] Task 7: Integrate validation call into `preflight_checks()` in `pipeline-util.sh`
- [ ] Task 8: Source the new module from pipeline-util.sh
- [ ] Task 9: Create `scripts/sw-test-validation-test.sh` with positive test cases
- [ ] Task 10: Add negative test cases (missing file, non-executable, missing patterns)
- [ ] Task 11: Add shellcheck and mock structure test cases
- [ ] Task 12: Add edge case tests (no test files, skip flag, mixed results)
- [ ] Task 13: Register test suite in `package.json`
- [ ] Task 14: Run full test suite to verify no regressions

## Context
- Pipeline: standard
- Branch: ci/test-infrastructure-pre-flight-validatio-232
- Issue: #232
- Generated: 2026-03-08T13:13:50Z
