# Design: Adaptive Stage Timeout Engine with P95 Duration-Based Auto-Tuning

## Context

Pipeline stages (build, test, review, etc.) use static timeout defaults (1800s) or per-stage hardcoded values in `daemon-adaptive.sh:105-110`. When a stage exceeds its timeout, the daemon kills it — even if it was progressing normally on a large changeset. Conversely, stages that typically complete in 30s still wait 1800s before timing out on genuine hangs.

**Existing infrastructure we build on:**

- `sw-adaptive.sh:60-73` — `percentile()` function for P-th percentile of sorted arrays via jq
- `sw-adaptive.sh:90-97` — `stddev()` for standard deviation
- `sw-adaptive.sh:99-109` — `confidence_level()` with low/medium/high thresholds
- `sw-adaptive.sh:141-172` — `get_timeout()` that already computes P95 * 1.2 from `stage.completed` events, but scans ALL events on every call (O(n) per invocation, no windowing, no caching)
- `daemon-adaptive.sh:87-132` — `get_adaptive_heartbeat_timeout()` reads pre-aggregated `stage-durations.json`
- `daemon-adaptive.sh:134-191` — `get_adaptive_stale_timeout()` + `record_pipeline_duration()` with rolling 50-entry window and atomic tmp+mv writes
- `pipeline-state.sh:179-217` — `mark_stage_complete()` already records stage duration to SQLite (`record_stage`), memory baselines, and predictive anomaly detection
- `sw-db.sh:183-195` — `pipeline_stages` table already stores `duration_secs` per stage per job
- `dashboard/server.ts:3894` — `/api/metrics/stage-performance` already computes per-stage duration stats from events
- `ADAPTIVE_THRESHOLDS_ENABLED` flag gating all adaptive behavior (checked in 10+ callsites)

**Constraints:**

- Bash 3.2 compatible (no associative arrays, no `${var,,}`)
- All file writes must be atomic (tmp + mv)
- Must degrade gracefully when SQLite is unavailable (JSON fallback)
- Must not break existing pipelines when disabled
- Gated behind existing `ADAPTIVE_THRESHOLDS_ENABLED` flag

## Decision

### Approach: Extend existing `pipeline_stages` table with a materialized aggregation layer

Rather than creating a new `stage_durations` table (which would duplicate data already in `pipeline_stages`), we:

1. **Add a `repo_hash` column** to the existing `pipeline_stages` table (schema v7 migration) and an index for timeout queries
2. **Pre-aggregate P50/P95/P99 per stage** into `~/.shipwright/optimization/stage-durations.json` (which `daemon-adaptive.sh` already reads) on a 7-day interval
3. **Replace the O(n) event scan** in `get_timeout()` with a direct SQLite query bounded by a 30-day window
4. **Wire `resolve_stage_timeout()`** into the pipeline's stage execution with a 5-level override chain

### Component Diagram

```
+---------------------------+     +---------------------------+
|   Pipeline Execution      |     |   Daemon Poll Loop        |
|   (sw-pipeline.sh)        |     |   (daemon-poll.sh)        |
|                           |     |                           |
|  resolve_stage_timeout()--+---->|  trigger_timeout_adjust() |
|  emit_stage_duration()    |     |  (every 7 days)           |
+-----------+---------------+     +----------+----------------+
            |                                |
            | INSERT                         | SELECT + aggregate
            v                                v
+---------------------------+     +---------------------------+
|   SQLite Layer            |     |   Aggregation Layer       |
|   (sw-db.sh)              |     |   (sw-adaptive.sh)        |
|                           |     |                           |
|  pipeline_stages table    |     |  aggregate_stage_durs()   |
|  + repo_hash column (v7)  |     |  calculate_adaptive_to()  |
|  + 30-day window index    |     |  percentile(), stddev()   |
+-----------+---------------+     +----------+----------------+
            |                                |
            | read (fallback)                | atomic write
            v                                v
+---------------------------+     +---------------------------+
|   JSON Fallback           |     |   State Files             |
|   (events.jsonl)          |     |   (stage-durations.json)  |
|                           |     |   (timeout-tuning.json)   |
+---------------------------+     +----------+----------------+
                                             |
                                             | read
                                             v
                                  +---------------------------+
                                  |   Dashboard + CLI         |
                                  |   (server.ts, adaptive)   |
                                  |                           |
                                  |  /api/adaptive/timeouts   |
                                  |  `adaptive show timeouts` |
                                  +---------------------------+
```

