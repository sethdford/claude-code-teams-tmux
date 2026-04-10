# Implementation Plan: Real-Time Success Rate Decomposition Dashboard with Failure Attribution

## Architecture Decision Record

### Context
Currently the overall pipeline success rate (77%) is known but there's no breakdown by stage, error type, template, or time period. The existing `getMetricsHistory()` in `dashboard/server.ts` computes aggregate success/failure counts from `events.jsonl` but doesn't decompose by stage, error category, or template. The CLI has no `metrics` command group.

### Decision
Create a new bash script `sw-metrics.sh` for CLI output and extend `dashboard/server.ts` with a `/api/metrics/success-breakdown` endpoint. The bash script parses `events.jsonl` with `jq` (following the pattern in `sw-dora.sh`). The dashboard server adds a TypeScript function `getSuccessBreakdown()` that reuses the existing `readEvents()` infrastructure.

### Alternatives Considered
1. **SQLite-only approach** — Rejected: would break when SQLite isn't configured; JSONL is the universal fallback
2. **Separate Node.js CLI tool** — Rejected: all CLI scripts are bash; consistency matters
3. **Extend sw-dora.sh** — Rejected: DORA metrics and success decomposition are orthogonal concerns; separate script is cleaner

### Consequences
- New script follows existing patterns (VERSION, helpers.sh, compat.sh, emit_event)
- Dashboard gains a new API route and frontend view
- CLI gets a new `metrics` command group (extensible for future metrics commands)

---

## Component Decomposition

1. **CLI Script** (`scripts/sw-metrics.sh`) — Parses events.jsonl, computes breakdowns, renders tables and ASCII charts
2. **CLI Router** (`scripts/sw`) — Adds `metrics` command routing
3. **Dashboard API** (`dashboard/server.ts`) — New `getSuccessBreakdown()` function and `/api/metrics/success-breakdown` route
4. **Dashboard Frontend** (`dashboard/public/index.html`) — New "Success Breakdown" tab/view
5. **Test Suite** (`scripts/sw-metrics-test.sh`) — Unit tests with mock events data
6. **Event Schema** (`config/event-schema.json`) — No changes needed; existing events have all required fields

---

## Files to Modify

### New Files
1. `scripts/sw-metrics.sh` — CLI command (~400 lines)
2. `scripts/sw-metrics-test.sh` — Test suite (~350 lines)

### Modified Files
3. `scripts/sw` — Add `metrics` to CLI router (2 locations: `route_observe` and main `case`)
4. `dashboard/server.ts` — Add `getSuccessBreakdown()` function and `/api/metrics/success-breakdown` route
5. `dashboard/public/index.html` — Add Success Breakdown tab and view HTML
6. `package.json` — Register test suite in scripts

---

## Implementation Steps

### Step 1: Create `scripts/sw-metrics.sh`

The script structure follows `sw-dora.sh` exactly:
- `set -euo pipefail`, VERSION, SCRIPT_DIR, source compat.sh + helpers.sh
- Fallback definitions for `info()`, `success()`, `warn()`, `error()`, `emit_event()`, color vars
- Subcommand routing: `success-breakdown` (default), `help`
- Flags: `--period <7|30|all>` (default: all), `--json` (machine output)

**Core functions:**

```bash
compute_stage_breakdown()    # jq: group stage.completed + stage.failed by stage name
compute_error_breakdown()    # jq: group stage.failed + pipeline.failed by error/error_class field
compute_template_breakdown() # jq: group pipeline.started (has template) joined with pipeline.completed/failed
compute_trends()             # jq: bucket by day for 7d, week for 30d, month for all-time
find_worst_combination()     # jq: cross-tabulate stage x template failure rates
```

**Event parsing pattern** (from sw-dora.sh):
- Read `~/.shipwright/events.jsonl`
- Filter by `ts_epoch` for time windows (7d, 30d, all)
- Use `jq -s` for array operations (group_by, map, select)

**Error categorization logic:**
- `error_class` field if present (already emitted by retry.classified events)
- Heuristic from `error` field: "timeout" -> timeout, "test" -> test_failure, "context" -> context_exhaustion, "rate limit|API|401|403" -> api_error, else -> unknown

### Step 2: Register in CLI Router (`scripts/sw`)

Add `metrics` command in two places:

1. In `route_observe()` (line ~216), add `metrics` case and update help text.
2. In `main()` case statement, add top-level shortcut:
   ```bash
   metrics)
       exec "$SCRIPT_DIR/sw-metrics.sh" "$@"
       ;;
   ```

### Step 3: Dashboard API (`dashboard/server.ts`)

Add a `getSuccessBreakdown()` function near `getMetricsHistory()` (~line 1489). It reuses `readEvents()` and returns:

