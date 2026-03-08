# Test Infrastructure Pre-Flight Validation Gate — Implementation Plan

## Goal
Add a pre-flight validation gate in the intake stage to validate test infrastructure exists and is correctly structured BEFORE starting the build loop. This prevents failed pipelines due to broken or missing test harnesses, saving cost and time by failing fast.

## Strategic Context
- **Priority**: P0 — Reliability & Success Rate
- **Complexity**: Fast (straightforward validation logic)
- **Cost Impact**: High — failures detected before build loop consumes tokens
- **Scope**: Single intake stage gate + test harness validation

---

## Architecture Decision Record

### Component Decomposition

```
┌─────────────────────────────────────────────────────────────┐
│  Intake Stage (pipeline-stages-intake.sh)                   │
│  - Fetches issue, detects task type, creates branch        │
│  - [NEW] Validates test infrastructure before proceeding   │
└─────────────────────────────────────────────────────────────┘
        │
        ├─ [NEW] validate_test_infrastructure()
        │         lib/pipeline-test-validation.sh
        │         ├─ check_test_file_exists()
        │         ├─ check_test_executable()
        │         ├─ check_harness_patterns()
        │         ├─ run_shellcheck()
        │         ├─ check_mock_directory_structure()
        │         └─ write_validation_report()
        │
        └─ Error Handling
           ├─ Fail intake stage with actionable message
           └─ Write detailed validation report to artifacts
```

### Interface Contracts

```bash
# Main validation function
validate_test_infrastructure() {
    # Input:  $1 = test_file_path (optional, auto-detected if not provided)
    #         $2 = skip_validation flag (true/false)
    # Output: writes report to .claude/pipeline-artifacts/test-validation.json
    # Returns: 0 on success, 1 on validation failure
    # Error contract:
    #   - VALIDATION_ERROR_MISSING_FILE: test file not found
    #   - VALIDATION_ERROR_NOT_EXECUTABLE: test file not executable
    #   - VALIDATION_ERROR_MISSING_HARNESS: required harness patterns missing
    #   - VALIDATION_ERROR_SHELLCHECK_FAILED: shellcheck found syntax errors
    #   - VALIDATION_ERROR_MOCK_STRUCTURE: mock directory structure invalid
}

# Helper functions
_validate_test_file_exists() {
    # Input:  $1 = test_file_path
    # Returns: 0 if file exists, 1 otherwise
}

_validate_test_executable() {
    # Input:  $1 = test_file_path
    # Returns: 0 if executable, 1 otherwise
}

_validate_harness_patterns() {
    # Input:  $1 = test_file_path
    # Returns: 0 if all patterns present, 1 otherwise
    # Checks for: set -euo pipefail, ERR trap, PASS/FAIL counters, test functions
}

_validate_shellcheck() {
    # Input:  $1 = test_file_path
    # Returns: 0 if shellcheck passes, 1 on errors
}

_validate_mock_directory() {
    # Input:  $1 = test_temp_dir (from test file)
    # Returns: 0 if structure valid, 1 otherwise
    # Checks for: $TEST_TEMP_DIR/bin, $TEST_TEMP_DIR/home/.shipwright
}

_write_validation_report() {
    # Input:  $1 = test_file_path
    #         $2 = validation_status (pass/fail)
    #         $3 = error_messages (JSON array string)
    # Output: writes JSON report to .claude/pipeline-artifacts/test-validation.json
}
```

### Data Flow

```
intake stage
  ↓
1. Detect test command (existing: detect_test_cmd)
  ↓
2. [NEW] Call validate_test_infrastructure()
  ├─ Extract test file path from TEST_CMD or --test-file flag
  │
  ├─ Check if --skip-test-validation provided → skip validation
  │
  ├─ Run 5 validation checks:
  │  ├─ File exists?
  │  ├─ File executable?
  │  ├─ Harness patterns present? (set -euo pipefail, ERR trap, PASS/FAIL, test functions)
  │  ├─ Shellcheck passes?
  │  └─ Mock directory structure valid?
  │
  ├─ Aggregate results → validation report JSON
  │
  └─ Return: 0 (pass) or 1 (fail)
  ↓
3. If validation failed:
  ├─ error "Test infrastructure validation failed: [reason]"
  ├─ Write validation report to artifacts
  └─ exit 1 (fail intake stage)
  ↓
4. If validation passed:
  ├─ success "Test infrastructure validated ✓"
  ├─ Write validation report to artifacts
  └─ Continue with remaining intake stage tasks
```

### Error Boundaries

1. **Validation Failure** (in validate_test_infrastructure):
   - Logs: individual check results
   - Artifacts: full report with error details to test-validation.json
   - Return code: 1 (triggers intake stage failure)
   - Error message: actionable ("test file not found at scripts/sw-my-test.sh" or "FAIL counter not found in test file")

2. **Shellcheck Errors** (in _validate_shellcheck):
   - Captures shellcheck output
   - Includes in report as "shellcheck_errors" array
   - Examples: "SC2181: Check exit code directly"

3. **Mock Directory Issues** (in _validate_mock_directory):
   - Checks for expected subdirectories based on test patterns
   - Detects missing directories: `/bin`, `/home/.shipwright`
   - Detects permission issues (not writable)