### Interface Contracts

```typescript
// --- Data Layer (sw-db.sh) ---

// db_save_stage_duration(job_id, stage, duration_s, result, repo_hash)
// Inserts into pipeline_stages. No-op if SQLite unavailable.
// Errors: silently falls back to event emission only
// Precondition: duration_s is a positive integer
// Postcondition: row exists in pipeline_stages OR event emitted to JSONL

// db_query_stage_durations(stage, repo_hash, window_days) -> JSON array of integers
// Returns sorted duration_secs from pipeline_stages within window.
// Errors: returns "[]" on any SQLite failure
// Postcondition: array is sorted ascending, all values > 0

// --- Aggregation Layer (sw-adaptive.sh) ---

// aggregate_stage_durations(stage, [repo_hash], [window_days=30]) -> JSON object
// Returns: {p50, p95, p99, mean, stddev, samples, last_updated, confidence}
// confidence: "low" (<10), "medium" (10-50), "high" (50+)
// Errors: returns default object with confidence="low", samples=0
// Precondition: SQLite initialized or events.jsonl exists

// calculate_adaptive_timeout(stage, [repo_hash], [--buffer N]) -> integer (seconds)
// Formula: max(P95 * buffer_multiplier, min_timeout_s), clamped to [MIN, MAX]
// Default buffer: 1.2
// Errors: returns stage default (1800) on any calculation failure
// Precondition: aggregate data available (falls back to default if not)

// should_adjust_timeouts() -> 0 (yes) or 1 (no)
// Checks (now - last_adjustment) > 7 days via adaptive-state.json
// Errors: returns 0 (trigger adjustment) if state file missing/corrupt

// trigger_timeout_adjustment() -> void
// Recalculates all stage P95 values, writes stage-durations.json + timeout-tuning-state.json
// Emits adaptation.timeout_adjusted event
// Errors: logs warning, preserves previous state files

// --- Resolution Layer (daemon-adaptive.sh) ---

// resolve_stage_timeout(stage) -> integer (seconds)
// Override chain (highest priority first):
//   1. CLI: --timeout N (via $STAGE_TIMEOUT_OVERRIDE)
//   2. Env: SW_<STAGE>_TIMEOUT (e.g. SW_BUILD_TIMEOUT)
//   3. Config: daemon-config.json .adaptive.stage_overrides.<stage>.timeout_s
//   4. Adaptive: calculate_adaptive_timeout(stage)
//   5. Default: per-stage hardcoded (build=1800, test=900, review=600, etc.)
// Errors: returns default on any resolution failure
// Postcondition: result is always a positive integer in [MIN_TIMEOUT, MAX_TIMEOUT]
```

### Data Flow

