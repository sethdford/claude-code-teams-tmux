---
goal: "Test Failure Git Bisection Tool with Automatic Root Cause Identification

## Plan Summary
# Implementation Plan: Test Failure Git Bisection Tool with Automatic Root Cause Identification

## Summary

Add `shipwright bisect` — a new command that, given a failing test command, drives
`git bisect run` to find the first bad commit that introduced a test failure, then
feeds the culprit commit's diff + failure output into the existing
`scripts/lib/root-cause.sh` classifier to produce an automatic root-cause verdict
(category, confidence, evidence, suggested fix). Output is a human-readable report
plus a machine-readable JSON artifact for downstream pipeline stages.

This is a **new standalone bash command** following the established
`scripts/sw-<name>.sh` + router + test-suite pattern. It **reuses** existing
infrastructure (`root-cause.sh`, `helpers.sh`, `compat.sh`, `emit_event`) rather
than building new classification logic — that "automatic root cause identification"
half already lives in the repo (`rootcause_classify`, `rootcause_suggest_fix`).

---

## Design Reasoning (Socratic Refinement)
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Test Failure Git Bisection Tool with Automatic Root Cause Identification
## Context
## Decision
### Component Diagram
### Interface Contracts
### Data Flow
### Error Boundaries
## Alternatives Considered
## Implementation Plan
## Validation Criteria
[... full design in .claude/pipeline-artifacts/design.md]

## Specification: Test Failure Git Bisection Tool with Automatic Root Cause Identification

### Goals
- Test Failure Git Bisection Tool with Automatic Root Cause Identification

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "knowledge.json",
      "relevance": 95,
      "summary": "Contains failure patterns with error signatures, fix strategies, and approaches. Directly applicable to root cause identification—tracks occurrences, success rates, and timestamps for test failures like mktemp errors."
    },
    {
      "file": "success-patterns.json (main repo)",
      "relevance": 78,
      "summary": "Documents successful build patterns with complexity, iteration count, files changed, and test strategy. Shows proven approaches for 'Fix bug' (60 complexity, 3 iterations) and feature work—useful for understanding what working builds look like."
    },
    {
      "file": "issues.json",
      "relevance": 72,
      "summary": "Records specific issues with outcomes and gotchas (e.g., 'Fix timeout bug in daemon' with 'check backoff' gotcha). Provides concrete examples of diagnosed and fixed failures with success patterns."
    },
    {
      "file": "patterns.json",
      "relevance": 61,
      "summary": "Project conventions: test runner (vitest), source dir (src/), import style (commonjs). Contextual for understanding the build environment and test strategy expectations."
    },
    {
      "file": "metrics.json",
      "relevance": 48,
      "summary": "Baseline metrics show historical build_duration_s (2089s). Useful for detecting regressions or unusual timing, but indirect relevance to root cause identification."
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Test Failure Git Bisection Tool with Automatic Root Cause Identification — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Test Failure Git Bisection Tool with Automatic Root Cause Identification

## Implementation Checklist
- [ ] Task 1: Scaffold `scripts/sw-bisect.sh` header, VERSION, lib sourcing + fallbacks
- [ ] Task 2: Implement argument parser (`--good/--bad/--test-cmd/--json/--no-classify/-h`)
- [ ] Task 3: Implement pre-flight guards (git repo, dirty tree, ancestry, capture branch)
- [ ] Task 4: Install EXIT/INT/TERM trap that runs `git bisect reset` + branch restore
- [ ] Task 5: Generate atomic exit-code-mapping bisect wrapper script
- [ ] Task 6: Drive `git bisect start` + `git bisect run`, parse first-bad-commit SHA
- [ ] Task 7: Collect culprit metadata + capped diff
- [ ] Task 8: Integrate `root-cause.sh` classification + fix suggestion
- [ ] Task 9: Write `bisect-result.json` atomically with `jq -n --arg`
- [ ] Task 10: Human-readable boxed report + `--json` mode
- [ ] Task 11: `emit_event` observability + optional memory capture
- [ ] Task 12: Add `bisect)` router case + help text in `scripts/sw`
- [ ] Task 13: Write `scripts/sw-bisect-test.sh` with real-git repo fixture
- [ ] Task 14: Register test in `package.json`, update `.claude/CLAUDE.md`
- [ ] Task 15: `shellcheck` + `bash -n` + run suite; keep VERSION synced
- [ ] `shipwright bisect --good <ref> --bad <ref> --test-cmd "<cmd>"` finds the first
- [ ] Working tree and branch are restored on success, failure, AND interrupt.
- [ ] `.claude/pipeline-artifacts/bisect-result.json` written atomically with a valid
- [ ] Dirty-tree and non-git inputs rejected with actionable errors.
- [ ] `scripts/sw-bisect-test.sh` passes and is registered in `package.json`.

## Context
- Pipeline: autonomous
- Branch: ci/issue-726
- Issue: none
- Generated: 2026-07-03T14:47:59Z"
iteration: 1
max_iterations: 20
status: error
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-07-03T14:54:03Z
last_iteration_at: 2026-07-03T14:54:03Z
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

