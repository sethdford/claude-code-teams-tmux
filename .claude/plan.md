# Pipeline Execution Visibility Dashboard — Implementation Plan

## Socratic Design Refinement

### Requirements Clarity

**Minimum viable change**: A new `sw-pipeline-analytics.sh` script that queries the existing SQLite database (`pipeline_runs`, `pipeline_stages`, `pipeline_outcomes`, `events` tables) to compute success rate breakdowns and attribution analytics, with `--json` output for strategic agent consumption, plus a new dashboard API endpoint and frontend tab.

**Implicit requirements**:
- Must work with zero data (empty state) — the strategic agent currently shows 0/0
- Must query SQLite (primary) with JSONL fallback (backward compat)
- JSON output must be stable for machine consumption by the strategic agent
- Must integrate with the existing `observe` command group

**Acceptance criteria** (from issue):
1. Dashboard shows current active pipelines with stage progress
2. Success rate metrics broken down by: template, stage, repo language/type, issue complexity, time of day
3. Failure attribution: which stage fails most, common error patterns
4. JSON export consumable by strategic agent
5. Historical trend graphs (7/30/90 day windows)
6. Integration with `shipwright status` and `shipwright dashboard`

### Design Alternatives

**Approach A — New standalone script + dashboard API endpoint**
- Create `sw-pipeline-analytics.sh` with pure SQLite queries
- Add `/api/analytics` endpoint to `dashboard/server.ts`
- Add "Analytics" tab to dashboard frontend
- Pros: Clean separation, testable in isolation, follows existing patterns
- Cons: New file, but minimal blast radius

**Approach B — Extend existing `sw-pipeline-vitals.sh` and `sw-dora.sh`**
- Add attribution analytics into vitals and DORA
- Pros: Fewer files
- Cons: Makes already large files bigger (vitals=1076 lines, dora=605 lines), mixes concerns (health scoring ≠ attribution analytics), harder to test

**Approach C — Pure dashboard-only (TypeScript in server.ts)**
- All analytics computed in the dashboard server
- Pros: Single language, richer computation
- Cons: No CLI access, strategic agent can't consume without dashboard running, breaks bash-first pattern

**Decision: Approach A** — New script + API endpoint. Follows the established pattern (each command = one script), keeps blast radius minimal, provides both CLI and dashboard access.

### Risk Assessment

| Risk | Impact | Mitigation |
|------|--------|------------|
| Empty database returns nulls/errors | Strategic agent crashes | Default all aggregations to 0, return empty arrays |
| SQLite queries slow on large datasets | Dashboard lag | Use indexed columns, LIMIT clauses, pre-computed windows |
| Schema changes break queries | Analytics fail | Query only existing tables/columns, no schema migrations needed |
| Time-of-day breakdown may be misleading | Wrong optimization | Use UTC consistently, document timezone |

### Dependency Analysis

**Depends on (all existing)**:
- `scripts/sw-db.sh` — SQLite query functions
- `scripts/lib/helpers.sh` — colors, emit_event
- `dashboard/server.ts` — REST API framework
- `dashboard/public/index.html` — frontend tabs

**Depended on by (new consumers)**:
- `scripts/sw-strategic.sh` — will import analytics JSON
- `scripts/sw-status.sh` — will show summary metrics
- Dashboard frontend — new tab

No circular dependency risks.

---

## User Stories

**Primary**: As an operations engineer running Shipwright pipelines, I want to see success rate breakdowns by template, stage, and complexity so that I can identify which pipeline configurations need improvement.

**Secondary**: As the strategic intelligence agent, I want machine-readable analytics JSON so that I can make data-driven optimization recommendations instead of showing 0/0 pipelines.

**Tertiary**: As a team lead, I want to see failure attribution (which stage fails most, common error patterns) so that I can prioritize reliability improvements.

### Acceptance Criteria (Given/When/Then)

