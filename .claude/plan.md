# Design: Pipeline telemetry collector for missing metrics

## Context

The Shipwright pipeline emits 30+ structured event types (`stage.started`, `stage.completed`, `loop.iteration_start`, `cost.record`, `prediction.validated`, `convergence.*`, `vitals.snapshot`, etc.) via the canonical `emit_event()` function (`scripts/lib/helpers.sh:62-119`). Events dual-write to `~/.shipwright/events.jsonl` and the SQLite `events` table.

However, the SQLite `metrics` table (`scripts/sw-db.sh:226-237`) — which has a proper schema with `metric_type`, `metric_name`, `value`, `period`, `unit`, `tags`, and a `job_id` FK to `pipeline_runs` — has **never been populated**. Events are write-only with zero aggregation. This means:

- No per-stage duration or success-rate tracking
- No loop iteration count or convergence analysis
- No cost breakdowns by stage/model (only raw `cost_entries`)
- No prediction accuracy calibration over time
- No queue wait-time measurement
- No vitals health trend persistence

The `sw-otel.sh` script reads events and produces Prometheus-format output but does not persist to the DB. The `sw-instrument.sh` script writes to JSON files in `.claude/pipeline-artifacts/`, not to the metrics table. The `sw-pipeline-vitals.sh` computes ephemeral health scores without persistence. There is currently no single script that bridges the event stream to the metrics table.

**Constraints**:

- Bash 3.2 compatibility required (no associative arrays, no `readarray`, no `${var,,}`)
- Must follow `set -euo pipefail` and existing output helpers (`info()`, `success()`, `warn()`, `error()`)
- Must use the existing `metrics` table schema — no DDL changes
- Must use the established consumer offset pattern (`db_get_consumer_offset` / `db_set_consumer_offset` in `sw-db.sh:766-779`) for incremental processing
- Must degrade gracefully when SQLite is unavailable (the `db_available` guard pattern)
- Must be idempotent — re-running collection on the same events must not create duplicates

## Decision

Create a new `scripts/sw-telemetry.sh` script that acts as a **batch consumer** of the event stream, aggregating raw events into the existing `metrics` table. The design follows the established consumer-offset pattern already in `sw-db.sh` rather than introducing real-time streaming or a separate aggregation database.

### Data Flow

```
emit_event() → events table (SQLite) + events.jsonl
                    │
     ┌──────────────┴───────────────┐
     │  sw-telemetry.sh collect     │  (batch, idempotent)
     │  consumer_id = "telemetry"   │
     │  reads events since offset   │
     │  writes to metrics table     │
     │  advances consumer offset    │
     └──────────────┬───────────────┘
                    │
            metrics table (SQLite)
                    │
     ┌──────────────┼───────────────┐
     │              │               │
  telemetry      telemetry       sw-dora.sh
    show           report        sw-adaptive.sh
                                 (future consumers)
```

### Seven Collectors

Each collector is an independent function that reads events of specific types and writes metric rows:

| Collector                     | Source Events                                                                                | metric_type   | metric_name examples                                              | unit                         |
| ----------------------------- | -------------------------------------------------------------------------------------------- | ------------- | ----------------------------------------------------------------- | ---------------------------- |
| `collect_stage_metrics`       | `stage.started`, `stage.completed`, `stage.failed`                                           | `stage`       | `stage.duration_s`, `stage.success_rate`                          | `seconds`, `ratio`           |
| `collect_loop_metrics`        | `loop.iteration_start`, `loop.iteration_complete`, `loop.restart`, `loop.stuckness_detected` | `loop`        | `loop.iterations_total`, `loop.exit_reason`, `loop.restart_count` | `count`, `category`, `count` |
| `collect_cost_metrics`        | `cost.recorded`                                                                              | `cost`        | `cost.per_stage_usd`, `cost.per_model_usd`, `cost.per_issue_usd`  | `usd`                        |
| `collect_prediction_metrics`  | `prediction.validated`, `risk.outcome`                                                       | `prediction`  | `prediction.accuracy`, `prediction.calibration`                   | `ratio`, `score`             |
| `collect_queue_metrics`       | `pipeline.started`, `daemon.spawn`                                                           | `queue`       | `queue.wait_time_s`, `queue.depth_at_start`                       | `seconds`, `count`           |
| `collect_convergence_metrics` | `convergence.tests_passed`, `convergence.stuck`, `convergence.plateau`                       | `convergence` | `convergence.pass_rate`, `convergence.stuck_rate`                 | `ratio`, `ratio`             |
| `collect_vitals_metrics`      | `vitals.snapshot`                                                                            | `vitals`      | `vitals.health_score`, `vitals.momentum`, `vitals.convergence`    | `score`, `score`, `score`    |

