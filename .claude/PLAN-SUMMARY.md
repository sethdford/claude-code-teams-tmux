# Test Failure Recovery Loop: Implementation Plan Summary

**Goal**: Test Failure Recovery Loop with Smart Iteration Budget Management
**Issue**: #230
**Complexity**: 8/10 | **Estimated Effort**: 40-50 hours
**Status**: Ready for implementation

---

## What We're Building

A comprehensive test failure recovery system that:

1. **Detects test failures intelligently**
   - Parses test output from Jest, Pytest, Go, Vitest, npm test
   - Extracts individual test names and failure signatures
   - Distinguishes between assertion failures vs timeouts vs syntax errors

2. **Tracks failure patterns**
   - Records which tests failed in which iterations
   - Detects when the same test fails 3+ consecutive times
   - Identifies context exhaustion vs repeated code errors

3. **Adapts iteration budget dynamically**
   - Base budget: complexity-based (simple=10, medium=15, complex=25)
   - Escalation: +5 iterations per high-impact failure
   - Hard limits: Max 3 escalations (prevent infinite loops)
   - Context-aware: Detect and abort on token exhaustion

4. **Provides smart recovery context**
   - Inject detailed error information into next iteration
   - Show history of previous failures for this test
   - Escalation reason ("repeated failures" vs "high complexity")

---

## Design Decision: Minimal Core + Library

**Why not extend sw-loop.sh directly?**
- Already 2527 lines, would become unmaintainable
- Recovery logic should be testable in isolation
- Follows existing Shipwright pattern: `lib/loop-*.sh`

**Why separate library?**
- Reusable across daemon, fleet, and interactive modes
- Easier to test (unit tests in isolation)
- Graceful degradation if missing
- Clear separation of concerns

**Architecture**:
```
lib/loop-recovery.sh          — Recovery core (300 lines)
  ├─ detect_test_failure()      — Parse test output
  ├─ extract_error_signature()  — Hash/classify errors
  ├─ calculate_smart_budget()   — Adapt iterations
  └─ is_context_exhausted()     — Check token limits

sw-loop.sh                     — Integration points (+50 lines)
  ├─ Source lib/loop-recovery.sh
  ├─ Record failure on test fail
  └─ Check budget & abort if needed

lib/loop-iteration.sh          — Prompt enhancement (+20 lines)
  └─ Inject recovery context into compose_prompt()
```

---

## Task Breakdown: 15 Concrete Tasks

### Phase 1: Recovery Library (Tasks 1-4)

**Task 1**: Create `scripts/lib/loop-recovery.sh` with:
- `detect_test_failure()` — Parse test output
- `extract_error_signature()` — Classify failure type
- `build_error_summary()` — Structure error details
- `is_context_exhausted()` — Token exhaustion check

**Task 2**: Implement budget calculation:
- `calculate_smart_budget()` — Complexity-based formula
- `apply_failure_escalation()` — Increase budget on patterns
- `should_abort_recovery()` — Hard circuit breaker

**Task 3**: Add memory integration:
- `track_failure_pattern()` — Save to memory system
- `get_similar_failures()` — Retrieve past patterns
- `compose_recovery_context()` — Build prompt section

**Task 4**: Create unit test suite (sw-lib-loop-recovery-test.sh):
- Parser tests (5+ formats)
- Budget calculation (10 scenarios)
- Exhaustion detection (5 cases)
- Edge cases (6 tests)
- **Target**: >40 tests, 95%+ pass

### Phase 2: Integration with sw-loop.sh (Tasks 5-7)

**Task 5**: Modify sw-loop.sh:
- Add source for loop-recovery library (~5 lines)
- Update help text (+10 lines)
- Add state tracking variables

**Task 6**: Recovery on test failure:
- After run_test_gate(), call recovery functions
- Record failure signature to state file
- Decide: recover or abort

**Task 7**: Smart budget application:
- Before iteration limit check
- Call calculate_smart_budget()
- Apply escalation if needed
- Update MAX_ITERATIONS dynamically

### Phase 3: Prompt Enhancement (Tasks 8-9)

**Task 8**: Update `lib/loop-iteration.sh`:
- Add recovery context section to compose_prompt()
- Show failure history if available
- List previously failing tests

**Task 9**: State file management:
- Update `.claude/loop-state.md` format
- Track failure signatures
- Record budget adjustments

### Phase 4: Testing & Docs (Tasks 10-15)

**Task 10**: Integration tests (sw-loop-test.sh additions):
- Recovery on test failure
- Circuit breaker stops loop
- Budget escalation works
- No regression in existing tests

**Task 11**: Scenario tests:
- Test fails → recovery → fix → pass
- Repeated failures → budget increase → resolution
- Exhaustion → abort
- Fast recovery (1 iteration)

**Task 12**: Edge cases:
- Large test output (>50KB)
- Corrupted state files
- Missing test command
- Concurrent recovery (multi-agent)