```
Stage Completes (pipeline-state.sh:mark_stage_complete)
  |
  +-- [EXISTING] record_stage() -> pipeline_stages table (duration_secs)
  |
  +-- [NEW] emit_stage_duration() -> event: stage.duration_recorded
  |       (adds repo_hash to pipeline_stages row if missing)
  |
  v
Daemon Poll Loop (daemon-poll.sh:daemon_poll_loop, every 10th cycle)
  |
  +-- should_adjust_timeouts()
  |     reads: ~/.shipwright/adaptive-state.json
  |     check: (now_epoch - last_adjustment_epoch) > 604800
  |
  +-- [if YES] trigger_timeout_adjustment()
        |
        +-- For each stage in (intake,plan,design,build,test,review,...):
        |     aggregate_stage_durations(stage)
        |       -> SELECT duration_secs FROM pipeline_stages
        |          WHERE stage_name = ? AND created_at > (now - 30 days)
        |          ORDER BY duration_secs ASC
        |       -> percentile(durations, 95) * 1.2
        |       -> clamp to [min_timeout_s, max_timeout_s]
        |
        +-- Write ~/.shipwright/optimization/stage-durations.json (atomic)
        |     { stages: { build: { p50, p95, p99, timeout_s, samples, confidence } } }
        |
        +-- Write ~/.shipwright/timeout-tuning-state.json (atomic)
        |     { last_adjustment, next_adjustment, stages, metrics }
        |
        +-- Write ~/.shipwright/adaptive-state.json (atomic)
        |     { last_adjustment_epoch: <now> }
        |
        +-- emit_event "adaptation.timeout_adjusted"

  === FAILURE POINTS ===
  [F1] SQLite unavailable -> fallback to jq scan of events.jsonl (existing pattern)
  [F2] No data in 30-day window -> return stage default, confidence="low"
  [F3] jq/bc unavailable -> return hardcoded default 1800
  [F4] Corrupt state file -> treat as "never adjusted", trigger recalc
  [F5] Concurrent daemon instances -> atomic writes prevent corruption;
       last writer wins (acceptable: both compute same P95 from same data)

Next Stage Execution (sw-pipeline.sh)
  |
  +-- resolve_stage_timeout(stage)
        reads: override chain (CLI > env > config > adaptive > default)
        -> integer timeout in seconds
  |
  +-- Execute stage with timeout
```

### Error Boundaries

| Component | Errors Handled | Propagation |
|-----------|---------------|-------------|
| `db_save_stage_duration` | SQLite write failure | Silently log warning; event still emitted to JSONL |
| `db_query_stage_durations` | SQLite read failure, corrupt data | Return `[]`; caller falls back to default |
| `aggregate_stage_durations` | No data, jq failure | Return `{samples: 0, confidence: "low"}`; caller uses default timeout |
| `calculate_adaptive_timeout` | bc unavailable, division errors | Return stage default (1800); log warning |
| `trigger_timeout_adjustment` | File write failure, partial calculation | Log error; preserve previous state files; next cycle retries |
| `resolve_stage_timeout` | Missing function, missing config | Return hardcoded per-stage default; never blocks pipeline |
| Dashboard endpoint | Missing state file | Return `{stages: [], error: "no data yet"}` with 200 |

## Alternatives Considered

### 1. New dedicated `stage_durations` table

**Pros:** Clean schema purpose-built for timeout queries; no risk of breaking existing `pipeline_stages` consumers; simpler window expiry (DELETE WHERE recorded_at < cutoff).

**Cons:** Duplicates data already captured by `record_stage()` in `pipeline_stages` (duration_secs, stage_name, job_id); requires dual-write from `mark_stage_complete()`; increases schema complexity; the `pipeline_stages` table already has 90% of what we need.

**Rejected because:** The existing `pipeline_stages` table already records exactly the data we need. Adding an index and a `repo_hash` column is less invasive than maintaining a parallel table.

### 2. Real-time P95 recalculation on every stage start

**Pros:** Always uses freshest data; no stale cache; no adjustment trigger needed.

**Cons:** O(n) SQLite query on every stage start (n = 30 days of stages, potentially thousands); adds latency to stage startup; wasteful since P95 changes slowly; `percentile()` via jq is not fast on large arrays.

**Rejected because:** P95 values for stage durations change slowly (days/weeks). A 7-day recalculation interval balances freshness vs cost. The pre-aggregated `stage-durations.json` provides O(1) reads at stage start.

### 3. Exponential moving average instead of P95 percentile

**Pros:** Constant memory (single value per stage); trivial to update incrementally; no windowing needed.

