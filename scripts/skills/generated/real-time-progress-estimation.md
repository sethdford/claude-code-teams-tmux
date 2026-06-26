# Real-Time Progress Estimation with ETA Calculation

## Overview

Progress estimation requires three interdependent design decisions: *what data to collect*, *how to aggregate it*, and *when to invalidate the cache*. Most implementations fail on edge cases (no historical data, extreme outliers, stale cache during rapid reruns) or produce estimates that mislead users.

## Core Algorithm: P50/P90 Percentiles

Use **P50 (median)** for the most likely completion time and **P90** for the conservative estimate:

1. **Collect stage durations** from historical runs, grouped by (issue_type, repo_size_bucket, complexity_score)
2. **Filter outliers** using IQR method: keep durations in [Q1 - 1.5×IQR, Q3 + 1.5×IQR]
3. **Calculate P50 and P90** from remaining durations
4. **Estimate total time** = sum of P50 durations for remaining stages
5. **Display both**: "42% complete, ~18 min remaining (P50) / 25 min (P90)"

## Cache Design (24h TTL)

- **Key**: `progress_estimate:<repo_hash>:<issue_type>:<complexity_bucket>:p50|p90`
- **Value**: `{stages: [duration_seconds], collected_at: timestamp, run_count: N}`
- **Invalidation**: Expire 24h after collection OR when new run completes (refresh immediately)
- **Cold start**: With <3 historical runs, show stage count only ("Stage 4 of 9"), no time estimate

## Edge Cases

1. **No historical data**: Disable time estimates, show only "3 of 9 stages complete"
2. **First pipeline of new issue type**: Estimate using closest match (by repo size + complexity)
3. **Extreme outliers**: One 10h run shouldn't break estimates for 2m runs—IQR filtering handles this
4. **Concurrent stage timing**: Use atomic writes to pipeline-state.md with process-safe locking
5. **Cache staleness during rapid reruns**: On stage completion, invalidate related estimates and recalculate
6. **Repo-size sensitivity**: Bucket repos by LOC ranges (0-10k, 10k-100k, 100k-1M, 1M+); estimates per bucket

## Implementation Checklist

- [ ] Extend pipeline-state.md to log `stage_start` and `stage_end` for each stage (atomic writes)
- [ ] Store raw durations in SQLite db under `stage_durations` table (indexed by issue_type, complexity)
- [ ] Add `--estimate` flag to `sw-status` to show progress + ETA (query db and apply P50/P90 calculation)
- [ ] Dashboard real-time update: websocket push P50/P90 as each stage completes
- [ ] Handle 0-data case: return `{progress: N/total, eta_minutes: null}` JSON
- [ ] Test with synthetic data: verify P90 is always >= P50, verify outlier filtering works

## Monitoring & Accuracy

Post-deploy, track `estimate_error = (actual_duration - predicted_duration) / predicted_duration` per pipeline. Target: |error| < 15% for P50, <30% for P90. If accuracy drops below target, disable cache and show stage-count-only estimates until data quality recovers.
