## Config Rollback Safety Patterns

Automatic rollback systems prevent operators from unknowingly deploying configs that degrade reliability. But rollback itself can fail, creating cascading problems. Use these patterns to build safe, debuggable rollback logic.

### Threshold & Detection
- **Measure relative change, not absolute value**: Trigger on >10% *relative drop* in success_rate (e.g., 99% → 89%, or 50% → 45% both trigger), not a fixed threshold. Avoids false positives in naturally low-success stages.
- **Rolling window aggregation**: Average metrics over N recent runs (e.g., 5) to filter single transient spikes. Store both current and previous window to compute the delta.
- **Cooldown period**: After rollback fires, disable rollback for 2+ hours to prevent thrashing if the new config needs time to stabilize.
- **Pre-alarm threshold**: Log warnings at 5% degradation so operators notice drift before automatic action.

### Last-Known-Good State
- **Atomic snapshots**: When creating a candidate for rollback, capture: (config content, timestamp, current success_rate, metric samples from this period). Store atomically.
- **Prevent ping-pong**: Track which configs were rolled back and when; add them to a 24-hour blocklist to avoid re-enabling them immediately.
- **Lineage audit log**: Keep a 30-day immutable log of all config changes and rollbacks with reasons.

### Rollback Execution
- **File atomicity**: Write new config to temp file, validate schema, then atomic rename to active location. Never partial writes.
- **Partial rollback support**: If only one stage (e.g., `build`) is degraded, roll back only that stage's config subset, not the entire pipeline config. Requires modular config design.
- **Verify-after wait**: After rollback, don't assume immediate recovery. Wait 5 runs and re-check success_rate before declaring rollback successful.

### Failure Recovery
- **Bounded rollback depth**: Allow rollback of rollback only once (revert to the previous known-good). Prevents infinite recursion if rollback itself is broken.
- **Manual override**: Provide `--disable-auto-rollback` flag for operators to investigate manually when system is misbehaving.
- **Rollback failure alerting**: If rollback is triggered but fails (e.g., last-known-good is corrupted), immediately alert and fall back to read-only mode.

### Validation & Sanity Checks
- **Config schema validation**: Before restoring a rolled-back config, validate it against the schema (not corrupted, all required fields present).
- **Metrics sanity check**: After rollback, verify that new metric samples follow the same statistical pattern as the last-good period (detect data anomalies or collection failures).
- **Staging pre-validation**: Test the entire rollback mechanism (detection, execution, recovery) on staging before enabling in production.

### Observability
- **Structured rollback events**: Log to machine-readable format: trigger reason, config version diff, before/after success_rate, latency of rollback execution, operator notified.
- **Dashboard visualization**: Plot success_rate trend line with rollback markers (vertical lines with reason), and show detection threshold bands.
- **Oscillation detection**: Alert if 3+ rollbacks occur within 1 hour (system thrashing). Page on-call for manual investigation.
