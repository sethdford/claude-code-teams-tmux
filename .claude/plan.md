# Implementation Plan: Platform Self-Improvement Health Dashboard and Auto-Issue Generator

## Socratic Design Refinement

### Requirements Clarity

**Minimum viable change**: A new `/api/platform-health` endpoint that runs the existing `scan_platform_refactor()` logic from `sw-hygiene.sh` server-side, a new "Platform Health" tab in the dashboard frontend, and a new `sw-platform-health.sh` script that auto-generates GitHub issues when thresholds are exceeded.

**Implicit requirements**: Trend data requires historical snapshots stored somewhere. The existing `scan_platform_refactor()` writes a one-shot JSON to `.claude/platform-hygiene.json` — we need to accumulate historical snapshots for 7/30 day deltas.

**Acceptance criteria** (from issue): Dashboard endpoint with counts + trends, frontend tab with charts, auto-issue generator with thresholds, strategic agent integration.

### Design Alternatives

**Approach A: Shell script scanner + JSONL history + dashboard integration**

- New `sw-platform-health.sh` script handles scanning, history, auto-issue generation
- Dashboard server reads the history file and serves `/api/platform-health`
- Frontend adds a new tab with charts using existing chart components (bar, sparkline, donut)
- Pros: Follows existing patterns exactly, minimal blast radius, reuses `scan_platform_refactor()` logic
- Cons: Slightly more files

**Approach B: All logic in dashboard server.ts**

