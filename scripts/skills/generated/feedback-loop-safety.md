## Feedback Loop Safety in Learning Systems

Post-merge feedback creates a learning loop: production signal → feedback event → memory tag → intelligence adjustment → future decision impact. This cycle can amplify mistakes if feedback is noisy or causality is misattributed.

### Key Principles

**1. Feedback Fidelity**
- Not every CI failure on main = regression caused by this PR
- Use commit history to correlate: was this commit in the failing run? Is the failure new to this commit range?
- Consider time-of-day patterns, test flakiness baseline, environment differences
- Tag confidence: `high` (clear causality), `medium` (probable), `low` (speculative)

**2. Memory Tagging Constraints**
- Never mark an issue pattern as "risky" based on a single feedback event
- Require minimum threshold: 2-3 correlated regressions in similar patterns before boosting scrutiny
- Include decay: old tags become stale (>30 days without recurrence)
- Always log the decision trail: which feedback events triggered this memory tag?

**3. Intelligence Adjustments with Cardinality**
- Intelligence can *boost* iteration count or *flag for review*, but should NOT auto-reject or auto-merge based on regression history
- Require human validation before using regression data to reduce approval gates
- Monitor: do issues marked "risky" actually have more issues post-merge? Measure precision of the signal

**4. Feedback System Failure Modes**
- Webhook delivery can be delayed/duplicated → use idempotency keys and deduplication
- Memory system can be temporarily unavailable → queue feedback events durably, don't lose signals
- Intelligence engine can be slow → feedback updates must not block webhook processing
- Feedback loop can go silent if event creation fails → monitor feedback event creation rate as a health metric

**5. Dashboard Trust**
- Production Health panel shows "regression" status, but make the confidence level visible
- Distinguish between "feedback pending" (data is stale) and "confirmed regression" (multiple signals agree)
- Allow manual override: developers can dispute a regression tag and provide context
- Audit trail: show which feedback events contributed to each regression status

### Implementation Checklist

- [ ] Feedback event schema includes `confidence` field (high/medium/low)
- [ ] Memory tagging logic checks minimum threshold before updating tags
- [ ] Intelligence adjustments are auditable; log the feedback → decision chain
- [ ] Feedback event processing is decoupled from webhook response (async processing)
- [ ] Webhook deduplication via idempotency keys (commit SHA + event type)
- [ ] Memory system can handle eventual consistency (don't require synchronous update)
- [ ] Dashboard shows confidence levels and allows manual dispute
- [ ] Health metrics: feedback event creation rate, memory update latency, intelligence query performance

### Testing

- Test scenario: merge → CI fails → feedback created → memory tagged
- Edge case: webhook delivered twice (same commit, same failure) → deduped, not double-tagged
- Edge case: feedback event lost → retried on next webhook delivery without corruption
- Edge case: memory unavailable → feedback queued locally, processed when memory recovers
