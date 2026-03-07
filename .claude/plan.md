# Implementation Plan: Platform Self-Improvement Health Dashboard and Auto-Issue Generator

## Socratic Design Refinement

### Requirements Clarity

**Minimum viable change:** A bash script (`sw-health-dashboard.sh`) that aggregates health signals from existing systems (vitals, DORA, patrol-meta, predictive, self-optimize, cost) into a unified health report, with auto-issue generation for detected problems. A dashboard view (`health.ts`) that renders the aggregated health data. A test suite.

**Implicit requirements:**

- Must integrate with existing event infrastructure (`events.jsonl`, SQLite)
- Must work in `NO_GITHUB` / local mode (degrade gracefully)
- Must follow bash 3.2 compat rules (no associative arrays, no `readarray`, etc.)
- Must follow existing view/router/API patterns in dashboard
- Auto-generated issues must deduplicate against open issues (reuse patrol-meta pattern)

**Acceptance criteria:**

1. `shipwright health` CLI outputs unified health report (terminal + JSON)
2. `shipwright health --suggest` lists auto-detected improvement opportunities
3. `shipwright health --create-issues` creates GitHub issues for suggestions (with dedup)
4. Dashboard `/api/health-dashboard` endpoint returns aggregated health data
5. Dashboard `health` tab renders health score, signal breakdown, suggestions, and trends
6. Test suite validates all health aggregation, suggestion scoring, and issue creation logic

### Alternatives Considered

| Approach                                       | Description                                                             | Complexity | Maintainability             | Blast Radius       |
| ---------------------------------------------- | ----------------------------------------------------------------------- | ---------- | --------------------------- | ------------------ |
| **A: Single script + dashboard view (CHOSEN)** | `sw-health-dashboard.sh` aggregates all signals, dashboard view renders | Low        | High (follows patterns)     | 3 new + 6 modified |
| **B: Separate aggregator + issue-generator**   | Two scripts: collector and actor                                        | Medium     | Medium (more wiring)        | 4 new + 6 modified |
| **C: Extend sw-patrol-meta.sh only**           | Add health scoring to patrol-meta, dashboard only                       | Low        | Low (overloads patrol-meta) | 1 new + 7 modified |

**Decision:** Approach A. Single script per command follows project conventions. Reuses `patrol_meta_create_issue()` pattern for issue creation. Minimal blast radius.

### Risk Assessment

| Risk                                                   | Impact                 | Mitigation                                               |
| ------------------------------------------------------ | ---------------------- | -------------------------------------------------------- |
| `/api/health` endpoint already exists (liveness check) | Name collision         | Use `/api/health-dashboard` for new endpoint             |
| Missing data sources on fresh install                  | Empty dashboard        | Graceful defaults: score=50, "insufficient data" message |
| patrol-meta not sourced in standalone mode             | Missing issue creation | Define local fallback `_health_create_issue()`           |
| Dashboard tab registration breaks existing views       | UI regression          | Follow exact pattern from main.ts/router.ts              |
| Large event log slows aggregation                      | Performance            | Limit reads to last 7 days, use `tail` + `jq` streaming  |

### Dependency Analysis

- **Depends on:** `sw-pipeline-vitals.sh` (health scoring), `sw-dora.sh` (DORA metrics), `sw-patrol-meta.sh` (issue creation pattern + checks), `sw-predictive.sh` (anomaly data), `sw-self-optimize.sh` (outcome data), `sw-cost.sh` (budget data)
- **Dashboard depends on:** `dashboard/server.ts` (endpoint), `dashboard/src/types/api.ts` (types), `dashboard/src/core/router.ts` (tab system)
- **No circular dependency risk** — new script reads existing data files, dashboard reads script output

---

## Architecture

