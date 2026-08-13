---
goal: "Add Unit Test Suites for the 5 Untested Core Scripts

## Plan Summary
# Plan: Add Unit Test Suites for the 5 Untested Core Scripts

## Which 5 scripts, and how they were identified

Derived mechanically, not guessed:

```bash
ls scripts/*.sh | grep -v -- '-test.sh' | sed 's|scripts/||;s|\.sh$||' | sort > all
ls scripts/*-test.sh          | sed 's|scripts/||;s|-test\.sh$||' | sort > tested
comm -23 all tested            # candidates
# then: grep -rl "<name>" scripts/*-test.sh   → 0 hits = genuinely untested
```

That leaves 14 candidates. Nine are release/install tooling (`build-release`,
`update-version`, `check-version-consistency`, `install-*`, `update-homebrew-sha`,
`test-skill-injection`) or already covered indirectly (`sw-tracker-{github,jira,linear}`
are exercised by `sw-tracker-providers-test.sh` and `sw-tracker-test.sh` — 2 hits each).

The 5 **core** scripts with **zero** test references anywhere:
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Architecture Decision Record: Add Unit Test Suites for 5 Untested Core Scripts
## Context
## Decision
### Component Architecture
## Interface Contracts
### Test Helper Library (`scripts/lib/test-helpers.sh`)
# Setup/Teardown
# Assertions (return 0 on pass, 1 on fail; print to stdout/stderr)
# Mocking
# Reporting
[... full design in .claude/pipeline-artifacts/design.md]

## Specification: Add Unit Test Suites for the 5 Untested Core Scripts

### Goals
- Add Unit Test Suites for the 5 Untested Core Scripts

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "success-patterns.json (test-repo)",
      "relevance": 85,
      "summary": "Pattern shows TDD approach with unit + integration test strategy for feature work, includes test file modifications (test/auth.test.ts). Directly applicable to writing test suites."
    },
    {
      "file": "success-patterns.json (test-repo-ranking)",
      "relevance": 78,
      "summary": "Two patterns with test.sh file patterns, build stage execution, and npm test strategy. Shows successful low-complexity test script modifications."
    },
    {
      "file": "index.json",
      "relevance": 72,
      "summary": "Contains test_failure pattern in build stage with timeout fix. Directly relevant to build stage issues and test execution in this pipeline context."
    },
    {
      "file": "success-patterns.json (test-repo-corrupt)",
      "relevance": 68,
      "summary": "Two patterns with test.sh file changes in build stage, low complexity, npm test strategy. Shows successful test script writing patterns."
    },
    {
      "file": "success-patterns.json (hash-consistency-repo)",
      "relevance": 62,
      "summary": "Pattern shows test.sh modification in build stage with npm test strategy. Relevant for understanding test script development in this repo context."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Add Unit Test Suites for the 5 Untested Core Scripts — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Add Unit Test Suites for the 5 Untested Core Scripts

## Implementation Checklist
- [ ] Task 1: Reproduce the 5-script selection; capture `SW_TEST_REPORT` baseline TSV
- [ ] Task 2: Read `lib/test-helpers.sh`; pin exact assertion signatures
- [ ] Task 3: `scripts/shipwright-file-suggest-test.sh` — 8 cases, fixture tree + mock git
- [ ] Task 4: `scripts/sw-tmux-role-color-test.sh` — table-driven role→color, recorder tmux mock
- [ ] Task 5: `scripts/sw-tmux-status-test.sh` — stage colors/icons, heartbeat freshness, dispatch
- [ ] Task 6: `scripts/sw-event-schema-sync-test.sh` — drift/sync/`--write`, isolated fixture repo
- [ ] Task 7: `scripts/sw-test-all-test.sh` — discovery, filter, timeout, TSV report, process-group kill
- [ ] Task 8: `chmod +x` all five; shellcheck clean
- [ ] Task 9: Run each new suite individually via `--pattern`
- [ ] Task 10: Full `npm test`; suite count +5; zero regressions vs baseline TSV
- [ ] Task 11: `shipwright docs sync` to refresh `AUTO:test-suites`
- [ ] Task 12: `git status` clean of fixtures and unintended tracked-file edits
- [ ] Five new `scripts/*-test.sh` files exist, executable, one per target script
- [ ] Each has ≥8 assertions covering happy path, error path, and at least one edge case
- [ ] Each exits 0 with `FAIL: 0` on both macOS and Linux CI
- [ ] Each completes in <30s (well under the 300s watchdog)
- [ ] `bash scripts/sw-test-all.sh --list` includes all five with no `package.json` change
- [ ] `npm test` green; total suite count is exactly baseline + 5
- [ ] No pre-existing suite changed status vs the baseline TSV
- [ ] `git status` clean after two consecutive full runs — no fixture leakage,

## Context
- Pipeline: autonomous
- Branch: ci/issue-1714
- Issue: none
- Generated: 2026-08-13T21:51:19Z"
iteration: 0
max_iterations: 20
status: running
test_cmd: "npm test"
model: haiku
agents: 1
started_at: 2026-08-13T21:55:06Z
last_iteration_at: 2026-08-13T21:55:06Z
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

