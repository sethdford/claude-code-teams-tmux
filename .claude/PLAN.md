# Implementation Plan: Test Infrastructure Pre-Flight Validation Gate

**Issue:** #232
**Goal:** Test Infrastructure Pre-Flight Validation Gate
**Generated:** 2026-03-08

---

## Executive Summary

Create a comprehensive pre-flight validation system that checks all aspects of the test infrastructure before test execution. This gate will:
- Validate dependencies (node, npm, bun, vitest, jq, bash tools)
- Verify test file structure and patterns
- Detect missing or misconfigured test suites
- Ensure test environment is clean
- Generate actionable reports
- Integrate into CI/CD pipelines and pre-commit workflows

---

## Requirements Analysis

### Stated Requirements
- Pre-flight validation gate for test infrastructure
- Gate should run before tests execute
- Must validate all test types (bash + TypeScript)

### Implicit Requirements (from codebase analysis)
1. **Bash 3.2 compatibility** — all scripts must work on older bash versions
2. **Modular design** — follow recent refactoring pattern (decompose into lib modules + orchestrator)
3. **Testable** — validation logic must be unit-testable (each test suite has a `-test.sh` counterpart)
4. **Backward compatible** — existing npm test pipeline must continue working
5. **Observable** — report should show what passed/failed (like existing test output format)
6. **Exit codes** — 0 for success, non-zero for failures (standard Unix convention)

### Definition of Done

- [ ] Pre-flight validation logic is modular (core in lib/)
- [ ] `sw-test-preflight.sh` orchestrator implemented and functional
- [ ] `sw-test-preflight-test.sh` has >80% test coverage of validation logic
- [ ] All dependencies checked (node, npm, bun, vitest, jq, bash version, required commands)
- [ ] All test files validated (existence, permissions, basic structure)
- [ ] Test suite count matches expected (102+ bash tests, 16+ dashboard tests)
- [ ] Validation time < 5 seconds (fast enough for pre-commit)
- [ ] Integration into `npm test` (runs as first stage)
- [ ] GitHub Actions workflow updated to use pre-flight gate
- [ ] Exit code 0 = all checks pass, non-zero = failures with actionable messages
- [ ] Documentation added to `.claude/CLAUDE.md` AUTO section
- [ ] No breaking changes to existing test infrastructure

---

## Architecture & Design Decisions

### Why Modular Approach (Approach B)

**Considered:**
1. **Approach A:** Single monolithic script (simple, quick)
   - Pros: Fast to implement, minimal file changes
   - Cons: Hard to test, monolithic, not reusable

2. **Approach B:** Core lib + orchestrator (recommended)
   - Pros: Testable, reusable, follows shipwright patterns
   - Cons: More files, slightly more complex

**Chosen:** Approach B
**Rationale:**
- Shipwright has recent pattern of decomposition (sw-recruit, sw-pipeline split into modules)
- Allows independent testing of validation functions
- Enables reuse in other contexts (IDE plugins, CI/CD tools, local development)
- Consistent with existing architecture

### Module Structure

```
scripts/
├── lib/
│   └── test-validation.sh        (NEW: core validation functions)
├── sw-test-preflight.sh          (NEW: orchestrator + CLI)
├── sw-test-preflight-test.sh     (NEW: unit tests for validation)
├── sw-*-test.sh                  (EXISTING: 102+ test suites)
└── sw (UPDATED: dispatch table adds test-preflight)
```

### Validation Layers

```
Level 1: Environment
├─ Node.js version (>=20)
├─ npm version
├─ Bash version (3.2+)
└─ Required CLI tools (jq, git, etc.)

Level 2: Dependencies
├─ vitest installed
├─ bun installed
├─ @testing-library/dom installed
├─ happy-dom installed
└─ Other devDependencies

Level 3: Test Files
├─ Bash test suite files exist
├─ *.test.ts files in dashboard/
├─ File permissions (executable for .sh)
└─ Syntax check (bash -n for shell scripts)

Level 4: Test Configuration
├─ vitest.config.ts is valid
├─ package.json test script is valid
├─ Test patterns match expectations
└─ Coverage thresholds defined

Level 5: Environment Health
├─ No uncommitted changes in test files
├─ node_modules installed (if needed)
├─ Temporary directories writable
└─ Required test fixtures present
```

### Acceptance Criteria by Layer

#### Environment Checks
- Node.js >= 20 ✓
- npm >= 9 ✓
- Bash >= 3.2 ✓
- Required tools (jq, git) available ✓
- TMPDIR or /tmp writable ✓

