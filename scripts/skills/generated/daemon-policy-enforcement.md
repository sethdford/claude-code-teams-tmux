## Daemon Policy Enforcement for Pre-Flight Approval

### Policy File Format

Add `cost_policy` section to `.claude/daemon-config.json`:

```json
{
  "cost_policy": {
    "enabled": true,
    "max_estimated_cost_usd": 10.0,
    "min_success_probability": 0.40,
    "min_estimated_confidence": 0.50,
    "escalation_mode": "auto_abort",
    "whitelist_labels": ["critical", "hotfix"],
    "always_allow_labels": ["p0", "security"],
    "dry_run_high_cost": true
  }
}
```

| Field | Default | Behavior |
|-------|---------|----------|
| `enabled` | `false` | Skip cost pre-flight checks if false |
| `max_estimated_cost_usd` | `15.0` | Abort if predicted cost exceeds this |
| `min_success_probability` | `0.35` | Abort if success rate < threshold |
| `min_estimated_confidence` | `0.50` | Require estimation algorithm confidence ≥ this; if lower, ask user or escalate |
| `escalation_mode` | `notify` | `auto_abort` (fail fast), `notify` (log + Slack), `ask` (block until human confirms) |
| `whitelist_labels` | `[]` | Skip cost checks for issues with any of these labels (e.g., `critical`, `hotfix`) |
| `always_allow_labels` | `[]` | Force proceed regardless of cost/success thresholds (e.g., `p0`, `security`) |
| `dry_run_high_cost` | `false` | If true, run in dry-run mode when cost > threshold (don't merge PR, save artifacts) |

### Decision Tree

```
Pre-flight: Estimate cost & success probability
  ↓
1. Has "always_allow_labels" → Proceed (skip all checks)
2. Estimation confidence < min_estimated_confidence → Escalate (notify or ask)
3. Estimated cost > max_cost → Check escalation_mode
   a. auto_abort → Emit error event, exit 1
   b. notify → Log to error-log.jsonl, emit Slack notification, queue issue for later
   c. ask → Block daemon, write issue to .claude/approval-pending.txt
4. Success probability < min_success_probability → Check escalation_mode (same as above)
5. Has whitelist_labels → Skip cost/success checks, proceed
6. All checks pass → Proceed to spawn pipeline
```

### Integration with Daemon

1. Call `sw-predictive.sh` (cost/success estimation) in daemon spawn loop, **before** calling `pipeline start`
2. If pre-flight fails and `escalation_mode=auto_abort`, emit event type `pre_flight_rejection` with reason
3. If `escalation_mode=notify`, post Slack notification: `"Issue #123 estimated $12.50 (threshold $10)—queued for manual review"`
4. If `escalation_mode=ask`, create interactive prompt in tmux or write JSON to `.claude/approval-pending/<issue-id>.json`

### Logging Pre-Flight Decisions

Append to `~/.shipwright/cost-predictions.jsonl` for every issue:

```json
{
  "timestamp": "2026-04-05T12:30:00Z",
  "issue_id": 352,
  "issue_title": "Pre-Flight Cost Estimator",
  "estimated_cost_usd": 6.50,
  "success_probability": 0.68,
  "estimation_confidence": 0.72,
  "signals_triggered": ["multiple_labels", "coverage_low"],
  "decision": "proceed",
  "policy_applied": "default",
  "actual_cost_usd": null,
  "actual_success": null,
  "actual_iterations": null
}
```

After pipeline completes, backfill `actual_*` fields. Track accuracy drift over time.
