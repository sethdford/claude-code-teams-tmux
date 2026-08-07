---
goal: "Quarantine E2E Test Issues From Production Issue Tracker

## Plan Summary
# Plan — Quarantine E2E Test Issues From Production Issue Tracker (#1303)

## Problem (verified against the repo)

`scripts/sw-e2e-integration-test.sh:117` creates **real** GitHub issues titled
`E2E test: add comment to README [automated]` (`:39`) with label `e2e-test`. It is the only
test script that calls a real `gh issue create` (verified:
`grep -ln "gh issue create" scripts/sw-*e2e*.sh` → only that file). Its cleanup trap
*closes* the issue but does not delete it, so every integration run leaves a permanent
closed issue. Downstream consumers then read those issues:

| Consumer | Site | What it reads |
| --- | --- | --- |
| Daemon poll | `scripts/lib/daemon-poll-github.sh:70`, `:97` | open issues with `$WATCH_LABEL` |
| Triage scoring | `scripts/sw-triage.sh:463` | all open issues |
| Triage unlabeled | `scripts/sw-triage.sh:669` | `--search "no:label"` |
| Triage label audit | `scripts/sw-triage.sh:695` | all open issues |
| Strategic title cache | `scripts/sw-strategic.sh:115-116` | open + last 30 closed titles |
| Strategic analysis | `scripts/sw-strategic.sh:286`, `:380`, `:388` | open + recent closed |
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Architecture Decision Record: Quarantine E2E Test Issues From Production Issue Tracker
## Context
## Decision
## Alternatives Considered
## Component Diagram
## Interface Contracts
### Quarantine Library (`scripts/lib/issue-quarantine.sh`)
### E2E Integration Test Harness (`scripts/sw-e2e-integration-test.sh`)
### Consumption Points (Daemon Poll, Triage, Strategic)
## Data Flow
[... full design in .claude/pipeline-artifacts/design.md]

## Specification: Quarantine E2E Test Issues From Production Issue Tracker

### Goals
- Quarantine E2E Test Issues From Production Issue Tracker

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "failures.json (first)",
      "relevance": 85,
      "summary": "Contains specific E2E test failure: 'Pipeline E2E tests fail because plan.md/review.md artifacts aren't written to .claude/pipeline-artifacts/' — directly describes E2E test issues and root cause"
    },
    {
      "file": "knowledge.json",
      "relevance": 62,
      "summary": "Contains KB entries for test infrastructure failures (mktemp issues, test setup problems) — provides patterns for fixing test environment issues that affect E2E test execution"
    },
    {
      "file": "success-patterns.json (first)",
      "relevance": 48,
      "summary": "Shows 'Fix bug' pattern with 3 iterations and standard template — demonstrates iteration strategy and test approach (npm test) applicable to build stage work"
    },
    {
      "file": "issues.json",
      "relevance": 42,
      "summary": "Records issue 'Fix timeout bug in daemon' with success pattern including gotchas — exemplifies how issues are captured and fixed with learned patterns"
    },
    {
      "file": "metrics.json (first)",
      "relevance": 38,
      "summary": "Contains baselines for build_duration_s (7095s) and test_duration_s (1459s) — provides context for test execution expectations and potential timeouts"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Quarantine E2E Test Issues From Production Issue Tracker — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Quarantine E2E Test Issues From Production Issue Tracker

## Implementation Checklist
- [ ] Task 1: Add `labels.e2e_test` + `labels.quarantine` to `config/defaults.json`
- [ ] Task 2: Create `scripts/lib/issue-quarantine.sh` with fail-open `quarantine_filter_json`
- [ ] Task 3: `sw-e2e-integration-test.sh` — ensure label exists, apply it, assert it stuck
- [ ] Task 4: `daemon-poll-github.sh` — filter after `gh_record_success`, before `issue_count`
- [ ] Task 5: `sw-triage.sh` — filter `:463`, `:695`; search qualifier on `:669`
- [ ] Task 6: `sw-strategic.sh` — filter `:115`, `:116`, `:286`, `:380`, `:388`
- [ ] Task 7: Create `scripts/sw-lib-issue-quarantine-test.sh` (14 cases incl. fail-open + wiring)
- [ ] Task 8: Register suite in `package.json` and `scripts/sw-test-all.sh`
- [ ] Task 9: Document quarantine label in `.claude/CLAUDE.md` Test Harness section
- [ ] Task 10: `bash -n` + shellcheck all touched scripts
- [ ] Task 11: Run new suite + daemon/triage/strategic/poll suites
- [ ] Task 12: `npm test` green; `shipwright version check` green
- [ ] Task 13: Verify existing synthetic issues carry a quarantined label; label any strays
- [ ] `scripts/lib/issue-quarantine.sh` exists, is Bash 3.2 clean, `VERSION` matches `package.json`, idempotently sourceable
- [ ] `sw-e2e-integration-test.sh` creates its issue with the `sw:e2e-test` label and asserts the label is present on the created issue
- [ ] `daemon-poll-github.sh`, `sw-triage.sh`, `sw-strategic.sh` exclude quarantined issues by default, and the daemon's logged count reflects the post-filter set
- [ ] Exclusion is overridable via config (`labels.quarantine`) and env (`SHIPWRIGHT_LABELS_E2E_TEST`) — no hardcoded label strings at any call site
- [ ] `quarantine_filter_json` provably fails open: malformed and empty input pass through, exit 0 (cases 8–9)
- [ ] `scripts/sw-lib-issue-quarantine-test.sh` passes 14/14, registered in `package.json`
- [ ] `npm test` green; `shipwright version check` green; `bash -n` clean on all touched scripts

## Context
- Pipeline: autonomous
- Branch: ci/issue-1303
- Issue: none
- Generated: 2026-08-07T01:54:31Z"
iteration: 0
max_iterations: 20
status: running
test_cmd: "npm test"
model: haiku
agents: 1
started_at: 2026-08-07T01:58:43Z
last_iteration_at: 2026-08-07T01:58:43Z
consecutive_failures: 0
total_commits: 0
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: "/home/runner/work/shipwright/shipwright/.claude/pipeline-artifacts/dod.md"
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log