### Storage Pattern

All metrics use the existing schema with no modifications:

```sql
INSERT OR REPLACE INTO metrics
  (job_id, metric_type, metric_name, value, period, unit, tags, created_at)
VALUES (?, ?, ?, ?, 'run', ?, ?, datetime('now'));
```

- `job_id`: Links to `pipeline_runs.job_id` when available, NULL for cross-run aggregates
- `tags`: JSON string for dimensional metadata, e.g. `{"stage":"build","issue":"42"}`
- `period`: `run` for per-pipeline metrics, `daily` for rolled-up aggregates
- Idempotency via `INSERT OR REPLACE` keyed on `(job_id, metric_type, metric_name, tags)`

### Consumer Offset Pattern

```bash
collect_all() {
    local offset
    offset=$(db_get_consumer_offset "telemetry")
    local events
    events=$(_db_query "SELECT id, type, payload FROM events WHERE id > ${offset} ORDER BY id ASC;")

    # ... run all 7 collectors against the event batch ...

    local max_id
    max_id=$( ... extract max event id from batch ... )
    db_set_consumer_offset "telemetry" "$max_id"
}
```

This ensures:

- Each event is processed exactly once (at-most-once delivery with idempotent writes)
- Incremental processing — only new events since last run
- Resume after crash — offset only advances after successful write

### Error Handling

- **SQLite unavailable**: Skip DB writes, log warning via `warn()`, exit 0 (non-fatal). The `db_available` guard is checked at entry. No JSONL fallback for metrics — the metrics table is the canonical store.
- **Malformed event payload**: Skip individual event, emit `warn()`, continue processing. Count skipped events in summary.
- **Empty event stream**: No-op with `info()` message. Exit 0.
- **Concurrent execution**: SQLite WAL mode handles concurrent reads. The consumer offset pattern prevents duplicate processing. No file locking needed beyond what SQLite provides.

### CLI Subcommands

```
shipwright telemetry collect   # Scan events, aggregate into metrics table
shipwright telemetry show      # Display collected metrics by type
shipwright telemetry gaps      # Identify missing metrics for recent runs
shipwright telemetry report    # One-page telemetry health dashboard
shipwright telemetry help      # Usage
```

### Pipeline Integration

A single non-intrusive call at the end of `sw-pipeline.sh` after the `emit_event "pipeline.completed"` block (~line 2420):

```bash
# Collect telemetry metrics from this run
if [[ -x "$SCRIPT_DIR/sw-telemetry.sh" ]]; then
    bash "$SCRIPT_DIR/sw-telemetry.sh" collect 2>/dev/null || true
fi
```

The `|| true` ensures telemetry failures never block the pipeline.

## Alternatives Considered

1. **Real-time aggregation in `emit_event()` itself** — Pros: metrics available instantly, no batch delay. Cons: adds latency to every event emission (30+ call sites), violates single-responsibility of `emit_event()`, failures in aggregation could block pipeline execution. The current `emit_event()` is already dual-writing (JSONL + SQLite) and adding a third write path risks cascading failures.

2. **Extend `sw-otel.sh` to write to the metrics table** — Pros: reuses existing event-to-metric parsing logic. Cons: `sw-otel.sh` is designed for external observability export (Prometheus format), coupling it to internal DB persistence would conflate concerns. Its output format (Prometheus text exposition) doesn't map cleanly to the metrics table schema. Better to keep OTEL as an export adapter and telemetry as an internal aggregator.

