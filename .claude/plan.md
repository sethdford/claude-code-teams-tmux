# Pipeline Execution Visibility Dashboard — Implementation Plan

## Socratic Design Analysis

### Requirements Clarity
**Minimum viable change:** The analytics infrastructure already exists (`sw-pipeline-analytics.sh`, `sw-db.sh` analytics queries, `dashboard/server.ts` `/api/analytics`, `dashboard/src/views/analytics.ts`). The gap is enriching the data model to support the **metrics attribution framework** — root cause categorization, repo language tracking, stage-level success rates, error pattern aggregation, and std_dev on trends.

**Implicit requirements:**
- The strategic agent (`sw-strategic.sh:259`) already calls `sw-pipeline-analytics.sh --json --period 7` — the output must remain backward-compatible while adding new fields
- `sw-status.sh:244` consumes analytics JSON — its jq filter must continue to work

### Alternatives Considered

**Approach A: Extend existing DB queries + analytics script (CHOSEN)**
- Add new columns to `pipeline_outcomes` for `root_cause_stage`, `root_cause_category`, `repo_language`
- Add new DB query functions for stage-level success rates and error patterns
- Extend `analytics_json()` output with new sections
- Extend dashboard `getAnalytics()` in server.ts
- Extend frontend `analytics.ts` to render new sections
- **Pros:** Minimal blast radius, builds on proven infrastructure, backward-compatible
- **Cons:** Schema migration needed (v6 → v7)

**Approach B: New separate metrics engine**
- Create a new `sw-metrics-attribution.sh` with its own data model
- **Pros:** Clean separation of concerns
- **Cons:** Duplicates existing analytics infrastructure, new integration surface area, more files

**Decision:** Approach A. The existing analytics pipeline covers 70%+ of the acceptance criteria. Extending it is simpler and more maintainable.

### Risk Analysis
1. **Schema migration breaks existing DB** — Mitigated: new columns are nullable, migration code in `sw-db.sh` follows established pattern (v5→v6 already exists as precedent)
2. **JSON output changes break strategic agent** — Mitigated: only additive fields, no removals
3. **Pipeline recording doesn't capture new fields** — Need to update `sw-pipeline.sh` at the exact points where `db_record_outcome()` and `emit_event "pipeline.completed"` are called

---

## User Stories

**Primary:** As a strategic intelligence agent, I want structured JSON metrics showing success rates by template/stage/language/complexity with root-cause attribution, so that I can generate actionable optimization recommendations instead of showing "0/0 pipelines."

**Secondary:** As an ops engineer, I want a terminal + web dashboard showing which stages fail most and why, so that I can prioritize reliability improvements.

### Acceptance Criteria (Given/When/Then)

1. **Given** pipelines have run, **When** I run `shipwright analytics --json`, **Then** I see `by_stage_success_rate` with per-stage pass/reached/rate values
2. **Given** pipelines have failed, **When** I run `shipwright analytics --json`, **Then** `by_stage_failure` includes `common_errors` array with top 3 error patterns per stage
3. **Given** pipeline outcomes recorded with repo language, **When** I view analytics, **Then** I see `by_repo_language` breakdown with success rates
4. **Given** a failed pipeline, **When** `db_record_outcome()` is called, **Then** `root_cause_stage` and `root_cause_category` are populated
5. **Given** 7/30/90 day trend data, **When** I query trends, **Then** each period includes `std_dev` alongside `success_rate`

### Edge Cases
1. **Empty state:** No pipeline data → all sections return empty arrays/zeroes (already handled)
2. **Error state:** SQLite unavailable → falls back to empty JSON (already handled)
3. **Overload state:** Thousands of pipeline runs → queries use LIMIT and cutoff dates (already handled)

---

## What Already Exists

| Component | File | Status |
|-----------|------|--------|
| CLI analytics command | `scripts/sw-pipeline-analytics.sh` | Complete |
| DB analytics queries | `scripts/sw-db.sh:1362-1507` | 6 query functions exist |
| API endpoint | `dashboard/server.ts:2910` (`/api/analytics`) | Complete |
| Frontend view | `dashboard/src/views/analytics.ts` | Complete |
| Test suite | `scripts/sw-pipeline-analytics-test.sh` | 16 tests passing |
| CLI router | `scripts/sw:448` | Registered |
| Status integration | `scripts/sw-status.sh:241-273` | Complete |
| Strategic agent | `scripts/sw-strategic.sh:259` | Consumes analytics JSON |
| `pipeline_outcomes` table | `scripts/sw-db.sh:433` | Schema exists |
| `pipeline_stages` table | `scripts/sw-db.sh:183` | Schema exists |
| `pipeline_runs` table | `scripts/sw-db.sh:162` | Schema exists |

## What's Missing (Gaps vs Acceptance Criteria)

| Gap | Where to Fix |
|-----|-------------|
| No `root_cause_stage` / `root_cause_category` in pipeline_outcomes | DB schema + `db_record_outcome()` + pipeline recording |
| No `repo_language` tracking | DB schema + pipeline recording + new query function |
| No stage-level success rate (pass/reached) | New DB query function |
| No error pattern aggregation in analytics JSON | Extend `db_analytics_by_stage_failure()` |
| No `std_dev` on trend success rates | Extend `db_analytics_trends()` |
| Dashboard doesn't render error patterns or stage success rates | Extend `analytics.ts` + `server.ts` |