```
                    ┌─────────────────────────────┐
                    │   sw-health-dashboard.sh     │
                    │   (Aggregator + Auto-Issue)  │
                    └──────────┬──────────────────┘
                               │ reads from existing sources
                    ┌──────────┴──────────────────┐
                    │  ~/.shipwright/              │
                    │  ├── events.jsonl            │  (pipeline events)
                    │  ├── costs.json              │  (cost tracking)
                    │  ├── budget.json             │  (budget limits)
                    │  ├── optimization/           │  (outcomes, weights)
                    │  ├── baselines/              │  (anomaly data)
                    │  └── health-snapshots.jsonl  │  (NEW: health history)
                    └──────────┬──────────────────┘
                               │ reads
                    ┌──────────┴──────────────────┐
                    │  dashboard/server.ts          │
                    │  GET /api/health-dashboard    │
                    └──────────┬──────────────────┘
                               │ serves
                    ┌──────────┴──────────────────┐
                    │  dashboard/src/views/health.ts│
                    │  (Score gauge, signals, etc.) │
                    └─────────────────────────────┘
```

---

## Files to Modify

### New Files

1. `scripts/sw-health-dashboard.sh` — Health aggregation, CLI, auto-issue generator (~600 lines)
2. `scripts/sw-health-dashboard-test.sh` — Test suite (~400 lines)
3. `dashboard/src/views/health.ts` — Dashboard health view (~350 lines)

### Modified Files

4. `dashboard/src/types/api.ts` — Add health interfaces + "health" to TabId
5. `dashboard/src/core/api.ts` — Add `fetchHealthDashboard()` function
6. `dashboard/src/core/router.ts` — Add "health" to VALID_TABS
7. `dashboard/src/main.ts` — Import and register healthView
8. `dashboard/public/index.html` — Add health tab button + panel div
9. `dashboard/server.ts` — Add `/api/health-dashboard` endpoint (~60 lines)
10. `scripts/sw` — Register `health` command routing
11. `package.json` — Register test suite

---

## Implementation Steps

### Step 1: Add TypeScript interfaces to `dashboard/src/types/api.ts`

```typescript
export interface HealthSignal {
  name: string;
  score: number; // 0-100
  weight: number; // percentage weight in overall score
  status: "healthy" | "warning" | "critical" | "unknown";
  detail: string;
}

export interface HealthSuggestion {
  id: string;
  title: string;
  body: string;
  severity: "low" | "medium" | "high" | "critical";
  source: string; // "vitals" | "patrol" | "dora" | "predictive" | "cost"
  labels: string[];
}

export interface HealthTrend {
  date: string;
  score: number;
}

export interface HealthDashboardData {
  health_score: number;
  verdict: "healthy" | "warning" | "critical" | "unknown";
  signals: HealthSignal[];
  suggestions: HealthSuggestion[];
  trends: HealthTrend[];
  last_updated: string;
}
```

Add `"health"` to the `TabId` union type.

### Step 2: Create `scripts/sw-health-dashboard.sh`

**Boilerplate:** `set -euo pipefail`, VERSION, helpers source, emit_event.

**Signal collection functions:**

1. `_health_signal_dora()` — Parse events.jsonl for pipeline completions in last 30 days. Compute: lead time (median pipeline duration_s), deploy frequency (completions/week), CFR (failed/total %), MTTR. Score: elite=100, high=75, medium=50, low=25.

2. `_health_signal_pipeline()` — Read active pipeline state from `.claude/pipeline-state.md`. If active: compute momentum (stage progress), convergence (error trend). If none active: score based on recent outcomes from `optimization/outcomes.jsonl`.

3. `_health_signal_cost()` — Read `costs.json` + `budget.json`. Score: <50% budget used=100, 50-80%=70, 80-95%=40, >95%=10.

4. `_health_signal_patrol()` — Run patrol-meta checks in-process (untested scripts, bash compat, version sync). Score: 0 findings=100, 1-2=70, 3-5=40, >5=20.