1. **Given** the database has pipeline run records, **When** I run `shipwright analytics`, **Then** I see success rate, failure attribution, and trend data in formatted terminal output.
2. **Given** the database has pipeline run records, **When** I run `shipwright analytics --json`, **Then** I get a stable JSON structure with all breakdowns.
3. **Given** the database is empty, **When** I run `shipwright analytics`, **Then** I see "No pipeline data found" with zero counts (no errors).
4. **Given** the dashboard is running, **When** I visit the Analytics tab, **Then** I see success rates, failure stage distribution, and trend charts.
5. **Given** pipeline data exists, **When** `sw-strategic.sh` calls `sw-pipeline-analytics.sh --json`, **Then** it receives actionable metrics.

### Edge Cases

1. **Empty state**: Zero pipeline runs → all metrics return 0, arrays empty, no division-by-zero
2. **Overload state**: 10,000+ pipeline runs → queries use LIMIT, only return top-N breakdowns
3. **Partial data**: Runs with null template/complexity → categorized as "unknown"

---

## Architecture Decision Record

### Component Diagram

```
┌─────────────────────────────────────────────────────────┐
│                    CLI / Terminal                        │
│  shipwright analytics [--json] [--period 7|30|90]       │
└───────────────────────┬─────────────────────────────────┘
                        │
┌───────────────────────▼─────────────────────────────────┐
│          sw-pipeline-analytics.sh  (NEW)                │
│  ┌──────────┐ ┌───────────┐ ┌──────────┐ ┌──────────┐  │
│  │ Summary  │ │ Breakdown │ │ Failure  │ │  Trends  │  │
│  │ Metrics  │ │ by attr.  │ │ Attrib.  │ │ 7/30/90d │  │
│  └────┬─────┘ └─────┬─────┘ └────┬─────┘ └────┬─────┘  │
│       └──────────────┴───────────┴─────────────┘        │
│                       │  SQLite queries                  │
└───────────────────────┼─────────────────────────────────┘
                        │
┌───────────────────────▼─────────────────────────────────┐
│              sw-db.sh  (EXISTING)                       │
│  pipeline_runs │ pipeline_stages │ pipeline_outcomes     │
│  events        │ cost_entries    │ memory_failures       │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│          dashboard/server.ts  (EXTEND)                  │
│  GET /api/analytics?period=7  → calls analytics queries │
└───────────────────────┬─────────────────────────────────┘
                        │
┌───────────────────────▼─────────────────────────────────┐
│       dashboard/public/index.html  (EXTEND)             │
│  New "Analytics" tab with charts & tables                │
└─────────────────────────────────────────────────────────┘
```

### Interface Contracts

```typescript
// GET /api/analytics?period=7|30|90
interface AnalyticsResponse {
  period_days: number;
  generated_at: string;  // ISO 8601
  summary: {
    total_runs: number;
    successful: number;
    failed: number;
    success_rate: number;  // 0-100 float
    avg_duration_secs: number;
    total_cost_usd: number;
  };
  by_template: Array<{
    template: string;
    total: number;
    successful: number;
    failed: number;
    success_rate: number;
    avg_duration_secs: number;
  }>;
  by_stage_failure: Array<{
    stage_name: string;
    failure_count: number;
    pct_of_failures: number;
    common_errors: string[];  // top 3
  }>;
  by_complexity: Array<{
    complexity: string;  // "low" | "medium" | "high" | "unknown"
    total: number;
    successful: number;
    success_rate: number;
  }>;
  by_hour: Array<{
    hour: number;  // 0-23 UTC
    total: number;
    successful: number;
    success_rate: number;
  }>;
  trends: {
    periods: Array<{
      label: string;  // "7d" | "30d" | "90d"
      total: number;
      success_rate: number;
      avg_duration_secs: number;
    }>;
  };
  active_pipelines: Array<{
    job_id: string;
    issue_number: number;
    goal: string;
    template: string;
    current_stage: string;
    started_at: string;
    elapsed_secs: number;
    stages_completed: string[];
  }>;
}
```

```bash
# sw-pipeline-analytics.sh CLI interface
# Usage: shipwright analytics [--json] [--period DAYS] [--active]
# Outputs: formatted terminal table (default) or JSON (--json)
# Exit: 0 always (analytics is informational)
```

### Data Flow