```typescript
interface SuccessBreakdown {
  overall: { success: number; failed: number; rate: number };
  by_stage: Array<{ stage: string; success: number; failed: number; rate: number }>;
  by_error: Array<{ category: string; count: number; pct: number }>;
  by_template: Array<{ template: string; success: number; failed: number; rate: number }>;
  trends: {
    daily_7d: Array<{ date: string; rate: number; count: number }>;
    weekly_30d: Array<{ week: string; rate: number; count: number }>;
  };
  worst_combination: { stage: string; template: string; rate: number; sample_size: number } | null;
}
```

**Logic:**
- Iterate events once, collecting:
  - `pipeline.started` -> record template per job_id
  - `pipeline.completed` / `pipeline.failed` -> overall counts, per-template counts
  - `stage.completed` / `stage.failed` -> per-stage counts
  - `stage.failed` -> extract error category from `error_class` or `error` field
- Cross-reference job_id from stage events to pipeline.started template
- Compute rates, sort by failure rate descending
- Find worst stage x template combination (minimum 3 samples)

Add route after `/api/metrics/history`:
```typescript
if (pathname === "/api/metrics/success-breakdown") {
  const period = parseInt(url.searchParams.get("period") || "0");
  return new Response(JSON.stringify(getSuccessBreakdown(period)), {
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}
```

### Step 4: Dashboard Frontend (`dashboard/public/index.html`)

Add a tab button in the `#tab-bar` nav and a corresponding view section. The view will:
- Fetch `/api/metrics/success-breakdown?period=7` on load
- Render 4 sections: stage breakdown table, error category bar chart, template comparison, trend sparklines
- Use inline SVG for simple bar charts (no external deps -- follows existing dashboard pattern)
- Period selector buttons (7d / 30d / All)
- Highlight worst combination with warning styling

### Step 5: Create Test Suite (`scripts/sw-metrics-test.sh`)

Following `sw-dora-test.sh` pattern:
- Setup: create temp dir, write mock events.jsonl with known data
- Test cases:
  - Script loads without error
  - Help output includes expected text
  - `success-breakdown` with mock events produces correct stage counts
  - `--period 7` filters events to last 7 days
  - `--json` outputs valid JSON
  - Error categorization works for each category
  - Empty events file produces zeros gracefully
  - Worst combination calculation with insufficient data returns "N/A"
  - Template breakdown correctly joins pipeline.started with pipeline.completed
  - Trend bars render correctly

### Step 6: Register Test in `package.json`

Add to the `scripts` section and aggregate test runner.

---

## Task Checklist

- [ ] Task 1: Create `scripts/sw-metrics.sh` with header, VERSION, helpers, subcommand routing, and `--help`
- [ ] Task 2: Implement `compute_stage_breakdown()` -- parse stage.completed/stage.failed events with jq
- [ ] Task 3: Implement `compute_error_breakdown()` -- categorize errors from stage.failed/pipeline.failed events
- [ ] Task 4: Implement `compute_template_breakdown()` -- join pipeline.started (template) with pipeline.completed/failed
- [ ] Task 5: Implement `compute_trends()` -- daily buckets for 7d, weekly for 30d, monthly for all-time
- [ ] Task 6: Implement `find_worst_combination()` -- cross-tabulate stage x template with minimum sample threshold
- [ ] Task 7: Implement ASCII chart rendering and formatted table output
- [ ] Task 8: Add `--json` flag for machine-readable output
- [ ] Task 9: Register `metrics` command in CLI router (`scripts/sw`) in both route_observe and main case
- [ ] Task 10: Add `getSuccessBreakdown()` function in `dashboard/server.ts`
- [ ] Task 11: Add `/api/metrics/success-breakdown` route in `dashboard/server.ts`
- [ ] Task 12: Add Success Breakdown view in `dashboard/public/index.html` with tab, charts, and period selector
- [ ] Task 13: Create `scripts/sw-metrics-test.sh` with comprehensive test coverage
- [ ] Task 14: Register test in `package.json` and verify all tests pass

---

## Endpoint Specification

### `GET /api/metrics/success-breakdown`

**Query Parameters:**
- `period` (optional, integer): Number of days to analyze. 0 = all-time (default). Max 365.

**Response (200 OK):**
```json
{
  "overall": { "success": 154, "failed": 46, "rate": 77.0 },
  "by_stage": [
    { "stage": "test", "success": 160, "failed": 40, "rate": 80.0 }
  ],
  "by_error": [
    { "category": "timeout", "count": 18, "pct": 39.1 }
  ],
  "by_template": [
    { "template": "fast", "success": 45, "failed": 5, "rate": 90.0 }
  ],
  "trends": {
    "daily_7d": [{ "date": "2026-04-03", "rate": 85.0, "count": 12 }],
    "weekly_30d": [{ "week": "2026-W14", "rate": 78.0, "count": 45 }]
  },
  "worst_combination": { "stage": "test", "template": "autonomous", "rate": 55.0, "sample_size": 20 }
}
```