**Cons:** Sensitive to outliers (a single 10x spike shifts the average significantly); no confidence metric (can't distinguish "10 data points" from "1000"); doesn't capture tail behavior (a stage that's usually 60s but occasionally 300s needs the P95, not the average).

**Rejected because:** Timeouts must protect against tail latency. P95 naturally captures "the worst non-anomalous case" which is exactly what a timeout should represent. EMA would either timeout too aggressively (low alpha) or not aggressively enough (high alpha).

## Implementation Plan

### Files to create

| File | Purpose |
|------|---------|
| `scripts/lib/db-migration-7.sh` | Schema v7: add `repo_hash` to `pipeline_stages`, add index for timeout queries, 30-day expiry helper |
| `scripts/sw-chaos-timeout-test.sh` | 9 chaos/edge-case tests for timeout engine resilience |

### Files to modify

| File | Change |
|------|--------|
| `scripts/sw-db.sh` | Bump `SCHEMA_VERSION` to 7; add `db_save_stage_duration()`, `db_query_stage_durations()`; source migration-7 |
| `scripts/sw-adaptive.sh` | Add `aggregate_stage_durations()`, `calculate_adaptive_timeout()`, `should_adjust_timeouts()`, `trigger_timeout_adjustment()`; add `show timeouts` subcommand |
| `scripts/lib/daemon-adaptive.sh` | Add `resolve_stage_timeout()` with 5-level override chain |
| `scripts/lib/pipeline-state.sh` | Extend `mark_stage_complete()` to call `emit_stage_duration()` with repo_hash |
| `scripts/lib/daemon-poll.sh` | Add `trigger_timeout_adjustment()` call every 10th poll cycle |
| `dashboard/server.ts` | Add `/api/adaptive/timeout-stats` endpoint reading `timeout-tuning-state.json` |
| `scripts/sw-adaptive-test.sh` | Add 17 unit + integration tests for percentile calculation, override chain, adjustment trigger |

### Dependencies

- None new. Uses existing `jq`, `sqlite3`, `bc` (all already required by Shipwright).

### Risk areas

1. **Schema migration on active databases** — Adding `repo_hash` column to `pipeline_stages` must be nullable (existing rows have no repo_hash). Migration must be safe with concurrent readers (WAL mode helps). Rollback: column is nullable, so it's ignored if feature is disabled.

2. **`bc` dependency for P95 * 1.2** — `bc` may not be installed on minimal systems. Mitigation: fall back to integer arithmetic (`p95 + p95 / 5`) when `bc` is unavailable.

3. **Stale `stage-durations.json` between adjustments** — If pipeline behavior shifts dramatically mid-week (e.g., new slow dependency), timeouts won't adapt for up to 7 days. Mitigation: anomaly detection (P99 + 2*stddev) emits immediate warnings; operators can run `shipwright adaptive train` to force recalculation.

4. **Concurrent daemon instances** — Multiple daemons reading/writing `adaptive-state.json` and `stage-durations.json`. Mitigation: atomic tmp+mv writes (existing pattern throughout codebase); last writer wins is acceptable since both compute from the same underlying data.

5. **JSONL fallback path performance** — When SQLite is unavailable, scanning `events.jsonl` with jq for 30 days of stage events could be slow on large files. Mitigation: existing `db_query_events` already handles this with a limit parameter; accept degraded performance as a fallback-only path.

## Schema Changes

### Forward Migration (db-migration-7.sh)

```sql
-- Add repo_hash to pipeline_stages for per-repo timeout calculation
ALTER TABLE pipeline_stages ADD COLUMN repo_hash TEXT DEFAULT '';

-- Index for efficient timeout queries: stage + time window
CREATE INDEX IF NOT EXISTS idx_pipeline_stages_timeout_lookup
    ON pipeline_stages(stage_name, created_at DESC)
    WHERE duration_secs > 0;

-- Update schema version
INSERT OR REPLACE INTO _schema (version, created_at, applied_at)
    VALUES (7, datetime('now'), datetime('now'));
```

### Rollback Migration

```sql
-- SQLite does not support DROP COLUMN before 3.35.0
-- Safe rollback: just revert schema version; column is ignored when feature disabled
INSERT OR REPLACE INTO _schema (version, created_at, applied_at)
    VALUES (6, datetime('now'), datetime('now'));

-- Drop the index (safe, always works)
DROP INDEX IF EXISTS idx_pipeline_stages_timeout_lookup;
```

**Data backfill:** Not required. New column defaults to `''`. Future `mark_stage_complete()` calls populate it. Historical data contributes to aggregations via the `stage_name` + `created_at` index (repo_hash is optional in queries).

## Idempotency Strategy

| Operation | Idempotency Mechanism |
|-----------|----------------------|
| `db_save_stage_duration` | Delegates to existing `record_stage()` which uses `job_id + stage_name` as natural key; duplicate inserts are harmless (same duration recorded) |
| `trigger_timeout_adjustment` | Keyed on `last_adjustment_epoch` in `adaptive-state.json`; if called twice within 7 days, second call is a no-op via `should_adjust_timeouts()` |
| Schema migration v7 | `ALTER TABLE ... ADD COLUMN` is idempotent in SQLite (fails silently if column exists); wrapped in `IF NOT EXISTS` pattern |
| State file writes | Atomic tmp+mv; concurrent writers produce valid files; content is deterministic from same input data |
| Event emission | Events are append-only to JSONL; duplicates are filtered by consumers via `ts_epoch + type + stage` |

## Rollback Plan

1. **Disable feature:** Set `"adaptive": {"stage_timeout_auto_tuning": {"enabled": false}}` in `daemon-config.json`, or set `ADAPTIVE_THRESHOLDS_ENABLED=false`. All `resolve_stage_timeout()` calls immediately return hardcoded defaults.

2. **Revert code:** Git revert the commit. All new functions are additive; removal has no side effects on existing code paths.

3. **Schema rollback:** Run rollback migration (drop index, revert version to 6). The `repo_hash` column remains but is ignored — SQLite doesn't support `DROP COLUMN` on older versions, and the column being present causes no harm.

4. **Clean state files:** `rm ~/.shipwright/timeout-tuning-state.json ~/.shipwright/adaptive-state.json`. The `stage-durations.json` file is shared with existing `get_adaptive_heartbeat_timeout()` — do NOT delete it.

5. **Verify:** Run `shipwright doctor` — should report clean. Run pipeline — should use default timeouts.

## Validation Criteria

- [ ] `pipeline_stages` table has `repo_hash` column after migration; `SCHEMA_VERSION=7` in `_schema` table
- [ ] `mark_stage_complete()` emits `stage.duration_recorded` event with stage, duration_s, result, repo_hash
- [ ] `aggregate_stage_durations build` returns `{p50, p95, p99, samples, confidence}` matching manual calculation against test data
- [ ] `calculate_adaptive_timeout build` returns `ceil(P95 * 1.2)` clamped to `[60, 7200]` with 50+ samples
- [ ] `calculate_adaptive_timeout` returns stage default when samples < 10 (low confidence)
- [ ] `resolve_stage_timeout` honors override chain: `--timeout 999` > `SW_BUILD_TIMEOUT=500` > config > adaptive > default
- [ ] `should_adjust_timeouts` returns 0 (yes) when state file missing or > 7 days old; returns 1 (no) when < 7 days
- [ ] `trigger_timeout_adjustment` writes valid JSON to `stage-durations.json` and `timeout-tuning-state.json` atomically
- [ ] `shipwright adaptive show timeouts` displays formatted table with Timeout, P95, Samples, Confidence columns
- [ ] `/api/adaptive/timeout-stats` returns valid JSON with per-stage timeout data
- [ ] Anomaly detection emits `anomaly.detected` event when duration > P99 + 2*stddev
- [ ] All functions degrade gracefully when SQLite unavailable (return defaults, log warnings)
- [ ] 10 unit tests PASS (percentile accuracy, bounds clamping, confidence levels, buffer override, empty data, outlier robustness)
- [ ] 7 integration tests PASS (pipeline wiring, override chain, adjustment trigger, atomic writes)
- [ ] 9 chaos tests PASS (DB unavailable, corrupt data, clock skew, anomaly storms, concurrent access)
- [ ] Existing `sw-adaptive-test.sh` tests continue to PASS (backward compatibility)
- [ ] Setting `adaptive.stage_timeout_auto_tuning.enabled = false` causes all timeouts to use defaults (kill switch works)
