---
goal: "Semantic Issue Clustering Engine for Pattern Reuse Across Pipelines

## Plan Summary
# Implementation Plan: Semantic Issue Clustering Engine for Pattern Reuse Across Pipelines

## Current State Assessment (grounded in codebase, not assumptions)

This feature is **already ~95% implemented** by commits `316ba8b0` and `c1e984d5` on branch `ci/issue-672`. Before planning new work, I verified what actually exists in the tree:

| Component | File | Status |
|-----------|------|--------|
| Clustering algorithm (TF-IDF, cosine, agglomerative) | `src/issue-clustering.js` (553 lines) | ✅ Done |
| Bash orchestrator (run/match/show/status/metrics/due) | `scripts/sw-issue-clustering.sh` (308 lines) | ✅ Done |
| Test suite (23 tests + node unit tests) | `scripts/sw-issue-clustering-test.sh`, `tests/issue-clustering.test.js` | ✅ Passing (23/0) |
| CLI router registration (`clustering`/`cluster`) | `scripts/sw:438` | ✅ Done |
| `npm test` registration | `package.json:39` | ✅ Done |
| Event schema (4 clustering events) | `config/event-schema.json:491-510` | ✅ Done |
| Config block | `.claude/daemon-config.json:56` | ✅ Done |
| Documentation | `.claude/CLAUDE.md` ("Issue Clustering Engine" section) | ✅ Done |
| **Daemon weekly re-clustering during quiet periods** | `scripts/lib/daemon-poll.sh` | ❌ **MISSING** |

**The one real gap:** `.claude/CLAUDE.md` states *"The daemon re-clusters weekly during quiet periods when `clustering.enabled` is true; the `due` check enforces `clustering.re_cluster_interval_days`."* A `grep` for `clustering` across `scripts/sw-daemon.sh` **and** `scripts/lib/daemon-poll.sh` returns **nothing**. The `clustering due` and `clustering run` subcommands exist and are tested, but nothing in the daemon ever calls them. The documented behavior is unimplemented — this is the WIP gap reflected in commit `8d1077be`.
[... full plan in .claude/pipeline-artifacts/plan.md]

## Key Design Decisions
# Design: Semantic Issue Clustering Engine for Pattern Reuse Across Pipelines
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

## Specification: Semantic Issue Clustering Engine for Pattern Reuse Across Pipelines

### Goals
- Semantic Issue Clustering Engine for Pattern Reuse Across Pipelines

### Acceptance Criteria
- [testable] All existing tests continue to pass

Historical context (lessons from previous pipelines):
{
  "results": [
    {
      "file": "success-patterns.json",
      "relevance": 95,
      "summary": "Contains detailed patterns from recent successful builds in this repo (2026-03-29) with iterations, file changes, test strategies, durations, and costs—directly applicable for understanding how builds complete in this codebase"
    },
    {
      "file": "patterns.json",
      "relevance": 90,
      "summary": "Shows current project configuration (Node.js, vitest, src/ directory, commonjs imports) captured 2026-06-19—essential context for build environment and conventions"
    },
    {
      "file": "knowledge.json",
      "relevance": 70,
      "summary": "Contains failure patterns from recent test runs in this repo including mktemp issues, sw-cleanup.sh heartbeat problems, and regression detection failures—directly relevant to anticipated build blockers"
    },
    {
      "file": "failures.json",
      "relevance": 65,
      "summary": "Recent test failures (last seen 2026-06-19) including sw-cleanup.sh output format and template validation issues—informs what commonly breaks in test stage and how to fix"
    },
    {
      "file": "metrics.json",
      "relevance": 55,
      "summary": "Shows baseline build duration of 2089 seconds (last updated 2026-05-15)—helps calibrate time expectations for the current build iteration"
    }
  ]
}

Discoveries from other pipelines:
✓ Injected 1 new discoveries
[design] Design completed for Semantic Issue Clustering Engine for Pattern Reuse Across Pipelines — Resolution: 

Task tracking (check off items as you complete them):
# Pipeline Tasks — Semantic Issue Clustering Engine for Pattern Reuse Across Pipelines

## Implementation Checklist
- [ ] Task 1: Confirm quiet-period insertion point and config-access (`policy_get`) pattern in `scripts/lib/daemon-poll.sh`.
- [ ] Task 2: Add `clustering.enabled` read (default `false`).
- [ ] Task 3: Insert `due`→`run` block with `|| daemon_log WARN` guards and an INFO log line.
- [ ] Task 4: Add `[[ -x "$SCRIPT_DIR/sw-issue-clustering.sh" ]]` guard; verify path resolution.
- [ ] Task 5: Bump `VERSION` in `scripts/sw-daemon.sh` to match `package.json`.
- [ ] Task 6: Add daemon poll test asserting enabled→invoked / disabled→skipped via mock binary.
- [ ] Task 7: `bash scripts/sw-issue-clustering-test.sh` stays 23/0.
- [ ] Task 8: `bash scripts/sw-daemon-test.sh` (+ `sw-lib-daemon-poll-test.sh`) green.
- [ ] Task 9: `bash -n` lint on modified scripts; confirm no bash 4 constructs.
- [ ] Task 10: `shipwright docs check` reports no newly-stale sections.
- [ ] Task 11: Smoke: `clustering.enabled=true`, `re_cluster_interval_days=0`, quiet state → assert `clustering.completed` appears in `events.jsonl`.
- [ ] `scripts/lib/daemon-poll.sh` invokes `clustering due`→`run` during quiet periods only when `clustering.enabled=true`.
- [ ] Disabled (default) path adds zero external calls — verified by test.
- [ ] A clustering failure logs a WARN and the poll loop continues (no crash under `set -euo pipefail`).
- [ ] `scripts/sw-issue-clustering-test.sh` passes 23/0 (no regression).
- [ ] New daemon test passes; daemon test suites green.
- [ ] `VERSION` in `sw-daemon.sh` matches `package.json`.
- [ ] `shipwright docs check` clean; documented daemon behavior now matches code.
- [ ] `git grep clustering scripts/lib/daemon-poll.sh` shows the new wiring (gap closed).

## Context
- Pipeline: autonomous
- Branch: ci/issue-672
- Issue: none
- Generated: 2026-06-19T14:12:04Z"
iteration: 0
max_iterations: 20
status: running
test_cmd: "npm test"
model: opus
agents: 1
started_at: 2026-06-19T14:16:05Z
last_iteration_at: 2026-06-19T14:16:05Z
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