5. `_health_signal_anomalies()` — Read `baselines/*/anomaly-detections.jsonl` for recent anomalies. Score: 0 recent=100, 1-2=70, 3+=30.

6. `_health_signal_memory()` — Check memory dir size and failure pattern count. Score: <5MB and <50 patterns=100, otherwise degrade.

**Aggregation:**

```
health_score = (DORA × 25%) + (Pipeline × 25%) + (Cost × 20%) + (Patrol × 15%) + (Anomalies × 10%) + (Memory × 5%)
```

Verdict: ≥70=healthy, 50-69=warning, <50=critical, insufficient data=unknown.

**Suggestion generation:**

- DORA lead time > 7 days → "Reduce pipeline lead time"
- CFR > 30% → "Investigate high change failure rate"
- Untested scripts found → "Add test coverage for sw-X.sh"
- Bash compat violations → "Fix bash 3.2 compatibility"
- Budget > 80% → "Review cost optimization strategies"
- Recent anomaly spikes → "Investigate metric anomaly in X"
- > 3 recurring failures → "Fix recurring failure pattern: X"

**Issue creation:** Uses dedup pattern from patrol-meta (`gh issue list --search "$title"` before creating). Labels: `health-alert,auto-patrol,ready-to-build`.

**History:** Append snapshot to `~/.shipwright/health-snapshots.jsonl` (date + score + signals). Cap at 90 days.

**CLI subcommands:**

- `shipwright health` / `shipwright health show` — Terminal report
- `shipwright health --json` — JSON output
- `shipwright health --suggest` — List suggestions only
- `shipwright health --create-issues` — Auto-create issues
- `shipwright health --dashboard` — Full JSON for dashboard API

### Step 3: Add `/api/health-dashboard` endpoint to `dashboard/server.ts`

Shell out to `bash scripts/sw-health-dashboard.sh --dashboard 2>/dev/null`. Cache result for 60 seconds. Return JSON response.

### Step 4: Add API client function to `dashboard/src/core/api.ts`

```typescript
export function fetchHealthDashboard(): Promise<HealthDashboardData> {
  return request<HealthDashboardData>("/api/health-dashboard");
}
```

### Step 5: Create `dashboard/src/views/health.ts`

Implement `View` interface (init/render/destroy). Sections:

1. **Health Score** — Large donut chart (reuse existing `renderDonutChart`) showing score 0-100 with verdict color
2. **Signal Cards** — Grid of cards, one per signal (name, score bar, status badge, detail text)
3. **Suggestions** — Table with severity badge, title, source, action buttons
4. **Trend Sparkline** — Show health score over last 30 days (reuse `renderSparkline`)

### Step 6: Register view and tab

- `main.ts`: Import `healthView` from `./views/health`, call `registerView("health", healthView)`
- `router.ts`: Add `"health"` to `VALID_TABS` array
- `index.html`: Add `<button class="tab-btn" data-tab="health">` in nav and `<div class="tab-panel" id="panel-health">` in content

### Step 7: Register CLI command in `scripts/sw`

Add `health|health-dashboard)` case to the dispatch switch, exec `sw-health-dashboard.sh`.

### Step 8: Create test suite `scripts/sw-health-dashboard-test.sh`

Tests:

- Signal computation with mock data (each signal function)
- Score aggregation (weighted average correctness)
- Suggestion detection (each detector with triggering + non-triggering data)
- JSON output format validation
- Terminal output format (boxed headers, colors)
- Issue creation with mock `gh` (verify dedup)
- History file append + cap at 90 days
- Graceful degradation (missing files, empty events.jsonl)
- Flag parsing (--json, --suggest, --create-issues, --dashboard)
- NO_GITHUB mode (dry-run issue creation)

### Step 9: Register test in `package.json`

Add `bash scripts/sw-health-dashboard-test.sh &&` to the test script chain.

---

## Task Checklist