---

## Files to Modify

### Core Changes (Backend)
1. **`scripts/sw-db.sh`** — Schema migration v6→v7 (add columns), new query functions, extend existing queries
2. **`scripts/sw-pipeline.sh`** — Pass root_cause_stage, root_cause_category, repo_language to `db_record_outcome()`
3. **`scripts/sw-pipeline-analytics.sh`** — Add new sections to JSON output and terminal dashboard

### Dashboard Changes
4. **`dashboard/server.ts`** — Extend `getAnalytics()` with new query sections
5. **`dashboard/src/views/analytics.ts`** — Render new data sections (stage success rates, error patterns, repo language)

### Test Changes
6. **`scripts/sw-pipeline-analytics-test.sh`** — Add tests for new analytics sections

---

## Implementation Steps

### Step 1: Schema Migration (sw-db.sh)

Add 3 columns to `pipeline_outcomes`:
```sql
ALTER TABLE pipeline_outcomes ADD COLUMN root_cause_stage TEXT;
ALTER TABLE pipeline_outcomes ADD COLUMN root_cause_category TEXT;
ALTER TABLE pipeline_outcomes ADD COLUMN repo_language TEXT;
```

Add to `migrate_schema()` as v6→v7 migration block (following existing pattern at line ~600). Bump `SCHEMA_VERSION=7`.

Update `db_record_outcome()` to accept and store the 3 new fields (positions 9, 10, 11).

### Step 2: New DB Query Functions (sw-db.sh)

Add `db_analytics_by_stage_success(days)`:
```sql
SELECT stage_name, COUNT(*) as reached,
  SUM(CASE WHEN status IN ('complete','completed') THEN 1 ELSE 0 END) as passed,
  ROUND(100.0 * SUM(CASE WHEN status IN ('complete','completed') THEN 1 ELSE 0 END) / COUNT(*), 1) as success_rate
FROM pipeline_stages WHERE created_at >= cutoff
GROUP BY stage_name ORDER BY reached DESC
```

Add `db_analytics_by_repo_language(days)`:
```sql
SELECT COALESCE(repo_language, 'unknown') as language, COUNT(*) as total,
  SUM(success) as successful,
  ROUND(100.0 * SUM(success) / COUNT(*), 1) as success_rate
FROM pipeline_outcomes WHERE created_at >= cutoff
GROUP BY repo_language ORDER BY total DESC
```

Extend `db_analytics_by_stage_failure(days)` to include `common_errors` from `pipeline_stages.error_message` (top 3 distinct errors per stage).

Extend `db_analytics_trends()` to include `std_dev` on success rates per window.

### Step 3: Record Attribution in Pipeline (sw-pipeline.sh)

At pipeline completion (~line 2794), pass additional fields to `db_record_outcome()`:
- `root_cause_stage`: `${CURRENT_STAGE_ID:-}` (already tracked for failures)
- `root_cause_category`: derive from `${LAST_STAGE_ERROR_CLASS:-unknown}` (already exists)
- `repo_language`: detect via `_detect_repo_language()` helper

Add `_detect_repo_language()` that checks: `package.json` → js/ts, `go.mod` → go, `Cargo.toml` → rust, `requirements.txt`/`pyproject.toml` → python, fallback → unknown.

### Step 4: Extend Analytics JSON (sw-pipeline-analytics.sh)

Add to `analytics_json()`:
- `by_stage_success_rate` section
- `by_repo_language` section
- Enhanced `by_stage_failure` with `common_errors` per stage

Add to `analytics_dashboard()`:
- Stage success rate table in terminal output
- Repo language breakdown table

### Step 5: Extend Dashboard Server (dashboard/server.ts)

Extend `getAnalytics()` function (~line 1491) with:
- Stage success rate query
- Repo language query
- Error pattern aggregation in stage failure query
- Std_dev in trend calculations

### Step 6: Extend Dashboard Frontend (dashboard/src/views/analytics.ts)

Add rendering for:
- **Stage Success Rate table:** stage name, reached count, passed count, rate with color coding
- **Repo Language table:** language, total, passed, rate
- **Error Patterns:** under each failure stage row, show top 3 error messages
- Update `AnalyticsData` interface with new fields

### Step 7: Tests (sw-pipeline-analytics-test.sh)

Seed `pipeline_outcomes` with `repo_language`, `root_cause_stage`, `root_cause_category` columns. Add tests:
- `by_stage_success_rate` has entries and correct structure
- `by_repo_language` has entries
- `by_stage_failure` entries include `common_errors`
- `trends.periods` entries include `std_dev`

---

## Task Checklist