- Server.ts runs grep/wc commands via execSync to collect metrics
- Stores history in SQLite
- Pros: Single component
- Cons: Violates architecture (server.ts is 3500 lines already — exactly the problem we're trying to solve), mixes concerns

**Chosen: Approach A** — follows established patterns (patrol-meta model), minimal blast radius, reuses existing scanning logic.

### Risk Assessment

- **Risk**: server.ts is already 3500 lines. Adding ~80 lines for 1 endpoint is acceptable.
- **Risk**: History file could grow unbounded. Mitigation: cap at 90 days of daily snapshots.
- **Risk**: Auto-issue creation could create duplicates. Mitigation: reuse `patrol_meta_create_issue()` dedup pattern.
- **Risk**: grep scanning could be slow on large repos. Mitigation: the existing hygiene scan already does this and is fast.

### Dependency Analysis

- Depends on: `sw-hygiene.sh` (scanning patterns), `sw-patrol-meta.sh` (issue creation pattern), dashboard server.ts (endpoint), dashboard frontend (tab/view system)
- No circular dependency risk — new script is standalone, dashboard reads its output files.

## Architecture Decision Record

### Component Diagram

```
                    ┌─────────────────────────┐
                    │  sw-platform-health.sh   │
                    │  (Scanner + Auto-Issue)  │
                    └──────────┬──────────────┘
                               │ writes
                               ▼
                    ┌─────────────────────────┐
                    │ ~/.shipwright/           │
                    │  platform-health.jsonl   │  (daily snapshots)
                    │  platform-health.json    │  (latest snapshot)
                    └──────────┬──────────────┘
                               │ reads
                               ▼
                    ┌─────────────────────────┐
                    │  dashboard/server.ts     │
                    │  /api/platform-health    │
                    └──────────┬──────────────┘
                               │ serves
                               ▼
┌──────────────────────────────────────────────┐
│  dashboard/src/                               │
│  ├── views/platform-health.ts  (view)        │
│  ├── core/api.ts               (client)      │
│  └── types/api.ts              (types)       │
└──────────────────────────────────────────────┘
```

### Interface Contracts

```typescript
// GET /api/platform-health
interface PlatformHealthResponse {
  current: PlatformHealthSnapshot;
  trend_7d: PlatformHealthDelta;
  trend_30d: PlatformHealthDelta;
  top_scripts: Array<{ script: string; lines: number }>;
  history: PlatformHealthSnapshot[]; // last 30 daily snapshots
}

interface PlatformHealthSnapshot {
  timestamp: string; // ISO8601
  hardcoded_count: number;
  fallback_count: number;
  todo_count: number;
  fixme_count: number;
  hack_count: number;
  total_debt: number; // sum of all counts
  largest_script_lines: number;
  script_count: number;
}

interface PlatformHealthDelta {
  hardcoded: number; // change from N days ago
  fallback: number;
  todo: number;
  fixme: number;
  hack: number;
  total_debt: number;
}
```

### Data Flow

```
[cron/launchd daily] → sw-platform-health.sh scan
    → grep scripts/ for hardcoded/fallback/TODO/FIXME/HACK counts
    → wc -l for script sizes
    → append snapshot to ~/.shipwright/platform-health.jsonl
    → write latest to ~/.shipwright/platform-health.json
    → check thresholds → create GitHub issues if exceeded

[dashboard request] → GET /api/platform-health
    → read platform-health.jsonl
    → compute 7d/30d deltas
    → return PlatformHealthResponse

[frontend] → fetch /api/platform-health → render charts
```

### Error Boundaries

- Shell script: `set -euo pipefail` + ERR trap. If grep fails, default to 0. If GitHub API fails, warn and continue.
- Server endpoint: try/catch around file reads, return `{ error: "..." }` with 500 on failure.
- Frontend: error boundary in view init (existing pattern from router.ts).

## Alternatives Considered

| Approach                              | Complexity | Performance         | Maintainability                | Blast Radius            |
| ------------------------------------- | ---------- | ------------------- | ------------------------------ | ----------------------- |
| A: Shell + JSONL + Dashboard (chosen) | Low        | Good (grep is fast) | High (follows patterns)        | 5 files modified, 2 new |
| B: All in server.ts                   | Medium     | Good                | Low (server already too large) | 2 files modified        |

## Schema Changes

Not applicable — using JSONL file storage (consistent with events.jsonl pattern). No SQLite migration needed.

## Data Flow Diagram

```
[Scan] ──► grep scripts/*.sh ──► count matches ──► JSON snapshot
                                                       │
                                              ┌────────┴────────┐
                                              ▼                 ▼
                                    platform-health.json   platform-health.jsonl
                                     (latest snapshot)      (history, append)
                                              │                 │
                                     ┌────────┘      ┌─────────┘
                                     ▼               ▼
                               [Dashboard API] ──► compute deltas ──► response
                                                                         │
                                                                         ▼
                                                                   [Frontend]
                                                                   charts/cards

[Auto-Issue] ──► check thresholds ──► gh issue create (with dedup)
```

Failure points: grep (graceful: default 0), file I/O (atomic write via tmp+mv), GitHub API (warn and skip).

## Idempotency Strategy

- **Scan**: Always overwrites latest snapshot, appends to history. Running twice same day produces two entries (acceptable, deduplicated by date in trend computation).
- **Auto-issues**: Deduplicated by exact title match using `gh issue list --search` (same as patrol-meta pattern).

## Rollback Plan

1. Remove `sw-platform-health.sh` and `sw-platform-health-test.sh`
2. Revert additions to `dashboard/server.ts`, `dashboard/src/views/platform-health.ts`, `dashboard/src/core/api.ts`, `dashboard/src/types/api.ts`, `dashboard/src/main.ts`, `dashboard/public/index.html`, `dashboard/src/core/router.ts`
3. Remove `~/.shipwright/platform-health.json` and `platform-health.jsonl`

## User Stories

**Primary**: As a platform maintainer, I want to see platform health trends (hardcoded counts, TODO counts, script sizes) in the dashboard, so that I can track technical debt over time and prioritize cleanup work.

**Secondary**: As an autonomous agent system, I want to auto-generate GitHub issues when technical debt exceeds thresholds, so that the platform can self-improve without human intervention.

### Acceptance Criteria (Given/When/Then)

- **Given** the dashboard is running, **when** I navigate to the "Platform Health" tab, **then** I see current counts (hardcoded, fallback, TODO, FIXME, HACK), top 10 scripts by size, and 7/30-day trend charts.
- **Given** `sw-platform-health.sh scan` has run daily for 7+ days, **when** the dashboard loads, **then** trend sparklines show directional change.
- **Given** hardcoded_count > 50, **when** `sw-platform-health.sh auto-issue` runs, **then** a GitHub issue is created with title "Platform Self-Improvement: Config Migration" and labels `platform,technical-debt`.
- **Given** an identical issue already exists, **when** auto-issue runs again, **then** no duplicate is created.

### Edge Cases

- **Empty state**: No history file yet → show "Run `shipwright platform-health scan` to collect first snapshot" message.
- **Error state**: File read fails → show error boundary with retry button (existing pattern).
- **Overload state**: 90+ days of history → truncate to latest 90 entries on read.

---

## Files to Modify

### New Files

1. `scripts/sw-platform-health.sh` — Scanner, auto-issue generator, CLI entry point
2. `scripts/sw-platform-health-test.sh` — Test suite
3. `dashboard/src/views/platform-health.ts` — Frontend view
4. `dashboard/src/views/platform-health.test.ts` — Frontend view tests

### Modified Files

5. `dashboard/server.ts` — Add `/api/platform-health` endpoint (~80 lines)
6. `dashboard/src/types/api.ts` — Add `PlatformHealthSnapshot`, `PlatformHealthDelta`, `PlatformHealthResponse` types + `TabId` union
7. `dashboard/src/core/api.ts` — Add `fetchPlatformHealth()` client function
8. `dashboard/src/core/router.ts` — Add `"platform-health"` to `VALID_TABS`
9. `dashboard/src/main.ts` — Import and register `platformHealthView`
10. `dashboard/public/index.html` — Add tab button + panel HTML
11. `scripts/sw` — Add `platform-health` command routing
12. `package.json` — Register test script

## Implementation Steps

### Step 1: Create `scripts/sw-platform-health.sh`

- Standard boilerplate: `set -euo pipefail`, VERSION, helpers source, emit_event
- `scan()` function: reuse grep patterns from `sw-hygiene.sh:scan_platform_refactor()` — count hardcoded/fallback/TODO/FIXME/HACK, compute script sizes top 10
- Write latest snapshot to `~/.shipwright/platform-health.json` (atomic: tmp + mv)
- Append snapshot line to `~/.shipwright/platform-health.jsonl`
- `auto_issue()` function: read latest snapshot, check thresholds:
  - hardcoded_count > 50 → "Platform Self-Improvement: Config Migration"
  - any script > 3000 lines → "Platform Self-Improvement: Script Decomposition [script-name]"
  - 7d debt trend > +5 → "Platform Self-Improvement: Debt Trend Alert"
- Issue creation uses dedup pattern from `sw-patrol-meta.sh`
- Labels: `platform,technical-debt,auto-patrol,ready-to-build`
- Priority in body: P1 if >3000 lines, P2 if hardcoded>50, P3 if trend>+5
- `strategic_context()` function: output JSON for sw-strategic.sh ingestion
- Subcommands: `scan`, `auto-issue`, `show`, `trend`, `strategic-context`

### Step 2: Add types to `dashboard/src/types/api.ts`

- Add `PlatformHealthSnapshot`, `PlatformHealthDelta`, `PlatformHealthResponse` interfaces
- Add `"platform-health"` to `TabId` union type

### Step 3: Add `/api/platform-health` endpoint to `dashboard/server.ts`

- Read `~/.shipwright/platform-health.json` for current snapshot
- Read `~/.shipwright/platform-health.jsonl` for history (cap at 90 lines from end)
- Compute 7d and 30d deltas by comparing current vs snapshot from N days ago
- Return `PlatformHealthResponse`

### Step 4: Add API client function to `dashboard/src/core/api.ts`

- `fetchPlatformHealth()` → `request<PlatformHealthResponse>("/api/platform-health")`

### Step 5: Add `"platform-health"` to router

- Add to `VALID_TABS` in `dashboard/src/core/router.ts`

### Step 6: Create `dashboard/src/views/platform-health.ts`

- Implement `View` interface (init/render/destroy)
- On init: fetch `/api/platform-health`, render sections
- Sections:
  - **Summary cards**: Current counts (hardcoded, fallback, TODO, FIXME, HACK) with trend indicators (up/down arrows, colored)
  - **Top 10 Scripts**: Bar chart using existing `renderBarChart()` from `dashboard/src/components/charts/bar.ts`
  - **Debt Trend**: Sparkline chart showing total_debt over time using `renderSparkline()` from `dashboard/src/components/charts/sparkline.ts`
  - **Debt Density Heatmap**: Reuse heatmap pattern from insights view — rows = debt type, columns = recent dates

### Step 7: Register view in `dashboard/src/main.ts`

- Import `platformHealthView` from `./views/platform-health`
- `registerView("platform-health", platformHealthView)`

### Step 8: Add tab button + panel to `dashboard/public/index.html`

- Add `<button class="tab-btn" data-tab="platform-health">Health</button>` in tab bar
- Add `<div class="tab-panel" id="panel-platform-health">` with empty state placeholder

### Step 9: Route CLI command in `scripts/sw`

- Add `platform-health` case to dispatch, exec `sw-platform-health.sh`

### Step 10: Create test suites

- `scripts/sw-platform-health-test.sh`: Mock environment, test scan output format, threshold detection, issue creation (mock gh), strategic context output
- `dashboard/src/views/platform-health.test.ts`: Vitest, mock API, verify DOM rendering

### Step 11: Register in package.json

- Add `sw-platform-health-test.sh` to the test chain

### Step 12: Strategic agent integration

- In `sw-strategic.sh`, add a step that reads `~/.shipwright/platform-health.json` if present and includes it in the strategic context

## Task Checklist

- [ ] Task 1: Create `scripts/sw-platform-health.sh` with scan, auto-issue, show, trend, strategic-context subcommands
- [ ] Task 2: Add TypeScript types to `dashboard/src/types/api.ts` (PlatformHealthSnapshot, PlatformHealthDelta, PlatformHealthResponse, TabId update)
- [ ] Task 3: Add `/api/platform-health` endpoint to `dashboard/server.ts`
- [ ] Task 4: Add `fetchPlatformHealth()` to `dashboard/src/core/api.ts`
- [ ] Task 5: Add `"platform-health"` to VALID_TABS in `dashboard/src/core/router.ts`
- [ ] Task 6: Create `dashboard/src/views/platform-health.ts` with charts and cards
- [ ] Task 7: Register view in `dashboard/src/main.ts` and add tab/panel to `dashboard/public/index.html`
- [ ] Task 8: Add `platform-health` command routing in `scripts/sw`
- [ ] Task 9: Create `scripts/sw-platform-health-test.sh` shell test suite
- [ ] Task 10: Create `dashboard/src/views/platform-health.test.ts` vitest test suite
- [ ] Task 11: Register test in `package.json`
- [ ] Task 12: Integrate with `sw-strategic.sh` for context injection

## Testing Approach

### Test Pyramid Breakdown

- **Unit tests (shell)**: 12+ test cases in `sw-platform-health-test.sh` — scan output format, threshold logic, issue dedup, trend computation, strategic context
- **Unit tests (TypeScript)**: 8+ test cases in `platform-health.test.ts` — DOM rendering, empty state, error handling, chart rendering, trend display
- **Integration**: Manual verification that `shipwright platform-health scan` produces valid JSON and dashboard displays it

### Coverage Targets

- Shell script: All subcommands, threshold boundary conditions, file I/O edge cases (missing files, empty files)
- TypeScript view: Init/render/destroy lifecycle, API error handling, empty state rendering

### Critical Paths to Test

- **Happy path**: scan → jsonl written → API returns data → frontend renders charts
- **Error: no history**: First run, no jsonl file → API returns current-only, frontend shows "no trend data yet"
- **Error: GitHub API down**: auto-issue fails gracefully, logs warning, doesn't crash
- **Edge: threshold boundary**: hardcoded_count=50 (no issue) vs 51 (creates issue)
- **Edge: duplicate issue**: Second auto-issue run doesn't create duplicate

## Endpoint Specification

### `GET /api/platform-health`

- **Request**: No body. Optional query param `?period=30` (default 30, max 90).
- **Response** (200): `PlatformHealthResponse` JSON
- **Response** (500): `{ "error": "Failed to read platform health data" }`
- **Rate Limiting**: Not applicable (internal dashboard endpoint, already behind auth)
- **Versioning**: v1 implicit (no API versioning in this project)

### Error Codes

| Status | Error                            | When                    |
| ------ | -------------------------------- | ----------------------- |
| 200    | (success)                        | Data available          |
| 200    | `{ current: null, history: [] }` | No scan data yet        |
| 500    | `{ error: "..." }`               | File read/parse failure |

## Definition of Done

- [ ] `shipwright platform-health scan` produces `~/.shipwright/platform-health.json` with correct schema
- [ ] `shipwright platform-health auto-issue` creates GitHub issues when thresholds exceeded (with dedup)
- [ ] `GET /api/platform-health` returns current snapshot + 7d/30d deltas + history
- [ ] Dashboard "Platform Health" tab renders: summary cards, script size bar chart, debt trend sparkline, debt heatmap
- [ ] Empty state shown when no history exists
- [ ] Shell test suite passes with 12+ test cases
- [ ] TypeScript test suite passes with 8+ test cases
- [ ] All existing tests continue to pass (`npm test`)
- [ ] Strategic agent receives platform health context when available