3. **Use a cron/daemon background process for continuous collection** — Pros: near-real-time metrics, no pipeline dependency. Cons: adds operational complexity (another daemon to manage), potential race conditions with pipeline writes, harder to test. The batch-at-pipeline-completion approach is simpler and sufficient — metrics don't need to be real-time since they're consumed by `sw-adaptive.sh` and `sw-dora.sh` which run periodically.

4. **Write metrics to JSONL files instead of SQLite** — Pros: simpler, no SQLite dependency. Cons: the `metrics` table already exists with proper schema and indexes (`idx_metrics_job_id`, `idx_metrics_type`), JSONL would make range queries and aggregation expensive, and it would leave the metrics table permanently empty — defeating the purpose.

## Implementation Plan

- **Files to create**:
  - `scripts/sw-telemetry.sh` (~600 lines) — Telemetry collector with 7 metric collectors, 4 CLI subcommands
  - `scripts/sw-telemetry-test.sh` (~350 lines) — Full test suite

- **Files to modify**:
  - `scripts/sw` — Add `telemetry)` case to the main dispatch (~line 400-500 area, alongside `eventbus`, `cost`, `otel`)
  - `scripts/sw-pipeline.sh` — Add post-completion telemetry collect call (~line 2420, after `emit_event "pipeline.completed"`)
  - `package.json` — Append `&& bash scripts/sw-telemetry-test.sh` to the `test` script chain

- **Dependencies**: None. Uses only existing `sw-db.sh` functions (`db_available`, `_db_exec`, `_db_query`, `db_get_consumer_offset`, `db_set_consumer_offset`) and `lib/helpers.sh` (`emit_event`, `info`, `warn`, etc.).

- **Risk areas**:
  - **Consumer offset correctness**: If the script crashes between writing metrics and advancing the offset, events will be re-processed on next run. Mitigated by `INSERT OR REPLACE` idempotency — re-processing is safe, just wasteful.
  - **Event payload parsing**: Events use space-delimited `key=value` pairs (not JSON). Parsing must handle missing keys, empty values, and special characters. The `jq` dependency is already present (used pervasively) for any JSON `tags` fields in the payload.
  - **Performance on large event backlog**: First run on a repo with thousands of unprocessed events could be slow. Mitigated by processing in batches (1000 events at a time) and the consumer offset ensuring subsequent runs are incremental.
  - **Bash 3.2 array limitations**: Cannot use associative arrays for grouping events by job_id. Must use `jq` for grouping or process events sequentially.

## Validation Criteria

- [ ] `shipwright telemetry collect` reads events from SQLite (or events.jsonl fallback) and writes rows to the `metrics` table — verified by `SELECT count(*) FROM metrics` returning > 0 after seeding test events
- [ ] Consumer offset advances correctly — running `collect` twice on the same event set produces identical metric counts (no duplicates)
- [ ] Each of the 7 collectors produces at least one metric row for its event type when given valid input events
- [ ] `shipwright telemetry show` displays metrics grouped by type with human-readable formatting
- [ ] `shipwright telemetry gaps` correctly identifies pipeline runs that have `pipeline.completed` events but no corresponding metrics
- [ ] Graceful degradation: when SQLite is unavailable (`db_available` returns false), the script exits 0 with a warning, no crash
- [ ] Malformed events are skipped with a warning, not fatal — collection continues for remaining events
- [ ] Pipeline integration (`sw-pipeline.sh`) calls telemetry collect without blocking on failure (`|| true` guard)
- [ ] Script passes `bash -n` syntax check and follows all project conventions (`set -euo pipefail`, `VERSION` variable, Bash 3.2 compatible)
- [ ] Test suite (`sw-telemetry-test.sh`) has 15+ assertions covering all subcommands, edge cases (empty events, no DB, duplicate runs), and all 7 collector categories
- [ ] `npm test` passes with no regressions to existing 100+ test suites
