# Test Infrastructure Pre-Flight Validation Gate — Implementation Plan

## Goal
Add a pre-flight validation gate in the intake stage to validate test infrastructure exists and is correctly structured BEFORE starting the build loop. This prevents failed pipelines due to broken or missing test harnesses, saving cost and time by failing fast.

## Strategic Context
- **Priority**: P0 — Reliability & Success Rate
- **Complexity**: Fast (straightforward validation logic)
- **Cost Impact**: High — failures detected before build loop consumes tokens
- **Scope**: Single intake stage gate + test harness validation

---

## Socratic Design Refinement

### Requirements Clarity

**Minimum viable change**: A single new library module (`scripts/lib/pipeline-test-validation.sh`) with a `validate_test_infrastructure()` function that checks test files exist, are executable, and contain required harness patterns. Called from `stage_intake()` after test command detection. Fails the intake stage early if checks fail, skippable with `--skip-test-validation`.

**Implicit requirements**:
- Must not break existing pipelines that have no test files (graceful degradation — warn, don't fail)
- Must work in local mode (`--local`, `$NO_GITHUB`)
- Must work in worktree mode (paths relative to `$PROJECT_ROOT`)
- Shellcheck validation must degrade gracefully when `shellcheck` is not installed
- Mock directory validation checks the **test file's setup code**, not runtime state

**Acceptance criteria**:
1. Pipeline with valid test harness passes validation in <2s and proceeds normally
2. Pipeline with missing/broken test file fails at intake with actionable error
3. `--skip-test-validation` bypasses all checks
4. No test command detected → warn and skip (don't fail)
5. JSON report written to `.claude/pipeline-artifacts/test-validation.json`
6. All 129 existing tests continue to pass (zero regressions)

### Design Alternatives

#### Alternative A: Validation in `preflight_checks()` (pipeline-util.sh)
- **Pros**: Runs even earlier (before any stage), alongside existing preflight checks for tools/git/disk
- **Cons**: `preflight_checks()` runs before `detect_test_cmd()`, so `TEST_CMD` isn't available yet. Would require restructuring the detection flow or duplicating detection logic.
- **Blast radius**: Medium — modifying `preflight_checks()` affects all pipeline runs

#### Alternative B: Validation in `stage_intake()` after `detect_test_cmd()` ← CHOSEN
- **Pros**: `TEST_CMD` is already resolved, natural integration point between detection and branch creation, only runs when intake stage is enabled
- **Cons**: Slightly later than pre-flight (after issue fetch), but still before any expensive stages (plan/build)
- **Blast radius**: Low — only touches intake stage, isolated to a new module

#### Alternative C: Standalone validation command (`shipwright validate-tests`)
- **Pros**: Can be run independently, useful as a standalone tool
- **Cons**: Doesn't gate the pipeline automatically, requires users to remember to run it
- **Blast radius**: Minimal but also minimal impact on pipeline reliability

**Decision**: Alternative B — integrating into `stage_intake()` after `detect_test_cmd()`. This is the natural point where test infrastructure is identified, and it gates all downstream stages automatically. The function lives in its own module for testability and can be called standalone if needed later.

### Risk Assessment

| Risk | Impact | Mitigation |
|------|--------|------------|
| False positives on non-shell test files (pytest, npm test pointing to JS) | Blocks valid pipelines | Only validate `.sh` test files; for non-shell test commands, skip harness pattern checks and only verify command exists |
| Breaking existing pipelines that have no tests | High — all pipelines fail at intake | When `TEST_CMD` is empty, log a warning and skip validation (don't fail) |
| Shellcheck not installed on all environments | Validation fails unnecessarily | Graceful fallback: skip shellcheck if not installed, note in report |
| Mock directory check is fragile (test setup varies) | False failures | Check for `TEST_TEMP_DIR` pattern in source code, not runtime directories; make this check advisory (warn, not fail) |
| Intake stage becomes slower | Pipeline latency increases | All checks are file/grep operations, total <500ms |

### Dependency Analysis

**Depends on**:
- `scripts/lib/pipeline-detection.sh` — `detect_test_cmd()` provides `TEST_CMD`
- `scripts/lib/pipeline-stages-intake.sh` — integration point in `stage_intake()`
- `scripts/lib/pipeline-cli.sh` — `parse_args()` for `--skip-test-validation` flag
- `scripts/lib/helpers.sh` — `info()`, `success()`, `warn()`, `error()`, `emit_event()`

**Depended on by**: Nothing (new module). Pipeline stages downstream of intake benefit passively.

**Circular dependency risks**: None. New module is leaf-level, only consumes existing APIs.

### Simplicity Check

- **Files changed**: 4 modified + 2 new = 6 total (minimum viable)
- **Reusable infrastructure**: Uses existing `test-helpers.sh` for test suite, existing `helpers.sh` for output, existing `emit_event` for observability
- **90% case**: File exists + is executable + has `set -euo pipefail` + has `PASS`/`FAIL` counters. The shellcheck and mock-dir checks are advisory extras.

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
        │         ├─ find_test_files()
        │         ├─ _validate_test_file_exists()
        │         ├─ _validate_test_executable()
        │         ├─ _validate_harness_patterns()
        │         ├─ _validate_shellcheck()
        │         └─ _write_validation_report()
        │
        └─ Error Handling
           ├─ Fail intake stage with actionable message
           └─ Write detailed validation report to artifacts
```

### Interface Contracts

```bash
# Main validation function
validate_test_infrastructure() {
    # Input:  Uses globals: TEST_CMD, SKIP_TEST_VALIDATION, PROJECT_ROOT, ARTIFACTS_DIR
    # Output: writes report to .claude/pipeline-artifacts/test-validation.json
    # Returns: 0 on success or skip, 1 on validation failure
    # Side effects: emits "test_validation.completed" event
}

# Find test files from TEST_CMD
find_test_files() {
    # Input:  $1 = test_cmd string (e.g., "npm test" or "bash scripts/sw-hello-test.sh")
    # Output: newline-separated list of .sh test file paths (stdout)
    # Returns: 0 always (empty output means no files found)
}

# Individual validators — all take test_file_path as $1
_validate_test_file_exists()   # Returns: 0 if exists, 1 otherwise
_validate_test_executable()    # Returns: 0 if -x, 1 otherwise
_validate_harness_patterns()   # Returns: 0 if patterns found, 1 otherwise
_validate_shellcheck()         # Returns: 0 if passes or shellcheck unavailable, 1 on errors

# Report writer
_write_validation_report() {
    # Input: $1=status, $2=test_file, $3=checks_json, $4=errors_json
    # Output: atomic write to $ARTIFACTS_DIR/test-validation.json
}
```

### Data Flow

```
intake stage (after issue fetch, task type detection)
  ↓
1. Detect test command (existing: detect_test_cmd → TEST_CMD)
  ↓
2. [NEW] Call validate_test_infrastructure()
  ├─ Check SKIP_TEST_VALIDATION → return 0 (skip)
  ├─ Check TEST_CMD empty → warn, return 0 (skip)
  ├─ Call find_test_files(TEST_CMD) → extract .sh file paths
  ├─ No .sh files found → warn, return 0 (non-shell tests are OK)
  │
  ├─ For each .sh test file:
  │  ├─ _validate_test_file_exists()
  │  ├─ _validate_test_executable()
  │  └─ _validate_harness_patterns()
  │
  ├─ Optionally: _validate_shellcheck() (first file only, if shellcheck available)
  │
  ├─ _write_validation_report()
  └─ Return: 0 (all pass) or 1 (any critical failure)
  ↓
3. If failed → error with actionable message, intake returns 1
4. If passed → success message, continue with branch creation
```

### Error Boundaries

1. **No TEST_CMD** → warn "No test command detected — skipping test validation", return 0
2. **Non-shell test command** (npm test, pytest, cargo test) → extract .sh files from package.json scripts.test expansion if possible, otherwise warn and return 0
3. **File not found** → CRITICAL: return 1, error "Test file not found: $path"
4. **Not executable** → CRITICAL: return 1, error "Test file not executable: $path (run: chmod +x $path)"
5. **Missing harness patterns** → CRITICAL: return 1, error "Missing required pattern in $path: [pattern]"
6. **Shellcheck fails** → ADVISORY: warn but don't fail (shellcheck errors may be acceptable)
7. **Shellcheck not installed** → SKIP: note in report, don't fail

---

## Files to Modify/Create

### New Files
1. **`scripts/lib/pipeline-test-validation.sh`** (~150 lines)
   - Module guard, helpers loading
   - `find_test_files()`, `validate_test_infrastructure()`, 4 validators, 1 report writer

2. **`scripts/sw-pipeline-test-validation-test.sh`** (~350 lines)
   - Test suite using test-helpers.sh
   - 20+ tests covering all paths

### Modified Files
3. **`scripts/lib/pipeline-cli.sh`** (1 line change)
   - Add `--skip-test-validation` to `parse_args()` case statement

4. **`scripts/lib/pipeline-stages-intake.sh`** (~5 lines added)
   - Source validation module
   - Call `validate_test_infrastructure()` after TEST_CMD detection (line ~62)

5. **`package.json`** (1 line change)
   - Append test suite to npm test chain

---

## Implementation Steps

### Phase 1: Core Validation Module (Tasks 1-4)

**Task 1**: Create `scripts/lib/pipeline-test-validation.sh` skeleton
- Module guard pattern: `[[ -n "${_PIPELINE_TEST_VALIDATION_LOADED:-}" ]] && return 0`
- Source helpers for `info()`, `warn()`, `error()`, `emit_event()`
- Defaults for `PROJECT_ROOT`, `ARTIFACTS_DIR`, `SKIP_TEST_VALIDATION`

**Task 2**: Implement `find_test_files()`
- Parse TEST_CMD to extract `.sh` file paths
- For `npm test`/`yarn test`: read `package.json` scripts.test, extract `bash scripts/*.sh` patterns
- For direct `bash path/to/test.sh`: extract the path directly
- For non-shell commands: return empty (no .sh files to validate)

**Task 3**: Implement validation functions
- `_validate_test_file_exists()`: `[[ -f "$1" ]]`
- `_validate_test_executable()`: `[[ -x "$1" ]]`
- `_validate_harness_patterns()`: grep for required patterns:
  - `set -euo pipefail` or `set -eu` (required)
  - `trap.*ERR` (required)
  - `PASS=` and `FAIL=` (required — test counters)
- `_validate_shellcheck()`: run `shellcheck -S error "$1"`, capture output, graceful if missing
- `_write_validation_report()`: atomic JSON write via tmp + mv

**Task 4**: Implement `validate_test_infrastructure()` orchestrator
- Check `SKIP_TEST_VALIDATION` → early return 0
- Check `TEST_CMD` empty → warn, return 0
- Call `find_test_files()`, if empty → warn, return 0
- Loop test files, run validators, aggregate results
- Write report, emit event, return 0 or 1

### Phase 2: Pipeline Integration (Tasks 5-6)

**Task 5**: Add `--skip-test-validation` flag to `scripts/lib/pipeline-cli.sh`
- Add case in `parse_args()`: `--skip-test-validation) SKIP_TEST_VALIDATION=true; shift ;;`
- Initialize `SKIP_TEST_VALIDATION="${SKIP_TEST_VALIDATION:-false}"` in defaults

**Task 6**: Integrate into `scripts/lib/pipeline-stages-intake.sh`
- Source module at top (after module guard)
- After TEST_CMD detection block (after line 62), add:
  ```bash
  # 3.5. Validate test infrastructure
  if type validate_test_infrastructure >/dev/null 2>&1; then
      validate_test_infrastructure || return 1
  fi
  ```

### Phase 3: Test Suite (Tasks 7-9)

**Task 7**: Create test suite skeleton `scripts/sw-pipeline-test-validation-test.sh`
- Standard header: shebang, `set -euo pipefail`, ERR trap, source test-helpers.sh
- Setup function: create mock test files, mock binaries, temp dirs
- Cleanup trap

**Task 8**: Implement positive and negative test cases
- Valid test file with all patterns → passes
- Missing file → fails with "not found"
- Not executable → fails with "not executable"
- Missing `set -euo pipefail` → fails with pattern error
- Missing PASS/FAIL counters → fails with pattern error
- Missing ERR trap → fails with pattern error
- Skip flag → passes regardless
- Empty TEST_CMD → skips with warning
- Non-shell test command → skips gracefully
- Report JSON structure validation
- Multiple test files (some valid, some not)

**Task 9**: Register in `package.json`
- Add `bash scripts/sw-pipeline-test-validation-test.sh` to test chain

### Phase 4: Verification (Task 10)

**Task 10**: Run full test suite, verify zero regressions
- Run new test suite in isolation
- Run `npm test` (all 129+ suites)
- Run `shellcheck` on new files

---

## Task Decomposition

1. Create `scripts/lib/pipeline-test-validation.sh` with module guard and `find_test_files()` — **no dependencies**
2. Implement `_validate_test_file_exists()`, `_validate_test_executable()`, `_validate_harness_patterns()` — **blocks Task 4**
3. Implement `_validate_shellcheck()` and `_write_validation_report()` — **blocks Task 4**
4. Implement `validate_test_infrastructure()` orchestrator — **depends on Tasks 2, 3**
5. Add `--skip-test-validation` flag to `pipeline-cli.sh` parse_args — **no dependencies**
6. Integrate validation call into `stage_intake()` in `pipeline-stages-intake.sh` — **depends on Task 4**
7. Create test suite skeleton `sw-pipeline-test-validation-test.sh` — **no dependencies**
8. Implement positive and negative test cases — **depends on Tasks 4, 7**
9. Register test suite in `package.json` — **depends on Task 7**
10. Run full test suite and verify zero regressions — **depends on Tasks 6, 8, 9**

Tasks 1-3, 5, 7 can all proceed in parallel. Task 4 blocks Task 6. Tasks 7-9 can proceed once Task 4 is done.

---

## Risk Analysis

| Risk | What Could Break | Mitigation |
|------|-----------------|------------|
| False positive on `npm test` (package.json references bash scripts) | Valid pipeline blocked at intake | `find_test_files()` only extracts explicit `.sh` paths; for `npm test` without `.sh` references, skip validation |
| Harness pattern grep too strict | Files using slight variations (e.g., `set -eu` without `o pipefail`) fail | Match `set -e` as minimum, check for `pipefail` separately as advisory |
| Module sourced in unexpected context | Variables undefined, crashes | Module guard + defaults for all variables (`${VAR:-default}`) |
| Existing `sw-pipeline-test.sh` breaks | False regression | Integration is behind `type validate_test_infrastructure >/dev/null 2>&1` guard — if module isn't loaded, validation is silently skipped |
| Shellcheck produces warnings that aren't errors | Advisory check becomes blocking | Only run `shellcheck -S error` (errors only, not warnings) |

---

## Testing Approach

### Unit Tests (in `sw-pipeline-test-validation-test.sh`)

**Positive Cases**:
1. Valid test file with all harness patterns → `validate_test_infrastructure` returns 0
2. Report JSON contains `"status": "pass"` and all checks pass
3. Multiple valid test files all pass

**Negative Cases**:
4. Missing test file → returns 1, report has `"file_exists": false`
5. Non-executable test file → returns 1, report has `"executable": false`
6. Missing `set -euo pipefail` → returns 1, report lists missing pattern
7. Missing PASS counter → returns 1, report lists missing pattern
8. Missing FAIL counter → returns 1, report lists missing pattern
9. Missing ERR trap → returns 1, report lists missing pattern

**Edge Cases**:
10. `SKIP_TEST_VALIDATION=true` → returns 0 without checking
11. `TEST_CMD=""` (empty) → returns 0 with warning
12. `TEST_CMD="pytest"` (non-shell) → returns 0 with warning
13. `TEST_CMD="npm test"` with package.json → extracts and validates .sh files
14. Shellcheck not installed → returns 0 (graceful skip)
15. Shellcheck finds errors → warns but doesn't fail (advisory)

**Report Validation**:
16. Report file exists at expected path
17. Report contains valid JSON
18. Report has required fields: `timestamp`, `status`, `test_files`, `checks`
19. Atomic write: report is complete (not truncated)

**find_test_files() Tests**:
20. Direct bash invocation extracts path
21. npm test with bash scripts in package.json extracts paths
22. Non-shell command returns empty

---

## Definition of Done

- [ ] `scripts/lib/pipeline-test-validation.sh` created with all validation functions
- [ ] `validate_test_infrastructure()` implements file, executable, and harness pattern checks
- [ ] Shellcheck validation is advisory (warn, not fail) with graceful fallback
- [ ] JSON report written atomically to `.claude/pipeline-artifacts/test-validation.json`
- [ ] `stage_intake()` calls `validate_test_infrastructure()` after `TEST_CMD` detection
- [ ] `--skip-test-validation` CLI flag works in pipeline
- [ ] No test command → warn and skip (not fail)
- [ ] Non-shell test commands → skip harness validation gracefully
- [ ] `sw-pipeline-test-validation-test.sh` has 20+ passing tests
- [ ] All 129 existing test suites pass (zero regressions)
- [ ] `shellcheck -S warning` passes on all new `.sh` files
- [ ] Code uses `set -euo pipefail`, module guards, bash 3.2 compatible syntax
- [ ] Error messages are actionable with file paths and fix suggestions
- [ ] Event emitted: `test_validation.completed` with status

---

## Alternatives Considered

### Alternative A: Integrate into `preflight_checks()` in `pipeline-util.sh`
- **Complexity**: Medium — requires calling `detect_test_cmd()` early or restructuring detection flow
- **Performance**: Same
- **Maintainability**: Lower — mixes infrastructure checks (tools, git) with content checks (test files)
- **Blast radius**: Higher — `preflight_checks()` is also used by daemon, not just pipeline
- **Rejected because**: `TEST_CMD` isn't available at preflight time; would require duplicating detection logic

### Alternative B: Integrate into `stage_intake()` after `detect_test_cmd()` (CHOSEN)
- **Complexity**: Low — `TEST_CMD` already resolved, single call insertion
- **Performance**: Same
- **Maintainability**: High — isolated module, clear integration point
- **Blast radius**: Minimal — only affects intake stage, guarded by `type` check
- **Chosen because**: Natural integration point, minimum code changes, clean separation of concerns

### Alternative C: Standalone CLI command (`shipwright validate-tests`)
- **Complexity**: Low
- **Performance**: Same
- **Maintainability**: High
- **Blast radius**: None — doesn't affect pipeline at all
- **Rejected because**: Doesn't automatically gate pipelines; users must remember to run it

### Alternative D: Validation in test stage (not intake)
- **Complexity**: Low
- **Performance**: Worst — validation happens after plan+design+build stages consume tokens
- **Maintainability**: High
- **Blast radius**: Minimal
- **Rejected because**: Defeats the purpose of fail-fast; expensive stages run before validation

---

## Task Checklist

- [ ] Task 1: Create `scripts/lib/pipeline-test-validation.sh` with module guard and `find_test_files()`
- [ ] Task 2: Implement `_validate_test_file_exists()`, `_validate_test_executable()`, `_validate_harness_patterns()`
- [ ] Task 3: Implement `_validate_shellcheck()` and `_write_validation_report()`
- [ ] Task 4: Implement `validate_test_infrastructure()` orchestrator function
- [ ] Task 5: Add `--skip-test-validation` flag to `pipeline-cli.sh` parse_args
- [ ] Task 6: Integrate validation call into `stage_intake()` in `pipeline-stages-intake.sh`
- [ ] Task 7: Create test suite skeleton `sw-pipeline-test-validation-test.sh`
- [ ] Task 8: Implement 20+ positive, negative, and edge case tests
- [ ] Task 9: Register test suite in `package.json`
- [ ] Task 10: Run full test suite and verify zero regressions
