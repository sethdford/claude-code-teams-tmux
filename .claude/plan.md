# Implementation Plan: Test Failure Recovery Loop with Smart Iteration Budget Management

**Goal**: Build a test failure tracking module that detects per-test failure patterns across iterations, provides smart recovery context injection, and adapts iteration budget based on failure severity.

**Complexity**: Medium (6/10) — new library module + 4 surgical integration points
**Estimated Lines**: ~350 new, ~80 modified

---

## Socratic Design Analysis

### Requirements Clarity

**Minimum viable change**: A new `lib/loop-test-failure-tracker.sh` module that:
1. Extracts individual test names from test framework output (Jest, Pytest, Go, Vitest)
2. Tracks which tests fail in which iterations via a JSON state file
3. Detects when the same test fails 3+ consecutive iterations → abort
4. Injects "previously failed tests" context into the next iteration's prompt

**Implicit requirements**:
- Must not break any of the 143 existing test suites
- Must follow Bash 3.2 compatibility (no associative arrays, no readarray)
- Must use atomic writes (tmp+mv) for state files
- Must gracefully degrade if module is missing (guard pattern)

**Acceptance criteria** (self-defined):
- `tft_extract_test_names()` correctly parses 5 test framework formats
- State file tracks per-test failure history as JSON
- Loop aborts with `STATUS="abort_repeated_test_failure"` after 3 consecutive same-test failures
- Grace period: no abort in iterations 1-2
- Non-consecutive failures (gaps) do NOT trigger abort
- Context section injected into `compose_prompt()` showing previously failed tests
- State resets on session restart
- All existing tests pass (`npm test` exit 0)

### Design Alternatives

**Alternative A: Extend `diagnose_failure()` in sw-loop.sh**
- Pros: No new files, builds on existing diagnostic path
- Cons: `diagnose_failure()` is already 100+ lines, mixes concerns (classification + tracking), sw-loop.sh is 2527 lines
- Blast radius: Medium — changes core diagnostic path that runs every iteration
- Trade-off: Less complexity but worse maintainability

**Alternative B: Add 8th signal to `detect_stuckness()` in loop-convergence.sh**
- Pros: Stuckness detection already has signal infrastructure
- Cons: Stuckness fires after iteration completes (too late for same-iteration injection), triggers session restart not clean abort, mixes generic health with test-specific logic
- Blast radius: Medium-High — alters convergence/stuckness logic
- Trade-off: Reuses infrastructure but wrong abstraction level

**Alternative C (Chosen): New `lib/loop-test-failure-tracker.sh` module**
- Pros: Clean separation of concerns, testable in isolation, follows `lib/loop-*.sh` pattern, non-breaking if missing, minimal integration points (4 lines in sw-loop.sh)
- Cons: One more file to maintain
- Blast radius: **Low** — all existing code unchanged except 4 surgical additions
- Trade-off: Best maintainability and testability at cost of one new file

**Why C wins**: The existing `lib/loop-*.sh` pattern (convergence.sh, iteration.sh, restart.sh, progress.sh) proves this architecture works. Adding a 5th module is the natural extension.

### Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|-----------|
| False positive abort on flaky test | Medium | High | Require 3 *consecutive* iterations (gaps break streak). Grace period: no abort in iter 1-2. |
| Parser misses test names (unusual framework) | Low | Low | Graceful fallback: if no names extracted, loop continues as before. No abort without names. |
| JSON state corruption | Low | Medium | Atomic writes (tmp+mv). Validate JSON on read. Reset to empty on corruption. |
| Breaking existing convergence logic | Very Low | High | New module is purely additive. Guards prevent breakage if missing. |
| `while read` subshell variable loss | Medium | Medium | Use `while read; done < <(cmd)` pattern per CLAUDE.md pitfalls. |
| Context bloat from many failed tests | Low | Low | Cap at 5 tests in injection, ~200 chars max per section. |

### Dependency Analysis

- **Depends on**: `jq` (already required), `$LOG_DIR` variable (set by sw-loop.sh), test output from `run_test_gate()`
- **Depended on by**: Nothing — purely additive module
- **Circular dependency risk**: None — module is sourced but never sources back

---

## Files to Modify

### New Files
1. `scripts/lib/loop-test-failure-tracker.sh` (~300 lines) — Core recovery module
2. `scripts/sw-lib-loop-test-failure-tracker-test.sh` (~450 lines) — Unit test suite

### Modified Files
3. `scripts/sw-loop.sh` (+8 lines) — Source module, record failures, check abort, reset on restart
4. `scripts/lib/loop-iteration.sh` (+12 lines) — Inject failed test context into `compose_prompt()`
5. `package.json` (+1 line) — Register new test suite

