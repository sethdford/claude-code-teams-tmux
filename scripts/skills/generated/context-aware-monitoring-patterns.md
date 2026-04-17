## Context-Aware Monitoring Patterns

Implement real-time context window monitoring in build loops to prevent exhaustion through automatic threshold-based remediation.

### Architecture

**In-Band Tracking**: Place context monitoring within the loop's main iteration, not as a separate process. Track after each Claude API call completes:
- Tokens used this iteration (input + output from API response)
- Running total since loop start
- Percentage of total window capacity

**Lightweight State**: Store health in a single JSON file, updated atomically after each iteration:
```json
{
  "iteration": 42,
  "tokens_used_total": 125000,
  "tokens_capacity": 200000,
  "percent_used": 62.5,
  "compressed_at_iterations": [20, 35],
  "restart_triggered": false,
  "last_checked_at": "2026-04-17T12:45:30Z"
}
```

**Event Emission**: After each token count update, emit to events.jsonl (one event per check, not per token):
```bash
emit_event "context_health_check" \
  "iteration=$iter" \
  "tokens_used=$used" \
  "percent_used=$pct" \
  "alert_threshold_hit=$alert_hit" \
  "compression_triggered=$comp_triggered"
```

### Threshold Tiers & Remediation

**Three-Tier Response**:
1. **Alert (80% default)**: Emit warning event, dashboard shows yellow gauge; loop continues
2. **Compress (90% default)**: Trigger automatic prompt summarization; redact old iterations from context, keep 3-5 most recent for continuity
3. **Restart (95% default)**: Hard stop — emit event, write checkpoint, exit loop for session restart

**Compression Logic**:
```bash
if (( tokens_used > tokens_capacity * 90 / 100 )); then
  # Summarize iterations 1-N into progress.md
  # Clear function defs, intermediate vars from prompt
  # Re-measure tokens after cleanup
  # If still >85%, escalate to restart
fi
```

**Graceful Degradation**: If reaching 99% before remediation completes, halt new Claude calls immediately. Don't attempt compression when already over limit.

### Integration Points

**Loop Hook**: After each `claude` invocation in loop:
```bash
update_context_health "$current_tokens" "$total_tokens"
if should_compress; then
  trigger_compression
fi
if should_restart; then
  exit_for_restart
fi
```

**Dashboard**: Vitals reads the health file and displays:
- Gauge showing % capacity used (0-100)
- Trend line over last 20 iterations
- Alert badge when >80%, compress badge when >90%
- Last N remediation actions

**Auto-Restart**: Existing restart logic detects `restart_triggered` flag and:
1. Saves progress.md and iteration history
2. Exits current session
3. New session reads checkpoint and continues

### Testing Patterns

1. **Synthetic Thresholds**: Mock large Claude responses (adjust token counts artificially) to hit 80%/90%/95% without real long iteration runs
2. **Metric Accuracy**: Calculate tokens independently from response metadata; verify reported ≈ actual (±5%)
3. **Compression Recovery**: Inject a fake 140k token state, compress, verify drops to <120k
4. **Failure Injection**: Force compression to fail (write-protected file), verify escalates to restart
5. **Threshold Sensitivity**: Run with 60%, 80%, 95% thresholds; find sweet spot preventing exhaustion without excessive restarts
