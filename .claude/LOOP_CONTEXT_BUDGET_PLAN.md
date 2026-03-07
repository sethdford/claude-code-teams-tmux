# Implementation Plan: Loop Context Window Budget Monitor

## Executive Summary

Build a proactive context window budget monitoring system for `sw-loop.sh` that tracks token consumption in real-time and automatically compresses iteration state when approaching context limits. This prevents context exhaustion during multi-iteration builds and enables graceful degradation.

---

## Requirements Clarity & Design Rationale

### What is the Minimum Viable Change?

The core requirement is to **detect approaching context exhaustion and trigger auto-summarization before memory fills**. This means:

1. **Real-time token estimation** per iteration (not just end-of-loop totals)
2. **Threshold detection** (warn at 70%, trigger summarization at 80%)
3. **Progress.md compression** that maintains critical state while reducing size
4. **Iteration-level budget reporting** to inform users of remaining context

### Implicit Requirements (from codebase analysis)

- Must not break existing session restart capability
- Must preserve error-summary.json (required for error recovery)
- Must work with multi-agent/worktree mode
- Must integrate with existing `loop-progress.sh`, `loop-restart.sh` modules
- Must support resuming after auto-summarization

### Acceptance Criteria

✓ Tracks cumulative tokens consumed per iteration
✓ Calculates remaining context window %
✓ Warns when >= 70% budget consumed
✓ Triggers auto-summarization when >= 80% consumed
✓ Auto-summarization compresses iteration history by ≥50% without losing critical state
✓ Loop resumes with fresh context after summarization
✓ All token data persists to loop-tokens.json
✓ Existing tests pass (no regression)
✓ New module testable in isolation

---

## Alternatives Considered & Trade-offs

### Alternative 1: Inline Monitoring in sw-loop.sh (Rejected)

**Approach**: Add all budget checking logic directly in main loop function.

**Trade-offs**:
- ✓ Simplicity: No new files
- ✓ Performance: No function call overhead
- ✗ Complexity: Adds ~200 LOC to already large script (2471 lines)
- ✗ Maintainability: Mixes concerns (iteration control + budget management)
- ✗ Testability: Cannot test budget logic in isolation
- ✗ Blast radius: Changes to main loop function risk breaking core iteration logic

**Verdict**: Too risky given sw-loop.sh's critical role. Context management is distinct enough to warrant a module.

### Alternative 2: Extend sw-cost.sh (Rejected)

**Approach**: Reuse existing cost tracking in sw-cost.sh, call it per iteration.

**Trade-offs**:
- ✓ Reuses proven token extraction logic
- ✓ Centralized cost tracking
- ✗ sw-cost.sh is global (tracks all CLI calls), not loop-specific
- ✗ Loop-specific thresholds would pollute global cost system
- ✗ Would require significant refactoring of sw-cost.sh
- ✗ Loss of clarity (cost ≠ context window)

**Verdict**: Cost system is for budgeting/spending; context system is for memory. Different purposes warrant separate modules.

### Alternative 3: New Separate Module (Chosen ✓)

**Approach**: Create `lib/loop-context-budget.sh` sourced by sw-loop.sh.

**Trade-offs**:
- ✓ Separation of concerns: Budget logic isolated
- ✓ Testability: Functions can be tested independently
- ✓ Maintainability: Single-purpose module, easy to extend
- ✓ Reusability: Other scripts can source if needed
- ✓ Minimal blast radius: No changes to core loop logic
- ✓ Follows existing pattern (other lib/loop-*.sh modules)
- ✗ One additional file to maintain
- ✗ Slight performance overhead (one extra source + function calls)

**Verdict**: Best choice. Follows existing codebase patterns, enables testing, minimal risk.

---

## Risk Analysis

### Risk 1: Inaccurate Token Estimation

**What could break**: Budget calculations diverge from reality; summarization triggers too early or too late.

