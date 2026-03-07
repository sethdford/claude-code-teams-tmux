# Plan: Post-Merge Production Feedback Integration and Regression Learning

## Brainstorming: Design Decisions

### Requirements Clarity

**Minimum viable change**: A new `sw-post-merge-monitor.sh` script that:

1. Watches for post-merge signals (CI failures on main, deployment failures, regression-labeled issues)
2. Correlates them back to merged PRs
3. Emits `feedback.production.regression` events
4. Feeds those events into the memory system (tagging failure patterns as "production_regression")
5. Feeds into intelligence engine (risk score adjustment for similar issues)
6. Exposes data via a dashboard API endpoint

**Implicit requirements**:

- Must respect `$NO_GITHUB` for local/offline mode
- Must follow bash 3.2 conventions (no associative arrays, no `${var,,}`)
- Must use atomic file writes (tmp + mv)
- Must use `jq --arg` for JSON (no string interpolation)
- Must integrate with existing event bus (`emit_event`)

### Alternatives Considered

**Approach A: Extend `sw-webhook.sh` to handle more event types**

- Pros: Reuses existing webhook infrastructure, single entry point
- Cons: `sw-webhook.sh` is already focused on issue processing for daemon; mixing concerns increases blast radius; harder to test independently
- Blast radius: High — webhook.sh is critical daemon infrastructure

**Approach B: New `sw-post-merge-monitor.sh` script + extensions to existing systems (CHOSEN)**

- Pros: Clean separation of concerns; new script handles monitoring logic; thin integration points into memory/intelligence; independently testable; follows existing pattern of one-script-per-command
- Cons: One more script file
- Blast radius: Low — new file for core logic; small targeted changes to memory.sh, intelligence.sh, dashboard/server.ts

**Approach C: Extend `sw-feedback.sh` with monitor subcommand**

- Pros: Conceptually related to existing feedback loop
- Cons: `sw-feedback.sh` focuses on error collection from logs, not GitHub event correlation; would conflate two different data sources
- Blast radius: Medium

**Decision**: Approach B. The post-merge monitor is a distinct concern (correlating GitHub events to merged PRs) separate from both webhooks (issue processing) and feedback (log analysis). A new script follows the project's one-command-per-script convention.

### Risk Assessment

| Risk                                                | Impact                                 | Mitigation                                                                                                       |
| --------------------------------------------------- | -------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| GitHub API rate limiting during monitoring          | Monitor stops working                  | Use cached GraphQL queries via `sw-github-graphql.sh`; poll interval configurable                                |
| False positive regressions (CI flake, not PR fault) | Memory system learns wrong patterns    | Require commit-level correlation (PR commits must appear in failing CI run); add confidence field                |
| Memory pollution from noisy signals                 | Intelligence gives bad recommendations | Use separate `source: "production"` tag; weight production regressions lower than direct test failures initially |
| Dashboard endpoint adds load                        | Dashboard slows down                   | Read from pre-computed JSONL file, not live GitHub queries                                                       |

## Component Diagram

```
                    GitHub Events
                         |
                   +-----v------+
                   | Post-Merge |
                   |  Monitor   |  (sw-post-merge-monitor.sh)
                   +--+--+--+---+
                      |  |  |
          +-----------+  |  +----------+
          v              v             v
   +------+---+   +-----+----+  +-----+------+
   |  Memory   |   | Event    |  | Dashboard  |
   |  System   |   |   Bus    |  |   API      |
   | (failures |   | (events  |  | (server.ts)|
   |  .json)   |   |  .jsonl) |  +------------+
   +------+----+   +----------+
          |
          v
   +------+------+
   | Intelligence |
   |   Engine     |
   | (risk scores)|
   +--------------+
```

## Data Flow

```
1. Poll: gh api → check runs on main, deployment statuses, regression-labeled issues
2. Correlate: For each signal, find merged PR whose commits are in the failing ref
3. Emit: feedback.production.regression event → events.jsonl
4. Store: Write to ~/.shipwright/post-merge-health.jsonl (per-merge tracking)
5. Memory: Call memory_capture_failure with source=production tag
6. Intelligence: On next pipeline, query production regressions for similar patterns → boost risk score
7. Dashboard: GET /api/production-health reads post-merge-health.jsonl → returns merge status array
```

## Interface Contracts

