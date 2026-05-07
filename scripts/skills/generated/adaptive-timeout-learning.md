## Adaptive Timeout Learning from Pipeline History

### Pattern Overview
Adaptive timeouts replace hardcoded values by analyzing historical pipeline performance. Collect successful run durations, compute percentiles (p75/p90/p99), and use these as runtime thresholds with a safety buffer.

### Data Collection Strategy
- Store completed run durations per stage in `.claude/pipeline-artifacts/performance-history.json` or similar
- Maintain a rolling window of last 50 runs per stage (FIFO queue to prevent unbounded growth)
- Record only successful runs (failed runs skew the data and don't represent normal behavior)
- Include run metadata: project type, stage name, duration_ms, timestamp

### Percentile Calculation
```
p75 = 75th percentile of durations
p90 = 90th percentile of durations  
p99 = 99th percentile of durations
adaptive_timeout = p90 + (p90 * 0.20)  # p90 + 20% buffer
```
If < 50 samples: fall back to hardcoded timeout or CLI override.

### Incremental Learning
- After each successful pipeline run, add its stage durations to history
- Recompute percentiles and update `daemon-config.json` adaptive_timeouts section
- Use atomic writes (write to temp file, then `mv`) to prevent corrupted state
- Maintain version number in adaptive_timeouts to detect stale data

### Cold Start Fallback
- If adaptive_timeouts section missing or insufficient data: use hardcoded timeout
- Emit `info` log: "Using hardcoded timeout (15 samples available, 50 required)"
- Do NOT fail—always have a safe fallback

### Anomaly Detection
- During stage execution, if duration > p90: emit `warn` log
- Example: "Build stage exceeded p90 threshold (actual: 45s, p90: 40s)"
- Do NOT auto-adjust timeout mid-run; collect data for next learning cycle
- Track anomaly frequency; if > 20% of runs exceed p90, flag the data as unreliable

### CLI Override
- `--force-timeout <ms>` sets a runtime timeout regardless of adaptive or hardcoded values
- Used for testing and emergency overrides
- Takes precedence over both adaptive and hardcoded timeouts
- Document precedence: CLI flag > adaptive > hardcoded > 30m default

### Edge Cases
1. **High variance stages** (some runs 10s, others 5m): p75+20% may still timeout frequently; monitor anomaly rate and alert if unreliable
2. **New project types**: Insufficient history; fall back to hardcoded until 50 samples collected
3. **Outliers**: One 10m run skews p99 for a normally 1m stage; consider p95 or trimmed mean for better robustness
4. **Concurrent updates**: Multiple pipelines finishing simultaneously; use file locking or atomic operations to prevent race conditions
5. **Corrupted history**: If parsing fails, reset history and fall back; log error for investigation

### Testing Checklist
- ✓ Percentile calculations match expected values (use known datasets)
- ✓ Fallback to hardcoded when < 50 samples
- ✓ CLI override takes precedence
- ✓ Atomic writes don't corrupt config
- ✓ Anomaly warnings emit at p90 threshold
- ✓ History file grows only to 50 runs per stage
- ✓ Works with zero initial history (cold start)
- ✓ Handles NaN/Infinity gracefully
