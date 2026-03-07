---
goal: "Pipeline Execution Visibility Dashboard with Success Rate Attribution Analytics

## Plan Summary
Implementation plan created at `.claude/plan.md`. Here's the summary:

## Plan Overview

**Approach**: New `sw-pipeline-analytics.sh` script + dashboard API endpoint + frontend tab (Approach A — clean separation, follows existing patterns, minimal blast radius).

**Root cause**: The strategic agent shows 0/0 because there's no analytics layer between raw SQLite data and consumers. The data exists in `pipeline_runs`, `pipeline_stages`, and `pipeline_outcomes` tables — it just isn't being queried and aggregated.

## 10 Tasks

| # | Task | Files | Blocks |
|---|------|-------|--------|
| 1 | Add 7 analytics query functions to `sw-db.sh` | `sw-db.sh` | Tasks 2, 4 |
| 2 | Create `sw-pipeline-analytics.sh` (terminal + JSON output) | new file | Task 3 |
| 3 | Register `analytics` command in CLI router | `sw` | — |
| 4 | Add `GET /api/analytics` endpoint | `server.ts` | Task 5 |
| 5 | Add Analytics tab to dashboard frontend | `index.html` | — |
| 6 | Integrate analytics summary into `sw-status.sh --json` | `sw-status.sh` | — |
| 7 | Update `sw-strategic.sh` to consume analytics JSON | `sw-strategic.sh` | — |
| 8 | Create test suite `sw-pipeline-analytics-test.sh` | new file | — |
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Pipeline Execution Visibility Dashboard with Success Rate Attribution Analytics
## Context
## Decision
### Data Flow
### Query Functions (added to `sw-db.sh`)
### CLI Script (`sw-pipeline-analytics.sh`)
### Dashboard API Endpoint
### Dashboard Frontend Tab
### Error Handling
### Integration Points
[... full design in .claude/pipeline-artifacts/design.md]

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "patterns.json (first entry)",
      "relevance": 80,
      "summary": "Node.js/JavaScript project with vitest, npm, src/ directory structure—directly applicable to building the dashboard within this repo's conventions"
    },
    {
      "file": "patterns.json (second entry)",
      "relevance": 45,
      "summary": "Confirms Node.js project type; lower detail than first entry but redundant confirmation of tech stack"
    },
    {
      "file": "failures.json",
      "relevance": 20,
      "summary": "Contains test failures in sw-cleanup.sh unrelated to dashboard; low relevance to dashboard build stage"
    },
    {
      "file": "metrics.json",
      "relevance": 5,
      "summary": "Empty baselines object; no actionable insights for build stage"
    },
    {
      "file": "global.json",
      "relevance": 5,
      "summary": "Empty common patterns and cross-repo learnings; no relevant data"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Pipeline Execution Visibility Dashboard with Success Rate Attribution Analytics — Resolution: 

## Skill Guidance (frontend issue, AI-selected)
### Why these skills were selected (AI-analyzed):
- **data-pipeline**: Core work: transform raw pipeline execution events into aggregated metrics with correct dimensional breakdown; critical to get the ETL logic right so counts are accurate across template/stage/repo-type/complexity dimensions.
- **observability**: Instrumenting both the metrics pipeline itself (latency, data freshness, query performance) and validating that dashboard metrics actually reflect what's happening in real pipelines.

## Data Pipeline Expertise

Apply these data engineering patterns:

### Schema Design
- Define schemas explicitly — never rely on implicit structure
- Use migrations for all schema changes (never manual ALTER TABLE)
- Add indexes for frequently queried columns
- Consider denormalization for read-heavy paths

### Data Integrity
- Use transactions for multi-step operations
- Implement idempotency keys for operations that could be retried
- Validate data at ingestion — reject bad data early
- Use constraints (NOT NULL, UNIQUE, FOREIGN KEY) in the database layer

### Query Patterns
- Avoid N+1 queries — use JOINs or batch loading
- Use EXPLAIN to verify query plans for complex queries
- Paginate large result sets — never SELECT * without LIMIT
- Use parameterized queries — never string concatenation for SQL

### Migration Safety
- Migrations must be reversible (include rollback steps)
- Test migrations on a copy of production data
- Add new columns as nullable, then backfill, then add NOT NULL
- Never drop columns in the same deploy as code changes

### Backpressure & Resilience
- Implement circuit breakers for external data sources
- Use dead letter queues for failed processing
- Set timeouts on all external calls
- Monitor queue depths and processing latency

### Required Output (Mandatory)

Your output MUST include these sections when this skill is active:

1. **Schema Changes**: Full migration SQL with both forward and rollback scripts, plus data backfill strategy if required
2. **Data Flow Diagram**: Text diagram showing data ingestion → processing → output with failure points marked
3. **Idempotency Strategy**: How the system handles duplicate requests (idempotency keys, deduplication, side-effect safety)
4. **Rollback Plan**: Step-by-step process to revert schema changes and restore data consistency

If any section is not applicable, explicitly state why it's skipped.

## Observability: Watch the Deploy Like a Hawk

Post-deploy monitoring catches what tests miss. Real traffic reveals real problems.

### What to Monitor (by Priority)

**P0 — Immediate (first 5 minutes):**
- Error rate: any increase over baseline?
- Health check: still returning 200?
- Latency: p50/p95/p99 within normal range?
- Memory/CPU: any sudden spikes?

**P1 — Short-term (5-30 minutes):**
- Business metrics: are users completing key flows?
- Queue depths: are background jobs processing normally?
- Connection pools: any exhaustion or leak patterns?
- Disk usage: any unexpected growth?

**P2 — Medium-term (1-24 hours):**
- Memory trends: gradual leak over time?
- Error rate trends: slowly increasing?
- User-reported issues: any new support tickets?
- Performance degradation under sustained load?

### Anomaly Detection Patterns
- **Spike detection**: >2x baseline error rate in any 1-minute window
- **Trend detection**: steadily increasing error rate over 5-minute window
- **Absence detection**: expected periodic events stop occurring
- **Latency shift**: p95 latency increases >50% from baseline

### Log Analysis
- Search for new ERROR/FATAL/PANIC entries not present before deploy
- Check for stack traces — they indicate unhandled exceptions
- Look for retry storms — repeated failed attempts at the same operation
- Monitor for resource exhaustion messages (OOM, connection refused, disk full)

### Auto-Rollback Triggers
Automatically rollback if ANY of these occur:
- Health check fails 3 consecutive times
- Error rate exceeds threshold for 2+ minutes
- Critical service dependency becomes unreachable
- Memory usage exceeds 90% of limit

### Monitoring by Issue Type

**Frontend changes:**
- JavaScript error rates in browser (if client-side monitoring exists)
- Asset load failures (404s on new bundles)
- Core Web Vitals regression (LCP, FID, CLS)

**API changes:**
- Response status code distribution (2xx vs 4xx vs 5xx)
- Request throughput — drops indicate client-side breakage
- Authentication failures — spikes indicate auth regression

**Database changes:**
- Query latency per endpoint
- Connection pool utilization
- Slow query log entries
- Replication lag (if applicable)

### Incident Escalation
If monitoring detects issues:
1. Execute rollback (if auto-rollback enabled)
2. Create incident issue with monitoring data
3. Attach relevant logs and metrics
4. Tag the original issue with `incident` label
5. Do NOT silence alerts — let them fire

### Required Output (Mandatory)

Your output MUST include these sections when this skill is active:

1. **Monitoring Checklist**: P0/P1/P2 metrics to watch (error rate, latency, memory, health checks) with specific thresholds
2. **Anomaly Detection Triggers**: Explicit conditions that trigger alerts (spike detection >2x, trend detection over 5min, absence detection, latency shift >50%)
3. **Log Analysis**: Search strategy for new ERROR/FATAL entries, stack traces, retry storms, resource exhaustion patterns
4. **Auto-Rollback Decision Criteria**: Conditions that trigger automatic rollback (health check failures, error rate threshold, critical dependency unreachable, memory exhaustion)

If any section is not applicable, explicitly state why it's skipped.
"
iteration: 0
max_iterations: 20
status: running
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-03-07T20:22:19Z
last_iteration_at: 2026-03-07T20:22:19Z
consecutive_failures: 0
total_commits: 0
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: ""
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log