```bash
# sw-post-merge-monitor.sh
cmd_monitor()          # Poll GitHub for post-merge signals, correlate to PRs
cmd_check_pr <pr_num>  # Check a specific merged PR's post-merge health
cmd_status()           # Show recent merge health summary (green/yellow/red)
cmd_ingest <event_json> # Manually ingest a production event (for webhook/CI integration)
cmd_help()             # Show help

# Event schema: feedback.production.regression
{
  "ts": "ISO8601",
  "type": "feedback.production.regression",
  "pr_number": "123",
  "signal_type": "ci_failure|deploy_failure|regression_issue",
  "ref": "abc1234",
  "error_context": "truncated error message",
  "confidence": "high|medium|low",
  "repo": "owner/repo"
}

# Post-merge health record: ~/.shipwright/post-merge-health.jsonl
{
  "pr_number": 123,
  "merged_at": "ISO8601",
  "merge_sha": "abc1234",
  "status": "stable|degraded|regression",
  "signals": [...],
  "last_checked": "ISO8601"
}

# Dashboard API: GET /api/production-health
Response: {
  "merges": [
    { "pr": 123, "status": "stable", "merged_at": "...", "signals": [] },
    { "pr": 122, "status": "regression", "merged_at": "...", "signals": [...] }
  ],
  "summary": { "total": 10, "stable": 8, "degraded": 1, "regression": 1 }
}
```

## Error Boundaries

- **Post-merge monitor**: Catches all GitHub API errors internally; logs warnings but never crashes. Returns gracefully when `$NO_GITHUB` is set.
- **Memory integration**: Uses existing `memory_capture_failure` with `|| true`; failures in memory don't block monitoring.
- **Intelligence integration**: Reads production regression data from files; missing files return 0 risk adjustment.
- **Dashboard**: Reads JSONL file; returns empty array if file missing.

## Schema Changes

**New file**: `~/.shipwright/post-merge-health.jsonl` — append-only JSONL, one record per merge status update.

**Existing file modification**: `~/.shipwright/memory/<repo-hash>/failures.json` — failure entries gain an optional `source` field (`"source": "production"`) and optional `tags` array (`["production_regression", "pr_123"]`).

**Rollback**: Delete `post-merge-health.jsonl`. The `source` and `tags` fields are additive (existing code ignores unknown fields). No destructive schema changes.

**Idempotency**: Each PR's health is keyed by `pr_number`. Re-processing the same signal updates existing records rather than duplicating. The monitor uses `jq` to check if a signal was already recorded before appending.

---

## Files to Modify

### New Files

1. `scripts/sw-post-merge-monitor.sh` — Core post-merge monitoring logic (~400 lines)
2. `scripts/sw-post-merge-monitor-test.sh` — Test suite (~300 lines)

### Modified Files

3. `scripts/sw-memory.sh` — Add `source` and `tags` fields to `memory_capture_failure`; add `memory_tag_failure_as_risky` function
4. `scripts/sw-intelligence.sh` — Add `intelligence_production_risk_adjustment` function that reads production regression data
5. `scripts/sw` — Register `post-merge-monitor` subcommand in CLI router
6. `dashboard/server.ts` — Add `GET /api/production-health` endpoint
7. `scripts/sw-feedback.sh` — Add `monitor` subcommand that delegates to `sw-post-merge-monitor.sh` (keeps `shipwright feedback monitor` as alias)
8. `package.json` — Register test suite

---

## Implementation Steps

### Step 1: Create `sw-post-merge-monitor.sh` core script

New script following existing conventions (`set -euo pipefail`, VERSION, helpers, emit_event). Functions:

- `get_recent_merged_prs()` — Uses `gh pr list --state merged --limit 20 --json number,mergedAt,mergeCommit,headRefName` to get recent merges
- `check_ci_status_for_commits()` — For a merge commit, checks `gh api repos/{owner}/{repo}/commits/{sha}/check-runs` for failures on the default branch
- `check_deployment_status()` — Uses `gh api repos/{owner}/{repo}/deployments` to find failed deployments containing the merge commit
- `check_regression_issues()` — Uses `gh issue list --label regression` and cross-references PR numbers in issue body
- `correlate_signals()` — Combines all signals for a given PR into a health status (stable/degraded/regression)
- `record_health()` — Atomically writes to `~/.shipwright/post-merge-health.jsonl`
- `emit_regression_event()` — Emits `feedback.production.regression` via `emit_event` and calls `memory_capture_failure`
- `cmd_monitor()` — Main monitoring loop: get recent PRs → check each → record → emit events
- `cmd_check_pr()` — Single PR check
- `cmd_status()` — Formatted display of recent merge health
- `cmd_ingest()` — Accept external event JSON (from webhook or CI)

### Step 2: Extend memory system

In `sw-memory.sh`, modify `memory_capture_failure()` to accept optional `source` and `tags` parameters:

- Add parameters: `local source="${3:-pipeline}"` and `local tags="${4:-}"`
- When creating new failure entry in jq, include `source` and `tags` array
- Add new function `memory_tag_failure_as_risky()` that finds a failure by pattern and adds `"production_regression"` to its tags array

### Step 3: Extend intelligence engine

In `sw-intelligence.sh`, add `intelligence_production_risk_adjustment()`:

