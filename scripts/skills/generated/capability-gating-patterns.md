## Capability-Gating Patterns

When a system must improve gradually and refuse work outside proven boundaries, capability gating prevents the death spiral of repeatedly attempting tasks the system can't yet handle.

### Core Principles

**1. Threshold-Based Expansion**
- Define minimum success rate thresholds per task category (e.g., 50% for refactors, 75% for feature delivery).
- Only enable a capability when success rate crosses threshold; disable if it drops below.
- Use hysteresis (e.g., 52% to enable, 48% to disable) to prevent oscillation near boundary.

**2. Conservative Mode Fallback**
- When overall platform success rate < 70%, activate conservative mode: reject all tasks outside a "proven-safe" set (e.g., small bugfixes, documentation updates).
- Conservative mode is not a failure state; it's a recovery mechanism.
- Clearly communicate to users why a task is being rejected: "Feature delivery at 44% success; please retry in conservative mode or wait for improvement."

**3. Registry as Source of Truth**
- Schema: `{ category, subcategory, success_rate, confidence_level, last_updated, sample_count }`.
- Registry is append-only by design; outcomes flow in, aggregations update atomically.
- Support versioning for schema evolution.

**4. Pre-Flight Check Implementation**
- Pre-flight check runs synchronously (latency budget ~10ms) before pipeline intake.
- If check rejects a task, emit an event with reason (low success rate, conservative mode, no data) and offer override path.
- Override should be explicit (`--override-capability-check`) and logged for audit.

**5. Update Consistency**
- Registry updates are triggered by pipeline outcome events, not polling.
- Use atomic compare-and-swap for threshold state to avoid race conditions with concurrent pre-flight checks.
- If a pre-flight check happens during an update, it sees either old or new state, never corrupted intermediate state.

**6. Dashboard Integration**
- Heatmap: rows = categories, columns = success %, color = confidence (green ≥75%, yellow 50-75%, red <50%).
- Allow drill-down: click a category to see recent outcomes, trending, and decisions made.
- Show conservative mode status prominently and reason why it was triggered.

**7. Bootstrap & Cold Start**
- On first run, registry is empty → all checks pass (optimistic until data arrives).
- Populate registry from historical outcomes if available (e.g., from previous runs).
- If no history, start with default thresholds and update as soon as 10 outcomes arrive (to reduce variance).

### Anti-Patterns

- **Brittle Thresholds**: Don't hard-code thresholds; make them configurable per category and adjustable via dashboard.
- **Stale Data**: Don't cache pre-flight decisions for more than 1 minute; registry can change rapidly.
- **Silent Rejection**: Always emit a reason event; users debugging why their task was rejected need clear signals.
- **Override Abuse**: Audit all override flags; if overrides exceed 20% of decisions, alert on possible bypass.

### Example: Refactor Task Gating

```
Registry before:
  { category: "refactor", success_rate: 0.45, confidence: 0.8 }

Outcome: Refactor attempt succeeds

Registry after update:
  { category: "refactor", success_rate: 0.47, confidence: 0.82, sample_count: 150 }

Next pre-flight check for refactor:
  success_rate 0.47 < threshold 0.50 → REJECT
  Message: "Refactors at 47% success. Try again when >50% or use --override-capability-check."

When success_rate crosses 0.50 (after more outcomes):
  ACCEPT (capability now proven)
```