---

## Implementation Steps

### Step 1: Create `scripts/lib/loop-test-failure-tracker.sh`

The core module with 5 public functions:

```bash
# Module guard
[[ -n "${_LOOP_TEST_FAILURE_TRACKER_LOADED:-}" ]] && return 0
_LOOP_TEST_FAILURE_TRACKER_LOADED=1

# Global state
TFT_STATE_FILE=""
TFT_ABORT_REASON=""
TFT_REPEATED_TESTS=""
```

**Function 1: `tft_extract_test_names(test_output)`**
- Input: Raw test output string
- Output: Newline-separated test identifiers (max 20) on stdout
- Parsers (in priority order):
  1. **Jest**: `FAIL  src/auth.test.js` or `✕ login should validate credentials`
  2. **Pytest**: `FAILED tests/test_auth.py::test_login`
  3. **Go test**: `--- FAIL: TestLogin` or `FAIL\tpkg/auth`
  4. **Vitest**: `FAIL  src/auth.test.ts > login > validates`
  5. **Generic fallback**: Lines matching `FAIL:` or `✗` or `✕`
- Empty input → empty output (return 0)
- Dedup results, cap at 20

**Function 2: `tft_record_iteration(iteration, test_output)`**
- Extract test names from output
- Load/create state file at `$LOG_DIR/test-failure-tracking.json`
- For each failed test: append current iteration to its history array
- Atomic write: `tmp.$$` + `mv`
- State format:
  ```json
  {
    "version": 1,
    "failed_tests": {
      "src/auth.test.js::login": { "iterations": [3, 4, 5], "first_seen": 3 }
    },
    "last_iteration": 5,
    "last_updated": "2026-03-08T12:34:56Z"
  }
  ```
- If test_output is empty (tests passed), still update `last_iteration` but don't add any failures

**Function 3: `tft_check_repeated_failures(threshold)`**
- Default threshold: 3
- Read state file, check each test's iteration array
- "Consecutive" = the last N entries form an unbroken sequence ending at `last_iteration`
  - Example: iterations [3,4,5] with last_iteration=5, threshold=3 → consecutive ✓
  - Example: iterations [3,5,7] with last_iteration=7, threshold=3 → NOT consecutive (gaps)
- Grace period: if `last_iteration < 3`, return 1 (no abort)
- Sets `TFT_ABORT_REASON` and `TFT_REPEATED_TESTS` on match
- Return 0 if abort warranted, 1 otherwise
- Critical: Use `< <(jq ...)` pattern to avoid subshell variable loss

**Function 4: `tft_compose_context_section()`**
- Read state file, extract top 5 most-failed tests (sorted by iteration count desc)
- Output markdown section:
  ```
  ## Previously Failed Tests
  These tests have failed in recent iterations — focus fixes here:
  - src/auth.test.js::login (iterations: 3, 4, 5) ⚠️ 3 consecutive
  - api.test.py::test_endpoint (iterations: 4, 5)
  ```
- If no state file or no failures, output empty string
- Cap output at 5 tests, ~200 chars

**Function 5: `tft_reset()`**
- Remove state file
- Clear global variables

### Step 2: Create test suite `scripts/sw-lib-loop-test-failure-tracker-test.sh`

Using existing test harness pattern from `scripts/lib/test-helpers.sh`:

**Parser Tests (6 tests)**:
1. Jest format: `✕ login should validate` → extracts test name
2. Pytest format: `FAILED tests/test_auth.py::test_login` → extracts qualified name
3. Go test format: `--- FAIL: TestLogin (0.01s)` → extracts `TestLogin`
4. Vitest format: `FAIL  src/auth.test.ts > login > validates` → extracts full path
5. Generic format: `FAIL: something broke` → extracts description
6. Empty input: returns empty, exit 0

**State Management Tests (4 tests)**:
7. Record creates new state file with correct JSON structure
8. Record appends iteration to existing test history
9. Record handles passed tests (empty output) — updates last_iteration only
10. Corrupted JSON file → graceful reset to empty state

**Consecutive Detection Tests (5 tests)**:
11. Exact threshold (3 consecutive: iters [3,4,5], last=5) → returns 0
12. Below threshold (2 consecutive: iters [4,5], last=5) → returns 1
13. Above threshold (5 consecutive: iters [1,2,3,4,5], last=5) → returns 0
14. Non-consecutive (gaps: iters [1,3,5], last=5) → returns 1
15. Sets TFT_ABORT_REASON and TFT_REPEATED_TESTS correctly