1. **CLI path**: User runs `shipwright analytics --json --period 30` → `sw-pipeline-analytics.sh` → SQLite queries via `sw-db.sh` → JSON to stdout
2. **Dashboard path**: Browser → `GET /api/analytics?period=7` → `dashboard/server.ts` reads SQLite directly → JSON response → frontend renders charts
3. **Strategic agent path**: `sw-strategic.sh` calls `sw-pipeline-analytics.sh --json` via command substitution → parses JSON for recommendations

### Error Boundaries

- `sw-pipeline-analytics.sh`: Catches all SQLite errors, returns zero-value defaults. Never exits non-zero.
- `dashboard/server.ts /api/analytics`: Returns `{ error: "..." }` with 500 status on failure. Frontend shows "Analytics unavailable" message.
- Frontend: Handles empty/null fields gracefully, shows "No data" states.

---

## Files to Modify

### New Files
1. **`scripts/sw-pipeline-analytics.sh`** — Core analytics engine (~400 lines)
2. **`scripts/sw-pipeline-analytics-test.sh`** — Test suite (~300 lines)

### Modified Files
3. **`scripts/sw`** — Add `analytics` command routing (2 lines)
4. **`scripts/sw-db.sh`** — Add analytics query functions (~80 lines)
5. **`dashboard/server.ts`** — Add `/api/analytics` endpoint (~60 lines)
6. **`dashboard/public/index.html`** — Add Analytics tab UI (~100 lines)
7. **`scripts/sw-status.sh`** — Add pipeline analytics summary to `--json` output (~15 lines)
8. **`scripts/sw-strategic.sh`** — Consume analytics JSON instead of raw event counting (~20 lines)
9. **`package.json`** — Add test suite to test command (~1 line)

---

## Implementation Steps

### Step 1: Add analytics query functions to `sw-db.sh`

Add these functions to `scripts/sw-db.sh`:
- `db_analytics_summary(days)` — Total/success/failed counts, avg duration, total cost
- `db_analytics_by_template(days)` — Grouped by template
- `db_analytics_by_stage_failure(days)` — Which stages fail most, with error patterns
- `db_analytics_by_complexity(days)` — Grouped by complexity from `pipeline_outcomes`
- `db_analytics_by_hour(days)` — Grouped by hour of day
- `db_analytics_trends()` — 7/30/90 day windows
- `db_analytics_active()` — Currently running pipelines

All queries use existing indexed columns. Join `pipeline_runs` with `pipeline_stages` and `pipeline_outcomes`.

### Step 2: Create `sw-pipeline-analytics.sh`

Core script with:
- Standard boilerplate (VERSION, set -euo pipefail, source helpers)
- `analytics_summary()` — Calls db functions, formats output
- `analytics_json()` — Calls db functions, assembles JSON via jq
- `analytics_dashboard()` — Colored terminal output with boxed tables
- `main()` — Parse `--json`, `--period`, `--active` flags
- Handle empty state gracefully

### Step 3: Register in CLI router

Add to `scripts/sw`:
- Add `analytics` to `route_observe()` group
- Add `analytics` as direct command in `main()` case statement

### Step 4: Add `/api/analytics` endpoint to dashboard server

Add to `dashboard/server.ts`:
- New route `GET /api/analytics?period=7`
- Read from SQLite directly (same db the server already uses)
- Return `AnalyticsResponse` JSON

### Step 5: Add Analytics tab to dashboard frontend

Add to `dashboard/public/index.html`:
- New tab button in navigation
- Analytics panel with: summary cards, template breakdown table, stage failure chart, hourly distribution, trend sparklines
- Fetch from `/api/analytics` on tab activation
- Auto-refresh every 30 seconds when tab is active

### Step 6: Integrate with `sw-status.sh`

Add analytics summary (total runs, success rate, top failing stage) to the `--json` output under an `analytics` key.

### Step 7: Update `sw-strategic.sh` to consume analytics

Replace the manual event counting in the strategic agent with a call to `sw-pipeline-analytics.sh --json`, parsing the structured output.

### Step 8: Create test suite

Create `scripts/sw-pipeline-analytics-test.sh`:
- Test empty database (zero data)
- Test with seeded pipeline_runs/stages/outcomes
- Test JSON output structure
- Test period filtering (7/30/90 days)
- Test template/stage/complexity breakdowns
- Test active pipeline listing
- Register in `package.json` test command

---

## Task Checklist

