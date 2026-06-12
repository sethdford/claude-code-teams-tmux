## Adaptive Timeout Algorithm Design

Design and implement a robust timeout adaptation algorithm that adjusts stage timeouts mid-flight based on historical data and real-time progress signals.

### Percentile Calculation
- Calculate P90 for stages of similar complexity (use complexity bins, not exact matches)
- Require minimum 5 historical samples before using adaptive timeout; fallback to template timeout otherwise
- Handle edge cases: all identical durations, single extreme outlier, Nan/null values
- Exclude the top 1% of durations to avoid skewing from stuck/killed stages

### Complexity Scoring
- Define complexity signals: file count, change size (lines added/deleted), test count, dependency count
- Bucket into categories (low: <50 files, medium: 50-200, high: >200) rather than continuous scoring
- If no historical data for exact bucket, use next-larger bucket as fallback

### Progress Detection
- Track three signals: new commits pushed to branch, test runner activity (test output appearing), file system changes (files written to disk)
- Progress = any signal detected in past 30% of timeout window
- Extend timeout by 50% of original if progress detected (cap at 2x original)
- Log when extension happens: timestamp, old/new timeout, which signals detected

### Stall Detection
- After 90% of timeout elapsed with no progress signals, consider stage stalled
- Before aborting, emit warning event giving stage 10 more seconds to show progress
- Only abort if still stalled at 100% + 10s threshold
- Do NOT kill if file descriptor activity detected (process may be flushing buffers)

### Thread Safety
- Timeout extension reads historical data once at stage start (immutable snapshot)
- Lock the timeout value before modification to prevent race with abort logic
- Store adjustment reason in state for event emission

### Event Emission
- Emit `timeout_adjusted` with keys: old_timeout_seconds, new_timeout_seconds, reason ("progress_detected"), complexity_bucket, p90_percentile_seconds
- Emit `timeout_stall_warning` with 10s countdown if hitting stall threshold
- Emit `timeout_aborted` with final duration_seconds if stage exceeds extended timeout

### Configuration Integration
- daemon-config.json `timeout_overrides.stage_name` takes precedence over calculated timeout
- If override set, use it directly (skip percentile calculation, disable mid-flight extension)
- Log when override applied

### Fallback Logic
- < 5 samples: use template timeout from pipeline config
- > 5 samples: use P90 from historical data
- If complexity bucket has no data, try next-larger bucket (low → medium → high)
- If still no data after climbing buckets, use template timeout