- [ ] Task 1: Add schema migration v6→v7 in `sw-db.sh` — 3 new nullable columns on `pipeline_outcomes`
- [ ] Task 2: Update `db_record_outcome()` in `sw-db.sh` to accept `root_cause_stage`, `root_cause_category`, `repo_language`
- [ ] Task 3: Add `db_analytics_by_stage_success()` query function in `sw-db.sh`
- [ ] Task 4: Add `db_analytics_by_repo_language()` query function in `sw-db.sh`
- [ ] Task 5: Extend `db_analytics_by_stage_failure()` to include `common_errors` in `sw-db.sh`
- [ ] Task 6: Extend `db_analytics_trends()` to include `std_dev` in `sw-db.sh`
- [ ] Task 7: Add `_detect_repo_language()` helper and pass attribution data to `db_record_outcome()` in `sw-pipeline.sh`
- [ ] Task 8: Extend `analytics_json()` and `analytics_dashboard()` in `sw-pipeline-analytics.sh` with new sections
- [ ] Task 9: Extend `getAnalytics()` in `dashboard/server.ts` with new query sections
- [ ] Task 10: Extend `analyticsView` in `dashboard/src/views/analytics.ts` to render new data
- [ ] Task 11: Add tests for new analytics sections in `sw-pipeline-analytics-test.sh`
- [ ] Task 12: Run full test suite and fix any failures

---

## Testing Approach

### Test Pyramid
- **Unit tests (8):** DB query functions return correct JSON for seeded data (stage success rates, repo language, error patterns, std_dev, extended outcome recording)
- **Integration tests (4):** Analytics JSON output includes all new sections, terminal dashboard renders new tables, period filtering works with new fields, backward compatibility maintained
- **E2E (1):** Run `sw-pipeline-analytics-test.sh` end-to-end with seeded DB containing all new field values

### Coverage Targets
- All new DB query functions tested with seeded data
- JSON schema validation for all new output fields
- Empty database returns graceful defaults (empty arrays, zero values)
- Backward compatibility: existing JSON consumers (strategic agent, status --json) continue to work

### Critical Test Cases
- **Happy path:** Seeded DB with mix of success/failure across templates, stages, languages → all analytics sections populated with correct values
- **Error case 1:** SQLite unavailable → returns empty defaults
- **Error case 2:** All new columns NULL (pre-migration data) → graceful fallback to 'unknown'
- **Edge case 1:** Single pipeline run → all analytics sections work (no division by zero)
- **Edge case 2:** All pipelines same template → by_template has 1 entry, std_dev = 0

---

## Definition of Done

- [ ] `shipwright analytics --json` returns JSON with all required sections: `summary`, `by_template`, `by_stage_failure` (with `common_errors`), `by_stage_success_rate`, `by_complexity`, `by_repo_language`, `by_hour`, `trends` (with `std_dev`), `active_pipelines`
- [ ] `shipwright analytics` terminal dashboard renders all new sections
- [ ] `db_record_outcome()` records `root_cause_stage`, `root_cause_category`, `repo_language`
- [ ] Pipeline completion in `sw-pipeline.sh` passes attribution data to outcome recording
- [ ] Dashboard web UI (`/api/analytics`) returns enriched JSON
- [ ] Dashboard frontend renders stage success rates, repo language breakdown, error patterns
- [ ] `sw-pipeline-analytics-test.sh` passes with tests covering all new functionality
- [ ] Full test suite (`npm test`) passes
- [ ] Strategic agent consumption path tested (backward compatible JSON)

---

## Task Decomposition with Dependencies

1. **Task 1** (schema migration) — no dependencies, must be first
2. **Task 2** (update db_record_outcome) — depends on Task 1
3. **Tasks 3-6** (new DB queries) — depend on Task 1, can be parallelized
4. **Task 7** (pipeline recording) — depends on Task 2
5. **Task 8** (analytics script) — depends on Tasks 3-6
6. **Task 9** (dashboard server) — depends on Tasks 3-6
7. **Task 10** (dashboard frontend) — depends on Task 9
8. **Tasks 11-12** (tests) — depend on Tasks 8-10

Critical path: 1 → 2 → 3/4/5/6 → 7/8/9 → 10 → 11 → 12

## Endpoint Specification

### `GET /api/analytics?period=7`
- **Request:** Query param `period` (7, 30, or 90)
- **Response (200):** JSON matching `AnalyticsData` interface (see `dashboard/src/views/analytics.ts`)
- **New fields added:**
  - `by_stage_success_rate`: `[{stage_name, reached, passed, success_rate}]`
  - `by_repo_language`: `[{language, total, successful, success_rate}]`
  - `by_stage_failure[].common_errors`: `[string]` (top 3 per stage)
  - `trends.periods[].std_dev`: `number`
- **Error (500):** `{"error": "Analytics computation failed"}`

### `shipwright analytics --json --period N`
- Same JSON structure as `/api/analytics`
- Consumed by `sw-strategic.sh` and `sw-status.sh --json`

### Error Codes
- Exit 0: Success (both terminal and JSON modes)
- Exit 1: Unknown CLI option
- No network errors possible (local SQLite queries only)

### Rate Limiting
- Not applicable (local CLI + dashboard endpoints behind auth)

### Versioning
- Additive-only changes, no breaking API version bump needed
