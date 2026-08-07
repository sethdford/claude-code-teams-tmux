---
goal: "Quarantine E2E Test Issues From Production Issue Tracker

## Plan Summary
# Plan: Quarantine E2E Test Issues From Production Issue Tracker

## Situation Assessment (read this first)

**The core of this feature is already implemented and merged on `main`.** `git diff main...HEAD --stat` is empty, `scripts/lib/issue-quarantine.sh` (VERSION 3.3.0) exists with all five public functions, `scripts/sw-lib-issue-quarantine-test.sh` passes 21/21, config defaults are in `config/defaults.json`, and `sw-e2e-integration-test.sh` creates its label idempotently and asserts it lands on the issue.

So this plan is **not** a greenfield build. It closes the gaps between what CLAUDE.md claims and what the code actually does.

What already works:

| Piece | Status |
|---|---|
| `lib/issue-quarantine.sh` — 5 functions, fail-open | Done |
| `config/defaults.json` → `labels.e2e_test`, `labels.quarantine` | Done |
| E2E suite labels + asserts its synthetic issue | Done |
| Filtered: daemon poll, triage score, triage audit, triage unlabeled (server-side), strategic titles ×2, strategic analysis ×3 | Done (9 sites) |
| Unit test suite, registered in `package.json` | Done |

What is **not** done — the actual scope of this issue:
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Quarantine E2E Test Issues From Production Issue Tracker
## Context
## Decision
### Component decomposition
### Interface contracts
### Data flow
### Error boundaries
### The one contract change: loading is not filtering
# shellcheck source=./issue-quarantine.sh
## Alternatives Considered
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
      "file": "failures.json",
      "relevance": 90,
      "summary": "Contains specific E2E integration test failures and pipeline artifact issues; directly documents quarantine-related challenges like stale pipeline locks and E2E test setup problems"
    },
    {
      "file": "success-patterns.json",
      "relevance": 52,
      "summary": "Captures successful build patterns with test strategies (npm test) and iteration counts; provides data on effective approaches for complex fixes like this one"
    },
    {
      "file": "knowledge.json",
      "relevance": 42,
      "summary": "Documents test infrastructure failures and fixes (mktemp issues, sw-cleanup.sh); relevant to E2E test isolation setup and cleanup logic"
    },
    {
      "file": "patterns.json",
      "relevance": 38,
      "summary": "Project metadata showing node/vitest configuration; establishes conventions for test patterns and package management relevant to E2E test framework"
    },
    {
      "file": "issues.json",
      "relevance": 28,
      "summary": "Recorded issue resolution patterns (timeout bug fixes, semaphore approaches); provides context on build-stage problem-solving techniques"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Quarantine E2E Test Issues From Production Issue Tracker — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Quarantine E2E Test Issues From Production Issue Tracker

## Implementation Checklist
- [ ] Task 1: Fix broken `source` fallback in `lib/daemon-poll-github.sh:7`; remove the error-swallowing `|| true`
- [ ] Task 2: Source `issue-quarantine.sh` in the consumer scripts lacking it
- [ ] Task 3: Filter `sw-decide.sh:66` dedup query
- [ ] Task 4: Filter `sw-autonomous.sh` dedup searches (3 sites)
- [ ] Task 5: Filter `lib/root-cause.sh:188` error-signature dedup (add `--json number,labels`)
- [ ] Task 6: Filter `sw-patrol-meta.sh:44` and `sw-strategic.sh:655` title dedup
- [ ] Task 7: Filter `lib/daemon-triage.sh:463` triage score fetch
- [ ] Task 8: Filter `sw-release-manager.sh:166` blocker count
- [ ] Task 9: Convert `lib/fleet-failover.sh:25` to `quarantine_search_qualifier` with empty-guard
- [ ] Task 10: Audit every modified site for `labels` in the `--json` field list
- [ ] Task 11: Add `shipwright triage quarantine list|apply` with dry-run default
- [ ] Task 12: Add quarantine validation section to `sw-doctor.sh`
- [ ] Task 13: Apply quarantine label in `sw-tracker-providers-test.sh`
- [ ] Task 14: Add regression test — library loads with `SCRIPT_DIR` unset — plus backfill-selector tests
- [ ] Task 15: Correct consumption-site count and consumer list in `.claude/CLAUDE.md`
- [ ] `lib/daemon-poll-github.sh` sources the library by self-relative path; a regression test proves it loads with `SCRIPT_DIR` unset
- [ ] All previously-unfiltered consumers filter quarantined issues; every one requests `labels` in its `--json` fields
- [ ] Every new filter site is fail-open: malformed JSON yields unfiltered input and exit 0, verified by test
- [ ] `shipwright triage quarantine list` reports unlabeled synthetic issues; `apply` is dry-run unless `--apply` is passed
- [ ] `shipwright doctor` reports quarantine config health

## Context
- Pipeline: autonomous
- Branch: ci/issue-1303
- Issue: none
- Generated: 2026-08-07T11:52:33Z"
iteration: 1
max_iterations: 20
status: error
test_cmd: "npm test"
model: haiku
agents: 1
started_at: 2026-08-07T12:49:09Z
last_iteration_at: 2026-08-07T12:49:09Z
consecutive_failures: 0
total_commits: 1
audit_enabled: true
audit_agent_enabled: true
quality_gates_enabled: true
dod_file: "/home/runner/work/shipwright/shipwright/.claude/pipeline-artifacts/dod.md"
auto_extend: true
extension_count: 0
max_extensions: 3
---

## Log