4. **Edge Cases**:
   - No test command detected → skip validation with warning (don't fail)
   - Test file in different location → use --test-file flag to override auto-detection
   - --skip-test-validation flag → bypass all checks (for edge cases)

---

## Files to Modify/Create

### New Files
1. **`scripts/lib/pipeline-test-validation.sh`** (NEW)
   - Main validation module
   - 6 functions: 5 validators + report writer
   - ~180 lines

2. **`scripts/sw-pipeline-test-validation-test.sh`** (NEW)
   - Test suite for validation module
   - Positive and negative test cases
   - ~400 lines

### Modified Files
3. **`scripts/lib/pipeline-stages-intake.sh`**
   - Add `validate_test_infrastructure()` call after test command detection
   - Source lib/pipeline-test-validation.sh at top

4. **`scripts/lib/pipeline-state.sh`**
   - Add `SKIP_TEST_VALIDATION` variable

5. **`scripts/sw-pipeline.sh`**
   - Add `--skip-test-validation` flag handling

6. **`package.json`**
   - Add test suite to npm test registry

---

## Implementation Steps

### Phase 1: Core Validation Module

1. Create `scripts/lib/pipeline-test-validation.sh` with header, VERSION, guards
2. Implement `_validate_test_file_exists()` — check `-f "$test_file"`
3. Implement `_validate_test_executable()` — check `-x "$test_file"`
4. Implement `_validate_harness_patterns()` — grep for: set -euo pipefail, ERR trap, PASS=0, FAIL=0, test_*()
5. Implement `_validate_shellcheck()` — run shellcheck, capture errors
6. Implement `_validate_mock_directory()` — check $TEST_TEMP_DIR/bin and /home/.shipwright
7. Implement `_write_validation_report()` — write JSON report atomically
8. Implement `validate_test_infrastructure()` [MAIN] — orchestrate all checks, handle skip flag, auto-detect test file

### Phase 2: Intake Stage Integration

9. Update `lib/pipeline-stages-intake.sh` — source validation module at top
10. Add validation call after TEST_CMD detection: `validate_test_infrastructure() || return 1`
11. Add `SKIP_TEST_VALIDATION` to `lib/pipeline-state.sh`

### Phase 3: CLI Flag Support

12. Update `scripts/sw-pipeline.sh` — add `--skip-test-validation` flag parsing
13. Export `SKIP_TEST_VALIDATION` environment variable

### Phase 4: Test Suite

14. Create `scripts/sw-pipeline-test-validation-test.sh` with 26+ tests
15. Test positive case (valid test file → pass)
16. Test 5 negative cases (each validation check fails independently)
17. Test shellcheck error detection
18. Test mock directory validation
19. Test skip flag behavior
20. Test auto-detection from TEST_CMD
21. Test validation report JSON structure
22. Test atomic write to avoid corruption

### Phase 5: Registration

23. Update `package.json` test registry

---

## Test Pyramid Breakdown

**Unit Tests (15 tests)** — 70% coverage:
- Individual validation functions with mock inputs
- Each _validate_* function tested in isolation (pass + fail cases)
- Each harness pattern check tested independently

**Integration Tests (8 tests)** — 20% coverage:
- validate_test_infrastructure with various file configurations
- Aggregation of multiple failures
- Skip flag behavior
- Auto-detection logic
- Report JSON structure validation

**E2E Tests (3 tests)** — 10% coverage:
- Full intake stage with valid test infrastructure (validation passes, continues)
- Full intake stage with broken test infrastructure (validation fails, intake fails)
- CLI flag --skip-test-validation works end-to-end

### Coverage Targets
- **Line coverage**: 95%+ (validation functions must be thoroughly tested)
- **Branch coverage**: 100% (all code paths including error cases)
- **Critical paths**: 100% (happy path, skip flag, all 5 validation checks, error aggregation)

---

## Critical Paths to Test

1. **Happy Path**: Valid test file with all harness patterns
   - Expected: validation returns 0, report status=pass, intake continues
   - Validates: core flow works as intended

2. **File Not Found**: Non-existent test_file_path
   - Expected: validation returns 1, report status=fail, error contains "file not found"
   - Validates: early detection of missing infrastructure

3. **Missing PASS Counter**: File has all patterns except PASS=0
   - Expected: validation returns 1, error mentions "PASS counter"
   - Validates: precise pattern detection

4. **Shellcheck Error**: Valid harness but syntax error in test code
   - Expected: validation returns 1, report.shellcheck_errors populated
   - Validates: shellcheck integration works

5. **Skip Flag**: --skip-test-validation provided
   - Expected: validation returns 0 regardless of file state
   - Validates: edge case bypass works

---

## Definition of Done

- [ ] `lib/pipeline-test-validation.sh` created with all 6 functions
- [ ] `validate_test_infrastructure()` implements all 5 checks + skip logic
- [ ] Validation report JSON schema correct (timestamp, test_file, status, checks{}, errors[])
- [ ] Atomic write to test-validation.json (no corruption on concurrent writes)
- [ ] `stage_intake()` sources validation module and calls validator after TEST_CMD detection
- [ ] `--skip-test-validation` flag works in sw-pipeline.sh CLI
- [ ] `SKIP_TEST_VALIDATION` environment variable exported
- [ ] `sw-pipeline-test-validation-test.sh` test suite with 26+ passing tests
- [ ] Test coverage: 95%+ line, 100% branch, all critical paths
- [ ] All existing tests pass (no regressions)
- [ ] shellcheck passes on new modules
- [ ] Code follows project conventions (bash 3.2, VERSION at top, set -euo pipefail)
- [ ] Error messages are actionable (e.g., "FAIL counter not found in scripts/sw-hello-test.sh")
- [ ] Documentation: help text updated, examples provided

---

## Success Metrics

1. **Functional**: Validation detects broken test harnesses in <2 seconds
2. **Cost Impact**: Failed pipelines due to test infra issues drop by 80%+
3. **UX**: Actionable error messages guide users to fix issues
4. **Reliability**: 100% test coverage on validation logic, zero false positives
5. **Integration**: Seamlessly integrates into intake stage without affecting other pipelines