**Mitigation**:
- Use conservative multiplier (1.35x) for token estimates (accounts for tokenizer variance)
- Compare estimates against actual Claude API counts from logs
- Store per-iteration estimates in loop-tokens.json for post-hoc analysis
- Set thresholds conservatively (70% warn, 80% summarize)
- Test with known token counts

### Risk 2: Summarization Data Loss

**What could break**: Auto-summarized progress loses critical error context or file change history, breaking subsequent iterations.

**Mitigation**:
- Preserve error-summary.json completely (never summarize)
- Keep recent commits (last 10) in full
- Keep recent changed files (last 20) in full
- Archive full progress.md before summarization to .claude/loop-logs/progress-archive/
- Log summarization event with before/after sizes

### Risk 3: Premature Summarization Blocks Real Work

**What could break**: Loop summarizes when work is nearly complete, causing unnecessary restart.

**Mitigation**:
- Set 80% threshold (not 75%), giving 20K tokens headroom
- Only summarize if iteration > 3 (avoid early summarization)
- Check if last 2 iterations show convergence before summarizing
- Log "context budget alert" warnings 5K and 10K tokens before limit

### Risk 4: Interaction with Restart Mechanism

**What could break**: Auto-summarization + session restart both compress state, causing conflicts.

**Mitigation**:
- Make summarization idempotent (can be called multiple times safely)
- Session restart reads compressed progress.md without issue (documented format)
- Preserve timestamp chain (show when compression occurred)
- Test restart after summarization explicitly

### Risk 5: Performance Regression

**What could break**: Per-iteration token counting adds measurable overhead.

**Mitigation**:
- Only extract tokens from existing log files (no new API calls)
- Use efficient grep/jq (no loops)
- Cache results in variables between checks
- Benchmark: <10ms per check target

---

## Task Decomposition

All tasks must be completed in order (dependencies listed). Critical path: Task 1 → 2 → 3 → 4 → 5 → 6 → 10 → 11.

### Phase 1: Core Module Development

#### Task 1: Create lib/loop-context-budget.sh Module Foundation
**Depends on**: Nothing
**Blocks**: Tasks 2–5

Create the new module with standard headers, helpers, and initialization.

#### Task 2: Implement Token Extraction & Accumulation
**Depends on**: Task 1
**Blocks**: Task 3

Extract real token counts from Claude logs and maintain cumulative totals per iteration.

#### Task 3: Implement Budget Checking & Threshold Detection
**Depends on**: Task 2
**Blocks**: Task 5

Calculate context window usage and detect warning/critical thresholds.

#### Task 4: Implement Progress.md Compression Logic
**Depends on**: Task 1
**Blocks**: Task 5

Compress iteration history while preserving critical state.

#### Task 5: Integrate Module into sw-loop.sh
**Depends on**: Tasks 2–4
**Blocks**: Task 6

Wire budget checking into main loop iteration flow.

### Phase 2: Testing

#### Task 6: Create Comprehensive Test Suite
**Depends on**: Task 5
**Blocks**: Task 7

Write unit tests for all budget module functions.

#### Task 7: Integration Test with Real Loop
**Depends on**: Task 6
**Blocks**: Task 10

Test budget monitoring in an actual multi-iteration loop.

### Phase 3: Robustness & Documentation

#### Task 8: Handle Edge Cases & Error Scenarios
**Depends on**: Task 7
**Blocks**: Task 9

Add defensive code for unusual conditions.

#### Task 9: Documentation & User Guidance
**Depends on**: Task 8
**Blocks**: Task 10

Update CLAUDE.md and add user-facing help.

#### Task 10: Update Version & Change Log
**Depends on**: Task 9
**Blocks**: Task 11

Version bump and release notes.

#### Task 11: Merge & Deploy
**Depends on**: Task 10
**Blocks**: Nothing

Merge changes to main and verify CI passes.

---

## Files to Modify / Create

