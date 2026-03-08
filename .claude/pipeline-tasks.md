# Pipeline Tasks — Test Infrastructure Pre-Flight Validation Gate

## Implementation Checklist
- [ ] **Create library**: Implement `scripts/lib/pipeline-validation.sh` with all validation functions
- [ ] **Helper 1**: Implement `_validate_test_file()` with all checks (PASS, FAIL, ERR, shellcheck)
- [ ] **Helper 2**: Implement `_verify_mock_structure()` to check mock directory layout
- [ ] **Integration**: Modify `scripts/sw-pipeline.sh` intake stage to call validation
- [ ] **CLI flag**: Add `--skip-test-validation` argument parsing to pipeline
- [ ] **JSON report**: Implement report generation with timestamp, summary, per-file details
- [ ] **Test suite**: Create `scripts/sw-pipeline-validation-test.sh` with 6+ test cases
- [ ] **Test positive**: Cover valid harness, mock structure, report generation
- [ ] **Test negative**: Cover missing PASS, missing FAIL, missing ERR, missing mock dirs
- [ ] **Test edge case**: Cover skip-validation flag, multiple test files, shellcheck failures
- [ ] **Documentation**: Update `.claude/CLAUDE.md` with flag documentation
- [ ] **Manual validation**: Test on this repository's own test harness
- [ ] **Error messages**: Ensure all error messages are actionable and point to report file
- [ ] **Integration test**: Run a pipeline with validation enabled to verify intake stage flow
- [ ] `validate_test_infrastructure()` function exists in `scripts/lib/pipeline-validation.sh`
- [ ] Checks for PASS counter, FAIL counter, ERR trap, test_ functions
- [ ] Runs shellcheck on all test files, reports errors
- [ ] Verifies mock directory structure (scripts/mocks/bin, scripts/mocks/data)
- [ ] Generates `.claude/pipeline-artifacts/test-validation.json` report
- [ ] Report includes timestamp, summary, per-file details, error list

## Context
- Pipeline: standard
- Branch: test/test-infrastructure-pre-flight-validatio-232
- Issue: #232
- Generated: 2026-03-08T12:37:51Z
