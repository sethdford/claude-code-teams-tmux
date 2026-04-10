## Health Regression Detection Algorithm Design

### Core Challenge
Detect when system-wide pipeline success rate degrades significantly, but avoid false positives that cause unnecessary rollbacks or cascading failures. Balance sensitivity (catch real regressions) vs. specificity (avoid noise).

### Algorithm Design

**Baseline Tracking**:
- Maintain rolling 7-day and 24-hour success rate windows in `~/.shipwright/health-baseline.json`
- Update only after pipeline completion (not mid-run)
- Store: `{ "baseline_7d": 0.82, "baseline_24h": 0.79, "current_rate": 0.68, "window_size": 42 }`

**Regression Detection**:
- Trigger when: `current_rate < 0.85 * baseline_rate` **AND** this condition holds for **>3 consecutive runs** (not single outlier)
- Rationale: 15% drop is meaningful but not noise; 3-run confirmation prevents false positives from single transient failure
- Edge case: if baseline < 5 runs, use 0.80 multiplier (more conservative when data is sparse)

**False Positive Prevention**:
1. Check run duration variance — if recent runs are exceptionally long, failures may be timeout-related, not intelligence regression
2. Check for infrastructure alerts in same window (CI outages, GitHub API limits) — skip rollback if external factors detected
3. Log rejection reasons: why this was NOT a regression (data too sparse, external factor detected, recovery in progress)

### Rollback Scope & Ordering

Rollback is **dangerous**; only revert auto-generated adaptive state, never user edits:

1. **Intelligence cache** (`~/.shipwright/intelligence-cache.json`): Revert to snapshot from 24h ago
2. **Adaptive overrides** (in-memory state): Clear model routing, timeout adjustments from `sw-adaptive.sh`
3. **User config** (`daemon-config.json`): **DO NOT TOUCH** if modified by user (check mtime)

**Rollback Ordering**:
- Disable intelligence first (stop new bad decisions)
- Clear adaptive state (prevent feedback loops)
- Emit alert event (notify operator)
- Log complete rollback details
- Do NOT kill running pipelines (let them finish)

### Validation Checklist
- [ ] Algorithm correctly identifies regression in test data (80%→55% drop)
- [ ] Does NOT trigger false positive on normal variance (random 3-run dip that recovers)
- [ ] Respects 3-run confirmation window (doesn't trigger on 1-2 outliers)
- [ ] Handles edge case: baseline < 5 runs (uses conservative threshold)
- [ ] Logs all decisions (both triggers and rejections with reasons)
- [ ] Rollback is idempotent (can be called twice safely)
- [ ] Event emission happens regardless of alert delivery (fire-and-forget)

### Integration Points
- Read from: pipeline result stream (success/failure per run)
- Write to: `health-baseline.json` (metrics), `rollback-log.jsonl` (audit trail), event bus
- Interact with: intelligence cache, adaptive config (state to revert)
- Called by: daemon poll loop or pipeline completion hook

### Common Pitfalls
- **Threshold too aggressive** (0.90 multiplier): triggers on normal variance, usefulness destroyed
- **Threshold too lenient** (0.95 multiplier): fails to detect real degradation
- **No time-series awareness**: single drop looks like regression, but system recovering masks it
- **Cascading rollbacks**: if rollback itself causes failures, system could oscillate
- **Missing external factors**: GitHub outage causes failures, rollback doesn't help
