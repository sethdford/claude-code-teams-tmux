## Memory Effectiveness Validation

### Challenge
Measuring pattern effectiveness is harder than it seems. A pattern might appear effective because:
1. It genuinely prevented a failure
2. The failure didn't occur for unrelated reasons
3. The outcome tracking is wrong
4. The issue was different enough that the pattern didn't apply

### Validation Strategy

**Ground Truth Definition**
- Define what "failure prevented" means: test suite passed when it would have failed without injection? Specific error signature didn't occur? Reduced iteration count?
- Ground truth must be measurable from pipeline state (logs, test output, git history) without requiring manual review.

**Outcome Tracking Accuracy**
- After pipeline completes, check: did the specific error type we predicted occur?
- If pattern was injected AND error didn't occur, mark as "potentially prevented."
- If pattern was injected AND error occurred anyway, mark as "ineffective."
- If pattern was NOT injected (score < 60) AND error occurred, mark as "missed opportunity."
- Build confusion matrix: true positives, false positives, true negatives, false negatives.

**Edge Cases to Handle**
- Pattern injected but issue was too simple/different to need it (false positive injection, true negative outcome)
- Multiple patterns injected simultaneously → can't isolate which one helped
- Outcome depends on random factors (flaky tests, timing) → score patterns by success rate, not binary yes/no
- Pattern matches but error signature changed → still track as partial effectiveness

**Scoring Patterns for Refinement**
- Calculate: (pattern_injected AND failure_prevented) / (pattern_injected AND applicable_issue) = true effectiveness
- Calculate: (pattern_not_injected AND failure_occurred) / (pattern_not_injected AND applicable_issue) = detection miss rate
- Flag patterns with low true effectiveness for removal or refinement
- Flag patterns with high miss rates (should have been injected more often)