**Grace Period Tests (2 tests)**:
16. Iteration 1 with failure → no abort (returns 1)
17. Iteration 2 with failure → no abort (returns 1)

**Context Section Tests (2 tests)**:
18. With failures → markdown section with test names and iteration lists
19. No state file → empty output

**Reset Test (1 test)**:
20. Reset removes state file and clears globals

**Edge Cases (2 tests)**:
21. More than 20 test names → truncated to 20
22. Special characters in test names (quotes, spaces) → handled via jq --arg

### Step 3: Integrate into `scripts/sw-loop.sh` (4 surgical additions)

**Addition 1** — Source module (after line 40, with other loop-*.sh modules):
```bash
# Test failure tracking for smart abort (issue #230)
[[ -f "$SCRIPT_DIR/lib/loop-test-failure-tracker.sh" ]] && source "$SCRIPT_DIR/lib/loop-test-failure-tracker.sh" 2>/dev/null || true
```
Location: After line 40 (`loop-progress.sh` source), before line 41 (`session-restart.sh` source).

**Addition 2** — Record failures after test gate (after line 2237 `write_error_summary`):
```bash
# Track individual test failures for smart abort (issue #230)
if type tft_record_iteration >/dev/null 2>&1 && [[ -n "$TEST_CMD" ]]; then
    tft_record_iteration "$ITERATION" "${TEST_OUTPUT:-}" 2>/dev/null || true
fi
```
Location: After line 2237, before line 2238.

**Addition 3** — Check for repeated failure abort (after line 2110 `check_max_iterations`):
```bash
# Smart test failure abort — same test failing 3+ consecutive iterations (issue #230)
if type tft_check_repeated_failures >/dev/null 2>&1 && [[ "${ITERATION:-0}" -gt 0 ]]; then
    if tft_check_repeated_failures 3; then
        STATUS="abort_repeated_test_failure"
        error "Aborting: repeated test failure — ${TFT_ABORT_REASON:-unknown}"
        emit_event "loop.abort_repeated_test_failure" \
            "iteration=$ITERATION" \
            "tests=${TFT_REPEATED_TESTS:-}" \
            "reason=${TFT_ABORT_REASON:-}" 2>/dev/null || true
        write_state
        write_progress
        show_summary
        break
    fi
fi
```
Location: After line 2110 (`check_max_iterations || break`), before line 2111 (`check_budget_gate`).

**Addition 4** — Reset on session restart (in restart block, after line 2484 `STUCKNESS_COUNT=0`):
```bash
# Reset test failure tracking for fresh session
type tft_reset >/dev/null 2>&1 && tft_reset 2>/dev/null || true
```
Location: After line 2484, before line 2485.

### Step 4: Integrate into `scripts/lib/loop-iteration.sh`

**In `compose_prompt()` — build failed test section** (after line 118, after error_summary_section):
```bash
# Previously failed test names for smart recovery (issue #230)
local failed_tests_section=""
if type tft_compose_context_section >/dev/null 2>&1; then
    failed_tests_section="$(tft_compose_context_section 2>/dev/null || true)"
fi
```

**In heredoc** (after line 358, after error_summary_section injection):
```bash
${failed_tests_section:+$failed_tests_section
}
```

### Step 5: Register test suite in `package.json`

Add to the test script's list of test suites:
```
./scripts/sw-lib-loop-test-failure-tracker-test.sh
```

### Step 6: Run full test suite and verify

```bash
# New test suite
./scripts/sw-lib-loop-test-failure-tracker-test.sh

# Existing loop tests (regression check)
./scripts/sw-loop-test.sh
./scripts/sw-convergence-test.sh
./scripts/sw-session-restart-test.sh

# Full suite
npm test
```

---

## Task Checklist

- [ ] Task 1: Create `scripts/lib/loop-test-failure-tracker.sh` with `tft_extract_test_names()` parser (5 formats: Jest, Pytest, Go, Vitest, generic)
- [ ] Task 2: Add `tft_record_iteration()` state management with atomic JSON writes
- [ ] Task 3: Add `tft_check_repeated_failures()` consecutive detection with grace period
- [ ] Task 4: Add `tft_compose_context_section()` markdown generator and `tft_reset()`
- [ ] Task 5: Create `scripts/sw-lib-loop-test-failure-tracker-test.sh` test suite (22+ tests)
- [ ] Task 6: Source module in `scripts/sw-loop.sh` (line ~41)
- [ ] Task 7: Record failures after test gate in `scripts/sw-loop.sh` (line ~2238)
- [ ] Task 8: Add abort check after `check_max_iterations` in `scripts/sw-loop.sh` (line ~2111)
- [ ] Task 9: Reset state on session restart in `scripts/sw-loop.sh` (line ~2485)
- [ ] Task 10: Inject failed test context in `scripts/lib/loop-iteration.sh` `compose_prompt()` (line ~119 + heredoc ~359)
- [ ] Task 11: Register test suite in `package.json`
- [ ] Task 12: Run new test suite and verify all 22+ tests pass
- [ ] Task 13: Run existing loop/convergence/restart test suites — zero regressions
- [ ] Task 14: Run full `npm test` — exit 0