**Task 13**: Performance tests:
- Recovery overhead <2% per iteration
- Budget calculation <100ms
- Error summary <500ms

**Task 14**: Documentation:
- Update help text
- Add `.claude/CLAUDE.md` section
- Example scenarios
- Troubleshooting guide

**Task 15**: Final verification:
- Run full test suite (`npm test`)
- No regressions
- Coverage >85%
- Exit code 0

---

## Files Modified/Created

### New Files:
- `scripts/lib/loop-recovery.sh` (300-400 lines)
- `scripts/sw-lib-loop-recovery-test.sh` (400-600 lines)

### Modified Files:
- `scripts/sw-loop.sh` (+50-100 lines)
- `scripts/lib/loop-iteration.sh` (+20-30 lines)
- `scripts/sw-loop-test.sh` (+200-300 lines)
- `.claude/CLAUDE.md` (documentation section)

---

## Key Features

### 1. Adaptive Iteration Budget
```
Complexity → Base Budget
  - Simple (1-5 files): 10 iterations
  - Medium (6-20 files): 15 iterations  
  - Complex (20+ files): 25 iterations

Escalation on high-impact failures:
  - Consecutive same-test failures: +5 iterations
  - Assertion + timeout pattern: +5 iterations
  - Multiple different tests failing: +3 iterations
  - Max escalations: 3 (hard cap)
```

### 2. Failure Classification
```
- Assertion failure: Low severity (code issue)
- Timeout: High severity (might need more budget)
- Syntax error: Critical (architectural issue)
- Context exhaustion: Abort (not recoverable)
```

### 3. Recovery Context Injection
```markdown
## Recovery Context
Previous iteration failed test: auth.test.js::login
- Failure type: assertion
- Last attempt: iteration 4
- Escalation: budget +5 (repeated pattern)
- Available: 20 iterations remaining
```

### 4. Termination Conditions
```
Loop stops when:
  ✓ LOOP_COMPLETE detected (success)
  ✓ Max iterations + extensions reached
  ✓ Circuit breaker: 3 consecutive low-progress iterations
  ✓ Context exhaustion: token limit hit
  ✓ Repeated test failure 3x consecutive
```

---

## Success Criteria

### Must Have (blocking):
- [ ] Test failure detected correctly (100% accuracy)
- [ ] Recovery context injected properly (no syntax errors)
- [ ] Smart budget adapts (within 2 iterations of optimal)
- [ ] Circuit breaker works (prevents runaway loops)
- [ ] All existing tests pass (zero regressions)
- [ ] >85% code coverage for new functions
- [ ] Performance: <2% overhead per recovery

### Should Have (important):
- [ ] Memory integration optional (graceful degradation)
- [ ] 5+ scenario tests passing
- [ ] Documented with examples
- [ ] User-friendly error messages

### Nice to Have:
- [ ] Multi-agent recovery (worktree mode)
- [ ] Cross-session failure learning
- [ ] Predictive budget (ML-based)

---

## Risk Mitigations

| Risk | Mitigation |
|------|-----------|
| Infinite loop | Hard iteration limit + circuit breaker + exhaustion detect |
| Context window exceeded | Check token count before context injection |
| Regression in loop | All existing tests must pass, new tests isolated |
| State file corruption | Atomic writes (tmp+mv) + JSON validation + reset on error |
| False positive abort | Require 3 *consecutive* failures, grace period, configurable threshold |
| Performance regression | Benchmark <2% overhead before merge |

---

## Timeline

**Week 1**: Tasks 1-4 (Core library + tests)
**Week 1-2**: Tasks 5-9 (Integration + enhancement)
**Week 2-3**: Tasks 10-15 (Full testing + docs)

**Go/No-Go Decision**: After Task 4, if library tests >95% pass, proceed to integration.

---

## Testing Strategy

### Unit Tests (50+ tests):
- Parser accuracy: 6 formats × 3-5 cases = 18 tests
- Budget calculation: 10+ edge cases
- Failure detection: 5+ scenarios
- Exhaustion detection: 5+ cases
- Edge cases: 8+ tests

### Integration Tests (10+ tests):
- End-to-end recovery scenarios
- Circuit breaker activation
- State persistence
- Memory integration
- Multi-agent mode

### Acceptance Tests:
- Failure → Recovery → Fix → Success
- Repeated failures → Budget escalation → Resolution
- Exhaustion → Abort
- No regression in existing loop functionality

---

## Next Steps

1. Read this plan and provide feedback
2. Create lib/loop-recovery.sh with test suite
3. Integrate into sw-loop.sh (minimal changes)
4. Run full test suite
5. Get PR review from maintainer
6. Merge and monitor in daemon mode

---

**Plan Version**: 1.0
**Created**: 2026-03-08
**Status**: Ready for implementation