| File | Type | LOC | Purpose |
|------|------|-----|---------|
| `scripts/lib/loop-context-budget.sh` | NEW | ~350 | Core module: token tracking, budget checking, summarization |
| `scripts/sw-loop.sh` | MODIFY | ~50 | Source module, call budget functions each iteration |
| `scripts/sw-lib-loop-context-budget-test.sh` | NEW | ~400 | Unit tests for budget module |
| `scripts/sw-loop-context-budget-integration-test.sh` | NEW | ~300 | E2E test with real loop |
| `.claude/CLAUDE.md` | MODIFY | ~50 | Add context management section |
| `CHANGELOG.md` | MODIFY | ~20 | Document new feature |
| `package.json` | MODIFY | ~5 | Add test scripts, bump version |

---

## Task Checklist

- [ ] Task 1: Create module foundation
- [ ] Task 2: Implement token extraction
- [ ] Task 3: Implement budget checking
- [ ] Task 4: Implement progress compression
- [ ] Task 5: Integrate into sw-loop.sh
- [ ] Task 6: Write unit tests
- [ ] Task 7: Write integration test
- [ ] Task 8: Handle edge cases
- [ ] Task 9: Document
- [ ] Task 10: Version & changelog
- [ ] Task 11: Merge & deploy

---

## Testing Approach

### Unit Testing
- Mock log files with known token counts
- Verify each function in isolation
- Test boundary conditions (0 tokens, max tokens, exactly at thresholds)

### Integration Testing
- Spin up temporary git repo
- Run short loop (5 iterations)
- Inject mock token counts
- Verify budget warnings appear
- Verify progress.md compression happens
- Check output format

### Regression Testing
- Run existing loop test suite
- Verify no changes to normal loop behavior
- Check that budget monitoring is transparent

### Manual Testing
- Run loop with real Claude on test repo
- Watch budget warnings appear
- Trigger summarization by manipulating thresholds
- Verify resumed session continues normally

---

## Definition of Done

✓ **Feature Complete**
- [ ] Real-time token tracking per iteration
- [ ] Budget percentage calculation
- [ ] Warning at 70%, summarization at 80%
- [ ] Progress.md compression preserving critical state
- [ ] Archive previous state before compression
- [ ] Graceful degradation on missing logs

✓ **Well Tested**
- [ ] Unit tests for all functions (>90% coverage)
- [ ] Integration test with mock loop
- [ ] Edge case handling (missing files, malformed JSON, overruns)
- [ ] No regressions in existing loop tests

✓ **Well Documented**
- [ ] CLAUDE.md updated with context management section
- [ ] Help text in loop command
- [ ] Code comments explaining compression logic
- [ ] Example output showing budget reports

✓ **Production Ready**
- [ ] Version bumped consistently
- [ ] CHANGELOG updated
- [ ] All CI tests passing
- [ ] Code review completed
- [ ] Merged to main

---

## Success Metrics

- **Token accuracy**: Estimates within 20% of actual Claude API counts
- **Threshold reliability**: Budget warnings/summarization occur within ±5% of target thresholds
- **Compression effectiveness**: Progress files reduced by ≥50% while remaining usable
- **Zero data loss**: No critical errors lost; full archives available if needed
- **Performance impact**: <20ms per budget check (negligible vs. Claude API call time)
- **User experience**: Budget reports clear and actionable; auto-summarization transparent

---

## Implementation Notes

### Design Decisions

1. **Separate Module Approach**: Created `lib/loop-context-budget.sh` following existing pattern of loop sub-modules (`loop-progress.sh`, `loop-restart.sh`, etc.)

2. **Conservative Thresholds**: 70% warning, 80% summarization provides 20K token headroom before hard limit

3. **Preservation Strategy**: Full archives before compression allow recovery if needed; error-summary.json untouched

4. **Token Extraction**: Reuse existing Claude log parsing (jq + grep fallback) to ensure consistency

5. **Idempotency**: Summarization can be called multiple times safely; no state conflicts with session restart

### Integration Points

- Sourced by `sw-loop.sh` after other loop modules
- Called each iteration after Claude execution
- Respects existing progress.md format
- Compatible with session restart mechanism
- Works with multi-agent/worktree mode