- Reads `~/.shipwright/post-merge-health.jsonl`
- For the current issue's file patterns, checks if similar patterns caused production regressions
- Returns a risk score bump (0-30 points) based on historical regression data
- Called from existing `intelligence_file_risk_score()` as an additional signal

### Step 4: Register CLI subcommand

In `scripts/sw`, add routing for `post-merge-monitor`:

```bash
post-merge-monitor|post-merge)
    exec "$SCRIPT_DIR/sw-post-merge-monitor.sh" "$@"
    ;;
```

### Step 5: Add dashboard endpoint

In `dashboard/server.ts`, add `GET /api/production-health`:

- Read `~/.shipwright/post-merge-health.jsonl`
- Parse and aggregate into summary
- Return JSON with merge list and summary counts
- Add to public routes list (no auth required for read-only health data)

### Step 6: Add feedback alias

In `sw-feedback.sh`, add `monitor` case to main router that delegates to `sw-post-merge-monitor.sh`.

### Step 7: Write test suite

`sw-post-merge-monitor-test.sh` following existing test harness patterns:

- Mock `gh` CLI with scripted responses
- Test: monitor detects CI failure → creates regression event → memory updated
- Test: monitor detects deployment failure → creates regression event
- Test: monitor detects regression-labeled issue → correlates to PR
- Test: stable PR gets "stable" status
- Test: NO_GITHUB mode skips GitHub calls gracefully
- Test: duplicate signals are deduplicated (idempotency)
- Test: status command displays formatted output
- Test: ingest command accepts external events
- Integration test: simulate merge → CI failure → verify regression event created and memory updated

### Step 8: Register test in package.json

Add `sw-post-merge-monitor-test.sh` to the test suite list in `package.json`.

---

## Task Checklist

- [ ] Task 1: Create `scripts/sw-post-merge-monitor.sh` with core monitoring functions (get_recent_merged_prs, check_ci_status, check_deployment_status, check_regression_issues, correlate_signals, record_health, emit_regression_event)
- [ ] Task 2: Add subcommands to `sw-post-merge-monitor.sh` (monitor, check-pr, status, ingest, help) with main router
- [ ] Task 3: Extend `scripts/sw-memory.sh` — add `source`/`tags` params to `memory_capture_failure` and add `memory_tag_failure_as_risky` function
- [ ] Task 4: Extend `scripts/sw-intelligence.sh` — add `intelligence_production_risk_adjustment` function
- [ ] Task 5: Register `post-merge-monitor` in CLI router (`scripts/sw`)
- [ ] Task 6: Add `GET /api/production-health` endpoint in `dashboard/server.ts`
- [ ] Task 7: Add `monitor` alias in `scripts/sw-feedback.sh`
- [ ] Task 8: Create `scripts/sw-post-merge-monitor-test.sh` with full test suite
- [ ] Task 9: Register test in `package.json`
- [ ] Task 10: Run tests and verify all pass

---

## Testing Approach

### Test Pyramid Breakdown

- **Unit tests (8 tests)**: Each core function tested in isolation with mocked `gh` CLI — PR listing, CI check, deployment check, regression issue detection, signal correlation, health recording, event emission, idempotency
- **Integration test (1 test)**: Full flow: mock merge → mock CI failure → verify regression event in events.jsonl AND memory failure tagged as risky
- **Edge case tests (3 tests)**: NO_GITHUB mode, empty PR list, malformed GitHub API responses

### Coverage Targets

- Core monitoring functions: 100% branch coverage
- Memory integration: verify `source` and `tags` fields written correctly
- Intelligence integration: verify risk score bump for known regression patterns
- Dashboard endpoint: verify JSON response structure

### Critical Paths to Test

**Happy path**: Recent merged PR → CI passes → status = "stable"
**Error case 1**: Merged PR → CI failure on main → `feedback.production.regression` event emitted → memory updated with production_regression tag
**Error case 2**: Merged PR → deployment failure → regression event with deploy context
**Edge case 1**: `NO_GITHUB=true` → graceful skip with warning
**Edge case 2**: No recent merged PRs → empty status, no errors

---

## Definition of Done

- [ ] `shipwright post-merge-monitor monitor` polls GitHub and detects CI/deployment failures for merged PRs
- [ ] `feedback.production.regression` events are emitted to `events.jsonl` with PR number and error context
- [ ] Memory system records production regressions with `source: "production"` and `tags: ["production_regression"]`
- [ ] Intelligence engine uses regression data to boost risk scores for similar file patterns (+10-30 points)
- [ ] `GET /api/production-health` returns recent merges with green/yellow/red status
- [ ] `shipwright feedback monitor` works as alias
- [ ] Integration test proves: merge → CI failure → regression event → memory tagged
- [ ] All existing tests still pass (no regressions)
- [ ] `NO_GITHUB` mode works without errors
- [ ] Script passes `bash -n` syntax check and follows bash 3.2 conventions