**Error Codes:**
- 200: Success (always returns valid JSON, even with empty data -- zeros throughout)
- No authentication required (dashboard is local-only)

**Rate Limiting:** Not applicable -- local dashboard server.

**Versioning:** No versioning needed -- internal API, not public.

---

## Testing Approach

### Test Pyramid Breakdown
- **Unit tests (12 tests)**: Script loading, help output, each computation function (stage/error/template/trend/worst), JSON output, empty data handling, period filtering, error categorization
- **Integration tests (3 tests)**: CLI router dispatches `metrics success-breakdown`, dashboard API returns valid JSON, full pipeline from events to CLI output
- **E2E tests (1 test)**: Write events, run CLI, verify output matches expected breakdown

### Coverage Targets
- 90% line coverage on `sw-metrics.sh` computation functions
- All 5 error categories tested
- All time periods (7d, 30d, all) tested
- Edge cases: empty events, single event, events with missing fields

### Critical Paths to Test
- **Happy path**: 50+ mock events across stages/templates -> correct breakdown tables
- **Error case 1**: events.jsonl doesn't exist -> graceful "No events found" message
- **Error case 2**: Events with missing `error_class`/`error` fields -> categorized as "unknown"
- **Edge case 1**: All events are successful -> 100% rate, empty error breakdown
- **Edge case 2**: Only 1 event per stage x template -> worst combination requires minimum 3 samples, shows "N/A"

---

## Performance Considerations

### Baseline Metrics
- Current `readEvents()` reads last 1000 lines from events.jsonl -- fast enough for dashboard
- `jq -s` loads full filtered set into memory -- acceptable for <10K events
- CLI execution should complete in <2s for typical event volumes

### Optimization Targets
- CLI response time <2s for 10K events
- Dashboard API response time <500ms (cached by readEvents limit)

### Profiling Strategy
- Not applicable for initial implementation -- pure observability feature with no hot paths
- If events.jsonl grows beyond 100K lines, consider SQLite-first path (already supported by readEvents)

### Benchmark Plan
- Skipped for initial implementation -- the feature reads existing data with jq, performance risk is low
- Monitor actual response times via emit_event after launch

---

## Failure Mode Analysis

### 1. Runtime Failure: Malformed JSON Lines in events.jsonl (CRITICAL)
**Impact:** jq parsing errors could crash the script under `set -e`.
**Mitigation:** Use `jq -R 'fromjson? // empty'` to silently skip malformed lines (same pattern as readEvents in server.ts which uses try/catch per line). This is the most critical failure mode -- addressed by using jq's error-tolerant parsing in every jq invocation.

### 2. Runtime Failure: events.jsonl Missing or Empty
**Impact:** CLI shows no data, dashboard returns zeros.
**Mitigation:** Check file existence first, return zero-initialized response. The script will display "No pipeline events found. Run some pipelines first." with exit 0.

### 3. Scale Risk: Very Large events.jsonl (>100K lines)
**Impact:** `jq -s` loading entire file into memory could be slow or OOM.
**Mitigation:** For CLI, use `tail -n 10000` to cap input (most recent events are most relevant). For dashboard, `readEvents()` already caps at 1000 lines. Document this limitation.

### 4. Concurrency Risk: events.jsonl Being Written While Reading
**Impact:** Could read a partial line at the end.
**Mitigation:** jq's `fromjson? // empty` handles partial lines gracefully. No write operations, so no corruption risk.

### 5. Rollback Story
**Impact:** Zero risk -- this adds new files and extends existing ones with additive changes only.
**Rollback:** Delete `sw-metrics.sh` and `sw-metrics-test.sh`, revert 3 lines in `scripts/sw`, revert dashboard additions. No data migration, no schema changes.

---

## Definition of Done

- [ ] `shipwright metrics success-breakdown` outputs a formatted table showing stage, error, and template breakdowns
- [ ] `shipwright metrics success-breakdown --json` outputs valid JSON matching the API schema
- [ ] `shipwright metrics success-breakdown --period 7` correctly filters to last 7 days
- [ ] Dashboard `/api/metrics/success-breakdown` returns correct JSON response
- [ ] Dashboard has a "Success Breakdown" view accessible from the tab bar
- [ ] Worst-performing stage x template combination is identified and highlighted
- [ ] Test suite passes with all planned test cases
- [ ] All existing tests continue to pass (`npm test`)
- [ ] Script follows all Shipwright conventions (VERSION, set -euo pipefail, Bash 3.2 compat, helpers.sh)
