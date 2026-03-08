## Shipwright Test Harness Conventions

### Purpose
Shipwright enforces a consistent test harness pattern across all 100+ test suites. The `validate_test_infrastructure()` function checks that test files conform to these conventions.

### Required Harness Patterns

Every test file must include:

#### 1. Shebang & Set Options
```bash
#!/bin/bash
set -euo pipefail
```
Validation: Check first two lines match this pattern (allow comments between).

#### 2. Version Variable
```bash
VERSION="X.Y.Z"
```
Validation: Grep for `^VERSION=` near top of file (before first function).

#### 3. PASS/FAIL Counters
```bash
PASS=0 FAIL=0
```
Validation: Grep for both `PASS=0` and `FAIL=0` at file scope (not inside functions).

#### 4. ERR Trap
```bash
trap 'FAIL=$((FAIL+1)); echo "ERR: $BASH_COMMAND at line $LINENO"' ERR
```
Validation: Grep for `trap` + `ERR`, ensure it increments `FAIL` and prints error context.

#### 5. Test Case Pattern
Test cases follow this structure:
```bash
# Test: Description of what's being tested
if condition_passes; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  echo "FAIL: specific error message"
fi
```
Validation: At least 2 test cases with `PASS=$((PASS+1))` or `FAIL=$((FAIL+1))`.

#### 6. Summary Output
```bash
echo "PASS: $PASS, FAIL: $FAIL"
exit $FAIL
```
Validation: Grep for summary line and exit with `$FAIL`.

### Mock Directory Structure
Tests that use mock binaries must have:
```
<repo>/.claude/test-mocks/
├── mock-<command-1>
├── mock-<command-2>
└── ...
```
Validation: Check `.claude/test-mocks/` exists and contains at least one `mock-*` file.

### Shellcheck Requirements
- Run: `shellcheck --shell=bash <test-file>`
- Validation: Exit code 0 means no errors; any errors fail validation.
- Ignore codes: SC2086 (unquoted expansion) only when intentional in mock setup.

### Executability
Validation: Test file must have execute bit (`-x`): `test -x <file>`.

### When Validation Fails
Output a clear error message identifying which check failed:
- "Test file not executable"
- "Missing PASS/FAIL counters"
- "ERR trap not found or malformed"
- "shellcheck errors: <count> issues"
- "Mock directory missing or empty"

### Edge Cases
Accept test files without mock binaries if `.claude/test-mocks/` is not referenced in the file. Allow --skip-test-validation flag for edge cases (e.g., tests that intentionally don't follow conventions).
