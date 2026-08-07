## Adaptive Convergence Analysis for Iteration Budgeting

### Overview
When the build loop encounters an issue, historical convergence data (how many iterations similar past issues took to complete) should inform the iteration budget. This skill guides safe extraction of convergence patterns, statistical analysis, and budget recommendation with robust error handling.

### Core Tasks

#### 1. Convergence Data Extraction
- Parse `events.jsonl` for past build-loop runs matching this issue's cohort (same labels, similar file-touch footprint, decompose complexity score within ±1)
- For each historical match, extract `iterations_to_convergence` (when tests passed after nth iteration)
- Handle missing/null fields: skip that record, log the skip
- Degrade gracefully if events.jsonl is missing, empty, or unreadable

#### 2. Statistical Aggregation
- Compute mean, median, and 90th percentile of `iterations_to_convergence` for the cohort
- Flag outliers (3σ above mean) and decide whether to include or exclude them from the budget recommendation
- If cohort has fewer than 3 samples, note "insufficient history" and apply confidence penalty

#### 3. Similarity Scoring
- Score current issue against each historical cohort on three dimensions:
  - **Label overlap**: jaccard(current_labels, historical_labels)
  - **File-touch similarity**: jaccard(current_file_paths, historical_file_paths)
  - **Complexity alignment**: 1 - abs(current_complexity - historical_complexity) / 10
- Weighted sum: `(label_weight * label_score) + (file_weight * file_score) + (complexity_weight * complexity_score)`
- Find the best-matching cohort (highest weighted score ≥ 0.6)

#### 4. Budget Derivation
- If best_match score ≥ 0.7 and cohort has ≥ 5 samples: use 90th percentile + 1 (to avoid starving complex outliers)
- If 0.5 ≤ score < 0.7 and cohort has ≥ 3 samples: use mean + 1 with lower confidence
- If score < 0.5 or cohort has < 3 samples: fall back to static default `--max-iterations`
- Cap recommendation at `max_allowed_iterations` to prevent runaway loops

#### 5. Fallback Strategy
- No events.jsonl: use static default
- Malformed JSON: log error, use static default
- No matching cohort found: use static default
- Empty cohort (< 1 sample): use static default
- All events are errors: use static default

#### 6. Traceability & Logging
- Emit a structured event: `{"type": "build_loop_budget_decision", "issue_id": "...", "matched_cohort": "...", "similarity_score": 0.72, "recommended_iterations": 8, "fallback_used": false, "reasoning": "..."}`
- Include in `progress.md` so fresh sessions (context restart) can see the decision
- On build-loop completion, emit outcome event with `actual_iterations_used` for next run's training data

### Edge Cases & Safety
1. **Division by zero**: Cohort with 0 variance → use mean
2. **NaN/Inf scores**: Clamp to [0, 1] range
3. **Sparse events (< 10 total records)**: Trust outliers less, increase confidence penalty
4. **Events from different Shipwright versions**: May have schema drift; validate required fields before use
5. **Skewed distribution** (e.g., one issue needed 50 iterations, rest ≤ 5): Use median instead of mean for budget, log the choice

### Configuration
```json
{
  "adaptive_iterations": {
    "enabled": false,
    "label_weight": 0.4,
    "file_weight": 0.4,
    "complexity_weight": 0.2,
    "min_sample_threshold": 3,
    "min_cohort_score": 0.6,
    "high_confidence_score": 0.7,
    "max_allowed_iterations": 30,
    "outlier_sigma": 3.0
  }
}
```

### Testing Checklist
- ✓ No history → static default
- ✓ Sufficient clean history (≥5 samples) → adjusted budget with confidence ≥ 0.7
- ✓ Sparse history (1–2 samples) → fallback with warning
- ✓ Malformed events.jsonl → graceful error, static default
- ✓ Missing events.jsonl → static default, no crash
- ✓ Outlier-heavy cohort → median-based budget, logged
- ✓ Low similarity score (< 0.5) → fallback
- ✓ Division by zero (0 variance) → uses mean
- ✓ End-to-end: budget decision logged, acted upon, outcome recorded
