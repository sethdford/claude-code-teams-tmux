---
goal: "Cache intelligence-layer GraphQL contributor/blame lookups across pipeline stages within a single run

## Plan Summary
Plan written to `.claude/pipeline-artifacts/plan.md` (278 lines).

## Key finding that reframes the goal

`scripts/sw-github-graphql.sh` **already has** a TTL disk cache at `~/.shipwright/github-cache` shared across stage subprocesses — so "add caching" is partly done. The real gaps I found by reading the code:

1. **No negative caching** — `gh_blame_data:305` and `gh_contributors:349` only call `_gh_cache_set` on success. Every failed lookup (no auth, rate limit, private repo) re-issues the full GraphQL query in *every* stage. And `sw-intelligence.sh:1322` swallows it with `|| echo "[]"`, so files silently score as low-risk.
2. **TTLs are wall-clock, not run-scoped** — change-frequency TTL is 3600s but the recorded `build_duration_s` baseline is 8506s. A run crosses the TTL mid-flight, so `review` re-fetches what `plan` fetched *and can see different data*. That's a consistency bug, not just cost.
3. **Per-file fan-out, no prewarm** — one round-trip per path, called from two different intelligence functions.

## Chosen approach

A **run-pinned overlay** on the existing cache: when `SW_GH_CACHE_RUN_ID` is set (exported once from `SHIPWRIGHT_PIPELINE_ID`, inherited by every stage subprocess), keys written during the run are recorded in a per-run manifest and read back ignoring TTL. Plus negative caching, in-process memoization, and a capped `gh_cache_prewarm` at intake.

Rejected: a separate per-run cache dir (worse for the daemon — loses reuse between back-to-back issues), and exporting a JSON blob into artifacts (changes every caller instead of the one choke point).

Behaviour is byte-identical when `SW_GH_CACHE_RUN_ID` is unset — which it is in all 102 existing suites, protecting the one criterion `spec.json` carries.

The plan covers the mandated sections: 13-task decomposition with explicit blocking edges, risk table, testable DoD, two alternatives with trade-offs, and four failure modes. The most critical (concurrent worktree pipelines sharing one cache dir) is addressed in implementation steps 3–4 via per-run manifests with duplicate-tolerant, lock-free appends.
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Cache intelligence-layer GraphQL contributor/blame lookups across pipeline stages within a single run
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

## Specification: Cache intelligence-layer GraphQL contributor/blame lookups across pipeline stages within a single run

### Goals
- Cache intelligence-layer GraphQL contributor/blame lookups across pipeline stages within a single run

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "retry-outcomes.json",
      "relevance": 92,
      "summary": "Direct build failure recovery data showing model_escalation strategy with 100% success rate across 5 attempts; directly applicable to build stage optimization and resilience"
    },
    {
      "file": "success-patterns.json (f4af3e2a/0bcf0637)",
      "relevance": 88,
      "summary": "Captured successful build patterns with iteration counts, durations (45-150s), cost metrics, and file change profiles; provides proven build stage approaches and cost baselines"
    },
    {
      "file": "metrics.json",
      "relevance": 82,
      "summary": "Build duration baseline (7095s) and test duration baseline (1459s) provide performance targets for understanding current build stage efficiency relative to historical performance"
    },
    {
      "file": "failures.json (detailed multi-stage)",
      "relevance": 76,
      "summary": "Extensive test-stage failure patterns (57-127 PASS/FAIL counts, flaky test signatures, timeout issues) inform build stage quality gates and regression detection; cache lookups reduce redundant test execution"
    },
    {
      "file": "knowledge.json",
      "relevance": 70,
      "summary": "Failure patterns with fix strategies (mktemp issues, JSON output validation, test environment setup) provide build robustness learnings; pattern metrics show what fixes succeed most consistently"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Cache intelligence-layer GraphQL contributor/blame lookups across pipeline stages within a single run — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Cache intelligence-layer GraphQL contributor/blame lookups across pipeline stages within a single run

## Implementation Checklist
- [ ] Given one pipeline run, each distinct `blame_<owner>_<repo>_<path>` and
- [ ] A failed/empty contributor or blame lookup is cached and not retried within the run.
- [ ] A cache entry whose wall-clock TTL expired mid-run still hits while the run pin is
- [ ] With `SW_GH_CACHE_RUN_ID` unset, cache behaviour is byte-identical to today.
- [ ] `gh_cache_prewarm` returns 0 and issues zero network calls under `NO_GITHUB=true`.
- [ ] Run manifests older than 24h are reaped; `shipwright github cache clear` removes them.
- [ ] New tests added to `sw-github-graphql-test.sh`; **all existing suites still pass**
- [ ] `shellcheck` clean; bash 3.2 compatible (no `declare -A`, no `readarray`, no `${var,,}`).
- [ ] `shipwright version check` passes; `.claude/CLAUDE.md` env-var table updated.

## Context
- Pipeline: autonomous
- Branch: ci/issue-4430
- Issue: none
- Generated: 2026-09-07T04:13:15Z"
iteration: 0
max_iterations: 20
status: running
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-09-07T04:17:28Z
last_iteration_at: 2026-09-07T04:17:28Z
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