### Task Dependencies

```
Task 1 ──┐
Task 2 ──┤── Task 5 (test suite needs all functions)
Task 3 ──┤
Task 4 ──┘
           │
Task 5 ────┤── Task 12 (run new tests)
           │
Task 6 ────┤
Task 7 ────┤── Task 13 (regression check)
Task 8 ────┤
Task 9 ────┤
Task 10 ───┘
           │
Task 11 ───┤── Task 14 (full suite)
Task 12 ───┤
Task 13 ───┘
```

Tasks 1-4 can be done sequentially in one file write.
Tasks 6-10 can be done in parallel (independent integration points).
Tasks 12-14 are sequential verification.

---

## Testing Approach

### Unit Tests (22+ cases in sw-lib-loop-test-failure-tracker-test.sh)
- **Parser accuracy**: 6 test frameworks × 1 case each = 6 tests
- **State management**: create, append, pass, corruption = 4 tests
- **Consecutive detection**: exact, below, above, gaps, variable setting = 5 tests
- **Grace period**: iter 1, iter 2 = 2 tests
- **Context section**: with failures, no file = 2 tests
- **Reset**: clears state = 1 test
- **Edge cases**: >20 names, special chars = 2 tests

### Regression Tests (existing suites, unmodified)
- `sw-loop-test.sh` — 30+ existing tests must pass
- `sw-convergence-test.sh` — 20 tests must pass
- `sw-session-restart-test.sh` — 12 tests must pass

### Integration Verification
- The new module is guarded by `type ... >/dev/null 2>&1` so if anything fails to load, the loop continues as before — zero regression risk.

---

## Definition of Done

### Functional
- [ ] `tft_extract_test_names()` parses Jest, Pytest, Go test, Vitest, and generic output
- [ ] State file tracks per-test failure history with atomic writes
- [ ] Loop exits with `STATUS="abort_repeated_test_failure"` after 3 consecutive same-test failures
- [ ] Grace period prevents abort in iterations 1-2
- [ ] Non-consecutive failures (gaps in iteration sequence) do NOT trigger abort
- [ ] `compose_prompt()` injects "Previously Failed Tests" section when failures exist
- [ ] State resets cleanly on session restart
- [ ] `loop.abort_repeated_test_failure` event emitted with test names and reason

### Quality
- [ ] 22+ unit tests in dedicated test suite, all passing
- [ ] Zero regressions in sw-loop-test.sh, sw-convergence-test.sh, sw-session-restart-test.sh
- [ ] Full `npm test` exits 0
- [ ] Bash 3.2 compatible (no associative arrays, readarray, ${var,,})
- [ ] Atomic writes via tmp+mv pattern
- [ ] Proper quoting and `jq --arg` for JSON (no string interpolation)
- [ ] `set -euo pipefail` in all new scripts
- [ ] Module guard pattern (`_LOOP_TEST_FAILURE_TRACKER_LOADED`)
- [ ] Graceful degradation on missing module, corrupted state, or empty input

### Integration
- [ ] Module sourced in sw-loop.sh with `|| true` guard
- [ ] Failure recording happens after `write_error_summary()` (line ~2238)
- [ ] Abort check happens after `check_max_iterations` (line ~2111)
- [ ] State reset happens in session restart block (line ~2485)
- [ ] Context injection in `compose_prompt()` heredoc

---

## Alternatives Considered

| Approach | Complexity | Blast Radius | Testability | Chosen? |
|----------|-----------|-------------|------------|---------|
| Extend `diagnose_failure()` | Low | Medium | Low (coupled) | No |
| Add stuckness signal | Medium | Medium-High | Medium | No |
| **New lib module** | **Medium** | **Low** | **High** | **Yes** |

The new module approach wins because it has the lowest blast radius, highest testability, and follows the established `lib/loop-*.sh` pattern. The only downside (one more file) is negligible given the existing 6 loop lib modules.

---

**Plan Version**: 2.0 (refined from v1.0 with exact line numbers and verified integration points)
**Created**: 2026-03-08
**Status**: Ready for build stage
