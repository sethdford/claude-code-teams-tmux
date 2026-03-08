# Pipeline Tasks — Test Failure Recovery Loop with Smart Iteration Budget Management

## Implementation Checklist
- [ ] Test name extraction with ≥90% accuracy across all frameworks
- [ ] Failed tests tracked per iteration with atomic JSON writes
- [ ] Loop exits with `STATUS="abort_repeated_test_failure"` on 3+ consecutive failures
- [ ] "Previously failed tests" section injected into agent prompt
- [ ] `loop.abort_repeated_test_failure` event emitted with test names
- [ ] Grace period enforced (no abort in iterations 1-2)
- [ ] Non-consecutive failures handled correctly (gaps break streak)
- [ ] Session restart clears tracking state
- [ ] ≥20 test cases covering happy path, errors, edge cases
- [ ] No regressions in existing test suites
- [ ] Graceful degradation on malformed input/JSON corruption
- [ ] <50ms overhead per iteration
- [ ] Bash 3.2 compatible
- [ ] Follows Shipwright shell standards (atomic writes, event logging, proper quoting)
- [ ] Module sourced with proper guards
- [ ] Failure tracking called after `write_error_summary()`
- [ ] Abort check before iteration increment
- [ ] Context section appears in composed prompt
- [ ] Event emitted with proper format
- [ ] Reset function called on session restart

## Context
- Pipeline: autonomous
- Branch: ci/issue-230
- Issue: none
- Generated: 2026-03-08T05:48:35Z