- [ ] Task 1: Add HealthDashboardData, HealthSignal, HealthSuggestion, HealthTrend interfaces to `dashboard/src/types/api.ts` and add "health" to TabId union
- [ ] Task 2: Create `scripts/sw-health-dashboard.sh` with signal aggregation, score computation, suggestion detection, issue creation, and CLI interface
- [ ] Task 3: Add `/api/health-dashboard` endpoint to `dashboard/server.ts`
- [ ] Task 4: Add `fetchHealthDashboard()` to `dashboard/src/core/api.ts`
- [ ] Task 5: Create `dashboard/src/views/health.ts` with health gauge, signal cards, suggestions table, and trend sparkline
- [ ] Task 6: Register health view in `dashboard/src/main.ts`, add "health" to VALID_TABS in `router.ts`, add tab/panel to `index.html`
- [ ] Task 7: Register `health` command in `scripts/sw` CLI router
- [ ] Task 8: Create `scripts/sw-health-dashboard-test.sh` test suite with 15+ test cases
- [ ] Task 9: Register test suite in `package.json`
- [ ] Task 10: Run tests and verify all pass

---

## Testing Approach

### Unit Tests (sw-health-dashboard-test.sh)

- Mock all data sources: create temp dirs with mock `events.jsonl`, `costs.json`, `budget.json`, `optimization/outcomes.jsonl`, `baselines/` files
- Test each `_health_signal_*` function independently with known inputs → expected scores
- Test `health_compute_score()` weighted average math
- Test each suggestion detector: provide triggering data → verify suggestion generated; provide clean data → verify no suggestion
- Test issue creation with mock `gh` binary (script that logs calls to a file)
- Test JSON output: pipe through `jq .` to validate, check required fields
- Test history append: verify JSONL grows, verify 90-day cap
- Test graceful degradation: missing files return "unknown" status, score defaults to 50
- Test CLI flags: `--json`, `--suggest`, `--create-issues`, `--dashboard`

### Integration (manual verification)

- `shipwright health` produces colored terminal output
- `shipwright health --json | jq .` produces valid JSON
- Dashboard health tab renders when dashboard is running

### Coverage Target

- 15+ PASS assertions, 0 FAIL
- All signal functions tested
- All suggestion detectors tested
- Edge cases: empty data, missing files, NO_GITHUB mode

---

## Definition of Done

- [ ] `shipwright health` outputs formatted terminal report with health score (0-100), verdict, signal breakdown, and suggestions
- [ ] `shipwright health --json` outputs valid JSON matching HealthDashboardData interface
- [ ] `shipwright health --suggest` lists improvement suggestions with severity levels
- [ ] `shipwright health --create-issues` creates GitHub issues for suggestions (or dry-runs in NO_GITHUB mode)
- [ ] Dashboard health tab renders: health score gauge, signal cards, suggestions table, trend sparkline
- [ ] `/api/health-dashboard` returns valid JSON
- [ ] Test suite passes with 15+ PASS and 0 FAIL
- [ ] All existing tests still pass (no regressions)
- [ ] Script follows bash 3.2 compatibility rules
- [ ] Works in NO_GITHUB/local mode with graceful degradation
- [ ] Health snapshots persisted to `~/.shipwright/health-snapshots.jsonl` for trend tracking

---

## Dependency Graph

```
Task 1 (types) ─────┬──→ Task 4 (api.ts fetch)
                     ├──→ Task 5 (health view) ──→ Task 6 (register + HTML)
                     └──→ Task 3 (server endpoint)

Task 2 (bash script) ──→ Task 3 (server shells out to script)
                     ──→ Task 7 (CLI routing)
                     ──→ Task 8 (test suite) ──→ Task 9 (package.json)

Task 10 (final validation) depends on all above
```

Tasks 1 and 2 are independent — can be built in parallel. Task 3 depends on both. Tasks 4-6 depend on Task 1. Tasks 7-9 depend on Task 2.
