## Failure Mode Detection & Adaptive Recovery

When the build loop fails, classify the failure mode from error signals and apply mode-specific recovery instead of generic retry. This improves success rate and token efficiency.

### Failure Mode Classification

Each mode has distinct signals in error-summary.json and progress.md:

**1. Context Exhaustion**
- Signal: `iteration_count >= 90% of max_iterations` AND error-summary.json shows same or similar error_line across last 3+ iterations
- Cause: Loop is converging too slowly or hitting a problem it can't solve
- Recovery: Restart with compressed progress briefing (remove verbose logs, keep only key decisions)

**2. Infinite Loop**
- Signal: `same error_line appears in last 5+ iterations` (exact match on file:line from error-summary.json)
- Cause: Loop is stuck in same error, making no progress
- Recovery: Reduce max_iterations by 50%, increase restart threshold to 2 (more likely to restart)

**3. Test Flakiness**
- Signal: `different test failures in consecutive iterations` OR `test passes on retry without code changes`
- Cause: Non-deterministic test failure, not code issue
- Recovery: Rerun same failed test 3 times; accept if 2+ pass (statistical remedy)

**4. Dependency Issue**
- Signal: error-summary.json contains keywords: `module not found`, `failed to resolve`, `Cannot find`, `ENOENT`, `ERR!` (npm/pip/cargo errors)
- Cause: Missing or broken dependency, not code error
- Recovery: Reinstall dependencies (npm ci/pip install --force-reinstall), clear caches, retry loop

**5. Code Error**
- Signal: `unique error_line` (first occurrence, not repeated) or deterministic test failure
- Cause: Legitimate code defect needing actual fix
- Recovery: Continue normal loop iterations; human intervention may be needed if iterations exhaust

### Implementation Pseudocode

```bash
# Parse signals
error_summary=$(cat error-summary.json | jq '.')
error_line=$(echo "$error_summary" | jq -r '.error_line')
error_message=$(echo "$error_summary" | jq -r '.error_message')
iterations=$(grep -c '^## Iteration' progress.md || echo 0)
max_iter=$(jq -r '.max_iterations' < progress.md || echo 100)

# Classify
if (( iterations >= max_iter * 9 / 10 )); then
  same_errors=$(grep "$error_line" progress.md | tail -3 | sort | uniq | wc -l)
  if (( same_errors == 1 )); then
    mode="context_exhaustion"
  fi
fi

if grep "$error_line" progress.md | tail -5 | grep -q .; then
  repeat_count=$(grep "$error_line" progress.md | tail -5 | wc -l)
  if (( repeat_count >= 5 )); then
    mode="infinite_loop"
  fi
fi

if echo "$error_message" | grep -qiE "(module not found|failed to resolve|Cannot find|ENOENT|ERR!)"; then
  mode="dependency_issue"
fi

# Apply recovery
case "$mode" in
  context_exhaustion) compress_progress_briefing; restart_session ;;
  infinite_loop) reduce_max_iterations 50; restart_session ;;
  test_flakiness) rerun_failed_test 3; continue_loop ;;
  dependency_issue) reinstall_deps; clear_caches; continue_loop ;;
  *) mode="code_error"; continue_loop ;;
esac

# Log for observability
emit_event "build_loop_recovery" "mode=$mode" "iteration=$iterations" "max_iterations=$max_iter" "error_line=$error_line"
```

### Testing Each Mode

- **Context Exhaustion**: Create progress.md with 95 iterations of same error; verify restart is triggered
- **Infinite Loop**: Create progress.md where last 5 iterations have identical error_line; verify iteration reduction
- **Test Flakiness**: Mock test that fails iteration 1, passes iteration 2, fails iteration 3; verify rerun recovery
- **Dependency Issue**: Create error-summary.json with "module not found"; verify reinstall is triggered
- **Code Error**: New error_line each iteration; verify loop continues without recovery

### Safety Guardrails

1. **State Preservation**: Always save progress.md and current git state before restart
2. **Retry Budget**: Ensure recovery doesn't exceed total retry limit (track restarts, not just iterations)
3. **False Positive Prevention**: Require 3+ repetitions for infinite_loop, 90% threshold for context_exhaustion
4. **Audit Trail**: Log every classification and recovery action to events.jsonl with timestamp
5. **Fallback**: If recovery strategy itself fails, fall back to generic retry with --max-restarts bump
