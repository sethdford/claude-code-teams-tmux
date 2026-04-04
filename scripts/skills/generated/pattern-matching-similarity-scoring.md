# Pattern Matching & Failure Prevention Scoring

## Overview

This skill guides design and implementation of pattern-based proactive failure prevention: matching incoming issues against captured failure patterns, scoring similarity, injecting relevant context, and measuring whether patterns actually prevent repeat failures.

## Similarity Scoring Algorithm (0-100 scale)

For each incoming issue, compute a composite similarity score against each known failure pattern:

### Component 1: Title Similarity (40% weight)
- Fuzzy string matching using token overlap or Levenshtein distance normalized by string length
- Captures semantic closeness of the problem description
- Example: "API timeout on user endpoint" vs "Timeout in auth middleware" → ~0.7 similarity → 28 points

### Component 2: File Overlap (35% weight)
- Compare changed files in original failure vs incoming issue
- Score = (overlapping_files / max(original_files, incoming_files)) * 100
- Files touching the same components are more likely to have similar root causes
- Example: Both touched `scripts/sw-daemon.sh` and `scripts/lib/daemon-dispatch.sh` → 35 points if full overlap

### Component 3: Error Signature Match (25% weight)
- Check if error message substrings or error codes appear in both
- Extract from error-summary.json or stack trace (structured format preferred)
- Example: Both contain "pipefail" or "ENOENT" → 25 points

**Formula: score = (title_score * 0.4) + (file_score * 0.35) + (error_score * 0.25)**

## Injection Thresholds

- **Below 60**: Pattern not relevant, no injection
- **60-80**: Inject with confidence tag ("medium confidence match")
- **80-100**: Inject with high confidence ("strong pattern match")
- **Configurable threshold**: daemon-config.json `memory_pattern_matching.similarity_threshold`

## Proactive Injection Strategy

When score > threshold (at pipeline spawn time, before plan stage):

1. Extract relevant context from memory pattern:
   - Root cause description
   - Applied fix(es)
   - Environment/version context if present
   - What worked vs what didn't

2. Inject into pipeline prompt:
   ```
   Similar pattern found (confidence: 85%): Issue #123 "API timeout on user endpoint"
   Root cause: Unbounded goroutine creation in event loop
   Applied fix: Add semaphore to limit concurrent handlers
   Files affected: scripts/sw-daemon.sh, internal/loop.go
   ```

3. Tag injection metadata:
   - `pattern_id`: which pattern was injected
   - `injection_score`: 0-100 confidence
   - `timestamp`: when injected
   - `source_issue_id`: which failure this pattern came from

4. **Important**: No coercion. Agent can ignore injected pattern if context doesn't match.

## Outcome Tracking

After pipeline completes, record:

```json
{
  "pattern_injected": true,
  "pattern_id": "mem_abc123",
  "injection_score": 85,
  "incoming_issue_id": "456",
  "source_issue_id": "123",
  "failure_occurred": false,
  "failure_type": null,
  "expected_failure_type": "timeout",
  "failure_type_matched": null,
  "failure_prevented": true,
  "confidence_in_prevention": 0.7,
  "notes": "Applied semaphore fix suggested by pattern; no timeout occurred."
}
```

**Caveat**: `failure_prevented` is **inference**, not proof.
- True positive: pattern injected, agent applied the fix, no failure occurred, failure type matched expected type
- Could be false positive: pattern coincidentally matched, but agent's own skill prevented failure
- Always include confidence score; never claim 100% causation

## Effectiveness Metrics (Dashboard)

**Per-pattern metrics:**
- **Success Rate**: (times_injected AND failure_prevented) / times_injected
- **Usage Frequency**: times_injected in last 30 days
- **Confidence Distribution**: histogram of injection_scores
- **False Positive Rate**: (times_injected AND failure_occurred) / times_injected

**Aggregate metrics:**
- **Overall Memory Injection ROI**: sum(successful_injections) / sum(total_injections)
- **Patterns Needing Refinement**: patterns with > 30% usage but < 40% success rate (candidates for root cause re-analysis)
- **Trending**: success rate on 7-day and 30-day windows; alert if trending down
- **Pattern Lifecycle**: which patterns are becoming obsolete (< 1% usage in 90 days)?

## Integration Points

1. **sw-memory.sh**
   - Call `memory_get_patterns()` to retrieve all patterns with timestamps, failure_type, root_cause
   - Call `memory_add_outcome_tracking()` to record success/failure outcome

2. **sw-intelligence.sh**
   - Integrate pattern scoring into `intake` stage
   - Score issue at pipeline spawn time (before plan stage)
   - Return top 3 matching patterns sorted by score

3. **Pipeline prompt composition**
   - Add `memory_pattern_context` section to prompt if score > threshold
   - Include confidence score so agent is aware this is a suggestion, not a fact

4. **Pipeline state tracking**
   - Add `memory_patterns` section to pipeline-state.md with injected pattern details
   - Track injection_score, outcome_recorded=true/false

5. **Loop iteration context**
   - If issue re-runs in build loop, re-score with new error context
   - Emerging error signatures may match different patterns on retry

## Testing Strategy

**Unit tests:**
- Similarity scoring against known issue pairs with ground truth
- Threshold boundary behavior (59, 60, 61)
- Weight adjustment: verify 0.4 + 0.35 + 0.25 = 1.0

**Edge cases:**
- Empty pattern database → score undefined, no injection
- Identical issues with different outcomes → verify both outcomes tracked
- Pattern with malformed error_signature → graceful fallback
- Very high similarity (> 95%) → verify no over-confidence

**Integration tests:**
- Inject pattern, verify it appears in pipeline prompt
- Run build, record outcome, verify outcome_tracking fires
- Query dashboard, verify metrics match recorded outcomes

**Effectiveness validation:**
- Mock a failure type, populate patterns database, run scoring
- Verify pattern was injected at expected score
- Mock outcome (failure_prevented=true/false), verify metrics compute correctly

## Configuration Example

```json
{
  "memory_pattern_matching": {
    "enabled": true,
    "similarity_threshold": 60,
    "weights": {
      "title_similarity": 0.4,
      "file_overlap": 0.35,
      "error_signature": 0.25
    },
    "confidence_tiers": {
      "high": 80,
      "medium": 60,
      "low": 30
    },
    "max_patterns_to_inject": 3,
    "metrics_retention_days": 90,
    "anomaly_detection_enabled": true
  }
}
```

## Risk Mitigation

**Risk 1: False positive injection**
- Monitoring: alert if false_positive_rate > 15%
- Mitigation: lower threshold, disable for specific pattern types, or retire pattern

**Risk 2: Outcome attribution confusion**
- Always show confidence_in_prevention as a float (0.0-1.0), never binary
- Document that "prevented" is inferred, not measured
- Quarterly review of patterns with low confidence

**Risk 3: Circular reasoning**
- Patterns must capture ROOT CAUSE, not just "solution"
- Red flag: if pattern root_cause is identical to another pattern → merge
- Quarterly audit of pattern root_cause quality

**Risk 4: Performance at scale**
- Scoring 100+ patterns should be < 500ms
- Use cached similarity scores if possible
- Parallel scoring if pattern database grows beyond 500

**Risk 5: Stale patterns**
- Patterns from > 180 days ago with < 5 uses → mark for review
- Dashboard should surface "patterns never injected" for root cause analysis