#### Bash Test Suite Checks
- [ ] All 102+ test scripts referenced in package.json exist
- [ ] Each test script is executable
- [ ] Each test script has `set -euo pipefail`
- [ ] No syntax errors (bash -n check)
- [ ] Test pattern matches: `*-test.sh`
- [ ] Helper functions available (from lib/test-helpers.sh)

#### Dashboard Test Checks
- [ ] vitest.config.ts exists and is valid TypeScript
- [ ] 16+ `*.test.ts` files in dashboard/src/**
- [ ] Each test file is accessible
- [ ] Coverage thresholds defined in config

#### Integration Checks
- [ ] npm test references preflight gate
- [ ] GitHub Actions workflows compatible
- [ ] No circular dependencies between test files
- [ ] Mock binaries setup can succeed

---

## Task Decomposition

### Phase 1: Core Implementation (3 tasks)

**Task 1: Create lib/test-validation.sh** (Blocks all others)
- Implement check_node_version()
- Implement check_npm_version()
- Implement check_bash_version()
- Implement check_required_tools()
- Implement check_vitest_installed()
- Implement check_bun_installed()
- Implement validate_bash_test_suite()
- Implement validate_typescript_test_files()
- Implement check_vitest_config()
- Implement check_test_file_syntax()
- Return structured output (JSON or key=value pairs for easy parsing)
- Total: ~200 lines with helpers

**Task 2: Create sw-test-preflight.sh** (Depends on Task 1)
- Source lib/test-validation.sh
- Parse CLI arguments (--strict, --fix, --json, --verbose)
- Run all validation layers
- Aggregate results (pass/fail counts)
- Generate report (plain text or JSON)
- Exit with appropriate code
- Handle colors and formatting (match existing test output)
- Total: ~150 lines

**Task 3: Create sw-test-preflight-test.sh** (Depends on Task 1 & 2)
- Test environment checks
- Test bash test suite validation
- Test TypeScript test validation
- Test error handling
- Test report generation
- >80% coverage of lib/test-validation.sh
- Total: ~250 lines

### Phase 2: Integration (2 tasks)

**Task 4: Update package.json test script** (Depends on Task 2)
- Add `pre-test` script that runs sw-test-preflight.sh
- Update `test` script to call `pre-test` first
- Add preflight gates before each test suite subset
- Maintain backward compatibility

**Task 5: Update CI/CD workflows** (Depends on Task 2)
- Add pre-flight gate stage to GitHub Actions
- Create new workflow: `.github/workflows/test-preflight.yml`
- Update existing test workflows to use preflight gate
- Add preflight status badge to README

### Phase 3: Polish & Documentation (3 tasks)

**Task 6: Create pre-commit hook integration** (Depends on Task 2)
- Add `.claude/hooks/pre-test.sh` hook
- Hook runs preflight gate on git commit
- Optional: fix mode (--fix flag to auto-resolve issues)
- Register hook in `.claude/settings.json`

**Task 7: Update documentation** (Depends on Task 2)
- Add section to `.claude/CLAUDE.md` under TEST HARNESS
- Document CLI usage: `shipwright test-preflight`
- Document integration points
- Add troubleshooting guide
- Update AUTO:test-harness section with new section

**Task 8: Add help and error messages** (Depends on Task 2)
- Create detailed help output
- Create actionable error messages
- Add recovery suggestions (e.g., "run npm install")
- Add examples to --help

---

## Risk Analysis

### Risk 1: Validation Takes Too Long
**Impact:** Developers skip pre-flight check or it times out in CI
**Likelihood:** Medium (bash syntax checking can be slow)
**Mitigation:**
- Optimize using parallel validation where possible
- Skip expensive checks with `--fast` flag
- Cache results between consecutive runs
- Target < 2 seconds for normal case, < 5 seconds for strict

### Risk 2: False Positives (healthy infra marked as broken)
**Impact:** CI failures, developer confusion
**Likelihood:** Medium (validation logic may be too strict)
**Mitigation:**
- Test with existing infrastructure
- Make strict mode optional (`--strict` flag)
- Provide `--explain` flag to show reasoning
- Allow overrides via env vars (SW_SKIP_CHECKS)

### Risk 3: Backward Compatibility Break
**Impact:** Existing test scripts fail to run
**Likelihood:** Low (we're only adding a gate, not changing tests)
**Mitigation:**
- Pre-flight gate is independent (can be bypassed)
- No changes to existing test harness
- New files only, no modifications to existing scripts

### Risk 4: Bash Compatibility Issues
**Impact:** Script fails on older bash versions
**Likelihood:** Low (we're enforcing bash 3.2 anyway)
**Mitigation:**
- Use `set -euo pipefail` (baseline)
- No associative arrays, no `${var,,}` syntax
- Test on bash 3.2 in CI

### Risk 5: Circular Dependencies
**Impact:** Validation script can't run because it needs itself
**Likelihood:** Very low (simple validation logic)
**Mitigation:**
- Validate lib modules don't depend on main scripts
- No sourcing of sw-* files in lib/test-validation.sh

### Risk 6: TypeScript/Node.js Dependency Changes
**Impact:** Validation checks become stale as tools update
**Likelihood:** Medium (dependencies evolve)
**Mitigation:**
- Make version checks configurable
- Check against package.json engines field
- Add `--update-checks` to refresh validation rules

---

## Files to Modify

### New Files
1. `scripts/lib/test-validation.sh` — Core validation functions (~200 lines)
2. `scripts/sw-test-preflight.sh` — Orchestrator script (~150 lines)
3. `scripts/sw-test-preflight-test.sh` — Validation tests (~250 lines)
4. `.claude/hooks/pre-test.sh` — Pre-commit hook (~80 lines)

### Modified Files
1. `scripts/sw` — Add `test-preflight` dispatch
2. `package.json` — Add pre-test script, update test script
3. `.github/workflows/test.yml` — Add preflight stage
4. `.claude/settings.json` — Register pre-test hook
5. `.claude/CLAUDE.md` — Add documentation AUTO section

### Updated (via AUTO sync)
- `.claude/CLAUDE.md` — AUTO:core-scripts, AUTO:test-suites

---

## Implementation Steps

### Step 1: Create lib/test-validation.sh
1. Create file with header comment
2. Implement helper functions:
   - `check_command()` — verify a CLI tool exists
   - `check_version()` — compare semantic versions
   - `count_files()` — count matching files
   - `report_check()` — format check result
3. Implement validation functions:
   - Environment checks (node, npm, bash, tools)
   - Dependency checks (vitest, bun, packages)
   - Test file checks (bash test suites, TS test files)
   - Configuration checks (vitest.config, package.json)
   - Health checks (git state, permissions)
4. Make functions idempotent (safe to call multiple times)
5. Return structured output

### Step 2: Create sw-test-preflight.sh
1. Create file with header comment
2. Source lib/test-validation.sh
3. Parse CLI arguments (--strict, --json, --fast, --verbose, --help)
4. Initialize counters (total_checks, passed, failed, skipped)
5. Run validation layers in order
6. Collect results
7. Generate report (plain text or JSON)
8. Print summary with colors
9. Exit with appropriate code

### Step 3: Create sw-test-preflight-test.sh
1. Copy test template from existing test suite
2. Create test functions:
   - test_check_node_version_passes
   - test_check_node_version_fails
   - test_check_npm_version_passes
   - test_validate_bash_test_suites
   - test_validate_typescript_tests
   - test_json_output_format
   - test_exit_code_on_failure
   - test_exit_code_on_success
3. Use mock functions to simulate failures
4. Run tests and count results

### Step 4: Update scripts/sw dispatcher
1. Add case for `test-preflight` in main dispatch
2. Ensure proper PATH includes scripts/

### Step 5: Update package.json
1. Add scripts.preflight-test = "bash scripts/sw-test-preflight.sh"
2. Prepend to scripts.test: run preflight first
3. Maintain current test command functionality

### Step 6: Update GitHub Actions workflows
1. Add step in test.yml to run preflight gate
2. Gate downstream test jobs on preflight success
3. Create separate pre-flight job if needed

### Step 7: Create pre-commit hook
1. Create .claude/hooks/pre-test.sh
2. Hook calls sw-test-preflight.sh before commit
3. Can be disabled with --no-verify (but warn)

### Step 8: Update .claude/CLAUDE.md
1. Add TEST INFRASTRUCTURE PRE-FLIGHT section
2. Document CLI: `shipwright test-preflight`
3. Document flags and examples
4. Update AUTO:core-scripts table
5. Update AUTO:test-suites table

---

## Testing Approach

### Unit Tests (sw-test-preflight-test.sh)
- Test each validation function independently
- Mock external commands (node, npm, etc.)
- Test both pass and fail paths
- Test error handling

### Integration Tests
- Run full preflight against real test infrastructure
- Verify all 102+ test suites are detected
- Verify all 16+ dashboard tests are detected
- Verify exit codes match expectations

### Smoke Tests
- Add to existing smoke test suite
- Run preflight as part of e2e-smoke-test.sh
- Verify preflight doesn't break existing pipeline

### Manual Testing
- Run locally: `bash scripts/sw-test-preflight.sh`
- Run with flags: `--strict`, `--json`, `--verbose`
- Verify output formatting

### CI Testing
- Add to GitHub Actions
- Run on every PR
- Verify all checks pass before tests run
- Measure execution time

---

## Success Metrics

- [ ] All 102+ bash test suites detected
- [ ] All 16+ dashboard test suites detected
- [ ] Pre-flight execution time < 2 seconds (normal) / < 5 seconds (strict)
- [ ] Exit code 0 when infrastructure healthy
- [ ] Exit code 1 when issues found
- [ ] Actionable error messages (developers know what to fix)
- [ ] 0 false positives in 50 CI runs
- [ ] >80% test coverage of validation logic
- [ ] No impact on existing test execution time
- [ ] Pre-commit hook integration working

---

## Alternatives Considered

### Alternative 1: Simple Single-File Validator
```bash
scripts/sw-test-preflight.sh (500+ lines, all-in-one)
```
- Pros: Simpler, fewer files, quicker initial implementation
- Cons: Hard to test, not reusable, monolithic
- **Rejected**: Violates Shipwright decomposition pattern

### Alternative 2: Python-Based Validator
```python
scripts/sw-test-preflight.py
```
- Pros: Easier to parse JSON, more libraries available
- Cons: Requires Python (not guaranteed on all systems)
- **Rejected**: Shipwright is bash-first, adds dependency

### Alternative 3: Lazy Validation (on-demand only)
- Validate only when explicitly called
- Not run as pre-commit or pre-test automatically
- **Rejected**: Defeats purpose of "gate" if optional

### Chosen: Modular Bash + Orchestrator
- Core validation in `lib/test-validation.sh`
- Orchestrator in `sw-test-preflight.sh`
- Tests in `sw-test-preflight-test.sh`
- Integrates into CI/CD via package.json + hooks
- Follows Shipwright patterns (modular, testable, decomposed)

---

## Dependency Graph

```
lib/test-validation.sh (no dependencies)
├─ sw-test-preflight.sh (depends on lib/test-validation.sh)
│  ├─ sw-test-preflight-test.sh (depends on both)
│  ├─ package.json test script (depends on sw-test-preflight.sh)
│  └─ GitHub Actions workflows (depends on sw-test-preflight.sh)
├─ .claude/hooks/pre-test.sh (depends on sw-test-preflight.sh)
└─ .claude/CLAUDE.md (documents sw-test-preflight.sh)
```

None of the dependencies are circular.

---

## Implementation Effort Estimate

| Task | Effort | Dependencies |
|------|--------|--------------|
| 1. lib/test-validation.sh | 2h | None |
| 2. sw-test-preflight.sh | 1.5h | Task 1 |
| 3. sw-test-preflight-test.sh | 1.5h | Task 1, 2 |
| 4. package.json integration | 30m | Task 2 |
| 5. GitHub Actions integration | 30m | Task 2 |
| 6. Pre-commit hook | 30m | Task 2 |
| 7. Documentation | 30m | Task 2 |
| 8. Testing & debugging | 1.5h | All tasks |
| **Total** | **~8.5h** | Sequential with parallelization possible |

---

## Questions Answered (Socratic Review)

### Requirements Clarity
**Q: What is the minimum viable change that satisfies this issue?**
- A: Running a validation script that checks dependencies, test files exist, and basic configuration is valid. Can exit with 0/1 based on results.

**Q: What are the acceptance criteria?**
- A: Pre-flight completes in <2s, detects all test suites, provides actionable error messages, integrates into CI.

### Design Alternatives
**Q: What are 2-3 different approaches?**
- A: Monolithic (all-in-one file), Python-based (easier but adds dependency), Modular bash (chosen — follows Shipwright patterns).

### Risk Assessment
**Q: What could go wrong?**
- A: Validation too slow (mitigated by --fast flag), false positives (--strict is optional), backward compatibility (independent gate).

### Dependency Analysis
**Q: Does this depend on code that might change?**
- A: Depends on test file paths and npm config, but loose coupling allows updates without breaking validation.

### Simplicity Check
**Q: Can this be solved with fewer files?**
- A: Technically yes (monolithic), but modular approach aligns with Shipwright's recent refactoring direction and enables reuse.

---

## Next Steps

1. **Approval**: Review this plan and confirm approach
2. **Implementation**: Execute in order (Tasks 1-8)
3. **Testing**: Run full test suite after each phase
4. **Documentation**: Update AUTO sections in .claude/CLAUDE.md
5. **Release**: Bump version, update CHANGELOG