- [ ] Task 1: Add analytics query functions to `sw-db.sh` (db_analytics_summary, db_analytics_by_template, db_analytics_by_stage_failure, db_analytics_by_complexity, db_analytics_by_hour, db_analytics_trends, db_analytics_active)
- [ ] Task 2: Create `scripts/sw-pipeline-analytics.sh` with terminal and JSON output modes
- [ ] Task 3: Register `analytics` command in CLI router (`scripts/sw`)
- [ ] Task 4: Add `/api/analytics` endpoint to `dashboard/server.ts`
- [ ] Task 5: Add Analytics tab UI to `dashboard/public/index.html`
- [ ] Task 6: Integrate analytics summary into `sw-status.sh --json` output
- [ ] Task 7: Update `sw-strategic.sh` to consume analytics JSON
- [ ] Task 8: Create `scripts/sw-pipeline-analytics-test.sh` test suite
- [ ] Task 9: Register test suite in `package.json`
- [ ] Task 10: Run full test suite and fix any regressions

---

## Testing Approach

### Test Pyramid Breakdown

- **Unit tests** (12 tests): All in `sw-pipeline-analytics-test.sh`
  - Empty database returns zero values (2 tests)
  - Seeded data returns correct breakdowns (4 tests: template, stage, complexity, hour)
  - JSON output validates with jq (2 tests)
  - Period filtering works (2 tests)
  - Active pipeline listing (1 test)
  - Edge cases: null template/complexity (1 test)

- **Integration tests** (3 tests): Within same test file
  - CLI `--json` flag produces valid JSON
  - CLI `--period 30` changes window
  - `--active` flag shows running pipelines only

- **E2E tests** (1 test): Dashboard API endpoint returns valid analytics JSON (covered by existing `sw-dashboard-e2e-test.sh` or manual verification)

### Coverage Targets
- DB query functions: 100% (all 7 functions tested)
- JSON output schema: 100% (all top-level keys validated)
- Empty state handling: 100% (explicit test)

### Critical Paths to Test
- **Happy path**: Seed 10 pipeline runs with mixed success/failure, verify all breakdowns compute correctly
- **Error case 1**: Database file doesn't exist → graceful fallback to zeros
- **Error case 2**: Pipeline run with NULL template → categorized as "unknown"
- **Edge case 1**: All runs successful → failure attribution returns empty array
- **Edge case 2**: Single run → all breakdowns have exactly 1 entry

---

## Definition of Done

- [ ] `shipwright analytics` shows formatted terminal output with success rates and failure attribution
- [ ] `shipwright analytics --json` returns valid JSON matching `AnalyticsResponse` schema
- [ ] `shipwright analytics --period 30` and `--period 90` work correctly
- [ ] Empty database produces clean output with zero values (no errors)
- [ ] Dashboard `/api/analytics` endpoint returns correct JSON
- [ ] Dashboard has Analytics tab with summary, breakdowns, and trends
- [ ] `shipwright status --json` includes analytics summary
- [ ] `sw-strategic.sh` consumes analytics instead of raw event counting
- [ ] All tests pass: `bash scripts/sw-pipeline-analytics-test.sh`
- [ ] No regressions: `npm test` passes
- [ ] Command registered and appears in `shipwright help --all`

---

## Endpoint Specification

### `GET /api/analytics`

- **Method**: GET
- **Path**: `/api/analytics`
- **Query params**: `period` (integer, default 7, valid: 7|30|90)
- **Auth**: Required (same as other `/api/*` routes)
- **Success**: 200 OK, body: `AnalyticsResponse` JSON
- **Error**: 500 Internal Server Error, body: `{ "error": "Analytics computation failed" }`
- **Rate limiting**: Same as other API endpoints (no additional limits needed — internal tool)

### Error Codes

| Status | Code | When |
|--------|------|------|
| 200 | — | Success (even with zero data) |
| 400 | `invalid_period` | Period not in 7, 30, 90 |
| 401 | `unauthorized` | Missing/invalid auth |
| 500 | `analytics_error` | SQLite query failure |

### Versioning

No API versioning needed — this is a new endpoint consumed internally. The JSON schema is documented in this ADR. If breaking changes are needed in the future, add `/v2/analytics`.
